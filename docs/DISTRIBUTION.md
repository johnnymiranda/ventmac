# Distributing VentMac via Homebrew

This is the plan to publish VentMac as a Homebrew cask. It needs a couple of
**decisions from you** (marked ⚠️) before anything goes public.

## The short version

```sh
Scripts/package-release.sh 0.1.0          # builds VentMac.app, zips it, prints sha256
gh release create v0.1.0 dist/VentMac-0.1.0.zip --title "VentMac 0.1.0" --notes "…"
# then in your tap repo, set version + sha256 in Casks/ventmac.rb
brew install --cask johnnymiranda/tap/ventmac
```

## Path: a personal tap (recommended)

The official `homebrew/cask` repo has notability + signing requirements a niche,
unsigned app won't clear. The right route is your own tap:

1. Create a public repo **`johnnymiranda/homebrew-tap`**.
2. Add **`Casks/ventmac.rb`** to it (a copy lives in this repo at `Casks/ventmac.rb`).
3. Users install with `brew install --cask johnnymiranda/tap/ventmac`
   (Homebrew maps `johnnymiranda/tap` → the `homebrew-tap` repo).

Each release: bump `version` and `sha256` in the tap's cask, and cut a GitHub
release with the zip.

## ⚠️ Decision 1 — signing / notarization

The app is currently **ad-hoc signed and not notarized**. On another person's
Mac, Gatekeeper will quarantine it, so first launch requires right-click → Open
or `xattr -dr com.apple.quarantine`. Options:

- **A. Ship unsigned (free).** The cask's `caveats` already tells users how to
  clear quarantine. Fine for friends / technical users. This is the default the
  drafted cask assumes.
- **B. Notarize (Apple Developer Program, $99/yr).** Sign with a Developer ID,
  submit to Apple's notary service, staple the ticket. Then the cask "just
  works" with no quarantine friction. Best if you want a clean public install.

You already need a self-signed cert for stable local TCC grants; a real Apple
Developer ID would cover both.

## ⚠️ Decision 2 — the speex dependency

VentMac links against Homebrew's `speex`/`speexdsp` dylibs by absolute path
(`/opt/homebrew/opt/speex/...`). The cask declares `depends_on formula: "speex"`
and `"speexdsp"`, so Homebrew installs them — this works for any arm64 user with
Homebrew in the standard prefix.

For a fully self-contained app (no brew dependency), a future step is to bundle
the dylibs into `VentMac.app/Contents/Frameworks/` and rewrite the install names
with `install_name_tool` to `@rpath`. Not required for the cask; noted for later.

## Files in this repo

- `Casks/ventmac.rb` — the cask definition (copy into your tap repo)
- `Scripts/package-release.sh` — builds + zips the artifact, prints the sha256
- `Scripts/make-app.sh` — assembles + signs `VentMac.app`

## Nothing here has been published

No GitHub release, tap repo, or public artifact has been created. Everything
above is staged for you to run when you've made the two decisions.
