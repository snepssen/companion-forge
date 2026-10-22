#!/usr/bin/env bash
# Print the polyglot snepssen voice to bundle (the .onnx; its .onnx.json sits
# beside it), or fail.
#
# Where training happens, that is voice-polyglot's newest export beside
# interpreter-forge (work/runs/polyglot/exports/epoch-NNN/, folders with a suffix
# such as epoch-047-before-retrim are not milestones). Anywhere else it is
# the latest GitHub Release of voice-polyglot, the one place the voice is
# published: fetched into models/voice/, checked against its SHA256SUMS, and
# fetched again when a newer release is out, so every build carries the
# newest voice.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXPORTS="$(dirname "$REPO")/voice-polyglot/work/runs/polyglot/exports"
for dir in $(ls -d "$EXPORTS"/epoch-* 2>/dev/null | grep -E '/epoch-[0-9]+$' | sort -r); do
  model="$dir/snepssen-polyglot-$(basename "$dir").onnx"
  if [ -s "$model" ] && [ -s "$model.json" ]; then echo "$model"; exit 0; fi
done

LATEST="https://github.com/snepssen/voice-polyglot/releases/latest/download"
CACHE="$REPO/models/voice"
mkdir -p "$CACHE"
sums=$(curl -fsSL "$LATEST/SHA256SUMS") || {
  if [ -s "$CACHE/snepssen-polyglot.onnx" ]; then
    echo "warning: no connection to GitHub; using the voice already in $CACHE" >&2
    echo "$CACHE/snepssen-polyglot.onnx"; exit 0
  fi
  echo "error: no polyglot voice: no export in $EXPORTS and the latest release can't be fetched" >&2
  exit 1
}
if ! (cd "$CACHE" && echo "$sums" | shasum -a 256 -c --status 2>/dev/null); then
  echo "fetching the latest snepssen voice from voice-polyglot's releases…" >&2
  for f in snepssen-polyglot.onnx snepssen-polyglot.onnx.json; do
    curl -fsSL -o "$CACHE/$f.part" "$LATEST/$f" && mv "$CACHE/$f.part" "$CACHE/$f"
  done
  (cd "$CACHE" && echo "$sums" | shasum -a 256 -c --status) || {
    echo "error: the downloaded voice does not match the release's SHA256SUMS" >&2; exit 1;
  }
fi
echo "$CACHE/snepssen-polyglot.onnx"
