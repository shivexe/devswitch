# Build and release

## Local builds

macOS requires Xcode Command Line Tools (`xcode-select --install`). Android requires JDK 17 and Android SDK Platform 37 (`platforms;android-37.0`). Set `JAVA_HOME` and `ANDROID_HOME` to your installations, or configure the SDK through Android Studio.

```sh
./devswitch doctor
./devswitch build
./gradlew :app:assembleDebug :app:lintDebug
```

Outputs: `mac/build/DevSwitch.app` and `app/build/outputs/apk/debug/app-debug.apk`. Builds do not install or replace apps. Copy the Mac app to Applications and use `adb install -r` for the APK.

`VERSION` supplies both version names. `DEVSWITCH_BUILD_NUMBER` and `ANDROID_VERSION_CODE` supply build numbers. Keep Android version codes increasing.

## Mac distribution

```sh
./scripts/package-mac.sh
```

Produces a universal Apple Silicon/Intel ZIP and SHA-256 checksum in `dist/`. Packaging always ad-hoc signs with `codesign --sign -`. No notarization, Apple Developer membership, or Apple signing secret is required. Users approve downloaded apps through macOS Privacy & Security.

For a private local build only, `DEVSWITCH_SIGN_IDENTITY` can explicitly select a certificate. Builds never auto-select Keychain identities. Changing between certificate and ad-hoc signing can trigger a Keychain approval prompt; it does not migrate or delete pairing credentials.

## Android signing

Android releases need a persistent signing key. Create one once outside the repository with `keytool -genkeypair`, or use an existing release keystore. Keep an offline backup. Configure these GitHub Actions secrets:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded keystore.
- `ANDROID_KEYSTORE_PASSWORD`: keystore password.
- `ANDROID_KEY_ALIAS`: signing alias.
- `ANDROID_KEY_PASSWORD`: key password.

For local release builds, set `RELEASE_KEYSTORE_PATH`, `RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS`, and `RELEASE_KEY_PASSWORD`, then run `./gradlew :app:assembleRelease`. Keep passwords out of committed files and command history.

An APK signed with a new key cannot replace a debug APK or another maintainer's APK in place. Uninstalling removes pairing data; after reinstalling, grant the permission and pair again. Updates using the same signing key and a sufficient version code preserve app data with `adb install -r`.

## GitHub release

1. Use the `shivexe/devswitch` repository, or configure your own remote when maintaining a fork.
2. Configure the Android secrets. Optionally set repository variable `ANDROID_VERSION_CODE_BASE` (default `100`) so base + workflow run number exceeds previously distributed version codes.
3. Update `VERSION` and the changelog. Commit the source, then push a matching tag such as `v0.3.0` when ready to release.
4. The workflow builds the signed APK and ad-hoc signed universal Mac ZIP, generates `SHA256SUMS`, and creates a **draft** release after both builds succeed.
5. Review the artifacts and publish the draft from your GitHub account.

No Apple account secrets are required. Branch CI runs Android build/lint and Mac packaging; it does not install apps on devices.
