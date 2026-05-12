cask "copiscope" do
  version "1.0.3"
  sha256 "5d1c28b28235b88d40b9655f7552e133a7a58df50173cfb425613e4a88d31f2f"

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
