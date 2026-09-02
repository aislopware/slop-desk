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
  desc "Low-latency remote coding for macOS: the client viewer"
  homepage "https://github.com/aislopware/slop-desk"

  # See the formula for why arm64 is a hard requirement rather than a default.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  # The cask DEPENDS ON THE FORMULA, and this is not a convenience.
  #
  # There is no host app any more. `docs/60` F.9 deleted `SlopDeskHost.app`, and the host is the
  # formula's `slopdesk-hostd` — a CLI daemon — with `slopdesk-superd` under it. This cask ships
  # the CLIENT VIEWER and nothing else, so a cask-only install on the machine somebody codes on is
  # a viewer with nothing to view: superd forks the pane shells and owns every PTY master
  # (`docs/51`), and every command-line tool comes from the formula too. Declaring the dependency
  # is what makes one `brew install --cask` leave a working machine behind.
  depends_on formula: "slopdesk"

  app "SlopDesk.app"

  caveats <<~EOS
    The host is `slopdesk-hostd` from the `slopdesk` formula this cask depends on, not an app
    bundle. Run it on the Mac you code on; this cask is the viewer you drive it from.

    superd owns every PTY master and comes from that same formula. Start it once with
    `brew services start slopdesk`; without it the host launches and cannot open a pane.

    Nothing installed here needs Screen Recording or Accessibility. Terminal panes need no TCC
    grant at all, and the two the GUI video path needs belong to `slopdesk-videohostd`, which no
    release ships yet -- build it from a checkout with `just videohostd`.

    The command-line tools live in the formula. SlopDesk.app links `slopdesk` at launch from a
    copy beside its own executable and the shipped bundle carries none, so that link is a no-op
    and `brew install aislopware/tap/slopdesk` is where the command comes from.
  EOS

  zap trash: [
    "~/Library/Application Support/SlopDesk",
    "~/Library/Containers/com.slopdesk.client.macos",
    "~/Library/Preferences/com.slopdesk.client.macos.plist",
    "~/Library/Preferences/com.slopdesk.host.macos.plist",
    "~/Library/Saved Application State/com.slopdesk.client.macos.savedState",
  ]
end
