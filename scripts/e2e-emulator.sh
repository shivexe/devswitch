#!/bin/bash
# Repeatable E2E run on the devswitch-test emulator against the fake Mac in scripts/e2e/main.swift
# (real mac/ Controller + HTTPServer + FileChannel on port 45990; the phone reaches it at 10.0.2.2).
# Every adb call targets emulator-5554 only. Prints PASS/FAIL per feature; exit 1 if any FAIL.
# Env: SKIP_BUILD=1 reuses the existing debug APK.
set -u
cd "$(dirname "$0")/.."
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
SERIAL=emulator-5554
PKG=com.himphen.playground.developeroptionstoggle
STATE="$PWD/scripts/e2e/.state"          # test pairing key + logs; gitignored
LOG="$STATE/harness.log"
mkdir -p "$STATE"
E() { adb -s "$SERIAL" "$@"; }
results=()
record() { results+=("$1 $2${3:+ ($3)}"); echo "$1 $2${3:+ ($3)}"; }
# wait_log <pattern> <seconds>: waits for a new harness log line (after mark) matching an extended regex.
mark() { MARK=$(wc -l < "$LOG"); }
wait_log() { local end=$((SECONDS + $2)); while ((SECONDS < end)); do tail -n +"$((MARK + 1))" "$LOG" | grep -Eq "$1" && return 0; sleep 0.5; done; return 1; }
command_() { local f="$STATE/$(date +%s)-$RANDOM.cmd"; printf '%s' "$1" > "$f.tmp" && mv "$f.tmp" "$f"; }
receipt_ok() { local id; wait_log "ENQUEUE [0-9a-f-]+ $1\$" 5 || return 1
  id=$(tail -n +"$((MARK + 1))" "$LOG" | grep -E "ENQUEUE [0-9a-f-]+ $1\$" | tail -1 | awk '{print $3}')
  wait_log "RECEIPT $id ok=true" "${2:-15}"; }
texts() { E shell uiautomator dump /sdcard/e2e-ui.xml >/dev/null 2>&1; E exec-out cat /sdcard/e2e-ui.xml | grep -o '\(text\|content-desc\)="[^"]\+"[^>]*bounds="[^"]*"' |
  sed -E 's/^(text|content-desc)="([^"]*)".*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\2|\3|\4|\5|\6/'; }
tap() { local line; line=$(texts | grep -F "$1" | head -1); [ -n "$line" ] || return 1
  IFS='|' read -r _ x1 y1 x2 y2 <<<"$line"; E shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2)); sleep 1.5; }

# 1. Emulator: share a running one, boot ours otherwise (and only then shut it down at the end).
EMU_PID=""
if ! adb devices | grep -q "^$SERIAL"; then
  "$ANDROID_HOME/emulator/emulator" -avd devswitch-test -no-snapshot-save -no-boot-anim > "$STATE/emulator.log" 2>&1 &
  EMU_PID=$!
