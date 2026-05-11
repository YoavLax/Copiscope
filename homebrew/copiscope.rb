cask "copiscope" do
  version "1.0.0"
  sha256 "PLACEHOLDER"

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
