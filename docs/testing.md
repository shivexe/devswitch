# Testing

## Automated suites

| Suite | Command |
|---|---|
| Kotlin unit tests (protocol vectors, Outbox, OTP extractor) | `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ./gradlew :app:testDebugUnitTest` |
| Swift tests (vectors, HTTP limits, replay cache, command queue, file chunks) | `mac-tests/run.sh` |
| Helium extension (Playwright) | `cd extension-tests && npx playwright test` |
| Emulator E2E against a fake Mac on port 45990 | `scripts/e2e-emulator.sh` |

`test-vectors/` holds fixed key, nonce, AAD and plaintext bytes with the expected ciphertext. Kotlin and Swift must both reproduce them. Do not regenerate them silently.

The E2E script only talks to `emulator-5554`. It keeps the test pairing key and logs in `scripts/e2e/.state/` (gitignored). On API 35 the notification listener sees OTPs redacted, so the emulator proves OTP through SMS only.

## Real-device checklist (iQOO Z6 Pro, Android 14, Funtouch OS 14)

Record pass or fail for each step in the PR description.

1. **Background survival.** In phone settings, turn Autostart on, set background power to "Allow", set battery to Unrestricted, and lock DevSwitch in Recents. Grant the battery-optimisation exemption from the app's setup checklist.
   Expected: after 10 minutes with the screen off, the Mac still shows the phone online.
2. **OTP.** In Messages → Settings, turn off verification-code protection if it is there. Trigger a real bank or UPI OTP.
   Expected: within 2 s the Mac shows a banner with no digits and a HUD with the code. `pbpaste` returns the code, and is empty again after 90 s. The code arrives once, not twice (SMS and notification are deduped).
3. **Autofill.** Open a real bank or UPI login in Helium. Then focus a native app's text field and press ⌃⌥V.
   Expected: the chip "From your phone: …" fills the OTP field in one click. ⌃⌥V types the code.
4. **Notifications.** Receive a WhatsApp message. Reply from the Mac notification, then dismiss one on each side. Mute an app.
   Expected: the message is mirrored with the app icon. The reply is delivered. A dismiss on either side removes it from both. The muted app never appears on the Mac.
5. **Find My Phone.** Silence the ringer and click Find on the Mac. Repeat with Do Not Disturb (priority mode) on.
   Expected: the phone rings at full volume both times. Stop ends it and the previous volume returns.
6. **Send SMS.** Send one message from the Mac on each SIM.
   Expected: the sent receipt shows on the Mac, and the message appears in Vivo Messages.
7. **Incoming call.** Call the phone, then press Decline. Call again and press Silence.
   Expected: the call panel appears within 1 s. Decline ends the call. Silence mutes the ringer, and the ringer volume is back after the call.
8. **Links and files.** Share a link from Chrome to DevSwitch. Send a photo and a 500 MB video to the Mac. Send a file from the Mac to the phone.
   Expected: the link opens in Helium after one click. Both files land in `~/Downloads` with a `com.apple.quarantine` xattr (`xattr -l`). The Mac file lands in Downloads/DevSwitch on the phone.
9. **Clipboard.** Copy text on the Mac. Then send the phone clipboard with the Quick Settings tile and with the share sheet.
   Expected: Mac→phone arrives automatically. Phone→Mac arrives both ways.
10. **Battery and listener.** Run `adb shell dumpsys batterystats --reset`, leave the phone unplugged and idle for 2 h, then run `adb shell dumpsys batterystats`. Check again after an overnight idle.
    Expected: record DevSwitch's battery share. The Mac still shows the notification listener as connected the next morning.
