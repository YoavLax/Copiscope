cask "copiscope" do
  version "1.0.0"
  sha256 "a1a05cdff318538395a235c308ba9f947b718181c1b073a9437bb720e75fbe74"

  url "https://github.com/YoavLax/Copiscope/releases/download/v#{version}/Copiscope.dmg"
  name "Copiscope"
  desc "macOS menu bar companion for GitHub Copilot sessions"
  homepage "https://github.com/YoavLax/Copiscope"
  auto_updates true

  depends_on macos: ">= :sonoma"

  app "Copiscope.app"

  zap trash: [
    "~/Library/Caches/com.copiscope.app",
    "~/Library/Preferences/com.copiscope.app.plist",
  ]
end
