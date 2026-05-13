cask "copiscope" do
  version "1.1.0"
  sha256 "4a4c66a30f558ee6f1eec2d15e11ee4786501737ddc0482786c7fb7aa8eaa126"

  url "https://github.com/YoavLax/Copiscope/releases/download/v#{version}/Copiscope-#{version}.dmg"
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
