#!/bin/zsh
# Ehitab build/Kirjuta.app ja allkirjastab selle sertifikaadiga "Kirjuta Dev" (vt make-cert.sh).
set -e
cd "${0:A:h}/.."
[[ -f vendor/whisper.cpp/build-mac/src/libwhisper.a ]] || scripts/build-whisper.sh
swift build -c release
APP=build/Kirjuta.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Kirjuta $APP/Contents/MacOS/
cp Resources/Info.plist $APP/Contents/
ID="${KIRJUTA_SIGN_ID:-Kirjuta Dev}"
if security find-certificate -c "$ID" >/dev/null 2>&1; then
  codesign --force --sign "$ID" --identifier ee.kirjuta.mac $APP
else
  echo "HOIATUS: sertifikaati '$ID' pole (käivita scripts/make-cert.sh) – ad-hoc allkiri, õigused võivad kaduda."
  codesign --force --sign - --identifier ee.kirjuta.mac $APP
fi
codesign -dr - $APP 2>&1 | tail -1
echo "Valmis: $APP  (käivita: open $APP)"
