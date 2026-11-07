#!/bin/zsh
# Jagatav build/Kirjuta-<versioon>.dmg: äpp + q8_0 mudel + kõnelejate mudelid, töötab ilma internetita.
set -e
cd "${0:A:h}/.."
KIRJUTA_BUNDLE_MODELS=1 scripts/make-app.sh
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=build/dmg
rm -rf $STAGE && mkdir -p $STAGE
cp -R build/Kirjuta.app $STAGE/
ln -s /Applications $STAGE/Applications
cp scripts/LOE-MIND.txt "$STAGE/LOE MIND.txt"
OUT=build/Kirjuta-$V.dmg
rm -f $OUT
hdiutil create -volname "Kirjuta $V" -srcfolder $STAGE -fs HFS+ -format ULFO -ov $OUT >/dev/null
rm -rf $STAGE
# arendaja äpp jääb ilma mudeliteta (väiksem, loeb ~/whisper-android-ist)
scripts/make-app.sh >/dev/null
echo "Valmis: $OUT ($(du -h $OUT | cut -f1))"
