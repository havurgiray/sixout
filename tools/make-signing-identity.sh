#!/bin/bash
# Creates the local self-signed code-signing identity "SixOut Dev" in the login keychain.
# build.sh signs the app with it so that macOS privacy grants (Accessibility for the volume keys,
# system-audio recording, microphone) survive rebuilds; an ad-hoc signature changes with every build
# and silently invalidates them. Run once per Mac. The certificate is valid for ten years.
set -euo pipefail
if security find-identity -p codesigning 2>/dev/null | grep -q '"SixOut Dev"'; then echo "identity SixOut Dev already exists"; exit 0; fi
T=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -nodes -subj "/CN=SixOut Dev/O=SixOut" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
openssl pkcs12 -export -legacy -out "$T/sixoutdev.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:sixout >/dev/null 2>&1 \
  || openssl pkcs12 -export -out "$T/sixoutdev.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:sixout >/dev/null 2>&1
security import "$T/sixoutdev.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P sixout -T /usr/bin/codesign -T /usr/bin/security
rm -rf "$T"
echo "identity SixOut Dev created; build.sh will use it"
