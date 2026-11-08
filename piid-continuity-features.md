# PIID — DevSwitch continuity features on protocol v2
> **Source request:** Build the next DevSwitch feature set: protocol v2 transport (event queue with acks, multi-command replies with receipts, interruptible 2 s wait with immediate poll on events, 500 ms while hot, status only when changed, raised replay cap, separate chunked file endpoint); phone status in the menu bar; OTP (notification listener + SMS backup, shared extractor, dedupe; Mac banner without digits, HUD, concealed/transient clipboard cleared at 90 s, Helium MV3 extension via native-messaging host over a Unix socket, Accessibility auto-type); notification mirroring with mute/dismiss/reply; Find My Phone; send SMS from the Mac; incoming call panel with Decline/Silence; send link to Mac; file drop both ways; shared clipboard; stable self-signed signing identity; `ACCESS_LOCAL_NETWORK` for Android 17. Tests requested by the owner. — Shivansh, 2026-11-07

# 1. Context

## Problem
DevSwitch today is a one-way remote switch. The phone (`RemoteService`) polls the Mac every 2 s and each exchange carries one status, at most one receipt up, and at most one command down (`enable`/`disable`). Payloads are capped at 32 KB, and interrupting the 2 s sleep kills the loop. None of the continuity features (OTP, notifications, calls, SMS, files, clipboard) can be built on that transport.

## Why this needs a fix
The owner wants Continuity-style phone↔Mac features for an iQOO Z6 Pro (Funtouch OS 14 / Android 14) paired with a Mac on macOS 27 using the Helium browser. OTP autofill and call alerts are the daily-use drivers. Each needs sub-second delivery, several items per exchange, and a channel for large files.

## Goal
- Protocol v2 on both sides: batched, acked events up; queued commands with receipts down; adaptive 2 s / 500 ms polling with an immediate poll on events; separate encrypted chunked file endpoint.
- All features listed in the source request work end to end on the iQOO and on the `devswitch-test` emulator where the emulator can simulate them.
- No OTP digits ever reach disk on the Mac (no UN notification, no logs, no UserDefaults).
- Kotlin, Swift, Playwright and emulator E2E tests as specified in §4 (e).

The **Decisions table** at the top of `research-continuity-features.md` is binding. Parts A and B of that file hold the evidence and the exact API calls. This ticket tells you what to build, in what order, and in which files. §3 lists the places where this ticket deliberately deviates from or sharpens the research.

# 2. References & Blast Radius

Read in this order (it follows a poll from the phone to the Mac and back). Line numbers are for the **working tree** of branch `persistent-wireless` at the time of writing (HEAD `4f9ae3b` + uncommitted changes).

**Design inputs**
- Binding decisions + evidence: `research-continuity-features.md` (Decisions table lines 8–24; Android §1–§9; Mac §1–§6; poll v2 schema §4.1 lines ~451–493; file channel §4.2; hardening §4.3).
- UI placement for every new surface: `/private/tmp/claude-501/-Users-notsg-shivansh-notsg-devswitch/5a21e7d1-0121-4cec-ae50-cce1b8018a15/scratchpad/ui-design.md` §2 (IA, `[future]` slots), §8 (future surfaces), §9 (component names). If that scratchpad file is gone, the redesigned views themselves (`mac/MenuPanelView.swift`, `mac/SettingsView.swift`, `mac/ViewComponents.swift`, `ui/screen/*.kt`) carry the same component names.
- Architecture diagram: `.archify/architecture-continuity-features-20261107-213107/continuity-features.html`. Sequences: `.archify/sequence-continuity-otp-call-20261107-213107/otp-sequence.html`, `.archify/sequence-continuity-call-20261107-213107/call-sequence.html`.

**Phone side (request path)**
- Foreground service, status builder, poll loop, single-command execute: `app/src/main/java/com/himphen/playground/developeroptionstoggle/remote/RemoteService.kt` — `status()` ~L68, `loop()` ~L93, transport fallback in the `catch` ~L149–153, `Thread.sleep(2000)` that breaks on interrupt ~L155, `execute()` ~L160, `onDestroy()` interrupts the worker ~L179.
- Envelope crypto + HTTP clients: `remote/Protocol.kt` — `seal/open` L32–50 (32 768 B ciphertext cap L48), IPv4 `post` L74–102, IPv6 link-local `postLinkLocal` L106–158. Uses `android.util.Base64` (L26–31), which does not work in JVM unit tests.
- Link selection: `remote/LocalLink.kt` (whole file, 40 lines). ADB mDNS: `remote/WirelessEndpoint.kt` (unchanged by this work).
- Pairing UI and invitation parsing: `remote/PairingActivity.kt` L229 hard-requires `invitation.version == 1`.
- Manifest: `app/src/main/AndroidManifest.xml` — permissions L5–15, `RemoteService` with `foregroundServiceType="connectedDevice"` L29–30.
- Build/test config: `app/build.gradle.kts` (minSdk 29, targetSdk 37, only `junit` + coroutines-test for unit tests), `gradle/libs.versions.toml`. Existing unit test to mirror: `app/src/test/java/com/himphen/playground/developeroptionstoggle/MainViewModelTest.kt`.

