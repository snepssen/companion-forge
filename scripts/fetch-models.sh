#!/usr/bin/env bash
# Silero VAD v5 into models/: from interpreter-forge beside this checkout if it
# has it, else from the Silero repository. The language model is chosen and
# downloaded in the app; interpreter-forge's models/ is used as it is.
set -euo pipefail
cd "$(dirname "$0")/.."
VAD=models/silero_vad.onnx
[ -s "$VAD" ] && exit 0
mkdir -p models
if [ -s ../interpreter-forge/models/silero_vad.onnx ]; then
  cp ../interpreter-forge/models/silero_vad.onnx "$VAD"
else
  curl -fsSL -o "$VAD" https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx
fi
echo "voice detector: $VAD"
