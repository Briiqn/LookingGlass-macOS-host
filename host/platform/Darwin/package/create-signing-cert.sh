#!/bin/bash
# Creates a self-signed code signing certificate, "LGMac Local Code Signing",
# in the login keychain. Signing the host with it gives the app a stable
# identity, so macOS keeps its privacy permissions across rebuilds.
#
# Afterwards, trust it for code signing only (asks for your password):
#   security add-trusted-cert -r trustRoot -p codeSign \
#     -k ~/Library/Keychains/login.keychain-db lgmac-codesign.pem
set -e

NAME="LGMac Local Code Signing"
KEYCHAIN=~/Library/Keychains/login.keychain-db

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# the keychain only imports the legacy PKCS#12 encryption
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

cp "$TMP/cert.pem" lgmac-codesign.pem
echo "created \"$NAME\"; now trust lgmac-codesign.pem for code signing (see the top of this script)"
