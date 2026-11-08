# PIID — Persistent wireless control: no 7-day trust loss, no typing IP:port
> **Source request:** "After some time if I try to control my phone, it's not able to… When I am trying to show it to somebody, it doesn't connect. It's not reliable… If I am connected, after a week it should be directly and easily able to connect to my phone. It should be fully dynamic." Plus: "we need to manually type the IP and the [port]… very irritating." — Shivansh, 2026-11-07

# 1. Context
## Problem
**Control phone** fails after the phone sits unused for about a week. The companion link (encrypted Mac ↔ phone polling on TCP 45874) stays healthy the whole time. Only the ADB layer fails.

Live evidence from 2026-11-07:
- The companion was online: `connection.lastSeen` was 1s old, over IPv6.
- The phone's ADB port was reachable: `nc -z 192.168.29.30 39849` succeeded.
- `adb connect` failed every time.
- The adb server log (`$TMPDIR/adb.501.log`) shows `Post-handshake SSL_peek failed [SSLV3_ALERT_CERTIFICATE_UNKNOWN]`. This means the phone no longer trusts this Mac's ADB key.
- The last successful handshake was `10-31 20:01:09`. The first rejection was `11-07 17:39:30`, 7 days and 21 hours later.
- The same rejection happened on `10-31 13:17`. The user re-paired, and it worked from `13:18`.

Cause: Android revokes ADB authorizations that have not connected within `Settings.Global.adb_allowed_connection_time`. The default is 604800000 ms (7 days), counted from the last successful connection. DevSwitch cannot tell this failure apart from a network error. It retries, then shows a generic message.

The second problem is setup. Wireless control setup makes the user type the pairing IP:port, the 6-digit code, and sometimes a second connection IP:port (`WirelessSetupView`, `finishPair`).

## Why this needs a fix
The tool exists to connect instantly, for example when demoing to someone. When the connection fails, the user has to re-pair by typing addresses, which defeats the product.

## Goal
- Once wireless control is paired, **Control phone** keeps working indefinitely: across weeks, IP changes, ADB port changes and phone reboots. It needs no user input while both devices are on the same Wi-Fi.
- Set up (or re-pair) by scanning one QR code. The only fallback asks for 6 digits; the address is found automatically.
- When something fails, the Mac names the failing layer and its single fix.

# 2. References & Blast Radius
Read these in this order. It follows a Control-phone press end to end.

- Menu button → `screen.start(controller:)` [mac/DevSwitch.swift:116-129]
- Main connect flow: enable dev settings via companion, pick endpoint, `adb connect`, verify serial, launch scrcpy [mac/ScreenControl.swift:168-285]
  - inner `connect()` and the `kill-server` restart [mac/ScreenControl.swift:196-228, :205-211]
  - endpoint candidate order: IPv6 from companion → already-connected devices → companion `wifiEndpoint` → Bonjour → `lastEndpoint` [mac/ScreenControl.swift:229-262]
- Current wireless pairing (typed address + code), then the post-pair connect loop [mac/ScreenControl.swift:94-144]; manual second step `finishPair` [mac/ScreenControl.swift:145-167]
- Address parser to reuse for every host:port [mac/ScreenControl.swift:47-65]
- Bonjour browser, hardcoded to `_adb-tls-connect._tcp.`, IPv4-only resolve [mac/BonjourDiscovery.swift:13-58]
- Setup UI with three text fields [mac/DevSwitch.swift:268-305]
- **Pattern to mirror for the QR:** companion pairing QR via `CIFilter.qrCodeGenerator` [mac/DevSwitch.swift:259-265]
- Companion status model; new fields must be optional for old/new compatibility [mac/Controller.swift:18-21]
- Poll handler that receives status and sends commands [mac/Controller.swift:125-157]
- Info.plist `NSBonjourServices`; browsing a type missing here silently finds nothing [mac/build.sh:37]
- Phone status builder, runs on every poll (about 2s) [app/.../remote/RemoteService.kt:65-78]
- Phone poll loop: the IPv6/IPv4 alternation [RemoteService.kt:108, :120, :132]; command expiry window [RemoteService.kt:125-129]
- Phone enable/disable writes [RemoteService.kt:140-158]
- Phone reports its own ADB endpoint via NSD [app/.../remote/WirelessEndpoint.kt]
- Live state to inspect: `defaults read dev.notsg.devswitch` (keys `screen.*`, `connection.*`); `$TMPDIR/adb.$(id -u).log` (grep `CERTIFICATE_UNKNOWN`, `Handshake succeeded`)
- adb CLI used: `adb pair HOST:PORT CODE` (the QR password goes in the CODE slot); `adb mdns services`

`app/...` = `app/src/main/java/com/himphen/playground/developeroptionstoggle`.

_Written 2026-11-07 ~17:50 IST against commit `4f9ae3b`. If repo behavior has drifted since this commit, stop, flag it to the user, and rework this piid._

