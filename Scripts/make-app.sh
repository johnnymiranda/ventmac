#!/bin/bash
# Assemble and sign VentMac.app from the SwiftPM release build.
#
# TCC note: Input Monitoring / Microphone grants are keyed to the code-signing
# identity. Ad-hoc signatures change every build and silently invalidate
# grants, so we prefer a persistent self-signed cert named "VentMac Dev".
# Create one in Keychain Access: Certificate Assistant -> Create a
# Certificate -> Name: "VentMac Dev", Type: Code Signing. Falls back to
# ad-hoc (-) with a warning if the cert doesn't exist.
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_ID="VentMac Dev"
APP=VentMac.app

swift build -c release --product VentMac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
cp .build/release/VentMac "$APP/Contents/MacOS/VentMac"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    # No hardened runtime: library validation would reject the Homebrew
    # speex/speexdsp dylibs. Unhardened is fine for a local personal app.
    codesign --force --entitlements Scripts/VentMac.entitlements --sign "$SIGN_ID" "$APP"
    echo "Signed with '$SIGN_ID' (TCC grants will persist across rebuilds)."
else
    codesign --force --sign - "$APP"
    echo "WARNING: signed ad-hoc — Input Monitoring grants reset on every rebuild."
    echo "Create a 'VentMac Dev' self-signed Code Signing cert in Keychain Access to fix."
fi

echo "Built $APP — launch with: open $APP"
