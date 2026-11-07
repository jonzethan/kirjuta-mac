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
cp Resources/AppIcon.icns $APP/Contents/Resources/
# KIRJUTA_BUNDLE_MODELS=1: mudelid äpi sisse (jagamiseks, vt make-dmg.sh)
if [[ "$KIRJUTA_BUNDLE_MODELS" == 1 ]]; then
  mkdir -p $APP/Contents/Resources/models $APP/Contents/Resources/diar/sherpa-onnx-pyannote-segmentation-3-0
  cp -L models/taltech-et-turbo-q8_0.bin $APP/Contents/Resources/models/
  cp -L diar-models/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx \
        diar-models/sherpa-onnx-pyannote-segmentation-3-0/LICENSE \
        $APP/Contents/Resources/diar/sherpa-onnx-pyannote-segmentation-3-0/
  cp -L diar-models/wespeaker_en_voxceleb_resnet34_LM.onnx $APP/Contents/Resources/diar/
  echo "mudelid kaasas: $(du -sh $APP/Contents/Resources | cut -f1)"
fi
ID="${KIRJUTA_SIGN_ID:-Kirjuta Dev}"
if security find-certificate -c "$ID" >/dev/null 2>&1; then
  codesign --force --sign "$ID" --identifier ee.kirjuta.mac $APP
else
  echo "HOIATUS: sertifikaati '$ID' pole (käivita scripts/make-cert.sh) – ad-hoc allkiri, õigused võivad kaduda."
  codesign --force --sign - --identifier ee.kirjuta.mac $APP
fi
codesign -dr - $APP 2>&1 | tail -1
echo "Valmis: $APP  (käivita: open $APP)"