# 3. Analysis
## Solution
- **Stop the expiry at the source.** On every poll, the phone app (which holds `WRITE_SECURE_SETTINGS`) checks `Settings.Global` `adb_allowed_connection_time`. If it isn't `0`, the app writes `0`. It reports the result in status as `adbTrustPersistent`. This equals the developer option "Disable adb authorization timeout." Approved by the user, with the trade-off that the Mac stays trusted until revoked on the phone.
- **QR wireless pairing (primary).** The Mac generates a service name and password and shows `WIFI:T:ADB;S:<name>;P:<password>;;` as a QR code. The user scans it from the phone's Wireless debugging → **Pair device with QR code** screen. The phone then advertises `_adb-tls-pairing._tcp` with instance name `<name>`. The Mac browses for it, resolves it, runs `adb pair host:port <password>`, then reuses the existing post-pair connect and serial save.
- **Code fallback.** In the **Pair with pairing code** screen, the phone also advertises `_adb-tls-pairing._tcp`. The Mac picks the instance whose resolved IPv4 equals the companion-reported `lanIPv4`, so the user types only the 6 digits. A manual pairing-address field appears only if nothing is found within 20s.
- **Delete the second manual step** (`needsConnectionAddress` / `finishPair`). After pairing, the connect endpoint comes from the companion's `wifiEndpoint` (already reported) or from Bonjour.
- **Detect lost trust.** If `adb connect` fails but a plain TCP connection to the same endpoint succeeds, the phone is rejecting the key. Set `screen.trustLost` and show "Your phone forgot this Mac — re-pair (one scan)". That button opens Connection settings with the QR already showing.
- **Fix the review bugs on this path:**
  - The phone keeps using whichever transport last worked. It retries IPv6 every 60s instead of on every other poll.
  - The phone accepts a command when `expiresAt` is within `now-30 .. now+60`, matching the Mac's ±30s clock tolerance.
  - `adb kill-server` only runs on the final (non-fallback) "no route to host", never during the IPv6 attempt.
- **Layer-specific messages:** phone offline; settings permission missing; Wireless debugging not on or Wi-Fi network not allowed; trust lost; phone not found on Wi-Fi.

## Iterations
**Preliminary solution:** Disable the timeout, plus a background keep-alive that reconnects every few hours, plus QR re-pair, plus bug fixes.

**Findings:**
- `adb connect` output for trust loss is just `failed to connect to <ep>` with no reason. Parsing the adb log file is fragile: **detect by "TCP reachable + adb rejects"** using `NWConnection` with a 2s timeout.
- Keep-alive can't help when Wireless debugging is off for a week (after **Disable development**). The timeout write covers every case. **Drop keep-alive.**
- Writing the timeout once could be undone by the user or the OEM. **Re-assert it on each poll.** It's a cheap global read, and it writes only when the value differs.
- The QR password works as `adb pair`'s code argument; this is the same SPAKE2 flow Android Studio uses. Local `adb help` confirms `pair HOST[:PORT] [PAIRING CODE]`. **Use the CLI. Don't use the adb server's QR support.**
- `BonjourDiscovery` hardcodes one service type. **Parametrize the type** and run a second instance for pairing, rather than writing a new class.
- `_adb-tls-pairing._tcp` is missing from `NSBonjourServices`. Without it, the macOS Local Network gate returns nothing, with no error. **Add it.**
- `finishPair` only existed because the post-pair loop couldn't always find the connect port. The companion now reports `wifiEndpoint` with the live port (Android 14+ subscribes to port updates). **Delete it.**
- `restartedServer` kills the user's other ADB sessions, such as Android Studio, whenever IPv6 is unreachable. **Restrict it to the final attempt.**
- Phone IPv6 alternation: `useIPv6 = true` after an IPv4 success makes every other poll wait up to 4s on a dead path. That pushes successful polls about 8s apart, close to the Mac's 10s "Offline" threshold. **Make the transport sticky, with a 60s IPv6 retry.**

# 4. Implementation Instructions
One agent, in this order. The code is one repo, two apps.

No test files or test runs; the user's defaults forbid them. Verify with builds and the live device check in step 8.

1. **Phone — persistent trust + status field** (`RemoteService.kt`)
   - In `status()`: if `WRITE_SECURE_SETTINGS` is granted and `Settings.Global.getLong(cr, "adb_allowed_connection_time", 604800000L) != 0L`, call `Settings.Global.putLong(cr, "adb_allowed_connection_time", 0L)`.
   - Add `.put("adbTrustPersistent", <value read back == 0L>)`.
   - Wrap it in try/catch so one failing write never breaks the poll.
2. **Phone — sticky transport + clock window** (`RemoteService.kt` loop)
   - Keep a `var ipv6RetryAt = 0L`.
   - At loop start: `if (!useIPv6 && now >= ipv6RetryAt) useIPv6 = true`.
   - On success: leave `useIPv6` as it is (delete line 120).
   - On failure: if this attempt used IPv6, set `useIPv6 = false; ipv6RetryAt = now + 60_000`. Otherwise flip back to IPv6 so a dead IPv4 path also falls over.
   - Change the command check to `expiry in (now - 30)..(now + 60)`.
3. **Mac — model + plist**
   - `PhoneStatus.adbTrustPersistent: Bool?` [Controller.swift:18].
   - Add `<string>_adb-tls-pairing._tcp</string>` to `NSBonjourServices` [build.sh:37].