**Mac side**
- Listener and HTTP framing: `mac/HTTPServer.swift` — `parse` L87–113 (POST only, `application/json` only, body ≤32 KB, total ≤48 KB), `respond` L115–122 (body ≤64 KB else 500, always `Content-Type: application/json`), 16 connections, 10 s deadline L58–68, `bytes.append` growth L74–75.
- Poll handler: `mac/Controller.swift` — v1 models L18–26, `send()` single pending command L109–114, `handle()` L126–158 (replay map `seen` capped at 500 → 409 at L136), Keychain `save()` L70–79 (`kSecAttrAccessible` only on add).
- Crypto: `mac/Crypto.swift` (40 lines; `open` caps ciphertext at 64 KB).
- App entry and `--doctor` early-exit pattern to mirror for the native host: `mac/DevSwitch.swift` L6–8.
- Redesigned views (being edited by another agent right now — see §4 ownership): `mac/MenuPanelView.swift`, `mac/SettingsView.swift` (pasteboard write for the pairing invitation at L155, no concealed markers), `mac/ViewComponents.swift` (`ModuleTile`, `ModuleGlyph`, `StatusLine`, `MenuRow`).
- Build and signing: `mac/build.sh` — `swiftc mac/*.swift` (every `.swift` in `mac/` is compiled, so test files must live elsewhere), Info.plist heredoc, `codesign --sign "${DEVSWITCH_SIGN_IDENTITY:--}"`.
- Docs to update at the end: `docs/architecture.md`, `docs/installation.md`.

