cask "agentscope" do
  version "1.0.0"
  sha256 "PLACEHOLDER"

  url "https://github.com/YoavLax/AgentScope/releases/download/v#{version}/AgentScope.dmg"
  name "AgentScope"
  desc "macOS menu bar companion for Claude Code sessions"
  homepage "https://github.com/YoavLax/AgentScope"
  auto_updates true

  depends_on macos: ">= :sonoma"

  app "AgentScope.app"

  zap trash: [
    "~/Library/Caches/com.agentscope.app",
    "~/Library/Preferences/com.agentscope.app.plist",
  ]
end
