#!/bin/bash
# Assemble VentMac.app from the SwiftPM release build: bundle the speex/speexdsp
# dylibs so the app is self-contained (no `brew install speex` needed by users),
# then code-sign with the best available identity.
#
# Signing tiers (auto-detected):
#   1. Developer ID Application  -> hardened runtime + timestamp (notarizable;
#      run Scripts/notarize.sh next). Bundled dylibs are signed with the same
#      identity, so library validation passes with no extra entitlements.
#   2. "VentMac Dev" self-signed -> stable local TCC grants across rebuilds.
#   3. ad-hoc (-)                -> works locally; TCC grants reset each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=VentMac.app

swift build -c release --product VentMac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
cp .build/release/VentMac "$APP/Contents/MacOS/VentMac"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

BIN="$APP/Contents/MacOS/VentMac"

# --- Bundle + relink codec dylibs (speex/speexdsp/opus) to @rpath so the app is self-contained ---
for old in $(otool -L "$BIN" | awk '/speex|opus/{print $1}'); do
    base=$(basename "$old")
    cp -L "$old" "$APP/Contents/Frameworks/$base"
    chmod u+w "$APP/Contents/Frameworks/$base"
    install_name_tool -id "@rpath/$base" "$APP/Contents/Frameworks/$base"
    install_name_tool -change "$old" "@rpath/$base" "$BIN"
done
# Add the Frameworks rpath (ignore error if already present).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true

# --- Pick a signing identity ---
DEVID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')
SELFSIGNED=$(security find-identity -v -p codesigning 2>/dev/null | grep -q "VentMac Dev" && echo yes || echo no)

sign() { codesign --force "$@"; }

if [ -n "$DEVID" ]; then
    OPTS=(--options runtime --timestamp)
    # Sign bundled dylibs first (inside-out), then the app.
    for dylib in "$APP"/Contents/Frameworks/*.dylib; do
        sign "${OPTS[@]}" --sign "$DEVID" "$dylib"
    done
    sign "${OPTS[@]}" --entitlements Scripts/VentMac.entitlements --sign "$DEVID" "$APP"
    echo "Signed with Developer ID ($DEVID), hardened runtime. Next: Scripts/notarize.sh"
elif [ "$SELFSIGNED" = yes ]; then
    for dylib in "$APP"/Contents/Frameworks/*.dylib; do sign --sign "VentMac Dev" "$dylib"; done
    sign --entitlements Scripts/VentMac.entitlements --sign "VentMac Dev" "$APP"
    echo "Signed with 'VentMac Dev' self-signed cert (TCC grants persist across rebuilds)."
else
    for dylib in "$APP"/Contents/Frameworks/*.dylib; do sign --sign - "$dylib"; done
    sign --sign - "$APP"
    echo "WARNING: signed ad-hoc — Input Monitoring/mic grants reset on every rebuild."
    echo "Renew your Apple Developer ID (or create a 'VentMac Dev' cert) to fix."
fi

echo "Built $APP (self-contained) — launch with: open $APP"
