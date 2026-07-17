#!/bin/bash
# Render the VentMac app icon and package it into Scripts/AppIcon.icns.
#
# Renders a 1024x1024 base PNG via Scripts/render-icon.swift (AppKit/CoreGraphics,
# no external assets), downscales it into a full AppIcon.iconset with sips, and
# packs the set into an .icns with iconutil. make-app.sh copies the resulting
# Scripts/AppIcon.icns into the app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

BASE=Scripts/icon-1024.png
ICONSET=Scripts/AppIcon.iconset
ICNS=Scripts/AppIcon.icns

echo "Rendering base 1024x1024 icon (Swift/CoreGraphics)..."
/usr/bin/swift Scripts/render-icon.swift "$BASE"

echo "Building iconset..."
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# name (macOS convention) -> pixel size
sips -z 16   16   "$BASE" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$BASE" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$BASE" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$BASE" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$BASE" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$BASE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$BASE" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$BASE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$BASE" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp                "$BASE"  "$ICONSET/icon_512x512@2x.png"

echo "Packing icns..."
iconutil -c icns "$ICONSET" -o "$ICNS"

echo "Built $ICNS"
sips -g pixelWidth -g pixelHeight "$ICNS"
ls -la "$ICNS"
