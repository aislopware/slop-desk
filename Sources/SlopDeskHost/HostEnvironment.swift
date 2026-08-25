import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskVideoProtocol

/// Builds the curated environment for a spawned login shell.
///
/// A Claude session is an auto-detected `.terminal` pane (see `ClaudePaneDetector`), not a curated
/// `claude` launch mode, so there is no per-agent env here at all — this is the env for a plain
/// login shell, whatever the user then runs in it.
///
/// ## The two `TERM` names live here because hostd is what advertises one
/// The client renders with libghostty, so a spawned shell advertises the native ghostty `TERM` —
/// which unlocks the kitty keyboard protocol and DEC 2026 synchronized output, and which a fresh
/// host very often has no terminfo entry for (it ships with Ghostty, not with the base OS). On such
/// a host every curses app would call `setupterm("xterm-ghostty")`, find nothing, and either refuse
/// to start or degrade to the wrong key sequences. That is Ghostty's own documented third option
/// (#54700): keep the name when the host resolves it, fall back to the universally-present
/// `xterm-256color` when it does not. Pushing terminfo the way kitty's `ssh` kitten does stays out
/// of scope — it mutates somebody else's machine.
///
/// The RESOLUTION — the search order, the two on-disk layouts, the `infocmp` authority — is
/// `slopdesk-probe`'s `terminfo` module, reached through ``resolveTerm(requested:)``. The two names
/// are passed INTO it: it resolves what it is handed and knows neither of them.
///
/// The allowlist, the defaults layered on top and the two login-shell answers are a face over
/// `slopdesk-muxsession`'s `spawn_env`, which is where the twelve mirrored keys are named and the
/// reasons for each are argued. What stays here is what is genuinely hostd's: the `EnvConfig`
/// overlay the `SLOPDESK_*` gates below resolve through, and the release-owned ``buildVersion``.
public enum HostEnvironment {
    /// The default `TERM` for a spawned shell: the native libghostty entry the client can actually
    /// render (kitty keyboard, DEC 2026).
    public static let defaultTerm = "xterm-ghostty"

    /// The entry every fallback lands on — present on effectively every Unix host. Advertising it
    /// costs DEC 2026 synchronized output and avoids the multi-line paste bug (#54700).
    public static let fallbackTerm = "xterm-256color"

    /// The effective `TERM` for a new PTY, resolved against this host's terminfo database, plus
    /// whether getting there meant giving up on `requested` (so the caller can log it once).
    ///
    /// A `requested` that IS the fallback short-circuits: the request is authoritative and there is
    /// nothing to fall back from. A host whose database cannot be read at all answers the fallback
    /// and reports it as one — advertising an entry nobody verified is a guess, and the fallback is
    /// right on every machine either way.
    public static func resolveTerm(
        requested: String = Self.defaultTerm,
    ) -> (term: String, fellBack: Bool) {
        var fellBack = false
        let term = ffiLend(requested) { requestedBytes in
            ffiLend(Self.fallbackTerm) { fallbackBytes in
                ffiAnswerText(capacity: 64) { out, cap in
                    slopdesk_terminfo_resolve(
                        requestedBytes.baseAddress, requestedBytes.count,
                        fallbackBytes.baseAddress, fallbackBytes.count,
                        &fellBack, out, cap,
                    )
                }
            }
        }
        guard !term.isEmpty else { return (Self.fallbackTerm, true) }
        return (term, fellBack)
    }

    /// The build/marketing version advertised via `TERM_PROGRAM_VERSION`. Kept in step with the app
    /// target's `MARKETING_VERSION` (`Apps/ClientApp-macOS/project.yml`) and `CLIVersion.version`.
    ///
    /// It is passed INTO the door rather than minted behind it: `make release` rewrites every place
    /// the marketing version is typed, and a copy inside a crate the release tool does not scan
    /// would be a version that silently stopped being bumped.
    public static let buildVersion = "0.4.0"

