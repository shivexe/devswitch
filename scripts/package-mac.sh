#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${DEVSWITCH_VERSION:-$(cat VERSION)}"
# Release packaging always uses ad-hoc signing; no Apple account or certificate is required.
DEVSWITCH_ARCHS='arm64 x86_64' DEVSWITCH_SIGN_IDENTITY=- ./mac/build.sh
mkdir -p dist
archive="DevSwitch-$version-macos-universal.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent mac/build/DevSwitch.app "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
echo "Created dist/$archive"
