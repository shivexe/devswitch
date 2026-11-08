#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${DEVSWITCH_VERSION:-$(cat VERSION)}"
# Ad-hoc by default; no Apple account or certificate is required. With a Developer ID identity and a
# notarytool keychain profile (DEVSWITCH_NOTARY_PROFILE), the app is notarized and stapled.
DEVSWITCH_ARCHS='arm64 x86_64' DEVSWITCH_SIGN_IDENTITY="${DEVSWITCH_SIGN_IDENTITY:--}" ./mac/build.sh
mkdir -p dist
archive="DevSwitch-$version-macos-universal.zip"
if [[ -n "${DEVSWITCH_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent mac/build/DevSwitch.app "dist/$archive"
  xcrun notarytool submit "dist/$archive" --keychain-profile "$DEVSWITCH_NOTARY_PROFILE" --wait
  xcrun stapler staple mac/build/DevSwitch.app
fi
ditto -c -k --norsrc --noextattr --noqtn --keepParent mac/build/DevSwitch.app "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
echo "Created dist/$archive"
