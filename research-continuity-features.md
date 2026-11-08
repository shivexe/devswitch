# DevSwitch Continuity Features — Research

Date: 2026-11-07. Branch `persistent-wireless`. Target: iQOO Z6 Pro (Android 14) + macOS 27 + Helium browser.

Scope (this round): OTP (banner + copy + Helium autofill chip + auto-type), notification mirroring (all apps, mute list, dismiss, reply), phone status in menu bar, Find My Phone, Send SMS from Mac, incoming call alert, Send link to Mac, file drop (both ways), shared clipboard, full UI redesign.
Later: lock together, media controls, phone as webcam, hotspot, auto unlock.

## Decisions (after reviewing both research passes against the code)

| Area | Decision | Why |
|---|---|---|
| Transport | Keep 2 s poll. Protocol v2: phone `events[]` with ids, Mac `acks[]` + `commands[]` (≤16), per-command receipts. Interruptible wait so an event triggers an immediate poll; 500 ms while ringing / transferring / commands pending. Status sent only when changed. | Today: 1 command per reply, 32 KB cap per message (`Protocol.kt:48`), interrupting the 2 s sleep kills the loop (`RemoteService.kt:155`). |
| Replay cache | Raise the 500-in-120 s cap (`Controller.swift:136`). | Burst polling would get HTTP 409. |
| Files | Separate authenticated endpoint, 256 KiB AES-GCM chunks, resumable, quarantine xattr, saved to `~/Downloads`; Mac→phone via MediaStore Downloads. | Doesn't fit in 32 KB polls. |
| OTP source | NotificationListenerService (primary) + RECEIVE_SMS (backup), shared pure extractor, dedupe by code for 90 s. | Works on Android 14; Android 15+ redacts OTPs for non-companion listeners. |
| OTP on Mac | Banner without digits ("Code from HDFC Bank — copied"); digits only in HUD panel, Helium chip, and clipboard (concealed + transient types, cleared after 90 s). Optional auto-type hotkey via Accessibility. | macOS stores notification text on disk (usernoted DB). |
| Helium autofill | MV3 extension + native messaging host (DevSwitch binary relays to the running app over a Unix socket). Host manifest dir: `~/Library/Application Support/net.imput.helium/NativeMessagingHosts/`. Verify unpacked-extension persistence first. | No new network listener. |
| Signing | Stable self-signed identity via `DEVSWITCH_SIGN_IDENTITY`. | Ad-hoc re-signing resets Accessibility + Keychain grants every build. |
| Notifications | Mirror all except ongoing/FGS/group-summary/non-clearable/muted; icon sent once per app; per-app rate limit + coalescing; dismiss via `cancelNotification(key)`; inline reply via RemoteInput. Mute list synced Mac↔phone. | — |
| Find My Phone | Alarm-usage audio at max volume; DND access lets it ring through DND on Android 14. | — |
| Calls | Floating Mac panel with Decline (`endCall`, ANSWER_PHONE_CALLS) and Silence (best effort: mute ring stream, restore on idle). | `silenceRinger()` needs a system permission. |
| SMS | `SmsManager` with per-message SIM choice, sent/delivered receipts. Check Vivo Messages shows sent items. | — |
| Clipboard | Mac→phone automatic; phone→Mac needs one tap (share sheet / Quick Settings tile / notification action); skip concealed/password-manager types; 16 KB inline cap. | Android 10+ blocks background clipboard reads. |
| Service type | Foreground service `connectedDevice|remoteMessaging`; request battery-optimisation exemption. Add `ACCESS_LOCAL_NETWORK` for Android 17 devices. | `dataSync` is time-capped on 15+. |

## Open risks
1. Funtouch killing the app / dropping notification access.
2. Battery cost of 2 s polling with wake locks (measure on device).
3. Helium unpacked-extension persistence and native-host launch untested.
4. Pasteboard privacy prompts on future macOS (status on macOS 27 unverified).
5. Ad-hoc builds and time-sensitive notifications unverified (calls use a panel instead).

---

# Part A — Android research

# DevSwitch Android side: Continuity-like features research

Written 2026-11-07 against working tree on branch `persistent-wireless` (base commit `4f9ae3b`). Read-only; no repo files changed.

Legend: **[V]** verified against the cited source. **[U]** unverified (my knowledge, AOSP recall, or forum reports). Test it on a device before relying on it.

---

## 0. What the current code actually does (constraints every feature inherits)

