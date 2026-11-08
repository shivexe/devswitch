# Installation

## Requirements

- macOS 14+. The release ZIP contains Apple Silicon and Intel binaries; only Apple Silicon has been verified on a device.
- Android 11+ for wireless control; Android 14+ is recommended for continuous port discovery. Standalone toggles support Android 10+. Verified device: iQOO Z6 Pro, Funtouch OS 14 / Android 14.
- A USB cable for the initial permission grant and a shared private Wi-Fi network.
- ADB Platform Tools 30+ and scrcpy 2+. Verified with ADB 37.0.1 and scrcpy 4.1.

## Install

Install [Homebrew](https://brew.sh) if needed, then:

```sh
brew install --cask android-platform-tools
brew install scrcpy
```

Download the APK and Mac ZIP from this repository's Releases. Move the unzipped Mac app to `/Applications`. Attempt to open it. If blocked, choose **System Settings → Privacy & Security → Open Anyway**, then confirm. Releases are ad-hoc signed and not notarized. [Apple's instructions](https://support.apple.com/102445).

On Android, enable Developer options and USB debugging, connect the cable, and accept **Allow USB debugging?** for your Mac. Run `adb devices`; the phone should say `device`, not `unauthorized`. Install the downloaded APK with `adb install /path/to/DevSwitch-VERSION-android.apk`, then grant permission:

```sh
adb shell pm grant com.himphen.playground.developeroptionstoggle android.permission.WRITE_SECURE_SETTINGS
```

For multiple devices, add `-s SERIAL` after `adb`. Open DevSwitch on both devices.

## Pair DevSwitch

1. Keep both devices on the same private Wi-Fi. Allow Mac Local Network access if prompted.
2. Choose **Pair phone** in the Mac menu. On Android, choose **Mac connection → Scan Mac QR code** and allow camera access. Pasting the invitation is also supported.
3. Compare the six-digit codes and approve on the Mac.
4. Allow Android notifications. Leave Mac control running; adjust battery/background settings if it gets suspended.

This connection controls developer settings even when ADB is off.

## Pair screen control

1. Choose **Enable development** on the Mac.
2. On Android, open **Settings → Developer options → Wireless debugging**. Allow your Wi-Fi network.
3. In the Mac's **Connection settings**, choose **Show pairing QR code** under Wireless control.
4. On Android, choose **Pair device with QR code** and scan it. The Mac finds the phone and pairs by itself.
5. Without a camera, use **Pair device with pairing code** on Android and **Use pairing code instead** on the Mac. Type only the six digits; the Mac asks for the address only if it cannot find the phone within 20 seconds.
6. Unplug USB and choose **Control phone**. Verify **Disable development → Control phone** reconnects.

The companion turns off Android's 7-day expiry of ADB authorizations (`adb_allowed_connection_time = 0`), so wireless control keeps working after long gaps. To revoke the Mac, use **Developer options → Revoke USB debugging authorizations** or forget it under **Wireless debugging → Paired devices**.

**Stop sharing** closes the mirror. **Disable development** also disables wireless debugging, USB debugging, and developer options. The individual Android switches change their named setting only.

## Doctor

From source, run `./devswitch doctor`. For an installed app, no compiler is needed:

```sh
/Applications/DevSwitch.app/Contents/MacOS/DevSwitch --doctor
```

Or open **Connection settings → Dependencies**. The doctor checks paths and versions, exits `0` when ready and `1` otherwise, and does not read pairing keys or change the phone. It does not certify Wi-Fi reachability or pairing.

Detection searches absolute directories in `PATH`, Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), MacPorts, and Android SDK platform-tools. Finder apps search standard locations because they do not inherit your shell PATH.

For custom paths that must work from Finder:

```sh
defaults write dev.notsg.devswitch tools.adbPath -string '/absolute/path/to/adb'
defaults write dev.notsg.devswitch tools.scrcpyPath -string '/absolute/path/to/scrcpy'
```

Terminal launches also accept `DEVSWITCH_ADB` and `DEVSWITCH_SCRCPY`, which override saved paths. Invalid explicit paths are reported rather than silently ignored. Remove a saved override with `defaults delete dev.notsg.devswitch tools.adbPath` (or `tools.scrcpyPath`).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Phone offline | Open its app, resume Mac control, and check Wi-Fi and background restrictions. |
| Mac IP changed | Pair DevSwitch again. A DHCP reservation keeps the Mac address stable. |
| Wireless connection missing | Confirm Android allowed your Wi-Fi network; keep the companion running. Android 14+ tracks port changes. Older versions may require reopening the companion. |
| Connections drop because another device uses the phone's IPv4 address | Updated apps prefer authenticated IPv6 link-local connections when available on the same Wi-Fi. The router's duplicate IPv4 assignment can still affect other apps. |
| "Your phone forgot this Mac" | Choose **Re-pair wireless control** and scan the QR from **Pair device with QR code**. |
| ADB cannot reach the phone | Check Mac Local Network access for DevSwitch and the app that started ADB. Connection errors are reported separately from discovery failures. |
| Tool missing or cannot launch | Run the doctor; update or configure the reported executable. |
| Settings permission missing | Repeat the USB grant. Some manufacturers restrict this permission. |
| Black screen in one app | That app may prohibit screen capture. |
| APK update rejected | Check signing key and version code; see [releasing](releasing.md). |
| Keychain prompt after a Mac update | The signature changed. Review the DevSwitch prompt; cancelling leaves pairing unavailable. |

Mac sleep, Android Doze, force-stop, guest-network isolation, and battery controls can interrupt connectivity. Payment-app compatibility is not guaranteed.

## Remove access

Disable development and stop sharing. Forget the phone in Mac settings and unpair the Mac in Android. Separately remove the Mac under **Wireless debugging → Paired devices** to revoke ADB access. To revoke the settings permission while keeping the app:

```sh
adb shell pm revoke com.himphen.playground.developeroptionstoggle android.permission.WRITE_SECURE_SETTINGS
```

Remove the apps normally when finished. DevSwitch does not remove other Android tools or their credentials.
