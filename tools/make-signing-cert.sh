#!/bin/bash
# One-time: create a self-signed code signing certificate in your login keychain.
# build.sh signs with it, so macOS keeps Read Aloud's permissions across rebuilds
# (ad-hoc signatures change every build and reset them).
set -euo pipefail
NAME="${1:-Read Aloud Local Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists"; exit 0
fi
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" \
  -days 3650 -config "$dir/cert.cnf" 2>/dev/null
pass=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" \
  -passout "pass:$pass" -name "$NAME" 2>/dev/null
security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign
echo "created \"$NAME\". It shows as not trusted; that's fine for local signing."