| Fact | Where | Impact on new features |
|---|---|---|
| One worker thread runs `loop()`: build status, POST `/v1/poll`, read reply, execute a single `command`, then `Thread.sleep(2000)` | `RemoteService.kt` `loop()` | Event latency today is 0 to 2 s plus RTT. No way to wake the loop early. |
| The request and reply each carry **at most one** item: `status` plus one `receipt` going up, one `command` coming down | `RemoteService.kt`; `mac/Controller.swift:24,26` (`Reply.command: Command?`) | Notifications, OTPs and calls need an **outbox list** going up and a **command list (or repeat-poll)** coming down. |
| Payload cap is **32 KB** each way (`require(bytes.size <= 32768)`, `require(ciphertext.size <= 32768)`, response cap) | `Protocol.kt` `post`, `postLinkLocal`, `open` | Notification icons, long chats and files **cannot** go through `/v1/poll`. Files need a separate chunked endpoint. Batch events up to about 24 KB and loop immediately if more are queued. |
| A new TCP connection per poll (`Connection: close` on IPv6; `disconnect()` on IPv4) | `Protocol.kt` | Adds a handshake plus Wi-Fi radio work every 2 s. This is the main cheap optimisation. |
| `status()` re-runs `wireless.update()`/`pairingService.update()` plus 6 `Settings.Global` reads every tick | `RemoteService.kt:65-78` | Cheap, but send a status diff or hash instead of the full status when nothing changed. |
| PARTIAL_WAKE_LOCK renewed every 30 s after each authenticated reply, 60 s timeout | `renewConnectionWakeLock()` | The CPU stays awake for as long as the Mac is reachable. This dominates battery cost already. New features add little on top. |
| FGS type `connectedDevice` (+ `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `CHANGE_NETWORK_STATE` satisfies the prerequisite) | `AndroidManifest.xml` | OK for all features. Add `remoteMessaging` for notification/SMS relay (see §8). |
| Commands must be within the Mac's skew window (`expiresAt` within -30 s/+60 s) and are de-duplicated by `id` against the last `receipt` | `loop()` | Reuse this for the new commands (ring, sendSms, reply, dismiss, decline). |
| `targetSdk = 37`, `minSdk = 29`, `usesCleartextTraffic=true` | `build.gradle.kts`, manifest | On an **Android 17 device**, target-37 rules apply: `ACCESS_LOCAL_NETWORK`, the SMS OTP 3 h delay, and background-audio WIU (see §R). They do not apply on the iQOO (Android 14). |

Target device: iQOO Z6 Pro on Funtouch OS 14 / Android 14. It shipped with Android 12, and Android 14 is likely its last OS update **[U]**. So the Android 15/16/17 rules below matter only for portability. They are not blockers today.

---

## 1. OTP capture

### Options

| Approach | Perms / manifest | Android 14 (target device) | Android 15/16 | Android 17 | Verdict |
|---|---|---|---|---|---|
| **NotificationListenerService (NLS)** reading the SMS app's notification **and** any app's (bank apps, Gmail, WhatsApp) | `<service android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">` + intent-filter `android.service.notification.NotificationListenerService`; user enables Notification access | Works. Sees the full text. | OTP notifications from "untrusted" listeners are **redacted** **[V]** ([A15 all-apps](https://developer.android.com/about/versions/15/behavior-changes-all#otp-redaction)). Exempt: holders of `RECEIVE_SENSITIVE_NOTIFICATIONS` (signature\|preinstalled\|knownSigner\|role, **[V]** [Manifest.permission](https://developer.android.com/reference/android/Manifest.permission#RECEIVE_SENSITIVE_NOTIFICATIONS)) and "companion device manager associations" **[V]** (A15 page). Reported workaround: `adb shell appops set <pkg> RECEIVE_SENSITIVE_NOTIFICATIONS allow` **[U]** | Same as 15 | **Primary.** Covers SMS and app OTPs. |
| **`SMS_RECEIVED` broadcast** | `RECEIVE_SMS` (+ `READ_SMS` for history) runtime; manifest receiver with `android.provider.Telephony.SMS_RECEIVED`, `android:permission="android.permission.BROADCAST_SMS"` | Works immediately | Android 15 extends sideload "restricted settings" (ECM) to SMS permissions **[U, press]** ([Android Authority](https://androidauthority.com/android-15-restricted-settings-sideloading-3481098)) | **3 h delay** for OTP-looking messages: WebOTP/Retriever for all apps, and **standard SMS for apps targeting 37** (= DevSwitch). Exempt: default SMS, assistant, dialer, carrier, **"connected device companion apps"**, system, known-signer **[V]** ([A17 target-37](https://developer.android.com/about/versions/17/behavior-changes-17#sms-otp-protection), [Telephony.Sms](https://developer.android.com/reference/android/provider/Telephony.Sms)) | **Secondary/backup.** Most reliable on 14, and gives the true sender ID. |
| SMS Retriever API | Play services; needs the 11-char **app hash in the SMS** | — | — | — | **Unusable**: banks do not include our hash. |
| SMS User Consent API | Play services; shows a consent dialog that must be launched from an Activity | Needs a user tap on the phone for each OTP | — | — | **Unusable** for silent Mac delivery. |

**Future-proofing (Android 15+/17).** Both blockers exempt CDM "companion" associations. Associating the Mac via `CompanionDeviceManager` (Mac advertises BLE from CoreBluetooth, or Bluetooth-classic discovery) is the documented way to keep OTPs on newer Android **[V for exemption wording; U for whether a non-WATCH profile qualifies]**. The exact AOSP check (any association vs a profile such as `DEVICE_PROFILE_WATCH`) is unverified. Test it on an API 37 emulator before investing.

**Funtouch quirk [U].** Vivo/OPPO Messages apps have a "verification code protection" style setting that may hide OTP SMS from third-party apps or notifications. Check Messages → Settings on the device. The user can disable it.

### Restricted settings (sideload) [V for A13 baseline / U for exact UX]
- Android 13+ blocks Notification access and Accessibility for apps installed via a non-session installer (browser or file manager). Fix: App info → ⋮ → **Allow restricted settings**. Or bypass via adb (DevSwitch users have adb anyway):
  - `adb shell cmd notification allow_listener com.himphen.playground.developeroptionstoggle/.remote.NotifListener` **[U, AOSP NotificationShellCmd]**
  - `adb shell appops set com.himphen.playground.developeroptionstoggle ACCESS_RESTRICTED_SETTINGS allow` **[U]**
  - The app already holds `WRITE_SECURE_SETTINGS`, so it can append itself to `Settings.Secure "enabled_notification_listeners"` (a commonly used trick) **[U]**. Treat this as a fallback, not the main path.
  - `adb shell pm grant <pkg> android.permission.RECEIVE_SMS` (same for READ_SMS, READ_CONTACTS, READ_CALL_LOG, READ_PHONE_STATE, SEND_SMS, ANSWER_PHONE_CALLS) works for any runtime permission declared in the manifest **[U, standard]**.

### OTP extraction heuristic (implement as a pure Kotlin function so it is unit-testable)
1. Normalise: NFKC, map Devanagari, Bengali and other Indic digits to ASCII (`Character.getNumericValue`), collapse whitespace.
2. Keyword gate (case-insensitive, within about 40 chars of the candidate): `otp|one[- ]time (pass(word|code))|verification code|security code|auth(entication)? code|passcode|login code|code|pin|tac|ओटीपी|कोड|सत्यापन`.
3. Candidates: `\b[0-9]{4,8}\b`, plus alphanumeric forms seen in practice: `G-123456`, `123-456`, `AB12CD`. Only accept alphanumerics with at least 2 digits, and only when the keyword is adjacent.
4. Reject:
   - amounts preceded by `Rs|INR|₹|\$|USD|amt|amount` or containing `.`/`,` (`Rs 1,234.00`)
   - masked accounts or cards (`XX1234`, `*1234`, `a/c ...1234`, `ending 1234`)
   - dates and times (`12/11`, `10:45`, `2026`)
   - 10-digit numbers starting `[6-9]` (Indian mobiles) and toll-free numbers (`1800...`)
   - "valid for N min(s)" numbers
5. Score: closest to the keyword wins. Bonus if it follows `is|:|-|is your` or precedes `is your (otp|code)`. Bonus for length 6. Penalise numbers inside URLs.
6. Indian bank patterns to include as fixtures:
   - `123456 is your OTP for txn of Rs 2,499.00 at AMAZON on HDFC Bank card ending 4321. Valid for 10 mins. Do not share.`
   - `Dear Customer, OTP for login is 482913. Do not share it with anyone - SBI`
   - `Use 7712 as OTP to verify your mobile on Swiggy. -Swiggy`
   - `आपका OTP 551204 है। किसी के साथ साझा न करें।`
   - `G-839201 is your Google verification code.`
   - Amount-only messages with **no** keyword (`Rs 4500 debited`) must yield null.
7. Sender: DLT headers look like `AX-HDFCBK`, `VM-SBIOTP-S`, `JD-AMAZON-T`. Normalise by dropping the 2-letter operator prefix and the `-S/-T/-P/-G` suffix, so the Mac shows "HDFCBK".

### Dedupe (SMS broadcast and NLS both fire for one SMS)
- Key = `sha256(code + normalisedSender)`. Keep a 3-minute LRU (in-memory plus the last 20 in prefs to survive restarts). The NLS sees the Messages app as the package, with a contact name or number as the title, so compare **code only** across sources within 90 s. Different sender strings for the same SMS are expected.
- Send OTPs as a high-priority `type:"otp"` event with `{code, sender, app, receivedAt, source:"sms"|"notification"}`. Mark the clip `EXTRA_IS_SENSITIVE` if the Mac pushes it back to the phone clipboard.

---

## 2. Mirror all notifications with a per-app mute list

APIs **[V: [NotificationListenerService](https://developer.android.com/reference/android/service/notification/NotificationListenerService)]**: `onNotificationPosted(sbn, rankingMap)`, `onNotificationRemoved(sbn, rankingMap, reason)`, `getActiveNotifications()`, `cancelNotification(key)`, `requestRebind(ComponentName)` (static), `onListenerConnected/Disconnected`.

| Concern | Recommendation |
|---|---|
| Skip | `sbn.packageName == ownPackage`; `n.flags & (FLAG_ONGOING_EVENT or FLAG_FOREGROUND_SERVICE) != 0`; `FLAG_GROUP_SUMMARY` (send children, which carry the content; if the summary is the only one, e.g. Gmail collapsed, fall back to it); `!sbn.isClearable` (music, navigation, downloads); `category in {transport, progress, service, sys, call}` (calls go via §5); `ranking.importance <= IMPORTANCE_MIN`; muted packages (user list, stored in prefs; the Mac also edits it via a `setMute` command). |
| Payload | `extras.getCharSequence(EXTRA_TITLE)`, `EXTRA_TEXT`, `EXTRA_BIG_TEXT` (prefer if present), `EXTRA_SUB_TEXT`, `EXTRA_TEXT_LINES` (InboxStyle). MessagingStyle: `NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)` (androidx core, already a dependency) gives `conversationTitle`, `isGroupConversation`, and messages (sender name, text, timestamp). Send only messages newer than the last one forwarded for that `key`. Truncate text to about 1–2 KB. |
| App label/icon | `packageManager.getApplicationLabel(getApplicationInfo(pkg,0))`. On Android 11+ this needs package visibility: `QUERY_ALL_PACKAGES` (fine when sideloaded) or `<queries>` **[U whether NLS grants implicit visibility]**. Icon: render `getApplicationIcon(pkg)` to a 48×48 PNG (about 2–4 KB) and send it **once per package** (`iconHash`). The Mac caches it. Never put an icon in every event (32 KB cap). |
| Updates | The same `sbn.key` re-posts on every chat message. Use key + `n.`when`` + a text hash as the event id. Send `update` rather than new. |
| Dismiss sync | Phone→Mac: `onNotificationRemoved` → event `{type:"removed", key, reason}` (reasons such as `REASON_CANCEL`, `REASON_CLICK`, `REASON_APP_CANCEL`). Mac→phone: command `dismiss{key}` → `cancelNotification(key)`. Only clearable notifications can be cancelled **[V, doc]**. |
| Inline reply | Find `n.actions` whose `remoteInputs` is non-empty (or `NotificationCompat.getAction` with `SEMANTIC_ACTION_REPLY`). Expose `actionIndex` plus the remote input key to the Mac. On command `reply{key, actionIndex, text}`: build `Intent()`, `RemoteInput.addResultsToIntent(inputs, intent, Bundle().apply{putCharSequence(input.resultKey, text)})`, then `action.actionIntent.send(context, 0, intent)`. Keep a `key → Notification` map (the latest `sbn`) because the Mac only has the key. Background-activity-launch rules apply only if the PendingIntent targets an activity; most messengers use a broadcast or service **[V, [BAL doc](https://developer.android.com/guide/components/activities/background-starts)]**. Other actions ("Mark as read", "Decline") can be sent the same way. |
| Rate limiting | Per-package token bucket (for example 5 events per 10 s, burst 10). Coalesce updates on the same key within 1.5 s (send the latest only). Global outbox cap of 200 events (drop the oldest non-OTP and non-call events). The Mac acks by `eventId` in the reply. Events stay queued until acked, and are dropped after 5 min if the Mac is offline (except a "missed" summary). |
| Lifecycle | `onListenerDisconnected` → `requestRebind(ComponentName(this, NotifListener::class.java))`. The NLS runs in the same process as `RemoteService`. Pass events through a process-wide `Outbox` object, not IPC. The enabled NLS is bound by system_server, which also tends to keep the process alive **[U]**. |
| Funtouch | Vivo kills background apps aggressively and unbinds listeners **[V for the general claim, [dontkillmyapp/vivo](https://dontkillmyapp.com/vivo)]**. User checklist: Autostart on; Battery → Background power consumption management → allow; App battery → Unrestricted/not optimised; lock the app in Recents. A third-party report says Funtouch 14 still kills Tasker despite these settings **[U, forum]**. The existing FGS plus wake lock helps. |

---

## 3. Find My Phone (ring at max volume on silent/DND)

| Step | API | Notes |
|---|---|---|
| Play | `MediaPlayer`/`Ringtone` with `AudioAttributes.Builder().setUsage(USAGE_ALARM).setContentType(CONTENT_TYPE_SONIFICATION)`; looping; `RingtoneManager.getActualDefaultRingtoneUri(TYPE_ALARM)` or a bundled loud asset | Alarm usage ignores the **ringer mode** (silent or vibrate). It plays through DND **only if DND allows alarms**. Alarms are allowed by default in AOSP DND; "Total silence" blocks them **[U, AOSP default policy]**. |
| Volume | `AudioManager.setStreamVolume(STREAM_ALARM, getStreamMaxVolume(STREAM_ALARM), 0)`; restore the old value on stop | No permission is needed for the alarm stream on 14 **[U]**. |
| DND override (Android 14) | `ACCESS_NOTIFICATION_POLICY` (manifest plus the user grants "Do Not Disturb access"); `NotificationManager.setInterruptionFilter(INTERRUPTION_FILTER_ALL)` during the ring, restore after | **Android 15+ with target 35+**: apps can no longer change global DND. The call creates an implicit `AutomaticZenRule` instead **[V, [A15 target-35](https://developer.android.com/about/versions/15/behavior-changes-15#dnd-changes)]**. So on 15+ rely on alarms being allowed. |
| Android 17 (target 37) | Background audio needs an FGS with **while-in-use**, *or* the **exact alarm permission + USAGE_ALARM** **[V, [bg-audio](https://developer.android.com/about/versions/17/changes/bg-audio)]**. Our FGS is started from `BOOT_COMPLETED` or an activity, so it is not reliably WIU. | Declare `SCHEDULE_EXACT_ALARM` (user grants) and/or `USE_EXACT_ALARM`. Always use `USAGE_ALARM`. Whether `USE_EXACT_ALARM` counts is **[U]**; the user can grant `SCHEDULE_EXACT_ALARM`. Test with `adb shell cmd audio set-enable-hardening throw`. |
| Stop control | (a) Mac command `ringStop`; (b) a high-importance notification on its own channel (`IMPORTANCE_HIGH`, alarm category) with a **Stop** action → `PendingIntent.getService`/broadcast; (c) volume key or power key: register a `MediaSession` while ringing **[U]**, or simply stop on `ACTION_SCREEN_ON`/`USER_PRESENT` after 3 s; (d) auto-stop after 60 s | — |
| Full-screen UI (optional) | `USE_FULL_SCREEN_INTENT`. On 14, `NotificationManager.canUseFullScreenIntent()`; if false → `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` **[V, [A14 changes](https://developer.android.com/about/versions/14/behavior-changes-14#fsi-permission)]**. Play revokes it for non-call or alarm apps; sideloaded apps keep the default grant **[U]**. Not needed: sound plus a heads-up Stop action is enough. Background activity starts are blocked unless an exemption applies (for example `SYSTEM_ALERT_WINDOW` granted) **[V, BAL doc]**. Do not depend on that. |
| Extras | Flash torch (`CameraManager.setTorchMode`, no runtime permission **[U]**); vibrate with `VibrationAttributes.USAGE_ALARM`; report `ringing:true` in status so the Mac shows state. |

Battery: negligible (on demand). Failure modes: DND "Total silence", or the user lowered alarm volume (we override it); Funtouch "Game mode" or Ultra power saving killing the FGS.

---

## 4. Send SMS from the Mac

| Item | Detail |
|---|---|
| Permission | `SEND_SMS` runtime **[V, [SmsManager.sendTextMessage](https://developer.android.com/reference/android/telephony/SmsManager#sendTextMessage(java.lang.String,%20java.lang.String,%20java.lang.String,%20android.app.PendingIntent,%20android.app.PendingIntent))]**. Android 15 ECM may block granting it to sideloaded apps without "Allow restricted settings" **[U]**. `adb shell pm grant` works around this. |
| Dual SIM | `SubscriptionManager.getActiveSubscriptionInfoList()` (needs `READ_PHONE_STATE`) gives subId, displayName, carrier, slot. Send via `getSystemService(SmsManager::class.java).createForSubscriptionId(subId)` (API 31+). Use `SmsManager.getSmsManagerForSubscriptionId` on 29–30 (deprecated in 31) **[V, SmsManager]**. This never shows the SIM-picker dialog **[V]**. Put the SIM list in status so the Mac can show a picker. |
| Multipart | `divideMessage(text)` then `sendMultipartTextMessage(dest, null, parts, sentIntents, deliveryIntents)`. Use one PendingIntent per part, a unique requestCode, `FLAG_IMMUTABLE`, and an explicit component (A14 rule). Unicode (Hindi) gives 70 chars per part. |
| Status | `sentIntent` result codes: `Activity.RESULT_OK`, `RESULT_ERROR_GENERIC_FAILURE`(1), `RADIO_OFF`(2), `NULL_PDU`(3), `NO_SERVICE`(4), `LIMIT_EXCEEDED`(5), … **[V, SmsManager]**. Delivery reports depend on the carrier and are often absent in India **[U]**. Report the result as the command `receipt` (the existing mechanism), plus later `smsStatus` events. |
| Appears in Messages thread? | **Yes.** "if and only if an app is not selected as the default SMS app, the system automatically writes messages sent using this method to the SMS Provider" **[V, SmsManager]**. Whether Vivo's Messages app shows provider-inserted rows: **[U]**, test on the device. |
| Composer data | Threads: `READ_SMS` + `Telephony.Sms.Conversations`/`Telephony.Threads` (subject to the A17 OTP filtering on 17). Contacts: `READ_CONTACTS`, `ContactsContract.CommonDataKinds.Phone` (name, number, label). Send a bounded list (top 200 by `TIMES_CONTACTED`/recent threads), paginated across polls because of the 32 KB cap, or a dedicated `/v1/contacts` chunked upload. |
| Safety | Require an explicit command with recipient plus text, with `expiresAt` (existing window). Rate-limit, for example 10 per minute. Never auto-retry a send whose result is unknown, to avoid duplicates. |

---

## 5. Incoming call alert

| Need | Option | Perms | Status |
|---|---|---|---|
| Ringing + number | `TelephonyManager.registerTelephonyCallback(executor, object: TelephonyCallback(), CallStateListener)` gives state **only, no number** **[U, API 31+ design]** | `READ_PHONE_STATE` | Good for state. |
|  | Manifest/dynamic receiver for `TelephonyManager.ACTION_PHONE_STATE_CHANGED` with `EXTRA_STATE`, `EXTRA_INCOMING_NUMBER` (deprecated in 29 but still populated with `READ_CALL_LOG`) **[U]** | `READ_PHONE_STATE` + `READ_CALL_LOG` | Gives the number. Fires twice (with and without the number). Dedupe. |
|  | Deprecated `PhoneStateListener.onCallStateChanged(state, phoneNumber)` (number needs `READ_CALL_LOG`) **[U]** | same | Works on 14; avoid. |
|  | **NLS**: the dialer posts a `Notification.CallStyle`/`category=call` notification with the caller name or number and **Answer/Decline actions** | Notification access (already needed for §2) | **Simplest.** Zero extra perms. The name comes from the dialer's own contact lookup. Firing the dialer's Decline PendingIntent from the NLS **[U]**. Vivo dialer behaviour unknown. |
| Contact name | `ContactsContract.PhoneLookup.CONTENT_FILTER_URI` + `Uri.encode(number)` → `DISPLAY_NAME` | `READ_CONTACTS` | Standard. |
| Decline | `TelecomManager.endCall()`: deprecated in 29, still documented: "If there is a single call and it is ringing, calling this method rejects the ringing call". Requires `ANSWER_PHONE_CALLS`. Returns false for emergency calls **[V, [TelecomManager.endCall](https://developer.android.com/reference/android/telecom/TelecomManager#endCall())]**. | `ANSWER_PHONE_CALLS` (runtime) | **Works.** Primary decline path. |
| Answer (bonus) | `acceptRingingCall()` (deprecated in 29) **[V]** | `ANSWER_PHONE_CALLS` | Audio stays on the phone. |
| Silence ringer | `TelecomManager.silenceRinger()` **requires `MODIFY_PHONE_STATE` or the dialer role** **[V, TelecomManager]**, so **not available**. Alternatives: `AudioManager.adjustStreamVolume(STREAM_RING, ADJUST_MUTE, 0)` and restore when IDLE (may require DND access on some builds) **[U]**; or fire the dialer notification's action, if one exists. | — | Best effort. |
| CallScreeningService | Hold the `ROLE_CALL_SCREENING` role (RoleManager). `onScreenCall(details)` gives the number with no READ_CALL_LOG. The response can set `setSilenceCall(true)`/`setRejectCall`, **but only at screening time, before ringing** **[U]**. Takes the role away from Truecaller, which is common in India. | role | **Not recommended.** |

Event: `{type:"call", state:"ringing|offhook|idle", number, name, simSlot}`. Push immediately (§8). On `idle` send `missed` if never offhook.

---

## 6. Send link / file drop phone→Mac, and Mac→phone receive

**Share target (phone→Mac)**
```xml
<activity android:name=".remote.ShareToMacActivity" android:exported="true"
    android:theme="@android:style/Theme.Translucent.NoTitleBar" android:excludeFromRecents="true">
  <intent-filter><action android:name="android.intent.action.SEND"/><category android:name="android.intent.category.DEFAULT"/><data android:mimeType="*/*"/></intent-filter>
  <intent-filter><action android:name="android.intent.action.SEND_MULTIPLE"/><category android:name="android.intent.category.DEFAULT"/><data android:mimeType="*/*"/></intent-filter>
</activity>
```
- Text or URL: `EXTRA_TEXT` (often "Title\nhttps://…"; extract the first URL with `Patterns.WEB_URL`) plus `EXTRA_SUBJECT`. Small payload, so it goes through the outbox (`{type:"link", url, title}`), and the Mac opens it.
- Files: `EXTRA_STREAM` (Uri or `ArrayList<Uri>`). Use `contentResolver.query(uri, [OpenableColumns.DISPLAY_NAME, SIZE])` and `openInputStream(uri)`.
- **URI grant lifetime**: the grant belongs to the receiving activity. If the activity `finish()`es before the stream is read, the read can fail **[U]**. Hand the Uri to `RemoteService` via `startService(Intent(...).setData(uri).addFlags(FLAG_GRANT_READ_URI_PERMISSION))` (the grant moves to the service), or copy to `cacheDir` first for small files. Android 18 will stop implicit grants **for senders**. That affects other apps sharing to us, which must add flags themselves **[V, [A17 all-apps](https://developer.android.com/about/versions/17/behavior-changes-all)]**.
- **Large files cannot use `/v1/poll`** (32 KB cap). Add `/v1/upload`: chunks of about 256 KB to 1 MB, each sealed with AES-GCM with AAD `devswitch/file/v1/<id>/<transferId>/<index>`. Use a per-transfer random id and a fresh nonce per chunk. The Mac reassembles and verifies count plus total SHA-256. Run it on its own thread (not the poll thread) so the 2 s heartbeat continues. Resume by index. The Protocol caps need a raised, separate limit for this path only.
- FGS type: the existing `connectedDevice` covers "transferring data to a locally connected device … local internet connection" **[V, [data-transfer options](https://developer.android.com/about/versions/15/changes/datasync-migration)]**. **Avoid `dataSync`**: on 15+ (target 35+) it has a 6 h/24 h cap and cannot start from `BOOT_COMPLETED` **[V, [A15 target-35](https://developer.android.com/about/versions/15/behavior-changes-15)]**.

**Mac→phone receive into Downloads (no storage permission on 29+)**
```kotlin
val values = ContentValues().apply {
  put(MediaStore.Downloads.DISPLAY_NAME, name); put(MediaStore.Downloads.MIME_TYPE, mime)
  put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/DevSwitch")
  put(MediaStore.Downloads.IS_PENDING, 1) }
val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)!!
contentResolver.openOutputStream(uri)!!.use { /* stream chunks */ }
values.clear(); values.put(MediaStore.Downloads.IS_PENDING, 0); contentResolver.update(uri, values, null, null)
```
**[U, standard MediaStore API 29+]**. Delivery: the Mac announces `fileOffer{transferId,name,size,mime}` as a command. The phone pulls `GET /v1/download?transferId&index` chunks (phone-initiated, which fits the current client-only phone design: the phone never listens). Post a notification "Received X from Mac", tap → `ACTION_VIEW` with `FLAG_GRANT_READ_URI_PERMISSION`. Cap at, for example, 2 GB, check `StatFs` free space first, and delete the pending row on failure.

---

## 7. Shared clipboard

| Direction | Mechanism | Status |
|---|---|---|
| Restriction | "Unless your app is the default IME or is the app that currently has focus, your app cannot access clipboard data on Android 10 or higher." **[V, [A10 privacy](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)]**. `OnPrimaryClipChangedListener` likewise does not fire for background apps **[U]**. | Hard limit |
| Mac→phone | `ClipboardManager.setPrimaryClip(ClipData.newPlainText(...))` from the background service. **Writes are allowed** from the background (the restriction is on reads) **[U, AOSP recall]**. Android 13+ shows the system copy overlay. For OTPs/passwords set `clip.description.extras = PersistableBundle().apply{ putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }` (API 33; on 29–32 use the string `"android.content.extra.IS_SENSITIVE"`) **[U, API ref]**. | **Feasible**, silent apart from the overlay |
| Phone→Mac, reliable | (a) Share sheet → `ShareToMacActivity` (EXTRA_TEXT) → outbox `clip` event. (b) **Quick Settings tile** (`TileService`, `BIND_QUICK_SETTINGS_TILE`): `onClick` → `startActivityAndCollapse(PendingIntent)` (on 34+ the Intent overload throws **[V, A14 changes]**) to a transparent activity that reads the clipboard in `onWindowFocusChanged(true)` (it has focus), sends it, then `finish()`. (c) An action on the persistent FGS notification ("Send clipboard to Mac") → same transparent activity (activity PendingIntent from a notification is allowed). (d) The Android 13+ copy overlay has a Share button → share to DevSwitch. | **Feasible**, one tap |
| Phone→Mac, automatic | KDE Connect approach: `READ_LOGS` granted via `adb shell pm grant <pkg> android.permission.READ_LOGS`, plus `SYSTEM_ALERT_WINDOW`. Watch logcat for the "Denying clipboard access" line, then flash a focusable invisible activity to read the clip **[U, [KDE Userbase](https://userbase.kde.org/KDEConnect) / forum]**. On Android 13+ a one-time logcat consent dialog appears. Reported broken on Android 16 One UI 8 **[U]**. Accessibility services do not lift the clipboard restriction **[U]**. | Hacky; optional "power mode" only |
| IME route | Being the default keyboard gives clipboard access, but replaces the user's keyboard. | Reject |

---

## 8. Transport: 2 s poll, battery, Doze, FGS types, instant push

### Current cost profile
- 43,200 polls/day. Each one does a new TCP connect, AES-GCM, a JSON build, and 6 Settings reads.
- The partial wake lock is held continuously while the Mac answers, so the **CPU never suspends while paired and in range**. This is already the dominant battery cost (documented in `docs/architecture.md`). Wi-Fi traffic every 2 s also keeps the radio out of its deepest power-save (DTIM skipping) **[U]**.
- **Doze**: "Ignores wake locks" and "Suspends network access" for non-exempt apps **[V, [Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)]**. Apps on the battery-optimisation allowlist "can use the network and hold partial wake locks during Doze" **[V]**. AOSP also exempts processes at FGS proc-state from idle network and wake-lock blocking **[U, NetworkPolicyManager/PowerManagerService recall]**. The existing "Heartbeat gap … idle=" log measures exactly this. **Recommend asking the user for the battery-optimisation exemption** (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; needs `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; fine for sideloaded) or `adb shell dumpsys deviceidle whitelist +<pkg>`. This also grants the "user turns off battery optimizations" exemption for **starting the FGS from the background** **[V, [FGS bg-start](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)]**, so the NLS can restart a killed `RemoteService`.

### Optimisations that keep "every 2 seconds"
1. **Persistent connection**: HTTP/1.1 keep-alive on one socket to the Mac (the Mac `HTTPServer.swift` would need keep-alive support). This saves the TCP handshake, socket setup and a few packets every tick. Biggest win.
2. **Status diff**: send the full status only when its hash changed, or every 30 s. Otherwise send `{"statusHash":…}`. Move `wireless.update()` to the NSD callbacks plus a 30 s refresh.
3. **Batch outbox** into the poll body (≤24 KB). If more remain or a command arrived, **poll again immediately** instead of sleeping.
4. **Immediate push**: replace `Thread.sleep(2000)` with a wait that can be interrupted:
   ```kotlin
   private val wake = java.util.concurrent.Semaphore(0)
   fun kick() = wake.release()            // called from NLS/SMS/call/share threads
   // in loop, instead of Thread.sleep(2000):
   wake.drainPermits(); wake.tryAcquire(2000, TimeUnit.MILLISECONDS)
   ```
   The outbox is a process-wide `ConcurrentLinkedQueue<JSONObject>` with ids. Events stay until the Mac's reply lists them in `ack:[ids]`. Latency becomes about one RTT (≈10–50 ms on LAN) instead of ≤2 s. CPU is already awake (wake lock), so `kick()` needs no extra wake lock while connected. While **disconnected** (wake lock released), the SMS broadcast and NLS callbacks still run, because the system wakes the process for them. `kick()` triggers an immediate attempt, and the event waits in the outbox.
5. Keep commands single per reply on the Mac for now, but have the Mac set `more:true` so the phone re-polls instantly. Alternatively change `Reply.command` to `commands:[…]` (version the AAD, e.g. `devswitch/reply/v2/`).
6. Optional later: a long-poll (the Mac holds the request ≤25 s and answers early on a command). This gives instant commands **and** about 12× fewer wake-ups, but it changes "every 2 s". Raise it with the user, do not impose it.

### FGS types
| Type | Fits | Prereq | Notes |
|---|---|---|---|
| `connectedDevice` (current) | Link to the Mac, file transfer to the Mac | `CHANGE_NETWORK_STATE` declared ✓ **[V, [FGS types](https://developer.android.com/about/versions/14/changes/fgs-types-required)]** | Keep |
| `remoteMessaging` | "Transfer text messages from one device to another … continuity" **[V]** | none; add `FOREGROUND_SERVICE_REMOTE_MESSAGING` | Add: `foregroundServiceType="connectedDevice|remoteMessaging"`. Sideloaded, so no Play declaration |
| `dataSync` | — | — | **Avoid** (6 h/24 h, no BOOT start on 15+) **[V]** |
| `mediaPlayback` | Find My Phone audio | — | Not needed on 14; on 17 prefer the exact-alarm + USAGE_ALARM waiver **[V]** |
| `shortService` | — | — | ~3 min cap. Not useful |

---

## 9. Test strategy

AVD present: `devswitch-test` = **API 35, google_apis_playstore, arm64** (no `adb root`, but shell-level `pm grant`, `cmd notification`, `appops` work). The emulator binary is **not on PATH**: `/opt/homebrew/share/android-commandlinetools/emulator/emulator -avd devswitch-test`. The emulator reaches the Mac at `10.0.2.2`, which passes `Protocol.origin()` (10/8 private). The Mac server must listen on loopback/all interfaces **[U]**. Recommend also installing `system-images;android-34;google_apis;arm64-v8a` (matches the phone, rootable) and an API 37 image (OTP delay, LNP, audio hardening).

| Feature | Emulator commands | Needs real iQOO? |
|---|---|---|
| Permissions setup | `adb install -r app.apk`; `adb shell pm grant $P android.permission.RECEIVE_SMS` (READ_SMS, SEND_SMS, READ_CONTACTS, READ_PHONE_STATE, READ_CALL_LOG, ANSWER_PHONE_CALLS, POST_NOTIFICATIONS); `adb shell cmd notification allow_listener $P/.remote.NotifListener`; `adb shell cmd notification allow_dnd $P` **[U]**; `adb shell dumpsys deviceidle whitelist +$P` | — |
| OTP SMS | `adb emu sms send AXHDFCBK "123456 is your OTP for txn of Rs 2,499.00. Do not share."` **[V, [emulator console](https://developer.android.com/studio/run/emulator-console)]**. Check both receiver and NLS fire, and dedupe | Yes: DLT sender format, Vivo Messages OTP protection, Funtouch kill |
| OTP redaction (A15) | On API 35: send the SMS, inspect the NLS text; try `appops set $P RECEIVE_SENSITIVE_NOTIFICATIONS allow` | n/a on the A14 phone |
| Notifications | `adb shell cmd notification post -S bigtext -t "Alice" tag1 "Hello from emu"`; `-S messaging --conversation "Grp" --message "Bob:hi"`; `-S inbox --line a --line b` **[U, see `adb shell cmd notification help`]**. Remove: `adb shell cmd notification cancel tag1` (or swipe). Real inline reply: install Messages/any chat app on the emulator | Yes: WhatsApp/bank apps, group summaries, Vivo listener unbinding |
| Find My Phone | `adb shell cmd notification set_dnd priority` / `alarms` / `none` **[U]**; `adb shell cmd audio set-enable-hardening throw` (API 37) **[V]**; `adb shell dumpsys audio \| grep -i hardening` | Yes: actual loudness, Funtouch DND variants |
| Send SMS | Start two emulators; send to the other's console port number (`5556`). `adb -s emulator-5556 emu sms …` for replies. sentIntent results; the thread appears in emulator Messages | Yes: dual SIM, carrier delivery reports, Vivo Messages showing provider rows |
| Incoming call | `adb emu gsm call 9876543210`; `adb emu gsm cancel 9876543210`; `adb emu gsm accept …` **[V]**; `adb emu phonenumber …` | Yes: Vivo dialer CallStyle notification and its actions |
| Share/link | `adb shell am start -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "https://example.com" -n $P/.remote.ShareToMacActivity`; files: `adb push big.bin /sdcard/Download/` then share from Files | No (mostly) |
| Mac→phone file | Check `adb shell content query --uri content://media/external/downloads` | No |
| Clipboard | Write: verify with `adb shell cmd clipboard get` **[U]** (or paste in an app). Read via QS tile: `adb shell cmd statusbar add-tile $P/.remote.ClipTile` **[U]** | Funtouch clipboard UI differences |
| Doze / battery | `adb shell dumpsys deviceidle force-idle` / `unforce`; `adb shell dumpsys battery unplug` / `reset`; `adb shell am set-inactive $P true` **[V, Doze doc]**; watch the `DevSwitchConnection` "Heartbeat gap" logs. Real cost: `adb shell dumpsys batterystats --reset` → 2 h unplugged → `adb bugreport` + Battery Historian | **Yes**: only the real phone gives meaningful battery numbers |
| FGS restrictions | `adb shell am compat enable FGS_BOOT_COMPLETED_RESTRICTIONS $P`; `adb shell am broadcast -a android.intent.action.BOOT_COMPLETED $P` **[V, A15 doc]** | — |

---

## R. Ranked risks

1. **Vivo/Funtouch background killing and NLS unbinding.** The feature silently stops. Mitigation: user checklist (Autostart, High background power, Unrestricted, lock in Recents), battery-opt exemption, `requestRebind`, a "listener connected / last event" field in status so the Mac can show health. **High likelihood.**
2. **Battery drain from the 2 s loop plus permanent wake lock.** Already present. New features add little, but users will blame them. Mitigation: keep-alive socket, status diff, instant-kick, measure with batterystats on the real phone. **High.**
3. **32 KB envelope and single-command reply.** Every feature needs an outbox, acks and a command list. Files need a new endpoint. This is a protocol change on both sides (new AAD version). **Certain; design work.**
4. **Future Android (15+/17) OTP lockdown.** NLS redaction plus a 3 h SMS delay for target-37 apps. Not a problem on the A14 phone. Fixable via a CDM association; unverified whether it qualifies. **Low now, high on any newer phone.**
5. **Android 17 `ACCESS_LOCAL_NETWORK` for target 37.** On an A17 device the **existing** poll loop breaks without this runtime permission (TCP to private IPs times out) **[V, [LNP](https://developer.android.com/privacy-and-security/local-network-permission)]**. Add the permission request now. Not a problem on the A14 phone.
6. **Restricted settings / ECM for a sideloaded app** (notification access; SMS perms on 15+). Mitigation: adb grants documented in the in-app setup screen.
7. **Silence ringer not possible** without the dialer role (`MODIFY_PHONE_STATE`). Offer Decline (endCall) plus best-effort mute instead.
8. **Clipboard phone→Mac cannot be automatic.** Set expectations: one tap via QS tile, share sheet, or notification action.
9. **Security surface grows** (SMS send, reply as user, OTPs over LAN). The existing AES-GCM, replay and expiry design stays. Add per-command rate limits, never log OTP/SMS bodies (current code logs error messages; keep bodies out), and keep the outbox in memory only (no plaintext on disk).
10. **DND "Total silence" / alarm volume** on Find My Phone. Override volume; on 14 flip the interruption filter with DND access.

## Recommended Android design per feature

| Feature | Design |
|---|---|
| Transport | Keep the 2 s cadence; add `Outbox` (ConcurrentLinkedQueue, ids, Mac acks), `kick()` semaphore for instant send, poll-again-immediately when `more`/outbox non-empty, keep-alive socket, status hash, protocol v2 (`events:[]` up, `acks:[]` + `commands:[]` down, 24 KB budget). FGS `connectedDevice|remoteMessaging`. Ask for the battery-opt exemption. Add `ACCESS_LOCAL_NETWORK` (A17). |
| OTP | NLS primary + `SMS_RECEIVED` receiver backup; pure-function extractor with Indian fixtures; dedupe on code within 90 s; priority event + immediate kick. Later: CDM association for 15+/17. |
| Notifications | Same NLS; filter ongoing/FGS/summary/non-clearable/min-importance/muted; MessagingStyle via androidx compat; icon once per package; per-package token bucket plus 1.5 s coalescing per key; `dismiss`, `reply`, `action` and `setMute` commands; removal events. |
| Find My Phone | `ring`/`ringStop` commands; USAGE_ALARM looping player, STREAM_ALARM to max, restore; DND access on 14 to force INTERRUPTION_FILTER_ALL; HIGH-importance notification with Stop; auto-stop after 60 s; declare exact-alarm perm for A17. |
| Send SMS | `sendSms{to,text,subId}` command; per-sub SmsManager; multipart with sent/delivered PendingIntents → receipt plus `smsStatus` events; SIM list in status; contacts/threads via a chunked upload, not the poll. |
| Calls | `ACTION_PHONE_STATE_CHANGED` receiver (READ_PHONE_STATE + READ_CALL_LOG) for number and state, plus the NLS call notification for name and actions; PhoneLookup for name; `decline` → `TelecomManager.endCall()` (ANSWER_PHONE_CALLS); `answer` → `acceptRingingCall()`; silence = best-effort ring-stream mute. Skip CallScreeningService. |
| Link/file | Translucent `ShareToMacActivity` (SEND/SEND_MULTIPLE `*/*`) → links via outbox; files via the service-held URI grant + new chunked `/v1/upload`; Mac→phone via `fileOffer` command + phone-pulled `/v1/download` chunks into `MediaStore.Downloads/DevSwitch` with IS_PENDING. |
| Clipboard | Mac→phone `setClip` command → `setPrimaryClip` (IS_SENSITIVE for OTPs); phone→Mac through share sheet, QS tile + transparent focus activity, and an FGS notification action. READ_LOGS auto-mode is an opt-in experiment only. |

## Sources
- Android 14 behavior changes (target 34): https://developer.android.com/about/versions/14/behavior-changes-14
- FGS types required (A14): https://developer.android.com/about/versions/14/changes/fgs-types-required
- Android 15 all apps (OTP redaction): https://developer.android.com/about/versions/15/behavior-changes-all
- Android 15 target 35 (dataSync timeout, BOOT_COMPLETED, DND, audio focus): https://developer.android.com/about/versions/15/behavior-changes-15
- Android 17 all apps (SMS OTP, bg audio): https://developer.android.com/about/versions/17/behavior-changes-all
- Android 17 target 37 (standard SMS OTP delay, LNP): https://developer.android.com/about/versions/17/behavior-changes-17
- Background audio hardening: https://developer.android.com/about/versions/17/changes/bg-audio
- Local network permission: https://developer.android.com/privacy-and-security/local-network-permission
- Telephony.Sms exemptions: https://developer.android.com/reference/android/provider/Telephony.Sms
- RECEIVE_SENSITIVE_NOTIFICATIONS: https://developer.android.com/reference/android/Manifest.permission#RECEIVE_SENSITIVE_NOTIFICATIONS
- SmsManager: https://developer.android.com/reference/android/telephony/SmsManager
- TelecomManager: https://developer.android.com/reference/android/telecom/TelecomManager
- Background activity starts: https://developer.android.com/guide/components/activities/background-starts
- FGS background-start exemptions / WIU: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- Data transfer options: https://developer.android.com/about/versions/15/changes/datasync-migration
- Companion device pairing: https://developer.android.com/develop/connectivity/bluetooth/companion-device-pairing
- Android 10 privacy (clipboard): https://developer.android.com/about/versions/10/privacy/changes
- Doze: https://developer.android.com/training/monitoring-device-state/doze-standby
- Emulator console: https://developer.android.com/studio/run/emulator-console
- Vivo background killing: https://dontkillmyapp.com/vivo
- Android 15 restricted settings / ECM (press): https://androidauthority.com/android-15-restricted-settings-sideloading-3481098
- KDE Connect clipboard READ_LOGS workaround: https://userbase.kde.org/KDEConnect , https://discuss.kde.org/t/kde-connect-clipboard-sync/6422


---

# Part B — Mac and transport research

# DevSwitch Continuity-like features: Mac side and transport research

Scope: macOS app (`mac/`), the companion transport, and a Helium extension. Read-only research; no repo files changed.
Read from the working tree on branch `persistent-wireless` (it has uncommitted changes to `mac/` and `RemoteService.kt`).
Labels: **[V]** checked against official docs, source, or the local machine. **[U]** not verified; test it.

---

## 0. How the transport works today (from the code)

| Aspect | Today | File |
|---|---|---|
| Listener | `NWListener(.tcp)` on **all interfaces**, port 45874, Bonjour `_devswitch._tcp`, main queue | `mac/HTTPServer.swift` |
| Accepted requests | `POST` only, `HTTP/1.1`, path ≤160, `Content-Type: application/json`, `Content-Length` required, no chunked encoding, headers ≤16 KB, **body ≤32 KB**, total buffer ≤48 KB | `HTTPServer.parse` |
| Connection limits | ≤16 concurrent, **hard 10 s deadline per connection**, `Connection: close`, one request per connection | `HTTPServer.accept` |
| Handler | **Synchronous** `(HTTPRequest) -> HTTPResponse` on `@MainActor`. It cannot hold a request open (long-poll) | `HTTPServer.init`, `Controller.handle` |
| Response cap | ≤64 KB on the Mac, but Android reads **≤32 768 B** (both `post` paths) and `Protocol.open` requires decoded ciphertext ≤32 768 | `Protocol.kt` |
| Crypto | AES-256-GCM with a random 12 B nonce. AAD is `devswitch/poll/v1/<id>` or `devswitch/reply/v1/<id>`. The envelope is JSON `{nonce,ciphertext,tag,deviceId}` in base64. The key is per pairing (32 B) | `Crypto.swift`, `Protocol.kt` |
| Replay | `requestId` is 32 random bytes. `sentAt` must be within ±30 s. The `seen` map keeps entries for 120 s and **returns 409 once it holds 500 entries**. The reply echoes `requestId`, and the phone checks it | `Controller.handle` |
| Commands | **Only one** `pending: Command{id,action,expiresAt}`. The action must be `enable` or `disable`, with a 20 s expiry. The phone dedupes only against the **last** receipt id, and its expiry window is `now-30 … now+60` | `Controller.send`, `RemoteService.loop` |
| Phone loop | One thread: prepare status → seal → POST → open → execute → `Thread.sleep(2000)`. **Interrupting the sleep exits the loop** (`catch InterruptedException → break`). Timeouts are 4 s connect and 4 s read. The CPU wake lock is renewed on authenticated replies | `RemoteService.kt` |
| Keys | Mac: Keychain generic password `dev.notsg.devswitch.pairing`, `AfterFirstUnlockThisDeviceOnly`. Android: wrapped by the Keystore | `Controller.save`, `PairStore` |
| Signing | `codesign --sign "${DEVSWITCH_SIGN_IDENTITY:--}"` (ad-hoc by default). No entitlements, no sandbox, `LSUIElement` | `mac/build.sh` |

Effective payload budget in each direction: 32 KB of base64 JSON is about **≤23 KB of plaintext JSON per message**. All new features must fit this budget or use a separate channel.

Existing issue found while reading: "Copy invitation" (`DevSwitch.swift:242`) puts the **pairing secret** on the general pasteboard with no concealed or transient marker. Clipboard managers will record it. Add the markers described in §3.5.

---

## 1. OTP: banner, clipboard, and autofill in Helium

### 1a. Helium extension with Native Messaging (recommended)

| Item | Finding |
|---|---|
| Host manifest location (Helium) | **`~/Library/Application Support/net.imput.helium/NativeMessagingHosts/<name>.json`** **[V]**. Chromium resolves `DIR_USER_NATIVE_MESSAGING` as `DIR_USER_DATA + "NativeMessagingHosts"` (`chrome/common/chrome_paths.cc`, lines ~488-493, fetched from googlesource). Helium's user-data dir on this Mac is `~/Library/Application Support/net.imput.helium`, and Helium already created an empty `NativeMessagingHosts/` folder in it (checked locally with `ls`; Helium 0.19.4.1, bundle `net.imput.helium`). The system-wide path compiled into the Helium framework is the non-Google default, `/Library/Application Support/Chromium/NativeMessagingHosts` (seen with `strings`). Do **not** use `~/Library/Application Support/Chromium/...`, because Helium does not read it |
| Manifest | `{"name":"dev.notsg.devswitch","description":"DevSwitch","path":"/Applications/DevSwitch.app/Contents/MacOS/DevSwitch","type":"stdio","allowed_origins":["chrome-extension://<ID>/"]}`. The path must be absolute, and `allowed_origins` **cannot contain wildcards** **[V]** |
| Protocol | The browser launches the host and talks over stdin/stdout with a 32-bit length prefix in native byte order. `argv[1]` = the caller origin. Host→browser messages are capped at **1 MB**, browser→host at **64 MiB** **[V]** |
| Host process | Reuse the app binary. In `DevSwitchApp.init`, `if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true { exit(NativeHost.run()) }`, the same pattern as `--doctor`. The host does not own the pairing key. It relays to the running app over a **Unix domain socket** at `~/Library/Application Support/DevSwitch/ext.sock` (directory mode 0700). The app checks the peer with `getsockopt(LOCAL_PEERPID)` and confirms it is the same executable (`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` against its own designated requirement) **[U: design]** |
| Stable extension ID | Put `"key"` (a public key) in `manifest.json` so the unpacked ID is deterministic. Without it, the ID depends on the path, and `allowed_origins` breaks when the folder moves **[V: Chrome manifest "key" docs; standard]** |
| Keeping the service worker alive | `chrome.runtime.connectNative()` keeps the MV3 service worker alive (Chrome 105+). Reconnect in `onDisconnect` **[V]** |
| Install in Helium | `chrome://extensions` → Developer mode → Load unpacked → choose a stable folder, such as `~/Library/Application Support/DevSwitch/extension` copied in by the app. The extension persists across restarts as long as the folder exists and Developer mode stays on. This is standard Chromium behavior **[U for Helium specifically; test it]**. DevSwitch's settings window can write the host manifest, copy the extension, and open `chrome://extensions`. Note that a page cannot open `chrome://` URLs. Use `open -a Helium chrome://extensions` **[U]** |
| Content script | `matches: ["<all_urls>"]`, `all_frames: true` (OTP inputs often sit in iframes), `run_at: document_idle`, plus a `MutationObserver` for single-page apps |

**OTP field detection, in priority order:**
1. `input[autocomplete~="one-time-code"]`
2. `input` whose name, id, placeholder, `aria-label`, or associated label text matches `/\b(otp|one[-_ ]?time|2fa|mfa|totp|verification|verify|security|auth(entication)?)[-_ ]?(code|pin|token)?\b|\bcode\b/i`, with `inputmode="numeric"` or `type in (text, tel, number)`, and `maxlength` 4-8 or unset
3. **Split inputs**: ≥4 sibling inputs with `maxlength=1` in one form or container, horizontally adjacent (compare `getBoundingClientRect` tops). Treat them as one field and fill them left to right.
4. Exclude `type=password`, fields named `/card|cvv|cvc|zip|postal|phone|amount/`, and hidden or disabled fields.

**Filling**: use the native value setter, `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,v)`, then dispatch `input` and `change` (`bubbles:true`), so React and Vue pick up the value. For split inputs, set each box and then fire `keyup` on the last one. The events are `isTrusted=false`. Most sites accept this; a few anti-bot forms may not **[U]**.

**Chip UX (similar to Apple Passwords)**: on `focusin` or `pointerenter` on a detected field, the content script asks the service worker `getOtp`. The service worker asks the host, and the host asks the app. The app returns the code only if it is <90 s old and has not been consumed. The content script then shows a chip anchored under the field in a **closed shadow root**: "From your phone: 482913 · Fill". One click fills the field, sends `consumed`, and removes the chip. If no code is available yet, the content script subscribes for 60 s and the chip appears when the SMS arrives (pushed over the port). Origin binding: if the SMS uses the standard domain-bound format (`@example.com #482913`), show the chip only on that eTLD+1 and say "for example.com" **[U: parse on the phone]**.

**Never broadcast codes to all tabs.** Deliver a code only to a frame that has a focused or hovered OTP field, and only on request.

### 1b. Localhost HTTP or WebSocket from the extension (not recommended)

- Opens a socket that every local process and every web page can reach. Chrome's Private Network Access and Local Network Access rules limit pages, but not local processes. It would need a separate listener bound to `127.0.0.1` (the current listener binds to all interfaces, so the 45874 listener must not be reused), plus a random bearer token. That token needs a delivery channel to the extension, which is the same problem native messaging already solves.
- Native messaging: no listener, the browser enforces the extension-ID allowlist, and there is no token to leak. **Use native messaging.**

### 1c. Banner and clipboard

- Banner: post through UNUserNotificationCenter, but **do not put the code in the notification** (see §5: macOS persists notification content). Use the title "Verification code from <app>" and an action "Copy code". Optionally, use a custom non-activating `NSPanel` HUD (code shown, auto-hides after 10 s, never persisted) **[V: Apple panel APIs; design]**.
- Copy: write to `NSPasteboard.general` with these types: `.string`, `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, and `org.nspasteboard.source = dev.notsg.devswitch` **[V nspasteboard.org]**. Record `changeCount` after the write. After **90 s**, if `changeCount` is unchanged, call `clearContents()`. If the user copied something else, leave it alone.

### 1d. System-wide auto-type in non-browser apps

| Option | API | Permission | Notes |
|---|---|---|---|
| Paste | Pasteboard (§1c) + `CGEvent` ⌘V posted to `.cghidEventTap` | Accessibility (`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`) or `CGRequestPostEventAccess()` (10.15+) **[V AX API; U exact TCC bucket for PostEvent]** | Works almost everywhere. Briefly replaces the clipboard (save and restore it afterwards) |
| Set value | `AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute` → `AXUIElementSetAttributeValue(kAXValueAttribute)` | Accessibility | Works in native Cocoa fields. Unreliable in Chromium and Electron fields **[U]** |
| Type | `CGEvent(keyboardEventSource:…)` + `keyboardSetUnicodeString` per character | Accessibility / PostEvent | Most compatible for digits. Secure Event Input (password fields) can interfere **[U]** |

Trigger: a global hotkey (for example ⌃⌥V, registered with `RegisterEventHotKey`, no permission needed) or the banner's "Type code" action. Do not type automatically into whatever has focus.

**Ad-hoc signing pitfall [V: standard TCC behavior; U exact wording]**: TCC stores Accessibility grants against the code requirement. For ad-hoc signatures that requirement is the **cdhash, which changes on every rebuild**. The toggle in System Settings stays on but stops working. Fix: build with a stable self-signed certificate using the existing `DEVSWITCH_SIGN_IDENTITY` hook in `build.sh`. Detect the broken state with `AXIsProcessTrusted()` at startup and tell the user to remove and re-add DevSwitch. The same root cause affects the existing Keychain item's ACL (prompts after a rebuild).

---

## 2. Notification mirroring

| Topic | Finding |
|---|---|
| Authorization when ad-hoc signed | Works when the app is a **bundled, signed** (including ad-hoc) app launched as a bundle with a `CFBundleIdentifier`. A bare binary fails with "Notifications are not allowed for this application" (Bitcoin Core GUI migration RFC; pyobjc reports). Some ad-hoc builds are granted access but do not appear in System Settings **[V: community reports, not Apple docs]**. DevSwitch already meets the bundle requirements (`dev.notsg.devswitch`). Set `UNUserNotificationCenter.current().delegate` in an `NSApplicationDelegateAdaptor` `applicationDidFinishLaunching` so action responses arrive |
| Per-Android-app icon | The banner's **app icon is always DevSwitch's**. `UNNotificationAttachment` (macOS 10.14+) adds a thumbnail on the right. The file must be on disk, and the system moves it into its attachment store **[V]**. Write the PNG to `Caches/icons/<pkg>-<hash>.png` and attach a fresh copy per notification. Communication-style avatars (`INSendMessageIntent`) need a restricted entitlement, so they are not available ad-hoc **[U]** |
| Grouping | `threadIdentifier = packageName` (macOS 10.14+) **[V]**. Use `summaryArgument` for the stack label |
| Dismiss sync | Mac→phone: `UNNotificationDismissActionIdentifier` requires the category option `.customDismissAction`. Send a `dismiss{key}` command. Phone→Mac: on the `notificationRemoved{key}` event, call `removeDeliveredNotifications(withIdentifiers:[key])`. Use the Android `StatusBarNotification.key` as the request identifier |
| Inline reply | `UNTextInputNotificationAction` (macOS 10.14+) **[V]**. Read `UNTextInputNotificationResponse.userText` → `reply{key, actionIndex, text}` command. Register the category only when the phone says the notification has a RemoteInput action |
| Time-sensitive | `interruptionLevel = .timeSensitive` (macOS 12+) can break through Focus **[V]**. On iOS it requires the `com.apple.developer.usernotifications.time-sensitive` entitlement. Whether ad-hoc macOS builds can carry it is **[U]**. Assume `.active` and fall back. Critical alerts need Apple approval and are not possible |
| Rate limiting | No documented macOS limit for local notifications. Apply your own: per-package token bucket (5/10 s), global 20/min, coalesce updates by key (replace the request with the same identifier), drop ongoing and foreground-service notifications, and drop group-summary notifications |
| Mute list UI | Settings section "Mirrored apps": a list of packages seen (name + icon + toggle), stored in `UserDefaults` (package names only, never content). Also add "Mute this app" in the banner's actions. Apply the filter on **both sides**: send the mute list to the phone in a `setMuted` command so muted content never leaves the phone |
| Persistence warning | See §5. macOS logs delivered notification title and body to the usernoted DB |

---

## 3. Other features

| Feature | Mac side | Permission | Failure modes |
|---|---|---|---|
| **Find My Phone** | Menu button "Ring phone" → `ring` command, then `stopRing` after the phone receipt or on user request. The phone plays the alarm stream at full volume, overriding DND (Android side) | none | Up to 2 s latency (fine). Phone offline: the button is disabled and the panel shows "last seen" |
| **Send SMS composer** | SwiftUI `Window("New message")` with recipient (phone contacts are not on the Mac; free-text number or a recent-threads list sent by the phone) and body ≤ 1 600 chars → `sendSms{to,body}`. Show the "sent / failed" receipt | none on Mac. Android `SEND_SMS` | Receipt timeout; multipart SMS; never store the draft on disk |
| **Incoming call** | Phone sends a `call{state:ringing, number, name}` event with an **immediate out-of-cycle poll**. Mac shows a **floating non-activating `NSPanel`** (top-right, `.nonactivatingPanel`, level `.statusBar`) with Decline and Silence buttons. Optionally also post a `.timeSensitive` notification with the same actions. Dismiss on `call{state:idle/offhook}` | none. Android `ANSWER_PHONE_CALLS` to end calls, `READ_PHONE_STATE` | Banners auto-hide after ~5 s unless the user chose the "Alerts" style, so the panel is more reliable. Decline latency is bounded by the poll interval, which is why hot polling (§4) is needed |
| **Send link to Mac** | `link{url}` event. Accept only `http`/`https` and ≤ 2 048 chars. Show a notification with an "Open" action, with an opt-in "open automatically" setting. Open with `NSWorkspace.shared.open([url], withApplicationAt: urlForApplication(withBundleIdentifier:"net.imput.helium") ?? default, configuration:)` | none | A compromised phone could push phishing links, so the default is click-to-open |
| **File drop Mac→phone** | Drop zone in the menu panel. Plus an `NSServices` entry ("Send to phone") in Info.plist, which appears in Finder's right-click Services or Quick Actions with no app extension needed **[U: wording in Finder]**. The Mac queues a `fileOffer{transferId,name,size,sha256}` command, and the phone pulls chunks (§4d) | none | Large files, sleep mid-transfer → resume by chunk index |
| **File drop phone→Mac** | `fileOffer` event → Mac notification "Accept / Decline" (auto-accept ≤ 25 MB optional). The phone uploads chunks. The Mac writes to `~/Downloads/<name>.part`, verifies the SHA-256, renames, **sets `com.apple.quarantine`** (via `URLResourceValues.quarantineProperties`), and offers "Reveal" | none (not sandboxed) | Disk full, name collisions, path traversal in the name (strip `/`, `..`, and control chars) |
| **Shared clipboard** | Timer at 0.5-1 s: read `NSPasteboard.general.changeCount` (cheap integer IPC); read content **only** when it changes and the feature is on. **Skip** when the types include `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`, `com.agilebits.onepassword`, or the custom `dev.notsg.devswitch.remote` type. **Loop prevention**: when writing a phone clip, add `dev.notsg.devswitch.remote` and record `changeCount`, then ignore that count. On the phone, echo-suppress by content hash. **Limits**: text ≤ 16 KB inline. Larger text or images go through the file channel (≤ 10 MB images); drop anything else. Debounce 300 ms | Pasteboard privacy (below) | See next row |
| Pasteboard privacy | macOS 15.4 added `NSPasteboard.accessBehavior`. Its default is **"ask on programmatic read of the general pasteboard"** in a future release, unless the read results from user paste input **[V Apple docs]**. Reportedly not enforced in macOS 26, and the developer-preview flag was reportedly deprecated in later betas **[V-secondary: mjtsai.com; U on macOS 27, which this Mac runs]**. Design for it: check `accessBehavior`. When the value is `.ask` or `.alwaysDeny`, disable auto-sync and offer a manual "Send clipboard to phone" menu item, which counts as user-originated. `detect…` APIs do not alert **[V]** | | |

---

## 4. Transport redesign: keep the 2 s poll, optimize it

| Option | Verdict | Why |
|---|---|---|
| (a) Piggyback events on the poll + batching + immediate out-of-cycle poll | **Adopt** | No new socket or server role. Latency from phone events drops from ≤2 s to about 1 RTT. Needs the phone loop to wait on a `LinkedBlockingQueue.poll(2, SECONDS)` (or `Object.wait`) instead of `Thread.sleep` + interrupt, which today **exits the loop** |
| (b) Multiple queued commands per reply | **Adopt** | Replace `pending: Command?` with an ordered queue (max 16, per-command TTL). The phone returns `receipts[]` and dedupes against a set of the last 64 command ids (today it only checks the last id) |
| (c) Long-polling | **Reject for now** | Would require an async handler (the current one is synchronous on the main actor), removing the 10 s per-connection kill, changing the phone `readTimeout` from 4 s to about 30 s, and rethinking wake-lock renewal. It also ties up one of the 16 connection slots. Adaptive polling covers the latency need |
| Adaptive interval (addition) | **Adopt** | The reply carries `nextPollMs`. 2 000 when idle. **500 for 30 s** while a call is ringing, a transfer is active, the menu panel is open, or commands are queued. Floor 250 ms, enforced on the Mac (429). The Mac sets `nextPollMs:0` when it enqueues a command it wants delivered quickly |
| (d) Separate authenticated file endpoint | **Adopt** | §4d. Do not push files through the poll's 23 KB budget |
| (e) Replay protection and size limits | **Adopt** | Keep the `requestId` + `sentAt` ±30 s scheme. Raise the `seen` cap from 500 to 2 048: at 4 req/s over 120 s that is 480, which hits the current cap and **409s legitimate traffic**. Use per-path limits in `HTTPServer.parse` (below). Event and command ids get an LRU dedupe of 512 entries kept in memory |

### 4.1 Poll v2 schema (plaintext inside the existing envelope; AAD `devswitch/poll/v2/<id>` and `devswitch/reply/v2/<id>`)

```jsonc
// phone -> Mac  (POST /v2/poll)   plaintext <= 20 KB, else split across polls
{
  "requestId": "<b64 32B>", "sentAt": 1762500000,
  "status": { ...PhoneStatus (unchanged)... },
  "receipts": [ {"id":"<cmd uuid>","ok":true,"message":""} ],
  "events": [                                   // max 32 per poll; ordered; at-least-once
    {"id":"<uuid>","t":"otp","at":1762500000,"code":"482913","source":"com.google.android.apps.messaging","domain":"example.com","expiresAt":1762500300},
    {"id":"<uuid>","t":"notification","key":"0|pkg|1|tag|10123","pkg":"com.whatsapp","app":"WhatsApp",
       "title":"…≤120","text":"…≤1024","postedAt":1762500000,"iconHash":"sha256-16hex","icon":"<b64 png ≤8KB, only if Mac asked>",
       "actions":[{"i":0,"title":"Reply","input":true},{"i":1,"title":"Mark as read"}],"silent":false},
    {"id":"<uuid>","t":"notificationRemoved","key":"0|pkg|…"},
    {"id":"<uuid>","t":"call","callId":"<uuid>","state":"ringing|offhook|idle","number":"+91…","name":"Mom"},
    {"id":"<uuid>","t":"clipboard","mime":"text/plain","text":"…≤16KB","hash":"sha256"},
    {"id":"<uuid>","t":"link","url":"https://…≤2048","title":"…"},
    {"id":"<uuid>","t":"fileOffer","transferId":"<uuid>","name":"IMG_1.jpg","size":2301234,"mime":"image/jpeg","sha256":"…","chunkSize":262144}
  ],
  "eventsDropped": 0                            // phone-side overflow counter
}
// Mac -> phone
{
  "requestId":"<echo>", "desktopIPv6":"fe80::…",
  "ack": ["<event uuid>", …],                   // phone deletes acked events; resends others
  "nextPollMs": 2000,
  "needIcons": ["sha256-16hex"],
  "commands": [                                 // max 16; ordered
    {"id":"<uuid>","expiresAt":…,"a":"enable"},                       // legacy actions kept
    {"id":"<uuid>","expiresAt":…,"a":"ring"},
    {"id":"<uuid>","expiresAt":…,"a":"stopRing"},
    {"id":"<uuid>","expiresAt":…,"a":"sendSms","to":"+91…","body":"…≤1600"},
    {"id":"<uuid>","expiresAt":…,"a":"dismiss","key":"0|pkg|…"},
    {"id":"<uuid>","expiresAt":…,"a":"reply","key":"0|pkg|…","action":0,"text":"…≤1000"},
    {"id":"<uuid>","expiresAt":…,"a":"declineCall","callId":"<uuid>"},
    {"id":"<uuid>","expiresAt":…,"a":"silenceCall","callId":"<uuid>"},
    {"id":"<uuid>","expiresAt":…,"a":"setClipboard","mime":"text/plain","text":"…≤16KB","hash":"…"},
    {"id":"<uuid>","expiresAt":…,"a":"fileOffer","transferId":"<uuid>","name":"…","size":…,"sha256":"…","chunkSize":262144},
    {"id":"<uuid>","expiresAt":…,"a":"setMuted","pkgs":["com.foo"]}
  ]
}
```
Rules: unknown `t` or `a` values are acked or receipted with `ok:false` and otherwise ignored (forward compatible). Dedupe on both sides by id. TTLs: `ring` 60 s, `declineCall`/`silenceCall` 15 s, others 120 s. Keep `/v1/poll` until both apps ship v2. Bump `Invitation.version` to 2 for capability negotiation.

### 4.2 (d) File channel

- Endpoints: `POST /v2/file/<transferId>/<index>` (phone→Mac upload) and `POST /v2/file/<transferId>/<index>/get` (phone pulls Mac→phone; the phone always initiates, so no server is needed on the phone).
- Framing: `Content-Type: application/octet-stream`, body = `nonce(12) || ciphertext || tag(16)` in raw binary (no base64, no JSON). **Chunk 256 KiB.** AAD = `devswitch/file/v1/<deviceId>/<transferId>/<index>/<total>/<final 0|1>`. Putting `total` and `final` in the AAD prevents reordering and truncation. Bind with the transfer's `sha256` at the end.
- Resume: `GET`-equivalent `POST /v2/file/<id>/status` (sealed JSON) → `{"have":[0,1,2…]}`. Accepted offers are kept for 10 min. Partial file lives at `~/Downloads/.<id>.part`, deleted when the offer expires.
- Caps: 2 GB per file (configurable), 1 concurrent transfer, 4 in-flight chunks, per-transfer token. Reject chunks for transfers the user did not accept (**403**).
- `HTTPServer` changes: per-path limits (`/v2/poll` 32 KB JSON; `/v2/file/*` 256 KiB + 28 octet-stream). Accumulate into a preallocated buffer (today `bytes.append` copies the growing `Data` on every receive, so it is O(n²) for large bodies). Keep the 10 s deadline per chunk. Write to disk off the main actor.

### 4.3 (e) Hardening checklist for `HTTPServer.swift` and `Controller.handle`
- Raise the `seen` cap and add a Mac-side minimum interval per device (≥200 ms) → 429.
- Reject `events.count > 32`, `commands.count > 16`, and string fields over their caps. Strip control characters from titles and names before display.
- Constant-time `deviceId` comparison is not needed (the id is not secret), but **fail GCM before parsing any field**. This already holds.
- Unauthenticated paths stay limited to `/v1/pair/*` (rate-limited 90/min). Everything else returns 403 without a valid envelope.
- The extension IPC is a **Unix socket, not TCP**, so nothing new is exposed on the LAN.

---

## 5. Security and privacy

| Risk | Mitigation |
|---|---|
| **macOS persists notification text** in `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (moved there and protected by TCC in Sequoia). Removing a notification from the UI may not erase its contents **[V-secondary: 9to5Mac, Objective-See; U exact retention]** | This conflicts with "never persisted". **Never put OTP codes in UN notifications**: use the HUD panel or extension chip. For mirrored notifications, add a setting "Show message content in macOS notifications" (default **on** with a disclosure, or **off** = "WhatsApp: New message" + click to reveal in the HUD). Call `removeDeliveredNotifications` when the phone dismisses one |
| Logging | Never pass event payloads to `os_log`, `print`, `message`, `UserDefaults`, or crash reports. Today's `UserDefaults` diagnostics write only network metadata; keep it that way. Log only event type, counts, and ids. Android: the current `Log.w` lines print only exception messages, so make sure new code does not log `text`/`code` |
| In-memory lifetime | OTP: kept in memory ≤ 90 s or until consumed, then zeroed. Notification content: an in-memory ring of 50 for the "recent" panel, cleared when the app quits and on unpair |
| Clipboard leakage | Concealed and transient markers on everything DevSwitch writes (including the existing "Copy invitation"). Auto-clear OTPs at 90 s. Skip concealed sources when syncing |
| Keychain | Keep one item. Add `kSecAttrAccessible` on the **update** path too (`save` sets it only on add). For stable ACLs across rebuilds, sign with a stable identity. No new secrets are needed for native messaging |
| Extension | Minimal permissions: `nativeMessaging`, and content scripts on `<all_urls>`. No `host_permissions`, no `storage` of codes. A closed shadow-root chip. The code goes only to the frame that requested it |
| Native-host IPC | Socket in a 0700 directory, peer-signature check, request rate limit. Same-user malware remains out of scope (state this in docs) |
| LAN exposure | No new LAN listener. The file endpoints live behind the same pairing key. Metadata (sizes, timing) remains visible on the LAN, as it already is |

---

## 6. Test strategy (Mac side)

| Layer | How |
|---|---|
| Protocol codec | Swift: round-trip `Poll2`/`Reply2` through `SyncCrypto.seal/open`. Fixture JSON shared with Kotlin (`Protocol.kt`) under `test-vectors/`, using a fixed key and nonce to get byte-identical ciphertext on both sides. Cases: tampered AAD, wrong device, oversize lists, unknown `t`/`a`, duplicate ids |
| HTTPServer limits | Feed `HTTPServer.parse` (a pure static function) with boundary inputs: 32 KB±1 body, 16 KB headers, duplicate headers, `transfer-encoding`, wrong content type per path, partial bodies (`nil`). Add per-path file limits. Note that `build.sh` compiles `mac/*.swift` with `swiftc` and has no test target. Use a tiny SwiftPM package or `swiftc` a test `main.swift` with `-D TESTING` |
| Replay and rate | Unit-test `Controller.handle`: same `requestId` twice → 409, `sentAt` ±31 s → 400, and 600 valid polls in 120 s → all accepted after the cap is raised |
| OTP field detection | Playwright with `chromium.launchPersistentContext(dir, {args:['--disable-extensions-except=ext','--load-extension=ext']})` (headful or `headless:'new'`) loading static fixture pages: `autocomplete=one-time-code`, 6 split boxes, a React-controlled input, a field in a cross-origin iframe, and negative cases (password, card CVV, phone). Mock the native host with a stub `chrome.runtime.connectNative` in a test build. Check the chip appears, one click fills, the framework state updates, and nothing appears on negatives |
| Native host | Run the host binary with the length-prefixed stdin protocol in a shell test. Check the origin argument and the 1 MB cap |
| E2E with emulator | Emulator → Mac: **`10.0.2.2` = host loopback** **[V developer.android.com]**. The Mac listener binds all interfaces, so `http://10.0.2.2:45874` reaches it, and `Protocol.origin` accepts `10.x`. Pair by editing the invitation URL or picking the address. Connections arrive from 127.0.0.1, so macOS Local Network privacy does not apply. The IPv6 link-local path will not work on the emulator (no shared link), and `LocalLink.current` needs Wi-Fi transport (API 25+ simulated Wi-Fi), so it falls back to IPv4 by design. Drive events with the emulator console: `adb emu sms send 5551234 "Your code is 482913"` (OTP), `adb emu gsm call 5551234` / `gsm cancel` (calls) **[V emulator console docs]**, and `adb shell cmd notification post -S bigtext -t Title tag "body"` (notifications) **[U: exact flags]**. Assert on the Mac via a debug-only `--e2e-dump` state file without content (types and counts only) |

---

## 7. Recommended design per feature

| Feature | Recommendation |
|---|---|
| OTP | Phone `otp` event + immediate poll → Mac keeps it in memory 90 s → (1) HUD panel with code + Copy (concealed/transient, auto-clear 90 s), (2) Helium extension chip via native messaging (host manifest in `~/Library/Application Support/net.imput.helium/NativeMessagingHosts/`), (3) optional ⌃⌥V paste-type through Accessibility. No UN notification carries the code |
| Notifications | UN notifications, `threadIdentifier = pkg`, icon attachment, reply and dismiss actions, mute list synced to the phone, rate limiter, content-in-banner toggle |
| Find My Phone | `ring`/`stopRing` commands; hot polling while ringing |
| SMS | Composer window → `sendSms` command → receipt |
| Calls | Floating NSPanel + optional time-sensitive banner; `declineCall`/`silenceCall`; 500 ms polling while ringing |
| Links | `link` event → notification "Open in Helium/default" (auto-open opt-in) |
| Files | Offer/accept through the poll; 256 KiB AES-GCM chunks on `/v2/file/*`, resumable, quarantine applied, `~/Downloads` |
| Clipboard | `changeCount` timer, marker-based skip/loop prevention, 16 KB inline cap, honor `accessBehavior` |
| Transport | Poll v2: batched events with ack, command queue with receipts, `nextPollMs` adaptive 2 s / 0.5 s, separate binary file endpoint, per-path limits, raised replay cap |

## 8. Ranked risks

1. **macOS persists notification content** (usernoted DB). This contradicts the "never persisted" requirement for any content shown in a UN notification. Mitigation: no OTPs in notifications, plus a content toggle.
2. **Ad-hoc signature → TCC and Keychain grants break on every rebuild** (Accessibility for auto-type, Keychain ACL). Mitigation: a stable self-signed identity through `DEVSWITCH_SIGN_IDENTITY`, plus detection in the UI.
3. **Pasteboard privacy prompts** (`accessBehavior` default "ask") may arrive in a future macOS and break auto clipboard sync. Status on macOS 27 is unverified. Mitigation: a manual fallback.
4. **Helium specifics unverified**: unpacked-extension persistence and native messaging host launch in Helium have not been tested, even though the path logic is verified from Chromium source and the local folder. Test once early before building on it.
5. **Phone loop changes**: the out-of-cycle poll needs a wait primitive (interrupting today's loop kills it), plus a multi-receipt and dedupe set. Wake-lock and Doze behavior with 500 ms hot polling costs battery.
6. **Replay cap of 500 entries → 409** once polls exceed about 4/s. Must be raised before adaptive polling ships.
7. **Payload budget about 23 KB per message** on both sides (Android caps at 32 768 B). Batches, icons, and clipboard must be capped and split, and files must go through the separate channel.
8. Time-sensitive entitlement availability for ad-hoc builds is unverified. Calls rely on the NSPanel instead.
9. Script-filled OTP inputs (`isTrusted=false`) are rejected by a small number of sites.
10. A compromised or stolen phone can push links, files, and clipboard content. Click-to-open, quarantine xattr, and accept prompts are the defaults.

## Sources
- Chrome native messaging: https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- Chromium `chrome_paths.cc` (DIR_USER_NATIVE_MESSAGING): https://chromium.googlesource.com/chromium/src/+/main/chrome/common/chrome_paths.cc
- MV3 service-worker lifetime: https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle
- Helium: https://github.com/imputnet/helium (local install inspected: bundle `net.imput.helium`, 0.19.4.1)
- UNNotificationInterruptionLevel.timeSensitive: https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive
- UNTextInputNotificationAction: https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction
- UNNotificationAttachment: https://developer.apple.com/documentation/usernotifications/unnotificationattachment
- threadIdentifier: https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/threadidentifier
- NSPasteboard.changeCount: https://developer.apple.com/documentation/appkit/nspasteboard/changecount
- NSPasteboard.AccessBehavior (15.4): https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum
- Pasteboard privacy preview and status: https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4
- AXIsProcessTrustedWithOptions: https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- nspasteboard.org marker types: http://nspasteboard.org/
- UN authorization needs a signed bundle: https://mirror.b10c.me/bitcoin-core-gui/112/ , https://forum.xojo.com/t/macos-unusernotificationcentermbs-user-notifications-works-during-debug-but-dont-work-for-build-app/83588
- Notification DB persistence: https://9to5mac.com/2024/09/01/security-bite-apple-addresses-privacy-concerns-around-notification-center-database-in-macos-sequoia/ , https://objective-see.org/blog/blog_0x2E.html
- Emulator networking (10.0.2.2): https://developer.android.com/studio/run/emulator-networking-address
- Emulator console (sms send / gsm call): https://developer.android.com/studio/run/emulator-console
