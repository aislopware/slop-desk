import Foundation
import SlopDeskVideoProtocol

/// Builds the curated environment for a spawned login shell.
///
/// W11 retired the curated `claude` launch mode (a Claude session is now an auto-detected `.terminal`
/// pane — see `ClaudePaneDetector`); the only Claude-specific surface left is the ``Term`` choice in
/// ``ClaudeCodeProfile`` (P4 removed `ClaudeCodeProfile.environment`/`ClaudeAuthResolver`). This generic
/// profile is the Claude-agnostic env for a plain login shell (WF-3).
///
/// TERM is shared: the client renders with libghostty, so the plain-shell path advertises the SAME
/// `TERM=xterm-ghostty` as the retired Claude path (``ClaudeCodeProfile/Term/ghostty``) — one source of
/// truth, not a divergent `xterm-256color` default. `curated(term:)` takes the value so callers can pick
/// the documented `.xterm256` fallback (#54700).
public enum HostEnvironment {
    /// The default `TERM` for a spawned shell. Single source of truth shared with
    /// ``ClaudeCodeProfile`` (its `.ghostty` raw value): the client renders with libghostty,
    /// so a plain shell advertises the native ghostty TERM.
    public static let defaultTerm = ClaudeCodeProfile.Term.ghostty.rawValue

    /// The terminal-program identity advertised to the child shell via `TERM_PROGRAM` (and the
    /// Amazon-Q/Fig `CW_TERM`). We report OURSELVES, never the launcher's `TERM_PROGRAM`, so the
    /// shell and any program inspecting it sees `slopdesk` rather than `Apple_Terminal`/`ghostty`.
    public static let termProgram = "slopdesk"

    /// The build/marketing version advertised via `TERM_PROGRAM_VERSION`. Kept in step with the app
    /// target's `MARKETING_VERSION` (`Apps/ClientApp-macOS/project.yml`) and `CLIVersion.version`.
    public static let buildVersion = "0.1.0"

