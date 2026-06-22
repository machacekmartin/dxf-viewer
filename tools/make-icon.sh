#!/usr/bin/env bash
# Rebuild Resources/AppIcon.icns from tools/icon-source.png (1024x1024,
# already cropped + alpha-keyed). Stock macOS tools only — no ImageMagick.
#
# To swap in new artwork: replace tools/icon-source.png with a new 1024x1024
# transparent-corner PNG and rerun this script (or just `bash scripts/build-app.sh`).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/icon-source.png"
ISET="$(mktemp -d)/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

[[ -f "$SRC" ]] || { echo "missing source: $SRC" >&2; exit 1; }
mkdir -p "$ISET"

# Apple icon set sizes — px : filename (without .png)
for pair in \
    "16:icon_16x16" "32:icon_16x16@2x" \
    "32:icon_32x32" "64:icon_32x32@2x" \
    "128:icon_128x128" "256:icon_128x128@2x" \
    "256:icon_256x256" "512:icon_256x256@2x" \
    "512:icon_512x512" "1024:icon_512x512@2x"
do
    px="${pair%%:*}"
    name="${pair##*:}"
    sips -s format png -Z "$px" "$SRC" --out "$ISET/${name}.png" >/dev/null
done

iconutil -c icns "$ISET" -o "$OUT"
rm -rf "$(dirname "$ISET")"
echo "Wrote $OUT"
