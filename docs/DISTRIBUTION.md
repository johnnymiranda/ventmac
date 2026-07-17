# Distributing VentMac via Homebrew

VentMac ships as a **self-contained, notarized** macOS app in a personal Homebrew cask. The app bundles its own speex/speexdsp libraries (no `brew install` needed by users) and, once notarized, installs with no Gatekeeper prompts.

## Release flow

```sh
Scripts/make-app.sh                       # builds + bundles dylibs + signs (Developer ID)
Scripts/notarize.sh                       # submits to Apple, staples the ticket
Scripts/package-release.sh 0.1.0          # zips the stapled app, prints the sha256
gh release create v0.1.0 dist/VentMac-0.1.0.zip --title "VentMac 0.1.0" --notes "…"
# then set version + sha256 in the tap's Casks/ventmac.rb
brew install --cask johnnymiranda/tap/ventmac
```

## One-time setup

### 1. Developer ID Application certificate (no full Xcode needed)

1. Keychain Access -> Certificate Assistant -> **Request a Certificate From a Certificate Authority** (save the CSR to disk; leave CA email blank, choose "Saved to disk").
2. developer.apple.com -> Certificates -> **+** -> **Developer ID Application** -> upload the CSR -> download the `.cer`.
3. Double-click the `.cer` to install it into your login keychain. `security find-identity -v -p codesigning` should now list a `Developer ID Application` identity.

`Scripts/make-app.sh` auto-detects that identity and switches to Developer ID + hardened-runtime signing.

### 2. notarytool credentials

Create an app-specific password at appleid.apple.com (Sign-In and Security -> App-Specific Passwords), then store it once:

```sh
xcrun notarytool store-credentials ventmac-notary \
    --apple-id johnnymiranda@gmail.com \
    --team-id  YOURTEAMID \
    --password <app-specific-password>
```

(Your Team ID is on developer.apple.com -> Membership.)

## Path: a personal tap

The official `homebrew/cask` repo has notability requirements a niche app won't clear, so use your own tap:

1. Create a public repo **`johnnymiranda/homebrew-tap`**.
2. Add **`Casks/ventmac.rb`** to it (a copy lives in this repo at `Casks/ventmac.rb`).
3. Users install with `brew install --cask johnnymiranda/tap/ventmac` (Homebrew maps `johnnymiranda/tap` -> the `homebrew-tap` repo).

Each release: cut a GitHub release with the zip, then bump `version` + `sha256` in the tap's cask.

## Files in this repo

- `Scripts/make-app.sh` — builds, bundles speex dylibs to `@rpath`, signs (Developer ID / self-signed / ad-hoc, auto-detected)
- `Scripts/notarize.sh` — submits to Apple's notary service and staples
- `Scripts/package-release.sh` — zips the stapled app and prints the sha256
- `Casks/ventmac.rb` — the cask definition (copy into your tap repo)

## Nothing here has been published

No GitHub release, tap repo, or public artifact has been created. Everything above is staged for you to run once the Developer ID cert and notarytool credentials are in place.
