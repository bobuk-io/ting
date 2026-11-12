#!/usr/bin/env bash
# Build the macOS app icon with tools included in macOS; no external renderer is needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MASTER="$ROOT/Assets/AppIcon.png"
OUTPUT=${1:-"$ROOT/.build/Icon.icns"}

if [[ ! -f "$MASTER" ]]; then
  echo "ERROR: App icon master is missing: Assets/AppIcon.png" >&2
  exit 1
fi
SIZE=$(sips -g pixelWidth -g pixelHeight "$MASTER" | awk '
  /pixelWidth:/ { width = $2 }
  /pixelHeight:/ { height = $2 }
  END { print width "x" height }
')
if [[ "$SIZE" != 1024x1024 ]]; then
  echo "ERROR: Assets/AppIcon.png must be 1024x1024 (found $SIZE)." >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ting-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Icon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    target="$ICONSET/icon_${size}x${size}${suffix}.png"
    if [[ "$pixels" == 1024 ]]; then
      cp "$MASTER" "$target"
    else
      sips -z "$pixels" "$pixels" "$MASTER" --out "$target" >/dev/null
    fi
  done
done
iconutil --convert icns "$ICONSET" --output "$WORK/Icon.icns"
mv "$WORK/Icon.icns" "$OUTPUT"
echo "ICON_READY: $OUTPUT"
