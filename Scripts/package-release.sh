#!/bin/bash
# Build VentMac.app, zip it as the release artifact, and print the sha256 to
# paste into Casks/ventmac.rb. Does NOT create a GitHub release or push
# anything — that's a manual step (see docs/DISTRIBUTION.md).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Scripts/Info.plist 2>/dev/null || echo 0.1.0)}"
OUT="dist"
ZIP="$OUT/VentMac-$VERSION.zip"

# Package the already-built, signed, and (ideally) notarized+stapled app.
# Do NOT rebuild here — that would re-sign and strip the notarization staple.
# Run Scripts/make-app.sh and Scripts/notarize.sh first.
[ -d VentMac.app ] || { echo "VentMac.app not found — run Scripts/make-app.sh (and notarize.sh) first."; exit 1; }
if xcrun stapler validate VentMac.app >/dev/null 2>&1; then
    echo "==> Packaging notarized + stapled VentMac.app"
else
    echo "==> WARNING: VentMac.app is not stapled — run Scripts/notarize.sh for a clean install. Packaging anyway."
fi

mkdir -p "$OUT"
rm -f "$ZIP"
# ditto preserves the bundle + resource forks correctly for distribution.
ditto -c -k --sequesterRsrc --keepParent VentMac.app "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo
echo "==> Artifact: $ZIP"
echo "==> Version : $VERSION"
echo "==> sha256  : $SHA"
echo
echo "Next:"
echo "  1. gh release create v$VERSION \"$ZIP\" --title \"VentMac $VERSION\" --notes \"...\""
echo "  2. Set version \"$VERSION\" and sha256 \"$SHA\" in the tap's Casks/ventmac.rb"
echo "  3. brew install --cask johnnymiranda/tap/ventmac"
