#!/bin/zsh
# Ehitab whisper.cpp (vendor/whisper.cpp, commit 482279b) Metaliga staatilisteks teekideks.
set -e
cd "${0:A:h}/../vendor/whisper.cpp"
cmake -B build-mac -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2
cmake --build build-mac -j 8 --config Release
