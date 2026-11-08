#!/bin/bash
# Creates a stable self-signed code-signing identity, once, so macOS privacy grants
# (Accessibility, Keychain access) survive rebuilds. Ad-hoc signatures change every build.
#   scripts/make-signing-identity.sh [keychain]      # default: login keychain
#   DEVSWITCH_SIGN_IDENTITY="DevSwitch Local" ./devswitch build
set -euo pipefail
name="DevSwitch Local"
keychain="${1:-$HOME/Library/Keychains/login.keychain-db}"
if security find-identity -p codesigning "$keychain" | grep -q "\"$name\""; then
  echo "\"$name\" already exists in $keychain"
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
password="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.conf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$tmp/identity.p12" -passout "pass:$password"
security import "$tmp/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
echo "Created \"$name\" in $keychain"
