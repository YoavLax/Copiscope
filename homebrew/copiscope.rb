cask "copiscope" do
  version "1.0.0"
  sha256 "5ce33323cf8f894c852e7d93c569f8f473f26ee10665e827dcb17928e29cabef"

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