4. **Mac — discovery**
   - `BonjourDiscovery.init(type: String)`; `refresh()` browses `type`.
   - The existing instance passes `"_adb-tls-connect._tcp."`.
   - `ScreenControl` owns a second instance `pairing = BonjourDiscovery(type: "_adb-tls-pairing._tcp.")`.
   - `endpoints` is already keyed by instance name, which the QR match needs.
5. **Mac — pairing flow** (`ScreenControl.swift`)
   - Extract the post-pair loop body [:110-140] into `private func completePairing(host:phoneID:connectionEndpoint:token:) async throws`. Keep its behavior, but delete the `needsConnectionAddress` ending. On failure, throw a clear message.
   - `startQRPairing(phoneID:connectionEndpoint:)`:
     - Make `name = "devswitch-" + 8 random alnum` and `password = 12 random alnum`.
     - Publish `@Published var qrPayload: String?` = `"WIFI:T:ADB;S:\(name);P:\(password);;"`.
     - Call `pairing.refresh()`. Poll `pairing.endpoints[name]` every 500ms for up to 120s.
     - When found, run `adbRun(["pair", endpoint, password], timeout: 25)` and require `"Successfully paired"`.
     - Then call `completePairing`. Clear `qrPayload` on finish or cancel.
     - Use the existing `generation`/`operation` token pattern for cancellation.
   - `pairWithCode(code:phoneID:lanIPv4:connectionEndpoint:manualAddress:)`:
     - If `manualAddress` is nil, browse pairing services for up to 20s and pick the one whose host == `lanIPv4`.
     - If none is found, set `@Published var needsPairingAddress = true` and return.
     - Otherwise run `adb pair` with the code (via stdin, as today), then `completePairing`.
   - Delete `pair(address:...)`, `finishPair`, `needsConnectionAddress`, `pendingPairHost`, `pendingPhoneID`.
6. **Mac — connect reliability + trust detection** (`ScreenControl.start`)
   - In inner `connect()`: only take the `kill-server` branch when `!fallbackAvailable`.
   - After a failed `adb connect` to an endpoint, probe TCP with `NWConnection(host:port:using: .tcp)`, waiting up to 2s for `.ready`. Add a small helper `reachable(_ endpoint:) async -> Bool`. Use `ScreenControl.endpoint()` to split host and port, and strip the brackets for IPv6.
   - If it is reachable, set `@Published var trustLost = true` and throw `"Your phone forgot this Mac. Choose Re-pair and scan the QR from Wireless debugging → Pair device with QR code."`
   - Reset `trustLost = false` after any successful pairing or connect.
   - Before endpoint selection, if `controller.status?.wifi == true` but there is no `wifiEndpoint` and no candidates, say "Wireless debugging is on but Android isn't advertising it. Open Wireless debugging on the phone and allow this Wi-Fi network."
   - If `controller.status?.permission == false`, say so instead of the current "not ready" message.
7. **Mac — UI** (`DevSwitch.swift`)
   - Rewrite `WirelessSetupView`. The primary state shows "On your phone: Wireless debugging → Pair device with QR code" plus the QR rendered from `screen.qrPayload`. Generalize `qr(_:)` to take a `String`.
   - Show a "Use pairing code instead" disclosure with a single 6-digit `SecureField`.
   - Show the pairing-address field only when `screen.needsPairingAddress`.
   - Paired state keeps "Pair again…".
   - In `MenuPanel`: when `screen.trustLost`, the primary button becomes **Re-pair wireless control**. It opens the settings window, which auto-starts QR pairing `.onAppear` if `trustLost`.
   - Starting QR pairing must not require `screen.isPaired`.
8. **Verify**
   - Run `./devswitch build` and `./gradlew :app:assembleDebug`, and install both.
   - On the phone after one poll: `adb shell settings get global adb_allowed_connection_time` → `0`. Over USB if wireless isn't paired yet.
   - Re-pair live by QR: the current Mac trust is already revoked, so this is the real user path. Then **Control phone** must open scrcpy.
   - Toggle **Disable development**, then **Control phone**. It must connect with no input, on the new ADB port.
   - Optional: `adb shell settings put global adb_allowed_connection_time 604800000`. Within one poll it must read `0` again.
   - Update `docs/installation.md` and `README.md` step 5 to describe QR pairing, and remove the typed-address instructions.

# 5. Miscellaneous
- The Mac still advertises an unused `_devswitch._tcp` service [mac/HTTPServer.swift:47]. Leave it unless removing it is trivial; it's out of scope.
- Future idea: a phone notification "Re-pair needed — open Wireless debugging" when the Mac reports `trustLost`. This needs a new companion command; not now.
- Edge case: OEM skins (iQOO/OriginOS) might ignore `adb_allowed_connection_time`. Step 8's readback plus `adbTrustPersistent` in status will show it. If ignored, the fallback is a keep-alive connect while `wifi` is true.
- Revoking Mac access now requires the phone's **Revoke USB debugging authorizations** (or Wireless debugging → Paired devices → Forget). Mention this in the README notes.
