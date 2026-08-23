# The SOURCE OF TRUTH for aislopware/homebrew-tap's Formula/slopdesk.rb.
#
# It lives here, in the repository whose releases it installs, for one reason: the list of binaries
# below has to agree with `scripts/shipped-tools.sh`, and a file in another repository agrees with
# nothing. It did not: the tap installed three of the twelve tools for four releases, so a `brew`
# install had no superd — and a host without superd cannot open a pane, because superd forks the
# shells and owns every PTY master (`docs/51`). `rust/slopdesk-invariants` now derives the list below
# from the same arrays `package-release.sh` packs, so the two cannot drift again.
#
# The release workflow's `tap` job COPIES this file into the tap and rewrites two lines — `version`
# and `sha256`. Keep both at two-space indentation, one per file, or that rewrite stops matching.
class Slopdesk < Formula
  desc "Low-latency remote coding: SlopDesk host daemon and command-line tools"
  homepage "https://github.com/aislopware/slop-desk"
  version "0.4.0"
  url "https://github.com/aislopware/slop-desk/releases/download/v#{version}/slopdesk-cli-#{version}-arm64.tar.gz"
  sha256 "6783dbd856e9e93591582113edf19cc609d5751ee675d5b85c7fb6542db4f053"
  license "MIT"

  # Apple silicon only, and not by preference: the client links libghostty, which ships a
  # macos-arm64 slice and nothing else, and the apps deploy against macOS 26 — which no Intel
  # Mac runs. The CLI is built from the same tree and released as one arm64 artifact.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    # All ten, in one flat `bin`. Not tidiness — `slopdesk-agenthooks` installs the relay from
    # `executable.parent()/slopdesk-hook`, so tucking the daemons into `libexec` would leave the
    # hook install with nothing to copy (`docs/49`).
    bin.install "slopdesk",
                "slopdesk-hostd",
                "slopdesk-ctl",
                "slopdesk-probe",
                "slopdesk-hook",
                "slopdesk-agenthooks",
                "slopdesk-superd",
                "slopdesk-screend",
                "slopdesk-dropd",
                "slopdesk-inspectord",
                "slopdesk-androidd",
                "slopdesk-codeseed"

    # The manifest travels with the install, one directory ABOVE `bin`, which is where
    # `slopdesk sidecars` looks after resolving its own argv[0] through Homebrew's symlink farm.
    # Without it an upgrade cannot say which of the twelve binaries actually changed, and the
    # honest fallback — "everything changed" — is the all-or-nothing behaviour it exists to end.
    prefix.install "MANIFEST.json"
  end

  # superd as a launchd agent, `brew services start slopdesk`.
  #
  # `keep_alive successful_exit: false` — never a bare `true` — and the detail is load-bearing:
  # superd exits 0 ON PURPOSE when another instance already holds its lock file, rather than
  # stealing a live socket and stranding the panes behind it. A bare `KeepAlive` restarts on any
  # exit, so the loser respawns every ten seconds forever. With this form a machine carrying both
  # agents — this one and a checkout's `com.slopdesk.superd` from `make superd-install` —
  # settles, with whichever booted first keeping the panes.
  service do
    run [opt_bin/"slopdesk-superd"]
    keep_alive successful_exit: false
    log_path var/"log/slopdesk-superd.log"
    error_log_path var/"log/slopdesk-superd.log"
  end

  # Records the manifest this install shipped, so the NEXT upgrade can diff against it.
  #
  # This has to happen at install time and nowhere else: Homebrew replaces the Cellar directory
  # wholesale, so by the time anything notices an upgrade the previous release's `MANIFEST.json`
  # is already gone. The copy lands in the user's Application Support container, which survives it.
  #
  # It prints the plan first — what the upgrade changed, tool by tool, and what each change means.
  # Nothing is restarted here: hostd restarts the three sidecars it owns at its next start, screend
  # retires itself once idle, and superd is the user's call because ending it ends every live pane.
  def post_install
    system bin/"slopdesk", "sidecars", "--record"
  rescue
    # A manifest that could not be read or recorded costs one upgrade's worth of detail. It must
    # never be the thing that fails an install.
    nil
  end

  def caveats
    <<~EOS
      slopdesk-hostd forks your login shell over a PTY and listens for inbound connections.
      There is no app-layer authentication by design — reach it over a private WireGuard
      mesh, never over an address the public internet can route to.

      superd owns every PTY master. Start it with `brew services start slopdesk`; a checkout's
      `make superd-install` agent and this one coexist, and whichever booted first keeps
      the panes.

      `slopdesk sidecars` says what the last upgrade changed, binary by binary, and what each
      change means for what is currently running.

      This formula is the only source of the command-line tools. The cask ships the two app
      bundles and nothing else — SlopDesk.app carries no copy of `slopdesk` inside it — so the
      app's first-launch "Install the CLI" card has nothing to link and reports so.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/slopdesk version")
    assert_match "usage: slopdesk-ctl", shell_output("#{bin}/slopdesk-ctl --help")
    # The daemon the tap shipped without for four releases. Asking it for its own version proves
    # the binary is present AND runnable, which `bin.install` alone does not.
    assert_match "slopdesk-superd", shell_output("#{bin}/slopdesk-superd --version")
    # The manifest is what makes a per-binary upgrade answerable at all.
    assert_predicate prefix/"MANIFEST.json", :exist?
    assert_match "TOOL", shell_output("#{bin}/slopdesk sidecars")
  end
end