    /// A curated child environment: inherit a safe allowlist from the parent and layer
    /// the terminal defaults on top. We deliberately do **not** forward the parent's
    /// `PATH` blindly ([12] §1.4) — we set a conservative default the child's login
    /// shell will re-derive from its profile anyway.
    ///
    /// - Parameters:
    ///   - term: the `TERM` to advertise. Defaults to ``defaultTerm`` (`xterm-ghostty`),
    ///     matching what the libghostty client renders.
    ///   - agentSocketPath: when non-nil, exported as `SLOPDESK_SOCKET_PATH` so an installed
    ///     Claude Code hook (W10, ``AgentInstaller``) knows where to POST hook events. Absent
    ///     by default — detection works WITHOUT hooks via the foreground watcher (Decision #5).
    ///   - paneID: when non-nil, exported as `SLOPDESK_PANE_ID` so the hook can tag which pane
    ///     it belongs to (Muxy's `MUXY_PANE_ID` analog). Absent by default.
    public static func curated(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        term: String = Self.defaultTerm,
        agentSocketPath: String? = nil,
        paneID: String? = nil,
        controlSocketPath: String? = nil,
    )
        -> [String: String]
    {
        var env: [String: String] = [:]

        // Mirror identity / locale-ish vars from the parent when present.
        //
        // TERMINFO / TERMINFO_DIRS are mirrored (R8 #2) because the host's terminfo PROBE
        // (``TerminfoResolver/searchDirectories``) honours them when deciding whether `xterm-ghostty`
        // resolves. If the host was launched from a shell whose TERMINFO points at a non-standard dir
        // holding the ghostty entry (Nix / Homebrew / per-user install), the probe says "resolvable" and
        // we advertise `TERM=xterm-ghostty` — but a child lacking those vars searches only the default
        // dirs, FAILS to find the entry, and every TUI degrades. Forwarding (only when present) makes the
        // child's ncurses search the SAME dirs the probe used, so a "resolvable" verdict is honoured.
        // NOTE: `TERM_PROGRAM` is deliberately NOT mirrored: the child must report OUR identity (set
        // below), not the launcher's (`Apple_Terminal` / `ghostty`); a mirrored value would also let
        // Amazon-Q/Fig `cwterm` re-exec mid-`.zshrc`.
        for key in [
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "TERMINFO",
            "TERMINFO_DIRS",
        ] {
            if let value = parent[key] { env[key] = value }
        }

        // Terminal defaults (UTF-8 end-to-end; [12] §1.4).
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        env["NCURSES_NO_UTF8_ACS"] = "1"

        // Terminal-program identity. Advertise OURSELVES unconditionally so the child shell reports
        // `slopdesk` (not the launcher's `Apple_Terminal`/`ghostty`), and set `CW_TERM=slopdesk`
        // so Amazon-Q/Fig's shell hooks recognise a supported host and do NOT `cwterm`-exec a nested
        // pseudo-terminal mid-`.zshrc`. These are local PTY env only (never on the wire).
        env["TERM_PROGRAM"] = Self.termProgram
        env["TERM_PROGRAM_VERSION"] = Self.buildVersion
        env["CW_TERM"] = Self.termProgram

        // Conservative PATH so the shell can find its own profile / common tools even
        // before the login profile augments it. (Not forwarded blindly from parent.)
        env["PATH"] = parent["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // Forward the OSC-133 marks opt-out to the child: the shim's `.zshrc` reads
        // `${SLOPDESK_OSC133:-1}` in the CHILD, so a daemon-side `SLOPDESK_OSC133=0` (the documented
        // marks-only opt-out) only takes effect if carried across this allowlist. Forwarded ONLY when
        // set — absent leaves the shim's default-on branch unchanged.
        if let osc133 = parent[ShellIntegration.osc133EnvKey] { env[ShellIntegration.osc133EnvKey] = osc133 }

        // W10: export the agent-hook socket path + pane id into the PTY env (Muxy's
        // MUXY_SOCKET_PATH / MUXY_PANE_ID analog) when the host has the opt-in hook listener
        // enabled. The installed hook script (``AgentInstaller/hookScript()``) reads these to
        // POST hook events to the host; absent → the hook is a silent no-op.
        if let agentSocketPath { env[Self.agentSocketEnvKey] = agentSocketPath }
        if let paneID { env[Self.agentPaneIDEnvKey] = paneID }
        if let controlSocketPath { env[Self.agentControlSocketEnvKey] = controlSocketPath }

        return env
    }

    /// The PTY env var carrying the agent-hook listener socket path (W10). The installed
    /// Claude Code hook (``AgentInstaller``) POSTs to this socket; matches `MUXY_SOCKET_PATH`.
    public static let agentSocketEnvKey = "SLOPDESK_SOCKET_PATH"

    /// The PTY env var carrying the pane id the hook should tag its events with (W10);
    /// matches `MUXY_PANE_ID`.
    public static let agentPaneIDEnvKey = "SLOPDESK_PANE_ID"

    /// Agent-control socket path exported to every PTY env when the control listener is
    /// enabled. Agents shell out to `slopdesk-ctl` pointing at this socket.
    public static let agentControlSocketEnvKey = "SLOPDESK_CONTROL_SOCKET"

    /// Whether the agent-control Unix-domain socket should be bound. Default idiom =
    /// DEFAULT-OFF via `env[key] == "1"` (same as hooks) — writing to PTYs and spawning
    /// shells is not something to enable silently. Only an explicit `"1"` enables it.
    public static let agentControlEnvKey = "SLOPDESK_AGENT_CONTROL"

    /// SENTINEL exported into a control-SPAWNED pane's env (P1): `"1"` tells an agent running
    /// inside that it lives under slopdesk control and the ctl socket/binary are reachable, so it
    /// can self-orient with zero discovery. Set ONLY for `spawn`-created panes (not user panes).
    public static let ctlSentinelEnvKey = "SLOPDESK_CTL"

    /// The absolute path to the `slopdesk-ctl` binary, exported into a control-spawned pane's env
    /// (P1) so an agent can invoke it directly without a PATH lookup. Empty/absent → the agent
    /// falls back to a PATH lookup of `slopdesk-ctl`.
    public static let ctlBinaryEnvKey = "SLOPDESK_CTL_BIN"

    /// Resolves whether the agent-control socket should be bound. Default-OFF: only `"1"` enables.
    public static func agentControlEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        environment[agentControlEnvKey] == "1"
    }

    /// W10 — whether host-side Claude-Code agent detection is enabled (the foreground
    /// process-watch + the rolled-up status emission). Default idiom = DEFAULT-ON via
    /// `env[key] != "0"` (only an explicit `"0"` disables) — process-watch is zero-config and
    /// the ratified primary signal (Decision #5), so it is on unless the operator opts out.
    public static let agentDetectEnvKey = "SLOPDESK_AGENT_DETECT"

    /// Resolves whether agent detection (the foreground watcher) is enabled. Default-ON:
    /// only the exact string `"0"` disables; anything else (unset, `"1"`, …) enables.
    ///
    /// W12: the default `environment` resolves through ``EnvConfig`` (ProcessInfo env → settings
    /// overlay), so a GUI toggle in the agent settings (folded in from `video-prefs.json`) reaches this
    /// gate. An EMPTY overlay is byte-identical to the old `ProcessInfo.processInfo.environment[key]`, so
    /// the default-ON `!= "0"` truth table is unchanged. An explicit `environment:` (tests) bypasses the
    /// overlay.
    public static func agentDetectEnabled(
        environment: [String: String] = configEnv(agentDetectEnvKey),
    )
        -> Bool
    {
        environment[agentDetectEnvKey] != "0"
    }

