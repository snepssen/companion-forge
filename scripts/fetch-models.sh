#!/usr/bin/env bash
# Silero VAD v5 into models/. A copy already in this checkout is kept. With
# WORKSHOP_ROOT set to the folder that holds the workshop checkouts,
# interpreter-forge's copy is used as it is. Otherwise the file is fetched
# from the Silero repository, which is where it comes from. The language
# model is chosen and downloaded in the app.
set -euo pipefail
cd "$(dirname "$0")/.."
VAD=models/silero_vad.onnx
[ -s "$VAD" ] && exit 0
mkdir -p models
if [ -n "${WORKSHOP_ROOT:-}" ] && [ -s "$WORKSHOP_ROOT/interpreter-forge/models/silero_vad.onnx" ]; then
  cp "$WORKSHOP_ROOT/interpreter-forge/models/silero_vad.onnx" "$VAD"
else
  curl -fsSL -o "$VAD" https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx
fi
echo "voice detector: $VAD"
