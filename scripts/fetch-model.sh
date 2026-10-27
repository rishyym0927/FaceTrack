#!/bin/sh
# Download the frozen face model from InsightFace's official release (macOS/Linux).
# The weights are non-commercial research only and are NOT redistributed with this
# project; this fetches them from the original source and verifies the checksum.
# Windows: use scripts/fetch-model.ps1.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/.local/spike/models/buffalo_sc"
URL="https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip"
ZIP_SHA="57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"

mkdir -p "$DEST"
if [ -f "$DEST/det_500m.onnx" ] && [ -f "$DEST/w600k_mbf.onnx" ]; then
  echo "Model already present in $DEST — nothing to do."
  exit 0
fi

TMP="$DEST/buffalo_sc.zip"
echo "Downloading model (non-commercial research use) from InsightFace..."
if command -v curl >/dev/null 2>&1; then
  curl -fL "$URL" -o "$TMP"
else
  wget -O "$TMP" "$URL"
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$TMP" | awk '{print $1}')
else
  ACTUAL=$(shasum -a 256 "$TMP" | awk '{print $1}')
fi
if [ "$ACTUAL" != "$ZIP_SHA" ]; then
  echo "ERROR: checksum mismatch (got $ACTUAL). Download may be corrupt; not extracting." >&2
  rm -f "$TMP"
  exit 1
fi

unzip -o "$TMP" -d "$DEST" >/dev/null
echo "Model ready in $DEST (det_500m.onnx + w600k_mbf.onnx)."
echo "Licensed for non-commercial academic research only; do not redistribute."
