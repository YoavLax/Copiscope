cask "copiscope" do
  version "1.0.1"
  sha256 "3dabc32edfe29ff33445cc2a06edc4daf963ab2cbd586b8399f2fbb0c100f4a2"

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