fi
for _ in $(seq 1 90); do
  [ "$(E get-state 2>/dev/null)" = device ] && [ "$(E shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break; sleep 2
done
if [ "$(E get-state 2>/dev/null)" != device ]; then
  record FAIL emulator "adb state: $(adb devices | awk -v s=$SERIAL '$1==s {print $2}')"
  [ -n "$EMU_PID" ] && kill "$EMU_PID"
  exit 1
fi
record PASS emulator

# 2. Build + install (emulator only) + grants.
if [ "${SKIP_BUILD:-}" != 1 ]; then ./gradlew -q :app:assembleDebug || { record FAIL build; exit 1; }; fi
E install -r -g app/build/outputs/apk/debug/app-debug.apk >/dev/null || { record FAIL install; exit 1; }
[ -f "$STATE/phone.json" ] || E shell pm clear "$PKG" >/dev/null   # a new harness key: drop any older pairing (grants follow)
for p in RECEIVE_SMS SEND_SMS READ_PHONE_STATE READ_CALL_LOG READ_CONTACTS ANSWER_PHONE_CALLS POST_NOTIFICATIONS; do
  E shell pm grant "$PKG" "android.permission.$p" 2>/dev/null; done
E shell cmd notification allow_listener "$PKG/$PKG.remote.NotifListener" >/dev/null 2>&1
E shell cmd notification allow_dnd "$PKG" >/dev/null 2>&1
E shell dumpsys deviceidle whitelist "+$PKG" >/dev/null 2>&1
record PASS install

# 3. Fake Mac.
HARNESS="$STATE/fakemac"
swiftc -wmo -swift-version 5 -Xfrontend -disable-access-control \
  $(printf 'mac/%s.swift ' Controller HTTPServer Crypto ProtocolV2 FileChannel LocalNetwork ScreenControl Dependencies BonjourDiscovery) \
  scripts/e2e/main.swift -o "$HARNESS" 2>/dev/null || { record FAIL harness-build; exit 1; }
rm -f "$STATE"/*.cmd; : > "$LOG"
"$HARNESS" "$STATE" >> "$LOG" 2>&1 &
HARNESS_PID=$!
cleanup() { kill "$HARNESS_PID" 2>/dev/null; E emu gsm cancel 9876543210 >/dev/null 2>&1; [ -n "$EMU_PID" ] && kill "$EMU_PID"; }
trap cleanup EXIT
MARK=0; wait_log "LISTENING" 10 || { record FAIL harness "$(tail -2 "$LOG")"; exit 1; }

# 4. Pair: reuse scripts/e2e/.state/phone.json when the app still holds that pairing; else paste the invitation.
mark
E shell am start -n "$PKG/.MainActivity" >/dev/null
if [ -f "$STATE/invitation.json" ]; then
  sleep 2
  # "|" ends the text field in texts(), so "Connect|" matches the button only. jq -c drops Swift's "\/" escapes.
  tap "Pair with your Mac" && tap "Paste invitation instead" && tap "From Copy Invitation" &&
    E shell input text "'$(jq -c . "$STATE/invitation.json" | sed 's/ /%s/g')'" && tap "Connect|"
  wait_log "APPROVED" 30 && record PASS pair || { record FAIL pair "$(texts | cut -d'|' -f1 | tr '\n' ' ')"; exit 1; }
fi
wait_log "STATUS online=" 30 && record PASS poll || { record FAIL poll "no v2 poll in 30 s"; exit 1; }

# 5. Features. Each one is independent; a missing feature just FAILs its row.
mark; E emu sms send AXHDFCBK "123456 is your OTP for txn of Rs 2,499.00. Do not share." >/dev/null
wait_log "EVENT otp .*codeLen=6" 15 && record PASS sms-otp || record FAIL sms-otp "no otp event"

mark; E shell cmd notification post -S bigtext -t Alice "e2e-$$" "'Hello from emu'" >/dev/null
wait_log "EVENT notification .*pkg=com.android.shell" 15 && record PASS notification || record FAIL notification "not mirrored"
# `cmd notification` has no cancel; a snooze removes the notification (reason SNOOZED) the same way for the listener.
mark; E shell cmd notification snooze --for 3600000 "'$(E shell cmd notification list | grep -F "|com.android.shell|2020|e2e-$$|" | tr -d '\r' | head -1)'" >/dev/null 2>&1
wait_log "EVENT notificationRemoved" 15 && record PASS notification-removed || record FAIL notification-removed

mark; E emu gsm call 9876543210 >/dev/null
if wait_log "EVENT call .*state=ringing" 15; then
  record PASS call-ringing; mark; command_ '{"a":"declineCall"}'
  if receipt_ok declineCall 15 && sleep 2 && ! E emu gsm list | grep -q 9876543210; then record PASS call-decline; else record FAIL call-decline "$(E emu gsm list | head -1)"; fi
else record FAIL call-ringing; record FAIL call-decline "no ringing event"; fi
E emu gsm cancel 9876543210 >/dev/null 2>&1

mark; command_ '{"a":"ring"}'
receipt_ok ring && record PASS ring || record FAIL ring "no ok receipt"
mark; command_ '{"a":"stopRing"}'
receipt_ok stopRing && record PASS stop-ring || record FAIL stop-ring

mark; command_ '{"a":"sendSms","to":"15555215554","body":"DevSwitch E2E"}'
if receipt_ok sendSms 20; then wait_log "EVENT smsStatus .*result=" 20 && record PASS send-sms || record FAIL send-sms "receipt ok, no smsStatus"
else record FAIL send-sms "no ok receipt"; fi

share() { E shell am start -W -a android.intent.action.SEND "$@" -n "$PKG/.remote.ShareToMacActivity" >/dev/null; sleep 2; tap "Send|"; }
mark; share -t text/plain --es android.intent.extra.TEXT "'https://example.com/e2e'"
wait_log "EVENT link .*url=https://example.com/e2e" 15 && record PASS link-share || record FAIL link-share

mark; share -t text/plain --es android.intent.extra.TEXT "'e2e clipboard text'"   # quoted for the device shell
wait_log "EVENT clipboard .*len=18" 15 && record PASS clipboard-to-mac || record FAIL clipboard-to-mac
mark; command_ '{"a":"setClipboard","text":"from mac e2e"}'
receipt_ok setClipboard && record PASS clipboard-to-phone || record FAIL clipboard-to-phone

# Mac→phone file: 3 chunks (600 KiB) into Downloads/DevSwitch. FileChannel enqueues the fileOffer itself, and its
# "Receiving" receipt only means the download started; the file is there once its bytes match.
MNAME="e2e-mac-$$.bin"; SRC="$STATE/$MNAME"; head -c 614400 /dev/urandom > "$SRC"
mark; command_ "offer $SRC"; got=""
if wait_log "RECEIPT [0-9a-f-]+ ok=true message=Receiving" 30; then
  for _ in $(seq 1 60); do E exec-out cat "/sdcard/Download/DevSwitch/$MNAME" 2>/dev/null | cmp -s - "$SRC" && { got=1; break; }; sleep 1; done
fi
[ -n "$got" ] && record PASS file-mac-to-phone || record FAIL file-mac-to-phone

# Phone→Mac file: share that received file back; FileChannel saves it to ~/Downloads. The app owns the MediaStore row, so
# no URI grant is needed (API 35 drops `am start --grant-read-uri-permission` grants from the shell: "holding WM lock").
ROW=$(E shell content query --uri content://media/external/downloads --projection _id:_display_name | grep "_display_name=$MNAME" | sed -E 's/.*_id=([0-9]+).*/\1/' | head -1)
if [ -n "$got" ] && [ -n "$ROW" ]; then
  mark; share -t application/octet-stream --eu android.intent.extra.STREAM "content://media/external/downloads/$ROW"
  if wait_log "file .* saved" 60 && cmp -s "$SRC" "$HOME/Downloads/$MNAME"; then record PASS file-phone-to-mac
  else record FAIL file-phone-to-mac "$(tail -n +"$((MARK + 1))" "$LOG" | grep -E 'fileOffer|file ' | tail -1)"; fi
  rm -f "$HOME/Downloads/$MNAME"
else record FAIL file-phone-to-mac "no received file to share back"; fi
E shell content delete --uri content://media/external/downloads --where "\"_display_name='$MNAME'\"" >/dev/null 2>&1; rm -f "$SRC"

echo; echo "E2E matrix:"; printf '  %s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q '^FAIL'
