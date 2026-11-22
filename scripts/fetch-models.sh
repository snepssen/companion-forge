#!/usr/bin/env bash
# Silero VAD into models/: the v6.2 release, checked against its SHA-256 (the
# file interpreter-forge pins too). A copy already in this checkout is kept if
# it is that file, and replaced if it is any other.
#
# Language models are downloaded in the app, into
# ~/Library/Application Support/Companion/Models/<id>/, the layout ModelStore
# checks file by file. When interpreter-forge already has them, each model the
# store does not have is symlinked to that copy (the files stay put). Set
# WORKSHOP_ROOT to the folder that holds the workshop checkouts; otherwise
# ../interpreter-forge/models is used when it is there. An existing model,
# real or already linked, is left as it is.
set -euo pipefail
cd "$(dirname "$0")/.."

# Link every model directory under $1 that $2 does not already have.
# A model directory holds a non-empty model.safetensors, as the pinned models do.
link_shared_models() {
  local shared="$1"
  local store="$2"
  local source name dest abs
  [ -d "$shared" ] || return 0
  mkdir -p "$store"
  for source in "$shared"/*; do
    [ -d "$source" ] || continue
    [ -s "$source/model.safetensors" ] || continue
    name="$(basename "$source")"
    dest="$store/$name"
    # A real folder, a file, or a link — including a broken one — stays.
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      continue
    fi
    abs="$(cd "$source" && pwd)"
    ln -s "$abs" "$dest"
    echo "linked $name -> $abs"
  done
}

if [ "${FETCH_MODELS_LINK_ONLY:-}" != 1 ]; then
  VAD=models/silero_vad.onnx
  VAD_URL=https://raw.githubusercontent.com/snakers4/silero-vad/v6.2/src/silero_vad/data/silero_vad.onnx
  VAD_SHA=1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3
  vad_ok() { [ -s "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$VAD_SHA" ]; }
  if ! vad_ok "$VAD"; then
    mkdir -p models
    curl -fsSL -o "$VAD.part" "$VAD_URL" || { rm -f "$VAD.part"; echo "error: could not fetch Silero VAD v6.2" >&2; exit 1; }
    vad_ok "$VAD.part" || { rm -f "$VAD.part"; echo "error: the fetched Silero VAD does not match its SHA-256" >&2; exit 1; }
    mv "$VAD.part" "$VAD"
    echo "voice detector: $VAD"
  fi
fi

if [ -n "${FETCH_MODELS_SHARED:-}" ]; then
  SHARED="$FETCH_MODELS_SHARED"
elif [ -n "${WORKSHOP_ROOT:-}" ] && [ -d "$WORKSHOP_ROOT/interpreter-forge/models" ]; then
  SHARED="$WORKSHOP_ROOT/interpreter-forge/models"
elif [ -d ../interpreter-forge/models ]; then
  SHARED="../interpreter-forge/models"
else
  SHARED=""
fi

if [ -n "$SHARED" ]; then
  STORE="${FETCH_MODELS_STORE:-$HOME/Library/Application Support/Companion/Models}"
  link_shared_models "$SHARED" "$STORE"
fi