    /// WB1 — whether the host segments the outbound PTY stream into Warp-style "Blocks" (the
    /// additive parallel ``CommandBlockSegmenter`` tap + the type-28/29 wire). Default idiom =
    /// DEFAULT-ON via `env[key] != "0"` (only an explicit `"0"` disables): when off, the byte
    /// pipeline + the live ``HostOutputSniffer`` stay byte-identical (no segmenter, no emit).
    public static let blocksEnvKey = "SLOPDESK_BLOCKS"

    /// Resolves whether the Blocks tap is enabled. Default-ON: only the exact string `"0"`
    /// disables; anything else (unset, `"1"`, …) enables. Same ``EnvConfig`` overlay resolution
    /// as ``agentDetectEnabled(environment:)`` (an empty overlay is byte-identical to a `ProcessInfo`
    /// read, so the default-ON `!= "0"` truth table is unchanged).
    public static func blocksEnabled(
        environment: [String: String] = configEnv(blocksEnvKey),
    )
        -> Bool
    {
        environment[blocksEnvKey] != "0"
    }

    /// E14/K2 — the env-bridge key carrying the client's "Auto Progress-Bar Commands" list to the
    /// host's synthetic OSC-9;4 spinner matcher (``AutoProgressMatcher``). Value is NEWLINE-separated
    /// prefix entries (each a whitespace-delimited command prefix, e.g. `git push`). Resolved at THIS ONE
    /// shared site — set IDENTICALLY on host + client (like ``SLOPDESK_FEC_M``): the client setting
    /// `autoProgressCommands` is the edit surface; a live edit re-drives the host only on its NEXT launch
    /// (env read at start). See docs/DECISIONS.md.
    public static let autoProgressCommandsEnvKey = "SLOPDESK_AUTO_PROGRESS_COMMANDS"

    /// Resolves the host's auto-progress prefix list (E14/K2). UNSET ⇒ ``AutoProgressMatcher/builtInPrefixes``
    /// (auto-progress ON for known slow commands); SET-but-EMPTY ⇒ `[]` (auto-progress DISABLED, the
    /// "clear the field" behaviour); SET ⇒ the parsed entries. Same ``EnvConfig`` overlay resolution as
    /// the other gates, so a GUI override reaches the matcher; an explicit `environment:` (tests) bypasses
    /// the overlay.
    public static func autoProgressPrefixes(
        environment: [String: String] = configEnv(autoProgressCommandsEnvKey),
    )
        -> [String]
    {
        AutoProgressMatcher.parsePrefixes(envValue: environment[autoProgressCommandsEnvKey])
    }

    /// E14/K13 — the env-bridge keys gating the agent-control ctl socket's MUTATING verbs. Default idiom =
    /// DEFAULT-OFF via `env[key] == "1"` (same as ``agentControlEnvKey``): injecting keys into a live PTY,
    /// spawning / killing a pane, or reaching a `sudo`/`ssh` prompt is not something to enable silently. The
    /// CLIENT toggles (`SettingsKey.ipcAllowSendKeys` / `ipcAllowSensitiveSessions`) are the edit surface,
    /// re-driving the host on its NEXT launch — set IDENTICALLY host+client, like ``SLOPDESK_FEC_M``. The
    /// guard ENFORCES host-side on the existing NDJSON ctl socket (no new socket, no tokens, no crypto — the
    /// WireGuard mesh is the security boundary). See docs/DECISIONS.md.
    public static let ipcAllowSendKeysEnvKey = "SLOPDESK_IPC_ALLOW_SEND_KEYS"
    public static let ipcAllowSensitiveEnvKey = "SLOPDESK_IPC_ALLOW_SENSITIVE"

    /// Resolves whether the ctl socket may run MUTATING verbs (`write`/`run`/`spawn`/`kill`/`resize`).
    /// Default-OFF: only the exact string `"1"` enables; read-only verbs are always allowed regardless. Same
    /// ``EnvConfig`` overlay resolution as the other gates, so a GUI toggle reaches the gate; an explicit
    /// `environment:` (tests) bypasses it.
    public static func ipcAllowSendKeys(
        environment: [String: String] = configEnv(ipcAllowSendKeysEnvKey),
    )
        -> Bool
    {
        environment[ipcAllowSendKeysEnvKey] == "1"
    }

