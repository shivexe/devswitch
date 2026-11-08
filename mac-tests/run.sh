#!/bin/bash
# Builds the Mac test runner from mac-tests/*.swift plus the mac/ sources under test, then runs it.
# mac/EventRouter.swift is replaced by a recording stub in Support.swift; Keychain calls are stubbed there too.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/devswitch-mac-tests"
rm -f "$out"
sources=(Controller HTTPServer Crypto ProtocolV2 FileChannel LocalNetwork ScreenControl Dependencies BonjourDiscovery)
swiftc -wmo -parse-as-library -swift-version 5 -Xfrontend -disable-access-control -target "$(uname -m)-apple-macos14.0" \
  $(printf 'mac/%s.swift ' "${sources[@]}") mac-tests/*.swift -o "$out"
"$out"
