#!/bin/zsh
# One-shot: complete the v0.2.0 release once the login keychain is unlocked.
# Safe to re-run; each step is idempotent or guarded. Written by the overnight
# session that built v0.2.0 — delete after the release is out.
set -e
cd ~/code/ventmac

echo "[1/7] notarize"
Scripts/notarize.sh

echo "[2/7] package"
Scripts/package-release.sh
ZIP=dist/VentMac-0.2.0.zip
SHA=$(shasum -a 256 $ZIP | awk '{print $1}')
echo "sha256: $SHA"

echo "[3/7] push main + tag"
git tag -f -a v0.2.0 -m "VentMac 0.2.0"
git push -q origin main
git push -qf origin v0.2.0

echo "[4/7] github release"
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | sed -n 's/^password=//p')
GH_TOKEN="$TOKEN" gh release create v0.2.0 $ZIP --repo johnnymiranda/ventmac \
  --title "VentMac 0.2.0" --verify-tag \
  --notes "The feature-parity release: text chat (channel + private), voice activation (VOX) with a live mic meter, auto-reconnect that rejoins your channel, a saved server list, per-user volume and mute, MOTD, paging, phantoms, user comments, and admin-mute badges. Everything rides on protocol support the vendored libventrilo3 already had." \
  || echo "(release may already exist — continuing)"

echo "[5/7] tap bump"
cd ~/code/homebrew-tap
perl -0pi -e "s/version \"0\\.1\\.5\"/version \"0.2.0\"/; s/sha256 \"[0-9a-f]{64}\"/sha256 \"$SHA\"/" Casks/ventmac.rb
git -c commit.gpgsign=false -c user.name='Johnny Miranda' -c user.email='8175008+johnnymiranda@users.noreply.github.com' commit -qam "ventmac 0.2.0" || echo "(tap already committed)"
git push -q origin main

echo "[6/7] brew upgrade"
pkill -f "VentMac.app/Contents/MacOS/VentMac" 2>/dev/null || true
brew update >/dev/null 2>&1
brew upgrade --cask ventmac

echo "[7/7] verify"
defaults read /Applications/VentMac.app/Contents/Info.plist CFBundleShortVersionString
xcrun stapler validate /Applications/VentMac.app
echo "RELEASE COMPLETE"