**Environment**
- Helium user-data dir exists: `~/Library/Application Support/net.imput.helium/` (native host manifests go in its `NativeMessagingHosts/`).
- Emulator: `/opt/homebrew/share/android-commandlinetools/emulator/emulator -avd devswitch-test` (API 35, arm64, Play image). Serial `emulator-5554`. It reaches the Mac at `10.0.2.2:45874`.
- Gradle: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ./gradlew ...`
- Node 22 + `npx` are installed (for Playwright).

Written 2026-11-07 21:45 local, last commit `4f9ae3b6b72b2cb9c9b34bac71ea7badbfe201c6` (working tree dirty: UI redesign + persistent-wireless changes in `RemoteService.kt`, `Controller.swift`, `ScreenControl.swift`, `DevSwitch.swift`, views). If repo behavior has drifted since this commit, stop, flag it to the user, and rework this piid.

# 3. Analysis

## Solution
- **Transport stays a 2 s phone-initiated poll** (no long-poll, no server on the phone). New endpoint `/v2/poll` with AAD `devswitch/poll/v2/<deviceId>` / `devswitch/reply/v2/<deviceId>`, schema exactly as research §4.1. `/v1/poll` stays working for an old phone app.
- **Phone:** a process-wide `Outbox` (ids, kept until acked, 200-event cap, OTP/call never dropped first, 5 min expiry offline) plus `kick()`. The loop waits on a `Semaphore.tryAcquire(nextPollMs)` instead of `Thread.sleep`. It polls again at once when the outbox still has items or the reply set `nextPollMs: 0`. Receipts become a list; the phone dedupes command ids against a 64-entry set.
- **Mac:** `pending: Command?` becomes an ordered queue (≤16, per-command TTL: ring 60 s, call 15 s, others 120 s). The reply carries `ack[]`, `commands[]`, `nextPollMs` (2000 idle; 500 for 30 s while a call rings, a transfer runs, commands are queued, or the menu panel is open), `needIcons[]`. `seen` cap goes from 500 to 2048. Events are deduped by id (LRU 512) and handed to an event router.
- **Status only when changed:** the phone sends full `status` when its hash changed or every 30 s, else omits it. `PhoneStatus` gains optional `battery`, `charging`, `network`, `sims`, `ringing`, `listenerConnected`.
- **File channel:** `POST /v2/file/<transferId>/<index>` (upload), `POST /v2/file/<transferId>/<index>/get` (phone pulls), `POST /v2/file/<transferId>/status` (resume). Raw binary `nonce(12)‖ciphertext‖tag(16)`, 256 KiB chunks, AAD `devswitch/file/v1/<deviceId>/<transferId>/<index>/<total>/<final>`. `HTTPServer` gets per-path limits and binary responses. Offers and accepts travel as normal poll events/commands.
- **OTP:** `NotifListener` + `SmsReceiver` → pure `OtpExtractor` → dedupe by code for 90 s → high-priority `otp` event + `kick()`. Mac `OtpVault` keeps the code in memory ≤90 s; banner without digits; HUD panel with digits; concealed+transient clipboard cleared at 90 s if `changeCount` unchanged; Helium chip via native messaging; ⌃⌥V auto-type through Accessibility.
- **Helium:** MV3 extension (content script + service worker) → `chrome.runtime.connectNative("dev.notsg.devswitch")` → the DevSwitch binary in host mode → Unix socket `~/Library/Application Support/DevSwitch/ext.sock` → running app's `OtpVault`. No new TCP listener.
- **Other features** follow the research "Recommended design per feature" tables (Android Part A end, Mac Part B §7) without change.
- **Signing:** a stable self-signed code-signing identity created once on this Mac and passed through the existing `DEVSWITCH_SIGN_IDENTITY` hook, so Accessibility and Keychain grants survive rebuilds.
- **Android 17:** declare and request `ACCESS_LOCAL_NETWORK`; add FGS type `remoteMessaging`.

## Iterations
**Preliminary solution:** follow the research verbatim, including byte-identical cross-language test vectors, an invitation version bump to 2, a 250 ms Mac-side floor returning 429, and a hard-coded `/Applications` host path.

**Findings:**
- Invitation version bump breaks pairing: `PairingActivity.kt:229` rejects any version other than 1, and that file is owned by the UI agent → **keep `Invitation.version = 1`**. The phone detects v2 by calling `/v2/poll`; on HTTP 404 it falls back to `/v1/poll`. The Mac serves both.
- 429 floor vs immediate re-poll: the research sets both "floor 250 ms → 429" and "`nextPollMs: 0`". The phone's `catch` (RemoteService ~L149–153) treats any non-200 as a transport failure and demotes IPv6 for 60 s → **Mac floor is 150 ms and only counts polls the Mac did not ask for; the phone treats 409/429 as "retry after `nextPollMs`", never as a transport failure.**
- Byte-identical ciphertext from JSON is impossible: Swift `JSONEncoder` escapes `/` and orders keys differently from `org.json` → **test vectors fix the plaintext bytes** (a UTF-8 string in the vector file). Both sides must produce identical ciphertext+tag from (key, nonce, aad, plaintext bytes), and each side must open the other's vector and decode the same fields.
- JVM unit tests cannot touch `android.util.Base64` or the android.jar `org.json` stubs → **Protocol.kt switches to `java.util.Base64`** (API 26+, minSdk is 29) and the test classpath adds `org.json:json`.
- `HTTPServer.respond` caps bodies at 64 KB and always says JSON → **add a binary response path and per-path caps**; the research only mentioned request limits.
- Seal must accept an injected nonce for test vectors → `Protocol.seal(..., iv: ByteArray = bytes(12))` and `SyncCrypto.seal(..., nonce: AES.GCM.Nonce? = nil)`. Production never passes it.
- Host manifest path: dev builds run from `mac/build/DevSwitch.app`, releases from `/Applications` → **write the manifest at install time from `Bundle.main.executablePath`**, not a constant.
- `PhoneStatus.status` is non-optional in Swift (Controller.swift L24) → v2 model makes it optional and keeps the last known status.
- The emulator image is API 35: the NLS sees **redacted** OTPs (Android 15 rule). E2E proves OTP through the SMS receiver; NLS OTP is proven only on the iQOO (or after `appops set ... RECEIVE_SENSITIVE_NOTIFICATIONS allow`, which may or may not work).
- Research cites "Copy invitation" at `DevSwitch.swift:242`; after the redesign it lives at `SettingsView.swift:155` → that fix belongs to workstream (c).
- The research asks to verify Helium's unpacked-extension persistence and native-host launch before building on it → this is step (d)1, a 15-minute spike that gates the rest of (d).

# 4. Implementation Instructions

## Delegation and file ownership

Five workstreams. **(a) goes first and merges before anything else starts.** After (a) lands, (b), (c), (d) and (e) run in parallel; no file is edited by two of them. A file listed under one workstream is read-only for the others. "Creates" means the workstream adds the file; after (a), stub files it created pass to the workstream named.

| Workstream | Owns (edits or creates) |
|---|---|
| (a) Protocol v2 | `mac/HTTPServer.swift`, `mac/Crypto.swift`, `mac/Controller.swift`, creates `mac/ProtocolV2.swift`, `mac/FileChannel.swift`, `mac/EventRouter.swift` (stub, then → c); `remote/Protocol.kt`, `remote/RemoteService.kt`, `remote/LocalLink.kt` (only if needed), creates `remote/Outbox.kt`, `remote/FileTransfer.kt`, `remote/Commands.kt` (stub, then → b); `app/src/main/AndroidManifest.xml` (then → b); `app/build.gradle.kts`, `gradle/libs.versions.toml` (then → e) |
| (b) Android features | after (a): `remote/Commands.kt`, `AndroidManifest.xml`; creates `remote/NotifListener.kt`, `remote/SmsReceiver.kt`, `remote/OtpExtractor.kt`, `remote/CallWatcher.kt`, `remote/FindMyPhone.kt`, `remote/SmsSender.kt`, `remote/ShareToMacActivity.kt`, `remote/ClipTile.kt`, `remote/ClipboardBridge.kt`, `remote/Received.kt` (MediaStore writer + "Received from Mac" notification), `remote/MutedApps.kt`; Android UI hookups in `ui/**`, `MainActivity.kt`, `remote/PairingActivity.kt`, `res/**` |
| (c) Mac features + UI | after (a): `mac/EventRouter.swift`; creates `mac/OtpVault.swift`, `mac/OtpHUD.swift`, `mac/AutoType.swift`, `mac/NotificationMirror.swift`, `mac/CallPanel.swift`, `mac/ClipboardSync.swift`, `mac/SmsComposerView.swift`, `mac/AppDelegate.swift`, `mac/E2EProbe.swift`; edits `mac/MenuPanelView.swift`, `mac/SettingsView.swift`, `mac/ViewComponents.swift`, `mac/DevSwitch.swift` |
| (d) Helium + host + signing | creates `extension/` (manifest, service worker, content script, chip CSS, `key`), `mac/NativeHost.swift`, `mac/ExtensionSocket.swift`, `scripts/make-signing-identity.sh`; edits `mac/build.sh` |
| (e) Tests | after (a): `app/build.gradle.kts`, `gradle/libs.versions.toml`; creates `app/src/test/.../remote/OtpExtractorTest.kt`, `.../remote/ProtocolV2Test.kt`, `test-vectors/`, `mac-tests/` (Swift test sources + runner script, outside `mac/` because `build.sh` compiles every `mac/*.swift`), `extension-tests/` (Playwright), `scripts/e2e-emulator.sh`; edits `.gitignore` for test outputs |

**UI files are being redesigned by another agent right now** (`mac/*View*.swift`, `mac/DevSwitch.swift`, Android `ui/**`, `PairingActivity.kt`). Do not start (b)'s or (c)'s UI steps until the owner confirms that redesign has landed. (a) must not touch them at all.

**Interfaces fixed up front** so (b), (c), (d) can work in parallel. Implement these signatures exactly in (a) and (c)/(d):

```swift
// mac/EventRouter.swift — created by (a) as a stub that only logs type + id; (c) fills it in.
@MainActor final class EventRouter {
    init(controller: Controller)
    func handle(_ event: PhoneEvent)            // called once per new (deduped) event id
}
// mac/Controller.swift — (a)
func enqueue(_ command: OutgoingCommand)        // queues even when offline (≤16, oldest non-call dropped); TTL handles staleness
var onReceipt: ((String /*commandId*/, Receipt) -> Void)?
func requestHotPolling(for seconds: TimeInterval) // menu panel open, transfer, call
// mac/FileChannel.swift — (a)
func offerToPhone(file: URL) throws -> String     // returns transferId; enqueues fileOffer command
func accept(offer: FileOfferEvent)                // phone→Mac; Mac then answers chunks; writes ~/Downloads
// mac/OtpVault.swift — (c). (d) calls only these two.
@MainActor final class OtpVault { static let shared: OtpVault
    func current() -> (code: String, source: String, domain: String?)?   // nil if >90 s or consumed
    func consume() }
