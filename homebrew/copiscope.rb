cask "copiscope" do
  version "0.6.3"
  sha256 "808aeba21b421fae5e969800c5c713aa2d5d2ac74c7b575dd63be32d990a90be"

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
