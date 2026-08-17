# The SOURCE OF TRUTH for aislopware/homebrew-tap's Casks/slopdesk.rb.
#
# In this repository for the same reason the formula is: it makes a claim about what SlopDesk needs
# to run, and a file in another repository cannot be checked against the tree that decides it.
#
# The release workflow's `tap` job COPIES this file into the tap and rewrites two lines — `version`
# and `sha256`. Keep both at two-space indentation, one per file, or that rewrite stops matching.
cask "slopdesk" do
  version "0.4.0"
  sha256 "1ba6e2978f947923784e290be5d73d6403187e1af2ba4b6e47c0c407cef68a2c"

  url "https://github.com/aislopware/slop-desk/releases/download/v#{version}/SlopDesk-#{version}-arm64.dmg"
  name "SlopDesk"
  desc "Low-latency remote coding for macOS: the client viewer and the host menu-bar app"
  homepage "https://github.com/aislopware/slop-desk"

  # See the formula for why arm64 is a hard requirement rather than a default.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  # The cask DEPENDS ON THE FORMULA, and this is not a convenience.
  #
  # `SlopDeskHost.app` does not shell out to `slopdesk-hostd`; it runs the same `HostServer`
  # in-process. So it needs superd exactly as much as the CLI does — superd forks the pane shells
  # and owns every PTY master (`docs/51`) — and a cask-only install was the same broken host wearing
  # a menu-bar icon: it launched, showed its icon, and could not open a single pane. The CLI tools
  # coming along is a side effect of declaring the real dependency.
  depends_on formula: "slopdesk"

  app "SlopDesk.app"
  app "SlopDeskHost.app"

  caveats <<~EOS
    SlopDeskHost needs Screen Recording and Accessibility (System Settings -> Privacy &
    Security). macOS keys both grants to the code signature, so they survive an upgrade in
    place -- but an unsigned local build of the same app will not inherit them.

    superd owns every PTY master and comes from the `slopdesk` formula this cask depends on.
    Start it once with `brew services start slopdesk`; without it the host launches and cannot
    open a pane.

    The command-line tools live in that formula too. SlopDesk.app carries no copy of the CLI,
    so its first-launch "Install the CLI" card has nothing to link.
  EOS

  zap trash: [
    "~/Library/Application Support/SlopDesk",
    "~/Library/Containers/com.slopdesk.client.macos",
    "~/Library/Preferences/com.slopdesk.client.macos.plist",
    "~/Library/Preferences/com.slopdesk.host.macos.plist",
    "~/Library/Saved Application State/com.slopdesk.client.macos.savedState",
  ]
end
