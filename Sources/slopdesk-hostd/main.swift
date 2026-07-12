import Foundation
import SlopDeskHost
import SlopDeskInspector
import SlopDeskVideoProtocol

// slopdesk-hostd — headless SlopDesk host daemon (PTY + transport).
//
// Wires up HostServer: bind a TCP listener (0.0.0.0 / OS-chosen — no interface pin,
// per [13]), spawn the user's login shell per session, relay PTY bytes over the dual
// data/control channels with replay-buffer reconnect, and survive client disconnects.
// Runs until SIGINT.

let arguments = CommandLine.arguments
let programName = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "slopdesk-hostd"

// Raise the soft fd limit toward 8192 (bounded by the hard limit) BEFORE anything opens files:
// every live/detached pane holds a PTY master + scrollback-journal fd (+ per-connection sockets),
// and the 256-session detach cap needs far more headroom than macOS's default soft limit (256).
var fdLimit = rlimit()
if getrlimit(RLIMIT_NOFILE, &fdLimit) == 0 {
    let target: rlim_t = 8192
    let raised = min(fdLimit.rlim_max, max(fdLimit.rlim_cur, target))
    if raised > fdLimit.rlim_cur {
        var newLimit = fdLimit
        newLimit.rlim_cur = raised
        _ = setrlimit(RLIMIT_NOFILE, &newLimit)
    }
}

// Fold the `video-prefs.json` sidecar into `EnvConfig.overlay` at launch, BEFORE
// any consumer reads a setting — here the agent-detection gates (`SLOPDESK_AGENT_DETECT`/`_HOOKS`,
// read below) resolve ProcessInfo env → overlay → default, so a GUI toggle applies on the next launch.
// A real `SLOPDESK_*` env var still wins (the sidecar only fills gaps). The same sidecar the
// `slopdesk-videohostd` daemon loads — both host daemons now honour the shared agent prefs. A
// missing / corrupt sidecar is a no-op. (No live reload — the gates are read once.)
let appliedHostPrefs = EnvBridge.loadDefaultSidecarIntoEnvConfig()
if !appliedHostPrefs.isEmpty, ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil {
    FileHandle.standardError.write(
        Data("\(programName): applied video-prefs.json overlay → \(appliedHostPrefs.sorted())\n".utf8),
    )
}

// `integration install|uninstall claude`: write/merge (or strip) the Claude Code hooks
// config + hook script, then EXIT. This is a one-shot setup command, not the daemon path; it
// runs entirely off the pure ``AgentInstaller`` + its thin disk shim. Honored before the daemon
// arg-parse so `integration …` never reaches the listener.
if arguments.count >= 2, arguments[1] == "integration" {
    let sub = arguments.count >= 3 ? arguments[2] : ""
    let target = arguments.count >= 4 ? arguments[3] : "claude"
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
        FileHandle.standardError.write(Data(
            "usage: \(programName) integration install|uninstall claude\n".utf8,
        ))
        exit(2)
    }
    guard target == "claude" else { fail("unknown integration target '\(target)' (only 'claude')") }
    let settingsPath = AgentInstaller.defaultSettingsPath()
    let scriptPath = AgentInstaller.defaultScriptPath()
    do {
        switch sub {
        case "install":
            _ = try AgentInstaller.install(settingsPath: settingsPath, scriptPath: scriptPath)
            print("slopdesk: installed Claude Code hooks → \(settingsPath)")
            print("slopdesk: hook script → \(scriptPath)")
            print("slopdesk: start the host with \(HostEnvironment.agentHooksEnvKey)=1 to bind the listener socket.")
            exit(0)
        case "uninstall":
            _ = try AgentInstaller.uninstall(settingsPath: settingsPath)
            print("slopdesk: removed Claude Code hooks from \(settingsPath)")
            exit(0)
        default:
            fail("unknown integration subcommand '\(sub)' (use install | uninstall)")
        }
    } catch {
        fail("integration \(sub) failed: \(error)")
    }
}

guard let parsed = HostdArguments.parse(arguments) else {
    FileHandle.standardError.write(Data(
        (HostdArguments.usage(programName: programName) + "\n").utf8,
    ))
    exit(2)
}

let log: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
}

// The foreground-process watch is the PRIMARY, zero-config Claude detection signal
// (Decision #5) — default-ON, only `SLOPDESK_AGENT_DETECT=0` disables it.
let agentDetectEnabled = HostEnvironment.agentDetectEnabled()

// The Warp-style "Blocks" tap (per-command segmentation) — default-ON, only
// `SLOPDESK_BLOCKS=0` disables it. When off the byte pipeline + sniffer are byte-identical.
let blocksEnabled = HostEnvironment.blocksEnabled()

