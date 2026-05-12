cask "copiscope" do
  version "1.0.2"
  sha256 "8a66b4916f5544c50ddf8ee533ad68dc08d11e14d9a03d46a25771cfaeb97080"

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