// mac/NativeHost.swift — (d). (c) calls these from DevSwitch.swift / SettingsView.swift.
enum NativeHost { static var isHostInvocation: Bool   // argv[1] has prefix "chrome-extension://"
    static func run() -> Int32
    static func installHostManifest(extensionID: String) throws
    static func installExtensionFolder() throws -> URL }
// mac/ExtensionSocket.swift — (d). (c) starts it once in AppDelegate.
@MainActor final class ExtensionSocket { func start(vault: OtpVault) }
```
```kotlin
// remote/Outbox.kt — (a)
object Outbox { fun add(type: String, fields: JSONObject, priority: Boolean = false): String /*eventId*/
                fun kick() }
// remote/Commands.kt — created by (a) with enable/disable moved out of RemoteService; (b) adds the rest.
object Commands { fun execute(context: Context, command: JSONObject): JSONObject /*receipt*/ }
// remote/FileTransfer.kt — (a)
object FileTransfer { fun upload(context: Context, uri: Uri, name: String, size: Long, mime: String): String /*transferId*/
                      fun download(context: Context, offer: JSONObject, sink: java.io.OutputStream) }
```

---

## (a) Protocol v2 — both sides (first; the dependency)

Steps:
1. **Kotlin codec seam.** In `Protocol.kt` replace `android.util.Base64` with `java.util.Base64` (`getEncoder()`/`getDecoder()`, no wrap). Add optional `iv: ByteArray = bytes(12)` to `seal`. Add `sealBytes(plain: ByteArray, key, aad, iv = bytes(12)): ByteArray` and `openBytes(...)` for the binary file framing (`nonce‖ct‖tag`). Keep the 32 768 B cap for `/v*/poll`; add `postBytes(origin, path, body): Pair<Int, ByteArray>` with a 300 KiB cap for `/v2/file/*`, for both the IPv4 and IPv6-link-local paths (reuse the hand-rolled socket for link-local; parametrise content type and cap).
2. **Swift codec seam.** `SyncCrypto.seal(_:key:aad:nonce:)` with optional nonce; add `sealBytes`/`openBytes` for raw framing. Create `mac/ProtocolV2.swift` with `Poll2`, `Reply2`, `PhoneEvent` (decode `t` into an enum with an `.unknown(String)` case and keep raw JSON for unknown fields), `OutgoingCommand`, `Receipt`, and `PhoneStatus` v2 (all new fields optional). Field names and caps from research §4.1. Strip control characters from every display string at decode. Additions to the research schema (both sides): commands `fileAccept{transferId}` / `fileDecline{transferId}` (Mac answers a phone `fileOffer` event), `setClipboard.sensitive: Bool`; event `smsStatus{commandId, part, result}`.
3. **HTTPServer.** Per-path rules in `parse`: `/v1/*` and `/v2/poll` keep JSON ≤32 KB; `/v2/file/*` accepts `application/octet-stream` ≤ 256 KiB + 28 B (or JSON for `/status`). Preallocate the receive buffer from `Content-Length` once headers are parsed instead of growing `Data`. `HTTPResponse` gets a `contentType` (default JSON); `respond` caps at 64 KB for JSON and 300 KiB for octet-stream. Keep the 16-connection limit and 10 s deadline per connection (one chunk per connection).
4. **Controller v2.** Route `/v2/poll` to a new `handleV2`, keep `handle` for `/v1/poll` unchanged. In `handleV2`: open envelope (fail GCM before parsing fields), check `sentAt` ±30 s and `requestId` replay with `seen` cap **2048**; reject `events.count > 32` or `receipts.count > 16` with 400. Record status only if present. Ack every event id (including unknown types), dedupe ids with an LRU of 512, pass new events to `EventRouter.handle`. Match receipts to queued commands and call `onReceipt`; keep the existing enable/disable confirmation message logic. Drop expired commands. Reply with `ack`, up to 16 `commands`, `nextPollMs`, `needIcons`, `desktopIPv6`. Replace `@Published var pending: Command?` with `@Published private(set) var queue: [OutgoingCommand]`, and keep a computed `pending` (first enable/disable in the queue) so existing views compile. `send(_:)` enqueues.
5. **Poll rate.** `nextPollMs` = 500 while hot (call ringing in last event, transfer active, queue non-empty, `requestHotPolling` window), else 2000; 0 right after `enqueue` when the phone is online. Enforce a 150 ms minimum between polls **only** for polls that arrive earlier than the Mac asked for; answer those with 429 and `nextPollMs` in a JSON body.
6. **FileChannel.swift.** Implements research §4.2 on a background queue: accepted offers (10 min), `.part` file at `~/Downloads/.<transferId>.part`, chunk AAD with `total` and `final`, SHA-256 verify, name sanitising (strip `/`, `..`, control chars, collisions → ` (1)`), `URLResourceValues.quarantineProperties`, then rename. Mac→phone: `offerToPhone` reads the file in 256 KiB sealed chunks on demand for `/get`. 403 for unknown or unaccepted transfers; one active transfer; 2 GB cap.
7. **Kotlin Outbox + loop.** Create `Outbox.kt` (ConcurrentLinkedQueue/`LinkedHashMap` guarded by a lock; never persisted; never logs payloads). In `RemoteService.loop()`: build `events` from the outbox up to 32 items / ~20 KB plaintext; send `receipts` list; send `status` only if its hash changed or 30 s elapsed (move `wireless.update`/`pairingService.update` out of every tick into that path). Remove acked events. Replace `Thread.sleep(2000)` with `wake.drainPermits(); wake.tryAcquire(delay, MILLISECONDS)` where `delay` = 0 if outbox non-empty or `nextPollMs == 0`, else `nextPollMs` (clamp 150..2000). `InterruptedException` still breaks the loop (onDestroy relies on it). Treat HTTP 409/429 as "wait `nextPollMs`, do not flip transport". Try `/v2/poll` first; on 404 set a `v1Only` flag for this service lifetime and use the v1 body.
8. **Commands.kt stub.** Move the enable/disable body of `execute()` into `Commands.execute`; unknown `a` → `{ok:false, message:"Unsupported"}`. The loop executes every command whose id is not in a 64-entry recent-id set and whose `expiresAt` is within `now-30 .. now+130` (TTL up to 120 s plus skew), on the worker thread, in order. Long actions (ring, SMS, file download) must hand off to their own thread and return an immediate receipt; (b) owns that.
9. **Status fields.** In `status()` add `battery` (sticky `ACTION_BATTERY_CHANGED`), `charging`, `network` (`wifi`/`cellular`/`none` from `ConnectivityManager`), and placeholders `ringing=false`, `listenerConnected=false`, `sims=[]` that (b) populates through a small `StatusExtras` map you expose in `RemoteService`'s companion object.
10. **FileTransfer.kt.** Upload: read the `Uri` stream on a dedicated thread, emit a `fileOffer` event, wait for the Mac's `fileAccept` command (or `fileDecline`), POST chunks with ≤4 in flight, resume from `/status`. Download: on a `fileOffer` command, pull chunks into the provided `OutputStream`, verify SHA-256, receipt ok/failed. While active, call `Outbox.kick()` so the 500 ms hot rate applies.
11. **Manifest (transport only).** Add `ACCESS_LOCAL_NETWORK`, `FOREGROUND_SERVICE_REMOTE_MESSAGING`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; change `RemoteService` to `foregroundServiceType="connectedDevice|remoteMessaging"` and pass both types in `startForeground(71, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ..._REMOTE_MESSAGING)`.

Verify (a):
- `./mac/build.sh` succeeds; `./gradlew :app:assembleDebug :app:lintDebug` succeeds (env vars from §2).
- Old behaviour intact: pair the emulator (invitation URL host edited to `10.0.2.2`), toggle Development from the Mac menu, receipt arrives. Then repeat with an APK built from `4f9ae3b` against the new Mac build to prove `/v1/poll` fallback.
- `adb -s emulator-5554 logcat -s DevSwitchConnection` shows no "Heartbeat gap" while idle and no transport flips when the Mac returns 429.
- Push a fake event: temporarily call `Outbox.add("link", ...)` from a debug `adb shell am broadcast` hook or a unit test; Mac logs type + id once and the phone removes it after the ack.
- `dd if=/dev/urandom of=/tmp/big.bin bs=1m count=20` → transfer each way once with (b)/(c) absent by calling the FileChannel/FileTransfer APIs from a debug path; SHA-256 matches; the received file has a `com.apple.quarantine` xattr (`xattr -l`).

## (b) Android feature services (after (a))

Steps (each feature: service/receiver → `Outbox.add` for phone→Mac, `Commands.execute` branch for Mac→phone):
1. **Manifest + permissions.** Declare `RECEIVE_SMS`, `SEND_SMS`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS`, `ANSWER_PHONE_CALLS`, `ACCESS_NOTIFICATION_POLICY`, `SCHEDULE_EXACT_ALARM`, `QUERY_ALL_PACKAGES`; the `NotifListener` service (`BIND_NOTIFICATION_LISTENER_SERVICE`), `SmsReceiver` (`BROADCAST_SMS`), `CallWatcher` receiver for `PHONE_STATE`, `ShareToMacActivity` (translucent, SEND/SEND_MULTIPLE `*/*`), `ClipTile` (`BIND_QUICK_SETTINGS_TILE`). Templates in research Part A §1, §5, §6, §7.
2. **OtpExtractor.kt** — pure Kotlin, no Android imports: `fun extract(text: String): String?` and `fun normaliseSender(raw: String): String`. Rules in research §1 "OTP extraction heuristic" (normalise digits incl. Devanagari, keyword gate within ~40 chars, candidate patterns, rejections, scoring). Dedupe object: code-only, 90 s window, last 20 kept in memory.
3. **NotifListener.kt** — one listener for OTP, mirroring, call notifications and dismiss/reply. Filters, payload, icon-once-per-package (`needIcons`), MessagingStyle, per-package token bucket 5/10 s, 1.5 s coalescing, `requestRebind` on disconnect, `key → latest sbn` map: research §2. Muted packages from `MutedApps` (prefs, updated by `setMuted` command). Set `StatusExtras.listenerConnected`. Never log text.
4. **SmsReceiver.kt** — extract OTP from `SMS_RECEIVED` PDUs, `Outbox.add("otp", …, priority = true)` + `kick()`.
5. **CallWatcher.kt** — `PHONE_STATE` receiver (+ `READ_CALL_LOG` for number, dedupe the double fire), contact name via `PhoneLookup`; `call` events `ringing/offhook/idle` with a `callId`; set `StatusExtras.ringing`. Commands: `declineCall` → `TelecomManager.endCall()`; `silenceCall` → mute `STREAM_RING`, restore on idle.
6. **FindMyPhone.kt** — `ring`/`stopRing`: `USAGE_ALARM` looping player, `STREAM_ALARM` to max and restore, DND override on Android 14 via `ACCESS_NOTIFICATION_POLICY`, HIGH-importance notification with Stop, auto-stop 60 s (research §3).
7. **SmsSender.kt** — `sendSms{to, body, subId?}` with multipart, per-sub `SmsManager`, sent/delivered `PendingIntent`s (unique request codes, `FLAG_IMMUTABLE`, explicit component) → receipt + `smsStatus` event; 10/min rate limit; never auto-retry. SIM list into `StatusExtras.sims`.
8. **ShareToMacActivity.kt** — text → first `http(s)` URL → `link` event (else `clipboard` event); streams → hand the Uri to `RemoteService`/`FileTransfer.upload` with `FLAG_GRANT_READ_URI_PERMISSION` before `finish()`. Bottom sheet confirmation per ui-design §8.
9. **Clipboard.** `setClipboard` command → `setPrimaryClip` (IS_SENSITIVE extra when the Mac flags it), echo-suppress by hash. `ClipTile` + an FGS-notification action open a transparent activity that reads the clip in `onWindowFocusChanged(true)` and sends a `clipboard` event (≤16 KB).
10. **Received.kt** — Mac→phone file: `fileOffer` command → MediaStore `Downloads/DevSwitch` with `IS_PENDING`, `FileTransfer.download`, then "Received X from Mac" notification (tap = `ACTION_VIEW`). Check `StatFs` first; delete the pending row on failure.
11. **Android UI hookups** (only after the redesign lands): Setup checklist on Main (notification access, SMS, phone, contacts, DND access, battery-optimisation exemption, `ACCESS_LOCAL_NETWORK` on API 37+, restricted-settings hint with the adb commands from research §1) and the mute list under Mac connection (ui-design §8). Request `ACCESS_LOCAL_NETWORK` at runtime when `Build.VERSION.SDK_INT >= 37`.

Verify (b): `./gradlew :app:assembleDebug :app:lintDebug`; on the emulator, each row of the E2E table in (e) passes manually before (e) automates it; `adb shell dumpsys notification | grep -A2 NotifListener` shows the listener bound.

## (c) Mac feature handlers and UI hookups (after (a))

Steps:
1. **AppDelegate.swift** via `@NSApplicationDelegateAdaptor` in `DevSwitch.swift`: set the `UNUserNotificationCenter` delegate, register categories (reply with `UNTextInputNotificationAction`, `.customDismissAction`, "Copy code", "Open link", "Accept / Decline file"), start `ExtensionSocket` (from (d)). Add `if NativeHost.isHostInvocation { exit(NativeHost.run()) }` in `DevSwitchApp.init` next to `--doctor`.
2. **EventRouter.swift** — dispatch `PhoneEvent` types to the handlers below; `link` → notification with "Open" (open in Helium via `NSWorkspace` with bundle id `net.imput.helium`, else default; http/https only, ≤2048 chars); `fileOffer` → notification Accept/Decline → `FileChannel.accept`.
3. **OtpVault.swift + OtpHUD.swift** — store code in memory ≤90 s, zero on expiry/consume. On arrival: UN banner "Verification code from <source>" with **no digits**; non-activating `NSPanel` HUD with code + Copy (auto-hide 10 s); write the clipboard with `.string`, `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, `org.nspasteboard.source = dev.notsg.devswitch`; record `changeCount`; clear after 90 s only if unchanged.
4. **AutoType.swift** — global hotkey ⌃⌥V via `RegisterEventHotKey`; type `OtpVault.current()` with `CGEvent` unicode key events; check `AXIsProcessTrusted()` and show a Settings warning when false.
5. **NotificationMirror.swift** — research Part B §2: `threadIdentifier = pkg`, icon attachment from `Caches/icons/<pkg>-<hash>.png`, reply/dismiss → `controller.enqueue`, `notificationRemoved` → `removeDeliveredNotifications`, Mac-side rate limit, content toggle ("Show message content in macOS notifications"), mute list in `UserDefaults` (package names only) synced via `setMuted`.
6. **CallPanel.swift** — floating non-activating `NSPanel` top-right, level `.statusBar`, caller + number, Silence / Decline → `enqueue` with 15 s TTL + `requestHotPolling(30)`; dismiss on `idle`/`offhook`.
7. **ClipboardSync.swift** — research Part B §3 "Shared clipboard" row (changeCount timer, skip marker types, loop prevention with `dev.notsg.devswitch.remote`, 16 KB cap, 300 ms debounce, honour `NSPasteboard.accessBehavior`; manual "Send clipboard to phone" fallback). Off by default; toggle in Settings.
8. **SmsComposerView.swift** — `Window("New message")`: To, body ≤1600, SIM picker from `status.sims`, Send → `sendSms`; show receipt; never persist the draft.
9. **UI hookups** (after the redesign lands; components per ui-design §8/§9): device-header badges (battery %, `bolt.fill`, wifi/cellular); Latest Code module; Notifications module + Settings → Notifications; Quick actions grid (Find → `ring`/`stopRing`, Message → composer, Send File; **no Send Link tile** this round: "Send link" in scope is phone→Mac only and arrives through `EventRouter`; use the freed slot for "Send Clipboard", the manual clipboard fallback), Send File (open panel + drag-and-drop onto the panel → `FileChannel.offerToPhone`); Settings → Clipboard, Files, Browser autofill (buttons calling `NativeHost.installExtensionFolder()`, `installHostManifest`, and `open -a Helium chrome://extensions`), Accessibility status. Call `controller.requestHotPolling(30)` while the menu panel is visible.
10. **Pasteboard fix** — add the concealed + transient markers to the invitation copy at `SettingsView.swift:155`.
11. **Keychain** — not in (c); (a) adds `kSecAttrAccessible` on the update path of `Controller.save`.
12. **E2E probe** — create `mac/E2EProbe.swift`, entire body inside `#if E2E`. It writes `~/Library/Application Support/DevSwitch/e2e/state.json` (event types and counts, `otpPresent: Bool`, `callPanelVisible: Bool`, mirrored notification count, last receipt ok/failed — **never codes or text**) and polls `e2e/command` for one-word actions (`declineCall`, `silenceCall`, `ring`, `stopRing`, `sendFile:<path>`), executing them through the same code paths as the UI.

