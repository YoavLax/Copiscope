cask "copiscope" do
  version "1.1.2"
  sha256 "7e0c9c59c00916073fb2b50ece678535662ae4d823ddf875e00c14ae0050f434"

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
