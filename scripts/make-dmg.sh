#!/bin/zsh
# Jagatav build/Kirjuta-<versioon>.dmg: äpp + q8_0 mudel + kõnelejate mudelid, töötab ilma internetita.
#   --no-models: ainult äpp (GitHubi Release); mudelid laeb kasutaja ise (README / download-models.sh)
set -e
cd "${0:A:h}/.."
NOMODELS=0; [[ "$1" == "--no-models" ]] && NOMODELS=1
if [[ $NOMODELS == 1 ]]; then scripts/make-app.sh; else KIRJUTA_BUNDLE_MODELS=1 scripts/make-app.sh; fi
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=build/dmg
rm -rf $STAGE && mkdir -p $STAGE
cp -R build/Kirjuta.app $STAGE/
ln -s /Applications $STAGE/Applications
cp scripts/LOE-MIND.txt "$STAGE/LOE MIND.txt"
OUT=build/Kirjuta-$V.dmg
[[ $NOMODELS == 1 ]] && OUT=build/Kirjuta-$V-ilma-mudeliteta.dmg
rm -f $OUT
hdiutil create -volname "Kirjuta $V" -srcfolder $STAGE -fs HFS+ -format ULFO -ov $OUT >/dev/null
rm -rf $STAGE
# arendaja äpp jääb ilma mudeliteta (väiksem, loeb ~/whisper-android-ist)
[[ $NOMODELS == 1 ]] || scripts/make-app.sh >/dev/null
echo "Valmis: $OUT ($(du -h $OUT | cut -f1))"
