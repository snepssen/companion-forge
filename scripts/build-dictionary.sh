#!/usr/bin/env bash
# The offline dictionary, models/dictionary.sqlite: English Wiktionary's
# translation tables and definitions (kaikki.org's extract, 523 MB, fetched
# once into models/source), cut down to the languages the companion is asked
# about by scripts/build-dictionary.py. About 130 MB.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -s models/dictionary.sqlite ] && [ "${1:-}" != "--again" ] && exit 0
mkdir -p models/source
SOURCE=models/source/kaikki-English.jsonl.gz
if [ ! -s "$SOURCE" ]; then
  echo "fetching English Wiktionary's extract from kaikki.org (523 MB)…" >&2
  curl -fSL -C - -o "$SOURCE" https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz
fi
python3 -I scripts/build-dictionary.py "$SOURCE" models/dictionary.sqlite
