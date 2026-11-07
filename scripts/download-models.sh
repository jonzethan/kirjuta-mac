#!/bin/zsh
# Laeb Kirjuta mudelid kausta ~/Kirjuta/models (ühekordne; äpp ise internetti ei kasuta).
#   keelemudel:  TalTechi whisper-large-v3-turbo-et-verbatim-2604 (GGML f16, 1,6 GB)
#   kõnelejad:   pyannote segmentation 3.0 (int8) + WeSpeaker ResNet34 (sherpa-onnx)
# Kui whisper.cpp on ehitatud (scripts/build-whisper.sh), tehakse lisaks väiksem q8_0 (sama kvaliteet).
set -e
D=~/Kirjuta/models
mkdir -p $D/diar/sherpa-onnx-pyannote-segmentation-3-0
cd $D

if [[ ! -f taltech-et-turbo-f16.bin && ! -f taltech-et-turbo-q8_0.bin ]]; then
  echo "== Keelemudel (1,6 GB)"
  curl -fL --progress-bar -o taltech-et-turbo-f16.bin \
    https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604/resolve/main/ggml/ggml-model.bin
fi
Q="${0:A:h}/../vendor/whisper.cpp/build-mac/bin/whisper-quantize"
if [[ -x $Q && -f taltech-et-turbo-f16.bin && ! -f taltech-et-turbo-q8_0.bin ]]; then
  echo "== q8_0 (874 MB)"
  $Q taltech-et-turbo-f16.bin taltech-et-turbo-q8_0.bin q8_0 >/dev/null
fi

if [[ ! -f diar/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx ]]; then
  echo "== Kõnelejate segmenteerimine"
  curl -fL --progress-bar -o /tmp/kirjuta-seg.tar.bz2 \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
  tar -xjf /tmp/kirjuta-seg.tar.bz2 -C diar sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx sherpa-onnx-pyannote-segmentation-3-0/LICENSE
  rm /tmp/kirjuta-seg.tar.bz2
fi
if [[ ! -f diar/wespeaker_en_voxceleb_resnet34_LM.onnx ]]; then
  echo "== Kõnelejate hääle-sõrmejälg"
  curl -fL --progress-bar -o diar/wespeaker_en_voxceleb_resnet34_LM.onnx \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx
fi
echo "Valmis: $D"
ls -la $D $D/diar