Verify (c): `./mac/build.sh`; with the emulator from (e): OTP shows banner without digits, HUD with digits, `pbpaste` returns the code and is empty after 90 s; `log stream --predicate 'process == "DevSwitch"'` never shows a code or message body; add a `#if DEBUG`-style `assert` in `OtpVault` that the UN content it posts contains no digit.

## (d) Helium extension, native host, signing

Steps:
1. **Spike first (gates the rest):** load a 10-line unpacked extension in Helium with Developer mode, restart Helium twice, confirm it persists; write a host manifest to `~/Library/Application Support/net.imput.helium/NativeMessagingHosts/dev.notsg.devswitch.json` pointing at a 5-line shell host and confirm `connectNative` gets a reply. If either fails, stop (d) and report to the owner with what you saw.
2. **Signing:** `scripts/make-signing-identity.sh` creates a self-signed code-signing certificate "DevSwitch Local" in the login keychain (once, idempotent; `security find-identity -v -p codesigning` shows it). Document usage in `docs/installation.md`: `DEVSWITCH_SIGN_IDENTITY="DevSwitch Local" ./mac/build.sh`. Keep the ad-hoc default in `build.sh` for public builds.
3. **build.sh:** copy `extension/` into `DevSwitch.app/Contents/Resources/extension`; when `DEVSWITCH_E2E=1`, pass `-D E2E` to `swiftc` (used by (c)'s `E2EProbe` and (e)'s emulator script). Nothing else.
4. **NativeHost.swift:** host mode reads 4-byte native-endian length + JSON from stdin, validates `argv[1]` equals the allowed origin, relays `{getOtp}` / `{consumed}` / `{subscribe}` to `ext.sock`, writes replies (≤1 MB). `installExtensionFolder()` copies Resources/extension to `~/Library/Application Support/DevSwitch/extension`; `installHostManifest(extensionID:)` writes the manifest with `path = Bundle.main.executablePath` and `allowed_origins = ["chrome-extension://<id>/"]`.
5. **ExtensionSocket.swift:** Unix socket in a 0700 directory, remove stale socket at start, check peer with `getsockopt(LOCAL_PEERPID)` and a code-signing check that the peer is the same executable (`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` against the app's own designated requirement), rate limit, serve `OtpVault.current()` / `consume()`, push a code to subscribers when one arrives (60 s subscription).
6. **extension/**: MV3 `manifest.json` with a fixed `"key"` (generate once; derive and record the extension ID), permissions `nativeMessaging` only, content script `<all_urls>`, `all_frames`, `document_idle`. Content script: OTP field detection and split-box handling in research Part B §1a; closed shadow-root chip "From your phone: 482913 · Fill"; fill with the native value setter + `input`/`change` events; only on focus/hover of a detected field; never broadcast. Service worker: `connectNative` with reconnect on disconnect.

Verify (d): spike result recorded; `codesign -dv --verbose=4 mac/build/DevSwitch.app` shows the stable identity; Accessibility grant survives two rebuilds; host round trip with `printf` framing from a shell; chip appears on `extension-tests` fixtures in real Helium with a code from the emulator.

## (e) Tests (after (a); unit tests can start immediately against (a)'s APIs)

1. **Gradle:** add `testImplementation("org.json:json:20240303")` (via `libs.versions.toml`). Run with `JAVA_HOME=... ANDROID_HOME=... ./gradlew :app:testDebugUnitTest`.
2. **OtpExtractorTest.kt** — every fixture in research §1 item 6, plus: Axis/ICICI/Kotak/Paytm/IRCTC/UIDAI-style messages, `Rs 4500 debited from a/c XX1234` → null, mobile number `9876543210` → null, `1800-...` → null, date `12/11` → null, "valid for 10 mins" → not 10, Devanagari digits `४८२९१३` → `482913`, `G-839201` → `839201` or `G-839201` (pick and document), sender normalisation `AX-HDFCBK` / `VM-SBIOTP-S` / `JD-AMAZON-T`. Dedupe: same code from SMS and NLS within 90 s → one event; after 91 s → two.
3. **test-vectors/** — `poll-v2.json`, `reply-v2.json`, `file-chunk.json`: each `{keyHex, nonceHex, aad, plaintextUtf8, ciphertextB64, tagB64}` plus negative cases (tampered AAD, wrong device id in AAD, oversize events list, unknown `t`/`a`, duplicate ids). Generate once from Kotlin, commit, and never regenerate silently.
4. **ProtocolV2Test.kt** — seal with the fixed nonce equals the vector; open every vector; negative cases throw; event/command field decoding.
5. **mac-tests/** — `CodecTests.swift` with a tiny `main` (no XCTest needed): compile with `swiftc -parse-as-library -D TESTING mac/Crypto.swift mac/ProtocolV2.swift mac-tests/*.swift` (add any other dependency the compiler asks for), run the same vectors, plus `HTTPServer.parse` boundary cases (32 KB ± 1, octet-stream on `/v2/file`, JSON on file path rejected, duplicate headers, `transfer-encoding`) and replay (`seen` 600 polls in 120 s all accepted). Runner `mac-tests/run.sh`.
6. **extension-tests/** — Playwright (`npm init -y && npm i -D @playwright/test && npx playwright install chromium`), `chromium.launchPersistentContext` with `--disable-extensions-except` / `--load-extension` pointing at `extension/`, a stubbed `connectNative` build flag, fixtures: `autocomplete=one-time-code`, 6 split boxes, React-controlled input, cross-origin iframe, negatives (password, CVV, phone, amount). Assert chip shows, one click fills, React state updates, nothing on negatives.
7. **scripts/e2e-emulator.sh** — boots nothing; expects a Mac app built with `DEVSWITCH_E2E=1 ./mac/build.sh` running, and the emulator paired to `http://10.0.2.2:45874` (pair once by pasting the invitation with its `url` host changed to `10.0.2.2`). It asserts on `e2e/state.json` and drives Mac-side clicks by writing `e2e/command` (both from (c) step 12). Grants (`pm grant`, `cmd notification allow_listener <pkg>/.remote.NotifListener`, `cmd notification allow_dnd`, `dumpsys deviceidle whitelist +<pkg>`), then drives:
   - `adb -s emulator-5554 emu sms send AXHDFCBK "123456 is your OTP for txn of Rs 2,499.00. Do not share."` → Mac OTP vault has a code (assert via a debug `--e2e-dump` file written by the app with types and counts only, **no content**, enabled only in `-D E2E` builds).
   - `adb -s emulator-5554 emu gsm call 9876543210` → `callPanelVisible: true`; write `declineCall` to `e2e/command` → `adb -s emulator-5554 emu gsm list` shows no active call and `callPanelVisible: false`; `emu gsm cancel 9876543210` as cleanup.
   - `adb -s emulator-5554 shell cmd notification post -S bigtext -t "Alice" tag1 "Hello from emu"` → mirrored; `cmd notification cancel tag1` → removed on the Mac.
   - share intent `am start -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "https://example.com" -n <pkg>/.remote.ShareToMacActivity` → link event.
   - 20 MB file each way; `adb shell content query --uri content://media/external/downloads` shows it.
   Expect the NLS OTP to arrive redacted on API 35; only the SMS path must pass.
8. **Real-device checklist (iQOO Z6 Pro)** — run manually, record pass/fail in the PR description:
   - Autostart on, background power "allow", battery Unrestricted, app locked in Recents; battery-optimisation exemption granted.
   - Messages → Settings: verification-code protection off if present; real bank OTP arrives on the Mac within 2 s via NLS and SMS, deduped to one.
   - Helium chip fills a real bank/UPI login; ⌃⌥V types into a native app.
   - WhatsApp message mirrored with icon; reply from the Mac delivered; dismiss syncs both ways; muted app never appears.
   - Find My Phone rings at full volume with ringer silent and with DND on (priority mode).
   - Send SMS on each SIM; sent receipt shows; message visible in Vivo Messages.
   - Incoming call: panel within 1 s; Decline ends the call; Silence mutes and ringer volume restored after.
   - Link share from Chrome opens in Helium after click; photo and 500 MB video transfer phone→Mac with quarantine; Mac→phone file lands in Downloads/DevSwitch.
   - Clipboard Mac→phone automatic; phone→Mac via QS tile and share sheet.
   - 2 h unplugged idle with `dumpsys batterystats --reset` before; record DevSwitch's share; listener still bound after overnight idle.

Verify (e): all suites green: `./gradlew :app:testDebugUnitTest`, `mac-tests/run.sh`, `cd extension-tests && npx playwright test`, `scripts/e2e-emulator.sh` exit 0.

# 5. Miscellaneous
- Later (out of scope): CompanionDeviceManager association for Android 15+/17 OTP access, keep-alive socket, long-poll, lock together, media controls, webcam, hotspot, auto unlock.
- Funtouch killing the app and unbinding the listener remains the top operational risk; `listenerConnected` in status lets the Mac show it.
- Pasteboard privacy on macOS 27 is unverified; (c) must ship the manual fallback regardless.
- Same-user malware can talk to `ext.sock` after defeating the signature check; state this in `docs/architecture.md`.
- Do not commit `.archify/` or this file unless the owner asks.
