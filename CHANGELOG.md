# Changelog

## DevSwitch 0.3.0 (unreleased)

- Add the Mac menu bar app, encrypted QR pairing, and remote development controls.
- Add wireless ADB/scrcpy control with Android 14 port updates.
- Redesign both interfaces and add dependency detection and a doctor command.
- Package universal, ad-hoc signed Mac releases alongside signed Android APKs.

Earlier entries belong to the upstream Developer Options Toggle project.

## [1.4.0] - 2026-08-04

### Added
- GitHub Actions CI and tag-based signed APK release workflows.
- Visible UI error handling for permission, read, write, and system-settings failures.
- A fixed dark Material 3 interface with redesigned setting cards and widgets.

### Changed
- Renamed the application ID and Kotlin package to `com.himphen.playground.developeroptionstoggle`.
- Reworked the README and added the MIT license.
- Removed operational Logcat logging and validated the result of secure-setting writes.

## [1.3.0] - 2025-06-25

### Added
- **Wi-Fi Debugging Toggle**: A new switch on the main screen to control the system's "Wi-Fi Debugging" setting.

### Changed
- The Wi-Fi Debugging toggle is now automatically disabled when the main Developer Options are turned off.

## [1.2.0] - 2025-06-25

### Added
- **USB Debugging Toggle**: A new switch on the main screen to control the system's "USB Debugging" setting.

### Changed
- The USB Debugging toggle is automatically disabled when the main Developer Options are turned off.

## [1.1.0] - 2025-06-24

### Added
- **Robust Permission Handling**: The application now actively checks for the `WRITE_SECURE_SETTINGS` permission on start-up.
- **Permission Warning UI**: A prominent warning card is displayed on the main screen if the required permission has not been granted.

### Changed
- All setting toggles are now disabled if the permission is missing, preventing failed actions and improving user feedback.
- The toggle widget's logic was made more robust to handle cases where the permission might have been revoked.

## [1.0.0] - 2025-06-24

### Added
- **Developer Options Toggle**: Core functionality to toggle the system's "Developer Options" from a simple main screen.
- **Toggle Widget**: A home screen widget to quickly toggle "Developer Options" on and off. The widget's color changes to reflect the current state.
- **Shortcut Widget**: A home screen widget that acts as a direct shortcut to the system's "Developer Options" settings page.
- A clean, dark-mode-only user interface built with Jetpack Compose and Material 3. 