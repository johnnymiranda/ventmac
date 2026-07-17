#!/bin/bash
# Notarize and staple VentMac.app (after Scripts/make-app.sh signed it with a
# Developer ID + hardened runtime). One-time credential setup:
#
#   xcrun notarytool store-credentials ventmac-notary \
#       --apple-id you@example.com \
#       --team-id  YOURTEAMID \
#       --password <app-specific-password>   # from appleid.apple.com
#
# Then: Scripts/make-app.sh && Scripts/notarize.sh && Scripts/package-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP=VentMac.app
PROFILE="${NOTARY_PROFILE:-ventmac-notary}"
ZIP="dist/VentMac-notarize.zip"

[ -d "$APP" ] || { echo "Build it first: Scripts/make-app.sh"; exit 1; }

if ! codesign -dvvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "ERROR: $APP is not Developer ID signed. Renew your Apple Developer ID,"
    echo "create a Developer ID Application cert, then rerun Scripts/make-app.sh."
    exit 1
fi

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket to $APP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment:"
spctl -a -vvv --type execute "$APP" || true

echo "Done. Now: Scripts/package-release.sh  (zips the stapled app for release)."
