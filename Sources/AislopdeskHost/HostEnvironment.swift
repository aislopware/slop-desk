import Foundation

/// Builds the curated environment for a spawned login shell.
///
/// WF-7 owns the Claude-Code-specific environment (`CLAUDE_CODE_NO_FLICKER=1`,
/// `CLAUDE_CODE_ENTRYPOINT=remote_mobile`, `claude setup-token` reuse, etc.) in
/// ``ClaudeCodeProfile`` / ``ClaudeAuthResolver`` (selected via
/// `HostServer.LaunchMode.claudeCode`). This generic profile is the env for a plain
/// login shell (WF-3) and stays Claude-agnostic.
///
/// TERM is shared: the client renders with libghostty, so the plain-shell path now
/// advertises the SAME `TERM=xterm-ghostty` as the Claude Code path
/// (``ClaudeCodeProfile/Term/ghostty``) — there is one source of truth, not a divergent
/// `xterm-256color` default. `curated(term:)` takes the value so callers can pick the
/// documented `.xterm256` fallback (#54700) symmetrically with the profile toggle.
public enum HostEnvironment {
    /// The default `TERM` for a spawned shell. Single source of truth shared with
    /// ``ClaudeCodeProfile`` (its `.ghostty` raw value): the client renders with
    /// libghostty, so a plain shell advertises the native ghostty TERM too.
    public static let defaultTerm = ClaudeCodeProfile.Term.ghostty.rawValue

    /// A curated child environment: inherit a safe allowlist from the parent and layer
    /// the terminal defaults on top. We deliberately do **not** forward the parent's
    /// `PATH` blindly ([12] §1.4) — we set a conservative default the child's login
    /// shell will re-derive from its profile anyway.
    ///
    /// - Parameter term: the `TERM` to advertise. Defaults to ``defaultTerm``
    ///   (`xterm-ghostty`), matching what the libghostty client renders.
    public static func curated(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        term: String = HostEnvironment.defaultTerm
    )
        -> [String: String]
    {
        var env: [String: String] = [:]

        // Mirror identity / locale-ish vars from the parent when present.
        //
        // TERMINFO / TERMINFO_DIRS are mirrored (R8 #2) because the host's terminfo PROBE
        // (``TerminfoResolver/searchDirectories``) honours them when deciding whether `xterm-ghostty`
        // resolves. If the operator launched the host from a shell whose TERMINFO points at a
        // non-standard dir holding the ghostty entry (Nix / Homebrew / per-user install), the probe says
        // "resolvable" and we advertise `TERM=xterm-ghostty` — but a child that did NOT inherit those vars
        // would have its ncurses search only the default dirs and FAIL to find the entry, so every TUI
        // degrades. Forwarding them makes the child's ncurses search the SAME dirs the probe used (only
        // forwarded when present), so a "resolvable" verdict is actually honoured.
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM_PROGRAM", "TERMINFO", "TERMINFO_DIRS"] {
            if let value = parent[key] { env[key] = value }
        }

        // Terminal defaults (UTF-8 end-to-end; [12] §1.4).
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        env["NCURSES_NO_UTF8_ACS"] = "1"

        // Conservative PATH so the shell can find its own profile / common tools even
        // before the login profile augments it. (Not forwarded blindly from parent.)
        env["PATH"] = parent["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        return env
    }

    /// The user's login shell path: `$SHELL` if set and absolute, else `/bin/zsh`.
    public static func loginShell(parent: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        if let shell = parent["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }

    /// The login-shell `argv[0]`: the shell's basename with a leading `-` (so it sources
    /// `.zprofile`/`.zshrc`; [12] §1.4).
    public static func loginArgv0(forShell shell: String) -> String {
        let name = (shell as NSString).lastPathComponent
        return "-" + name
    }
}
