# DevSwitch

Control your Android phone from the Mac menu bar. Switch developer settings on or off, mirror the screen, and use your mouse and keyboard over Wi-Fi. No root or cloud account.

## Install

Requires macOS 14+. Wireless control requires Android 11+; automatic port updates use Android 14+. Verified on iQOO Z6 Pro / Android 14.

1. Install dependencies:
   ```sh
   brew install --cask android-platform-tools
   brew install scrcpy
   ```
2. Download the APK and Mac ZIP from [Releases](https://github.com/shivexe/devswitch/releases). Move `DevSwitch.app` to Applications and install the APK on your phone. The Mac app is ad-hoc signed, not notarized: after attempting to open it, use **System Settings → Privacy & Security → Open Anyway** if blocked.
3. Enable USB debugging, connect the phone once, accept the authorization prompt, then run:
   ```sh
   adb shell pm grant com.himphen.playground.developeroptionstoggle android.permission.WRITE_SECURE_SETTINGS
   ```
4. Put both devices on the same Wi-Fi. Choose **Pair phone** on the Mac, scan its QR from **Mac connection** on Android, compare the codes, and approve on the Mac.
5. On the Mac, **Enable development**. On Android, open **Wireless debugging**, allow your Wi-Fi network, then **Pair device with pairing code**. Enter that address and code under the Mac's **Connection settings → Wireless control**.

Unplug USB. **Control phone** enables development and opens the screen. **Disable development** stops sharing and turns off developer options, USB debugging, and wireless debugging.

## Build / check

```sh
./devswitch doctor       # Find ADB and scrcpy; report versions and fixes
./devswitch build       # macOS app → mac/build/DevSwitch.app
./gradlew :app:assembleDebug  # Android APK → app/build/outputs/apk/debug/
```

Source builds require Xcode Command Line Tools, JDK 17, and Android SDK 37. The installed Mac app also has **Connection settings → Dependencies**.

[Full setup & troubleshooting](docs/installation.md) · [Build & release](docs/releasing.md) · [How it works](docs/architecture.md)

## Notes

Keep both devices on the same network. Battery restrictions can interrupt the phone connection; a changed Mac IP currently requires pairing DevSwitch again. Protected screens may not mirror. Payment-app compatibility depends on the app and phone.

Based on [Developer Options Toggle](https://github.com/himphen/Developer-Options-Toggle). [MIT license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md).
