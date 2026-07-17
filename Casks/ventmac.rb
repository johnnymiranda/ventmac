# Homebrew cask for VentMac. This lives in a personal tap
# (johnnymiranda/homebrew-tap → Casks/ventmac.rb), installed with:
#   brew install --cask johnnymiranda/tap/ventmac
#
# Update `version` and `sha256` on each release. `Scripts/package-release.sh`
# builds the artifact and prints the sha256 to paste here.
cask "ventmac" do
  version "0.1.0"
  sha256 :no_check # replace with the real sha256 from package-release.sh

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
