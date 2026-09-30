#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${DEVSWITCH_VERSION:-$(cat VERSION)}"
build_number="${DEVSWITCH_BUILD_NUMBER:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be MAJOR.MINOR.PATCH' >&2; exit 1; }
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be a positive integer' >&2; exit 1; }
app="$PWD/mac/build/DevSwitch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
architectures="${DEVSWITCH_ARCHS:-$(uname -m)}"
binaries=()
for arch in $architectures; do
  [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
  binary="$PWD/mac/build/DevSwitch-$arch"
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos14.0" mac/*.swift -o "$binary"
  binaries+=("$binary")
done
[[ ${#binaries[@]} -gt 0 ]] || { echo 'No architectures selected' >&2; exit 1; }
if [[ ${#binaries[@]} -eq 1 ]]; then
  cp "${binaries[0]}" "$app/Contents/MacOS/DevSwitch"
else
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/DevSwitch"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.notsg.devswitch</string>
<key>CFBundleName</key><string>DevSwitch</string>
<key>CFBundleExecutable</key><string>DevSwitch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect with your paired Android phone to control developer settings and share its screen.</string>
<key>NSBonjourServices</key><array><string>_devswitch._tcp</string><string>_adb-tls-connect._tcp</string><string>_adb-tls-connect._tcp.</string></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/licenses"
cp licenses/*.txt "$app/Contents/Resources/licenses/"
# Public builds are ad-hoc signed. Never select a certificate from the build machine automatically.
codesign --force --sign "${DEVSWITCH_SIGN_IDENTITY:--}" --identifier dev.notsg.devswitch "$app"
codesign --verify --strict "$app"
echo "Built $app ($version; $architectures)"