    /// Resolves whether a mutating ctl verb may target a SENSITIVE foreground session (`ssh`/`sudo`/`login`/…).
    /// Default-OFF: only the exact string `"1"` enables. Same ``EnvConfig`` overlay resolution as
    /// ``ipcAllowSendKeys(environment:)``.
    public static func ipcAllowSensitiveSessions(
        environment: [String: String] = configEnv(ipcAllowSensitiveEnvKey),
    )
        -> Bool
    {
        environment[ipcAllowSensitiveEnvKey] == "1"
    }

    /// W10 — whether the opt-in Claude-Code HOOK listener (the `AF_UNIX` socket) is enabled.
    /// Default idiom = DEFAULT-OFF via `env[key] == "1"` (only an explicit `"1"` enables):
    /// hooks are the SECOND/opt-in signal (Decision #5), so the socket is bound only when the
    /// operator turned it on (or `integration install claude` set it for them).
    public static let agentHooksEnvKey = "SLOPDESK_AGENT_HOOKS"

    /// Resolves whether the hook listener socket should be bound. Default-OFF: only `"1"`
    /// enables; anything else (unset, `"0"`) keeps it off (foreground watch still runs).
    ///
    /// W12: the default `environment` resolves through ``EnvConfig`` — same as
    /// ``agentDetectEnabled(environment:)`` — so a GUI toggle reaches the gate; an EMPTY overlay is
    /// byte-identical to a `ProcessInfo` read (default-OFF `== "1"` preserved).
    public static func agentHooksEnabled(
        environment: [String: String] = configEnv(agentHooksEnvKey),
    )
        -> Bool
    {
        environment[agentHooksEnvKey] == "1"
    }

    /// E13 WI-3 (ES-E13-3) — whether the host holds a system-sleep assertion while ANY agent is processing
    /// ("Prevent Sleep While Processing"). Default idiom = DEFAULT-OFF via `env[key] == "1"` (like
    /// ``agentHooksEnvKey``): blocking system sleep is not something to enable silently. The CLIENT toggle is
    /// the ``AgentPreferences/preventSleep`` field, shipped via the `video-prefs.json` sidecar (reconnect-
    /// tagged); the daemon reads this gate at launch and, when ON, drives ``PreventSleepAssertion`` off the
    /// `claudeStatus .working` aggregate it already computes.
    public static let agentPreventSleepEnvKey = "SLOPDESK_AGENT_PREVENT_SLEEP"

    /// Resolves whether prevent-sleep is enabled. Default-OFF: only the exact string `"1"` enables. Same
    /// ``EnvConfig`` overlay resolution as the other agent gates, so a GUI toggle reaches the gate; an
    /// explicit `environment:` (tests) bypasses it.
    public static func agentPreventSleepEnabled(
        environment: [String: String] = configEnv(agentPreventSleepEnvKey),
    )
        -> Bool
    {
        environment[agentPreventSleepEnvKey] == "1"
    }

    /// E13 WI-3 — whether the host re-arms a detached agent session on connection recovery ("Resume on
    /// Recovery"). Default idiom = DEFAULT-ON via `env[key] != "0"` (like ``agentDetectEnvKey``): re-arming a
    /// recovered session is the helpful default, opt-OUT only. The CLIENT toggle is
    /// ``AgentPreferences/resumeOnRecovery``, sidecar-borne (reconnect-tagged). ACTUATED by ``HostServer``:
    /// it AND-s this flag into ``HostServer/detachEnabled``, mapping "Resume on Recovery" onto the
    /// ``DetachedSessionStore`` reattach machinery, so OFF makes a recovered terminal spawn a fresh shell
    /// instead of reattaching the still-running detached agent session.
    public static let agentResumeOnRecoveryEnvKey = "SLOPDESK_AGENT_RESUME_ON_RECOVERY"

    /// Resolves whether resume-on-recovery is enabled. Default-ON: only the exact string `"0"` disables. Same
    /// ``EnvConfig`` overlay resolution as the other agent gates.
    public static func agentResumeOnRecoveryEnabled(
        environment: [String: String] = configEnv(agentResumeOnRecoveryEnvKey),
    )
        -> Bool
    {
        environment[agentResumeOnRecoveryEnvKey] != "0"
    }

    /// The single `SLOPDESK_*` key resolved through ``EnvConfig`` (ProcessInfo env →
    /// settings overlay) and wrapped back into the `[String: String]` shape these gates index — so the gate's exact
    /// truth table stays at the call site while the key's *source* honours a GUI override. An empty
    /// overlay ⇒ at most the one `ProcessInfo` entry (or none), so the read is byte-identical to the
    /// old `ProcessInfo.processInfo.environment` default. `public` only because a `public` function's
    /// default-argument expression references it (evaluated at the call site).
    public static func configEnv(_ key: String) -> [String: String] {
        guard let value = EnvConfig.string(key) else { return [:] }
        return [key: value]
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
        let name = URL(fileURLWithPath: shell).lastPathComponent
        return "-" + name
    }
}
