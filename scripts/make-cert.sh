#!/bin/zsh
# Loob püsiva isetehtud koodiallkirjastamise sertifikaadi "Kirjuta Dev" login-võtmeahelasse.
# Sama sertifikaadiga allkirjastatud äpp jääb macOS-i jaoks "samaks äpiks" -> mikrofoni/süsteemiheli
# õigused ei kao iga ehitusega. Käivita ainult üks kord.
set -e
NAME="Kirjuta Dev"
if security find-certificate -c "$NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Sertifikaat '$NAME' on juba olemas."; exit 0
fi
T=$(mktemp -d); trap 'rm -rf $T' EXIT
cat > $T/cfg <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout $T/key.pem -out $T/cert.pem -config $T/cfg 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey $T/key.pem -in $T/cert.pem -out $T/c.p12 -passout pass:kirjuta -name "$NAME" 2>/dev/null
security import $T/c.p12 -k ~/Library/Keychains/login.keychain-db -P kirjuta -T /usr/bin/codesign
echo "Valmis: '$NAME'"