// The OPT-IN Claude-hook listener (Decision #5: SECOND/opt-in). Bound only when
// `SLOPDESK_AGENT_HOOKS=1` (default-OFF). The socket lives in the user's temp dir, keyed by
// pid so concurrent hosts don't collide. The installed hook (`integration install claude`)
// POSTs to `SLOPDESK_SOCKET_PATH`, which every PTY env exports.
var agentHookListener: AgentHookListener?
var agentHookSocketPath = ""
if HostEnvironment.agentHooksEnabled() {
    agentHookSocketPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("slopdesk-agent-\(getpid()).sock").path
    let listener = AgentHookListener()
    listener.onLog = log
    agentHookListener = listener
}

// Agent-control Unix-domain socket (DEFAULT-OFF: only `SLOPDESK_AGENT_CONTROL=1` enables).
// The socket path is keyed by pid (same derivation as the hook socket) so concurrent hosts
// don't collide. chmod 0600 is applied by `AgentControlAcceptor.start(path:)`.
// Resolve the path BEFORE constructing HostServer so the server can inject it into PTY envs.
let agentControlSocketPath: String =
    if HostEnvironment.agentControlEnabled() {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("slopdesk-ctl-\(getpid()).sock").path
    } else {
        ""
    }

// Resolve the sibling `slopdesk-ctl` binary (P1 env sentinel for spawned panes). hostd and ctl
// ship in the same directory, so derive ctl's path from hostd's executable path. If the sibling is
// absent, leave empty → spawned agents fall back to a PATH lookup of `slopdesk-ctl`.
let ctlBinaryPath: String = {
    guard let hostdPath = CommandLine.arguments.first else { return "" }
    let dir = URL(fileURLWithPath: hostdPath).deletingLastPathComponent()
    let candidate = dir.appendingPathComponent("slopdesk-ctl").path
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : ""
}()

let server = HostServer(
    port: parsed.port,
    shellPath: parsed.shell,
    launchMode: parsed.launchMode,
    agentDetectEnabled: agentDetectEnabled,
    agentHookListener: agentHookListener,
    agentHookSocketPath: agentHookSocketPath,
    agentControlSocketPath: agentControlSocketPath,
    ctlBinaryPath: ctlBinaryPath,
    blocksEnabled: blocksEnabled,
    // Disk scrollback journals (history survives hostd restarts / TTL evictions). `nil` when
    // SLOPDESK_SCROLLBACK_PERSIST=0 or SLOPDESK_SCROLLBACK_DISK=0; HostServer additionally
    // AND-s the detach gate.
    scrollbackJournals: ScrollbackJournalStore.makeFromEnvironment(),
)
server.onLog = log

// Hold a system-sleep assertion while ANY agent is processing. DEFAULT-OFF — only
// `SLOPDESK_AGENT_PREVENT_SLEEP=1` (the client `preventSleep` toggle, via the video-prefs.json sidecar)
// enables it. macOS-host-only: the `IOPMAssertion` glue (`PreventSleepAssertion`) lives behind `#if
// os(macOS)`. The driver aggregates each pane's `claudeStatus` transition (the existing P1 fan-out) into a
// `.working` set and asks the pure `PreventSleepPolicy` whether to hold the assertion — asserting on the
// first working pane, releasing when none remain (strictly balanced, so a quiet host always sleeps).
#if os(macOS)
// The driver (`PreventSleepDriver`, in SlopDeskHost) guards the working-pane set AND the balanced
// `IOPMAssertion` apply under ONE lock, so the agent-status fan-out (which calls observers OUTSIDE its own
// lock, from BOTH the foreground-poll thread and the mux teardown fan) can never apply a stale state that
// leaks the assertion. The macOS-only `PreventSleepAssertion` is injected as its `PreventSleepAsserting`
// sink; the driver asks the pure `PreventSleepPolicy` whether to hold the assertion each edge.
let preventSleepEnabled = HostEnvironment.agentPreventSleepEnabled()
if preventSleepEnabled {
    let preventSleepDriver = PreventSleepDriver(enabled: preventSleepEnabled, asserter: PreventSleepAssertion())
    server.observeAgentStatusForPreventSleep { paneId, state in
        // "working" is the ctl supervision string for `ClaudeStatus.working` (see `AgentControlState`).
        preventSleepDriver.note(paneId: paneId, working: state == "working")
    }
    log("prevent-sleep: SLOPDESK_AGENT_PREVENT_SLEEP=1 — holding a system-sleep assertion while any agent works")
}
#endif

