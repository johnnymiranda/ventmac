# Reference copy of the VentMac cask. The cask users actually install from lives
# in the tap (johnnymiranda/homebrew-tap → Casks/ventmac.rb):
#   brew install --cask johnnymiranda/tap/ventmac
#
# On each release, update `version` and `sha256` (Scripts/package-release.sh prints
# the sha256). IMPORTANT: the published tap cask must pin the real sha256 — never
# ship `sha256 :no_check`, which disables download integrity checking.
cask "ventmac" do
  version "0.1.0"
  sha256 :no_check # reference copy only — the tap cask pins the real sha256

  url "https://github.com/johnnymiranda/ventmac/releases/download/v#{version}/VentMac-#{version}.zip"
  name "VentMac"
  desc "Native macOS client for legacy Ventrilo 3 servers with global push-to-talk"
  homepage "https://github.com/johnnymiranda/ventmac"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "VentMac.app"

  # The app bundles its own speex/speexdsp libraries and is notarized, so it
  # installs and launches with no extra dependencies or Gatekeeper prompts.
  caveats <<~EOS
    For mouse-button push-to-talk, grant Input Monitoring under
    System Settings -> Privacy & Security -> Input Monitoring.
  EOS
end