    /// A curated child environment: inherit a safe allowlist from the parent and layer
    /// the terminal defaults on top. We deliberately do **not** forward the parent's
    /// `PATH` blindly ([12] §1.4) — we set a conservative default the child's login
    /// shell will re-derive from its profile anyway.
    ///
    /// - Parameters:
    ///   - term: the `TERM` to advertise. Defaults to ``defaultTerm`` (`xterm-ghostty`),
    ///     matching what the libghostty client renders.
    ///   - agentSocketPath: when non-nil, exported as `SLOPDESK_SOCKET_PATH` so an installed
    ///     Claude Code hook relay knows where to POST hook events. Absent by
    ///     default here (the daemon always supplies it); detection still works without hooks via
    ///     the foreground watcher (Decision #5).
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
        // The parent crosses WHOLE, as KEY, VALUE runs, because the rule names twelve variables and
        // passing twelve `(ptr, len)` pairs would put the closed list back on this side in the
        // argument order — which is the drift the port exists to end. See `crate::spawn_env`.
        var blob: [UInt8] = []
        for (key, value) in parent {
            ffiPushRun(&blob, key)
            ffiPushRun(&blob, value)
        }
        var pairs = 0
        let delivery = blob.withUnsafeBufferPointer { parentBytes in
            ffiLend(term) { termBytes in
                ffiLend(Self.buildVersion) { versionBytes in
                    ffiLend(agentSocketPath ?? "") { socketBytes in
                        ffiLend(paneID ?? "") { paneBytes in
                            ffiLend(controlSocketPath ?? "") { controlBytes in
                                ffiAnswerBytes(capacity: max(4096, blob.count + 1024)) { out, cap in
                                    slopdesk_spawn_env(
                                        parentBytes.baseAddress, parentBytes.count,
                                        termBytes.baseAddress, termBytes.count,
                                        versionBytes.baseAddress, versionBytes.count,
                                        socketBytes.baseAddress, socketBytes.count,
                                        paneBytes.baseAddress, paneBytes.count,
                                        controlBytes.baseAddress, controlBytes.count,
                                        out, cap, &pairs,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        let runs = ffiRuns(delivery, count: pairs * 2)
        var env: [String: String] = [:]
        env.reserveCapacity(pairs)
        for index in stride(from: 0, to: runs.count - 1, by: 2) {
            env[runs[index]] = runs[index + 1]
        }
        return env
    }

    /// The PTY env var carrying the agent-hook listener socket path. The installed
    /// The Claude Code hook relay POSTs to this socket; matches `MUXY_SOCKET_PATH`.
    public static let agentSocketEnvKey = "SLOPDESK_SOCKET_PATH"

    /// The PTY env var carrying the pane id the hook should tag its events with;
    /// matches `MUXY_PANE_ID`.
    public static let agentPaneIDEnvKey = "SLOPDESK_PANE_ID"

    /// Agent-control socket path exported to every PTY env when the control listener is
    /// enabled. Agents shell out to `slopdesk-ctl` pointing at this socket.
    public static let agentControlSocketEnvKey = "SLOPDESK_CONTROL_SOCKET"

    /// Whether hostd CLAIMS the agent-control listener. Default idiom = DEFAULT-OFF via
    /// `env[key] == "1"` (same as hooks) — writing to PTYs and spawning shells is not something to
    /// enable silently. Only an explicit `"1"` enables it.
    ///
    /// superd binds that socket either way and knows nothing about this flag; what the flag decides
    /// is whether hostd `listen`s for the `control` kind. An unclaimed listener is never advertised
    /// into a spawned child's environment, so off still means a child sees no
    /// `SLOPDESK_CONTROL_SOCKET` (`docs/51` §6.6).
    public static let agentControlEnvKey = "SLOPDESK_AGENT_CONTROL"

    /// SENTINEL exported into a control-SPAWNED pane's env: `"1"` tells an agent running
    /// inside that it lives under slopdesk control and the ctl socket/binary are reachable, so it
    /// can self-orient with zero discovery. Set ONLY for `spawn`-created panes (not user panes).
    public static let ctlSentinelEnvKey = "SLOPDESK_CTL"

    /// The absolute path to the `slopdesk-ctl` binary, exported into a control-spawned pane's env
    /// so an agent can invoke it directly without a PATH lookup. Empty/absent → the agent
    /// falls back to a PATH lookup of `slopdesk-ctl`.
    public static let ctlBinaryEnvKey = "SLOPDESK_CTL_BIN"

    /// Resolves whether hostd claims the agent-control listener. Default-OFF: only `"1"` enables.
    public static func agentControlEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        environment[agentControlEnvKey] == "1"
    }

    // Agent detection has no gate either. `SLOPDESK_AGENT_DETECT` (and its "Foreground-process
    // watch" toggle) is gone: knowing what the agent in a pane is doing is what this product is
    // for, and the watch is zero-config, host-local and costs a `tcgetpgrp` per second. Turning it
    // off bought nothing and cost every status the sidebar shows.
    //
    // `HostServer.agentDetectEnabled` / `MuxChannelSession(agentDetectEnabled:)` remain as INJECTED
    // arguments — several tests want a channel whose byte pipeline is provably identical to one
    // with no watch at all, and that is a test seam, not a user-facing switch.

    /// Whether the host segments the outbound PTY stream into Warp-style "Blocks" (the
    /// additive parallel `CommandBlockSegmenter` tap (`rust/slopdesk-superd/src/commandblocks.rs`) + the type-28/29 wire). Default idiom =
    /// DEFAULT-ON via `env[key] != "0"` (only an explicit `"0"` disables): when off, the byte
    /// pipeline + the live sniffer (`rust/slopdesk-superd/src/sniffer.rs`) stay byte-identical (no segmenter, no emit).
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

    /// The env-bridge key carrying the client's "Auto Progress-Bar Commands" list to the synthetic
    /// OSC-9;4 spinner matcher, which lives in superd (`autoprogress.rs`). Value is NEWLINE-separated
    /// prefix entries (each a whitespace-delimited command prefix, e.g. `git push`). Resolved at THIS ONE
    /// shared site and read at host START. The edit surface is Settings → Advanced → **Raw overrides**
    /// (which folds into the `video-prefs.json` sidecar the host reads); the dedicated client toggle that
    /// used to claim this bridge never actually reached it and was removed. See docs/DECISIONS.md.
    public static let autoProgressCommandsEnvKey = "SLOPDESK_AUTO_PROGRESS_COMMANDS"

    /// The bridge's value, UNPARSED, for the spawn request to carry across as-is.
    ///
    /// Deliberately not a `[String]`: superd owns the parse AND the built-in slow-command list, and
    /// hostd resolving either here would be the second copy of both. The three states the feature has
    /// survive the crossing intact — `nil` UNSET ⇒ the built-ins (auto-progress ON for known slow
    /// commands); `""` SET-but-EMPTY ⇒ DISABLED, the "clear the field" behaviour; anything else ⇒ the
    /// entries superd parses out. Same ``EnvConfig`` overlay resolution as the other gates, so a GUI
    /// override reaches the matcher; an explicit `environment:` (tests) bypasses the overlay.
    public static func autoProgressCommandsRaw(
        environment: [String: String] = configEnv(autoProgressCommandsEnvKey),
    )
        -> String?
    {
        environment[autoProgressCommandsEnvKey]
    }

    /// The env-bridge keys gating the agent-control ctl socket's MUTATING verbs. Default idiom =
    /// DEFAULT-OFF via `env[key] == "1"` (same as ``agentControlEnvKey``): injecting keys into a live PTY,
    /// spawning / killing a pane, or reaching a `sudo`/`ssh` prompt is not something to enable silently. The
    /// edit surface is Settings → Advanced → **Raw overrides** (which folds into the sidecar the host
    /// reads); the dedicated client toggles that used to claim this bridge never reached it and were
    /// removed. The guard ENFORCES host-side on the existing NDJSON ctl socket (no new socket, no tokens,
    /// no crypto — the WireGuard mesh is the security boundary). See docs/DECISIONS.md.
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

    // The Claude-Code HOOK listener has NO gate. It was `SLOPDESK_AGENT_HOOKS`, default-OFF,
    // because Decision #5 called hooks the "second, opt-in" signal — a claim about where the
    // detector's evidence RANKS, mistaken for a claim about whether to bind a socket.
    //
    // Off, the product is wrong rather than reduced. `ClaudeStatus.done` exists only on this path
    // (the screen engine has no `done` verdict at all), so a finished turn was indistinguishable
    // from one that never happened; the hook reading's `idle_prompt` notification filter had
    // nothing to filter; and `suppressesChildNotifications` stayed false, so claude's own OSC 9
    // notifications passed through as a second banner. A user cannot be expected to diagnose any of
    // that — they see a grey pane and a phantom prompt.
    //
    // Nothing is risked by binding it: the listener is READ-ONLY (it parses hook JSON and folds it
    // into the detector — it never writes to a PTY, which is what `SLOPDESK_AGENT_CONTROL` gates
    // and why THAT one stays opt-in), the socket is 0600 in the per-user temp dir, and an installed
    // hook with no socket to reach already exits silently. The only remaining choice a user makes is
    // whether to INSTALL the hooks into their own `~/.claude/settings.json` — which is theirs, and
    // stays an explicit action in Settings → Agents.

    /// Whether the host holds a system-sleep assertion while ANY agent is processing
    /// ("Prevent Sleep While Processing"). Default idiom = DEFAULT-OFF via `env[key] == "1"` (like
    /// ``agentControlEnvKey``): blocking system sleep is not something to enable silently. The CLIENT toggle is
    /// the ``AgentPreferences/preventSleep`` field, shipped via the `video-prefs.json` sidecar (reconnect-
    /// tagged); the daemon reads this gate at launch and, when ON, drives ``PreventSleepDriver`` off the
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

    /// Whether the host re-arms a detached agent session on connection recovery ("Resume on
    /// Recovery"). Default idiom = DEFAULT-ON via `env[key] != "0"` (like ``blocksEnvKey``): re-arming a
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
    /// overlay ⇒ at most the one `ProcessInfo` entry (or none), so the read is byte-identical to a plain
    /// `ProcessInfo.processInfo.environment` read. `public` only because a `public` function's
    /// default-argument expression references it (evaluated at the call site).
    public static func configEnv(_ key: String) -> [String: String] {
        guard let value = EnvConfig.string(key) else { return [:] }
        return [key: value]
    }

    /// The user's login shell path: `$SHELL` if set and absolute, else `/bin/zsh`.
    ///
    /// The one dictionary read stays here and the VALUE crosses, the way `crate::tool_path` leaves
    /// its three environment reads on the near side.
    public static func loginShell(parent: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        ffiLend(parent["SHELL"] ?? "") { shell in
            ffiAnswerText(capacity: 256) { out, cap in
                slopdesk_login_shell(shell.baseAddress, shell.count, out, cap)
            }
        }
    }

    /// The login-shell `argv[0]`: the shell's basename with a leading `-` (so it sources
    /// `.zprofile`/`.zshrc`; [12] §1.4).
    public static func loginArgv0(forShell shell: String) -> String {
        ffiLend(shell) { bytes in
            ffiAnswerText(capacity: 256) { out, cap in
                slopdesk_login_argv0(bytes.baseAddress, bytes.count, out, cap)
            }
        }
    }
}
