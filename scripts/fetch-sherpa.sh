#!/bin/zsh
# Laeb sherpa-onnx (kõnelejate eristamine) Maci staatilised teegid kausta vendor/sherpa-onnx.
# Sama versioon mis Androidi AAR-is. Võrku on vaja ainult selle skripti jaoks, mitte äpi käitamisel.
set -e
V=2.0.1
cd "$(dirname "$0")/.."
D=vendor/sherpa-onnx
[[ -f $D/.version && $(cat $D/.version) == $V ]] && { echo "sherpa-onnx $V olemas"; exit 0; }
rm -rf $D && mkdir -p $D
curl -fL --progress-bar -o /tmp/sherpa-$V.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v$V/sherpa-onnx-v$V-osx-arm64-static-no-tts-lib.tar.bz2
tar -xjf /tmp/sherpa-$V.tar.bz2 -C $D --strip-components=1
rm /tmp/sherpa-$V.tar.bz2
mkdir -p $D/include/sherpa-onnx/c-api
curl -fsL -o $D/include/sherpa-onnx/c-api/c-api.h https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$V/sherpa-onnx/c-api/c-api.h
echo $V > $D/.version
echo "valmis: $D"
