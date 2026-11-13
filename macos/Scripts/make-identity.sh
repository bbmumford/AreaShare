#!/bin/bash
# Creates "AreaShare Local": a self-signed code-signing certificate and key in
# the login keychain, for signing builds on this Mac. It never leaves the Mac
# and is not trusted for distribution. Run once; macOS then asks for the
# login password the first time codesign uses the key (choose Always Allow).
set -euo pipefail

name="AreaShare Local"
if security find-identity -p codesigning | grep -q "\"$name\""; then
    echo "\"$name\" is already in the keychain."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# The system's openssl writes a PKCS#12 file the keychain can read.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
passphrase="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/identity.p12" -passout "pass:$passphrase"
security import "$work/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$passphrase" -T /usr/bin/codesign

echo "created \"$name\" in the login keychain."
