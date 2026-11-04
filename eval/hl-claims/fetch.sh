#!/usr/bin/env bash
# Downloads the sources HL-Claims is built from into data/hl-claims-sources
# (not committed: FreshQA states no licence for its sheets, so only derived
# claims and their citations live in this repo). build.py checks each file
# against the hashes in MANIFEST.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/data/hl-claims-sources"
mkdir -p "$OUT"
sheet() { curl -fsSL -m 60 -o "$OUT/$1" "https://docs.google.com/spreadsheets/d/$2/export?format=csv"; }
sheet freshqa-2024-02-26.csv 1V6nIxVTI9tqZ-wfgK-uFuUPiGEa1Zmnz53OeGbaNtO0
sheet freshqa-2026-04-21.csv 1_8mi-yuK30mvoDJu1KQXD6ODem7MKMcIgVAwDSzJkjM
curl -fsSL -m 60 -o "$OUT/recencyqa.json" https://raw.githubusercontent.com/DataScienceUIBK/RecencyQA/21b0c3b/dataset/RececnyQA_dataset.json
ls -l "$OUT"
