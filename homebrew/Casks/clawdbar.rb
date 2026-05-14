cask "clawdbar" do
  version "0.1.0"
  sha256 "d1e4a7701e396bdf784d93693224a2b34b441183ae6b024a24283b0b0fe03b60"

  url "https://github.com/rauppvj/clawdbar/releases/download/v#{version}/ClawdBar-#{version}.dmg"
  name "ClawdBar"
  desc "Menu-bar app showing live Claude Code (5h + 7d) usage"
  homepage "https://github.com/rauppvj/clawdbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "ClawdBar.app"

  zap trash: [
    "~/Library/Preferences/com.vinicius.clawdbar.plist",
    "~/Library/Application Support/ClawdBar",
    "~/.clawdbar",
  ]

  caveats <<~EOS
    ClawdBar is distributed unsigned (no Apple Developer ID yet).
    On first launch macOS will refuse to open it. To bypass:

      1. Right-click ClawdBar.app in Finder → Open → Open
    or
      2. xattr -dr com.apple.quarantine /Applications/ClawdBar.app

    You also need an active Claude Code login (`claude /login`) so the
    OAuth token is available in your macOS Keychain.
  EOS
end