// Construct the control listener (needs a reference to the server for verb dispatch).
var agentControlListener: AgentControlListener?
if !agentControlSocketPath.isEmpty {
    let listener = AgentControlListener(socketPath: agentControlSocketPath, server: server)
    listener.onLog = log
    agentControlListener = listener
}

// Bind the hook socket now (before the listener accepts client connections). A bind failure is
// logged + non-fatal — the foreground watch still provides detection (Decision #5).
if let agentHookListener {
    do {
        try agentHookListener.start(path: agentHookSocketPath)
    } catch {
        log("agent-hook listener failed to bind (\(error)) — continuing with process-watch only")
    }
}

// Bind the agent-control socket. A bind failure is logged + non-fatal (the terminal path is
// unaffected); agents will get connection-refused and should report the error to the operator.
if let agentControlListener {
    do {
        try agentControlListener.start()
        log("agent-control socket: \(agentControlSocketPath) (SLOPDESK_CONTROL_SOCKET)")
    } catch {
        log("agent-control listener failed to bind (\(error)) — control socket unavailable")
    }
}

// Inspector server (NWConnection #2, port + 1) — read-only structured companion.
// Constructed when --inspector / --transcript is set. The replay log is the
// replay-then-live fan-out; the engine feeds it. Live per-PTY transcript-path
// discovery via the SessionStart hook is DEFERRED — for now the path is the injected
// --transcript value (if any), tailed straight into the engine. Without a path the
// server still binds (so a client can connect) and the replay log stays empty until
// per-session tailing is wired up.
let inspectorEngine = InspectorEngine()
let inspectorReplayLog = InspectorReplayLog()
inspectorReplayLog.ingest(inspectorEngine.events)

let inspectorServer: InspectorServer?
if parsed.inspectorEnabled {
    let inspector = InspectorServer(
        terminalPort: parsed.port,
        replayLog: inspectorReplayLog,
        transcriptPath: parsed.transcriptPath,
    )
    inspector.onLog = log
    inspectorServer = inspector

    // If a transcript path was injected, tail it into the engine now (per-PTY discovery
    // will replace this later). The tailer tolerates the file not existing
    // yet, so it is safe to start before `claude` creates it.
    if let path = parsed.transcriptPath {
        let tailer = TranscriptTailer(path: path)
        inspectorEngine.run(tailer: tailer, subagents: nil)
        log("inspector tailing transcript \(path)")
    }
} else {
    inspectorServer = nil
}

// A one-shot latch so a SECOND SIGINT during the (potentially ~0.25s/pane) async shutdown does not
// spawn a second teardown Task that calls `exit(0)` again — two concurrent libc `exit()` calls are UB
// (atexit handlers / stdio flush run twice).
final class ShutdownLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns `true` exactly once (the first call); `false` thereafter.
    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

let shutdownLatch = ShutdownLatch()

// Install a SIGINT handler that stops the server and exits. Use a DispatchSource so
// the default SIGINT disposition does not kill us mid-shutdown.
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    guard shutdownLatch.tryFire() else { return } // ignore repeated Ctrl-C during the async drain
    log("SIGINT — shutting down")
    Task {
        agentHookListener?.stop()
        agentControlListener?.stop()
        inspectorServer?.stop()
        await server.stop()
        exit(0)
    }
}

sigintSource.resume()

Task {
    do {
        try await server.start()
        let bound = await server.boundPort() ?? parsed.port
        log("listening on 0.0.0.0:\(bound) (shell=\(server.shellPath), mode=shell)")
    } catch {
        log("failed to start: \(error)")
        exit(1)
    }

    // Bring up the inspector listener (port + 1) once the terminal server is up. This is SEPARATE from
    // the terminal-server bring-up above: by now the terminal server is already bound + accepting, so
    // an inspector-bind failure (e.g. EADDRINUSE on port+1 while the main port was free) must tear the
    // terminal server down CLEANLY — the orderly child-reap / `bye` path — before exiting, not `exit(1)`
    // and leak a just-accepted shell un-reaped.
    if let inspectorServer {
        do {
            try await inspectorServer.start()
        } catch {
            // Route this exit(1) through the SAME one-shot latch as the SIGINT
            // handler, so an inspector-bind failure and a concurrent Ctrl-C can never both call exit()
            // (two concurrent libc exit()s are UB). If SIGINT already owns shutdown, let it finish.
            guard shutdownLatch.tryFire() else { return }
            log("inspector failed to start: \(error) — shutting down")
            await server.stop()
            exit(1)
        }
    }
}

// Keep the process alive for the listener + relay tasks; SIGINT drives exit().
dispatchMain()
