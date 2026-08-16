import Foundation
import SlopDeskHost
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
// any consumer reads a setting — the remaining gates resolve ProcessInfo env → overlay → default,
// so a GUI toggle applies on the next launch.
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
// config + hook relay, then EXIT. This is a one-shot setup command, not the daemon path; it
// forwards to `slopdesk-agenthooks`, which owns the merge and stages the relay from beside itself.
// Honored before the daemon arg-parse so `integration …` never reaches the listener.
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
    // A host built without `make hook` has no installer to forward to. Saying so beats merging a
    // settings file here: entries pointing at a relay nobody staged look installed and relay nothing.
    let missingInstaller = "no \(AgentHooks.binaryName) beside \(programName) — run `make build`"
    guard target == "claude" else { fail("unknown integration target '\(target)' (only 'claude')") }
    switch sub {
    case "install":
        guard let answer = AgentHooks.install() else { fail(missingInstaller) }
        if let error = answer.error { fail("integration install failed: \(error)") }
        print("slopdesk: installed Claude Code hooks → \(answer.settings)")
        print("slopdesk: hook relay → \(answer.hook ?? "?")")
        print("slopdesk: restart claude in a slopdesk pane — the host is already listening.")
        exit(0)
    case "uninstall":
        guard let answer = AgentHooks.uninstall() else { fail(missingInstaller) }
        if let error = answer.error { fail("integration uninstall failed: \(error)") }
        print("slopdesk: removed Claude Code hooks from \(answer.settings)")
        exit(0)
    default:
        fail("unknown integration subcommand '\(sub)' (use install | uninstall)")
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
// (Decision #5). No gate — see `HostEnvironment`.
let agentDetectEnabled = true

// The Warp-style "Blocks" tap (per-command segmentation) — default-ON, only
// `SLOPDESK_BLOCKS=0` disables it. When off the byte pipeline + sniffer are byte-identical.
let blocksEnabled = HostEnvironment.blocksEnabled()

// The Claude-hook listener — ALWAYS served, no gate (see `HostEnvironment` for why the old
// `SLOPDESK_AGENT_HOOKS` is gone). hostd BINDS NOTHING: superd owns the socket, at a stable
// pid-free path, because the address is baked into every agent's environment at `execve` and can
// never be corrected afterwards (`docs/51` §1). hostd claims the listener at handshake and serves
// each connection superd hands it over `SCM_RIGHTS`. A host whose hooks were never installed simply
// never receives one.
let agentHookListener: AgentHookListener? = {
    let listener = AgentHookListener()
    listener.onLog = log
    return listener
}()

// Agent-control (DEFAULT-OFF: only `SLOPDESK_AGENT_CONTROL=1` enables). Same socket ownership as
// the hook path; what the flag now decides is whether hostd CLAIMS that listener, and superd
// advertises `SLOPDESK_CONTROL_SOCKET` to a child only while someone has.
let agentControlEnabled = HostEnvironment.agentControlEnabled()

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
    agentControlEnabled: agentControlEnabled,
    ctlBinaryPath: ctlBinaryPath,
    blocksEnabled: blocksEnabled,
    // Disk scrollback journals (history survives hostd restarts / TTL evictions). `nil` when
    // SLOPDESK_SCROLLBACK_PERSIST=0 or SLOPDESK_SCROLLBACK_DISK=0; HostServer additionally
    // AND-s the detach gate.
    scrollbackTranscripts: ScrollbackTranscripts.makeFromEnvironment(),
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

// The ctl connection server (needs a reference back to the server for verb dispatch, which is why
// it cannot be an init parameter). Installed BEFORE `start()`, because that is where the listener
// claim goes out — a `control` connection arriving with nothing installed here is closed.
//
// Nothing is bound in either direction: superd owns both addresses and hands over each accepted
// connection. There is no bind to fail, so the old "failed to bind, continuing" paths are gone; what
// can still fail is the CLAIM, and `HostServer.claimChildListeners` reports that.
var agentControlListener: AgentControlListener?
if agentControlEnabled {
    let listener = AgentControlListener(server: server)
    listener.onLog = log
    server.serveAgentControl(with: listener)
    agentControlListener = listener
}

// PATH 3, the read-only structured companion (`terminalPort &+ 1`), served by
// `slopdesk-inspectord` under superd. hostd does not bind this port, tail the transcript or hold
// the replay window any more — the client dials the daemon directly, exactly as it always did
// (`docs/54`). Set inside the startup Task once `server.start()` resolves the real bound port; a
// signal racing construction just sees `nil` and skips the not-yet-started service.
var inspectorService: InspectorServiceManager?

// PATH-4 drag-drop file drops (`terminalPort &+ 2`), served by `slopdesk-dropd` under superd. Same
// nil-race tolerance as the inspector: a signal racing construction skips the not-yet-started
// service.
var fileDropService: FileDropServiceManager?

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

// Install SIGINT/SIGTERM handlers that stop the server and exit. Use DispatchSources so
// the default dispositions do not kill us mid-shutdown. SIGTERM matters as much as Ctrl-C:
// it is what `kill <pid>`, launchd stop, and system shutdown/restart deliver — without the
// handler those paths killed hostd instantly, skipping the orderly drain (child reap, replay
// flush, `bye`) that SIGINT gets. Both route through the ONE-SHOT latch, so a SIGTERM racing
// a Ctrl-C can never start two teardowns (two concurrent libc `exit()`s are UB).
@MainActor
func makeShutdownSignalSource(_ sig: Int32, name: String) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    // The source is bound to the main queue, so the handler runs on the main actor's
    // executor — `assumeIsolated` makes that visible to the compiler (the top-level
    // daemon globals it touches are main-actor state).
    source.setEventHandler {
        MainActor.assumeIsolated {
            guard shutdownLatch.tryFire() else { return } // ignore repeated signals during the async drain
            log("\(name) — shutting down")
            Task {
                // The hook sinks go; the SOCKET does not, because it is not ours to close. superd
                // keeps both child-facing addresses bound across this exit, which is the point:
                // a running agent's `SLOPDESK_SOCKET_PATH` stays valid while hostd is rebuilt.
                agentHookListener?.stop()
                // Gone before the drain, not after: from here on this daemon will not serve, and a
                // record naming a dying pid is worse than none. Its ABSENCE is meaningful — a
                // record whose pid is gone means hostd died badly, which is worth telling apart
                // from a clean stop.
                HostLaunchRecord.remove()
                // RELINQUISH, never terminate: superd keeps these children, so an upload in flight
                // and a session's replay window both survive this daemon's restart, and the next
                // hostd adopts the same child (`docs/53`, `docs/54`).
                inspectorService?.relinquish()
                fileDropService?.relinquish()
                await server.stop()
                exit(0)
            }
        }
    }
    source.resume()
    return source
}

let sigintSource = makeShutdownSignalSource(SIGINT, name: "SIGINT")
let sigtermSource = makeShutdownSignalSource(SIGTERM, name: "SIGTERM")

Task {
    let bound: UInt16
    do {
        try await server.start()
        bound = await server.boundPort() ?? parsed.port
        log("listening on 0.0.0.0:\(bound) (shell=\(server.shellPath), mode=shell)")
    } catch {
        log("failed to start: \(error)")
        exit(1)
    }

    // State how this daemon was started, now that the BOUND port is known (`--port 0` mints one
    // that differs from the request). `scripts/restart-hostd.sh` reads it, so a rebuild is one
    // command that cannot pick the wrong process, the wrong port or the wrong flags — the ritual
    // was the last thing making a restart feel expensive, now that superd makes it cheap.
    // Best-effort: a host that cannot write it still serves every client.
    let launchRecord = HostLaunchRecord.current(boundPort: bound)
    if launchRecord.write(), let recordPath = HostLaunchRecord.url()?.path {
        log("launch record at \(recordPath) — `scripts/restart-hostd.sh` restarts this exact daemon")
    }

    // Boot the code panel's backend NOW, off the client path: the shared code-server pays its
    // settings seed + extension install + Node boot while nobody is waiting, so the first panel
    // expand connects to a live workbench (user-directed startup-latency pass, 2026-08-07). A
    // binary-less host no-ops — verb 18 keeps answering `unavailable`.
    server.prewarmCodeServer()

    // Bring up PATH 3 on `terminalPort &+ 1` once the terminal server is up and its REAL bound port
    // is known — `--port 0` mints an OS-chosen ephemeral port that can differ from `parsed.port`,
    // and the inspector port is `bound &+ 1`, so this must be built from `bound`. The port is not
    // bound HERE any more: `slopdesk-inspectord` binds it, under superd, and the client dials it
    // directly — so the transcript tail and the replay window now survive `make host-restart`
    // (`docs/54`). A daemon that will not start is logged loudly and NON-fatal, exactly as a failed
    // bind was: it must not tear down the terminal server that just successfully bound.
    if parsed.inspectorEnabled {
        let inspectorPort = bound &+ 1
        let inspector = InspectorServiceManager()
        inspectorService = inspector
        if let served = await inspector.start(port: inspectorPort, transcriptPath: parsed.transcriptPath) {
            let subject = parsed.transcriptPath.map { "transcript \($0)" } ?? "no transcript yet"
            log("inspector service on 0.0.0.0:\(served) (\(subject))")
        } else {
            log(
                "slopdesk-inspectord did not come up on port \(inspectorPort) — continuing with terminal server only, no inspector",
            )
            inspectorService = nil
        }
    }

    // Bring up PATH 4 on `terminalPort &+ 2` (mirrors the inspector's `+1`), once the terminal
    // server's REAL bound port is known. The port is not bound HERE any more: `slopdesk-dropd`
    // binds it, under superd, and the client dials it directly — hostd never sees a body byte and a
    // host restart no longer takes an upload with it (`docs/53`). Gated by `SLOPDESK_FILE_TRANSFER`
    // (default-ON; `0` disables); the drop directory is `SLOPDESK_FILE_DROP_DIR` or `~/Downloads`.
    // A daemon that will not start is logged loudly and NON-fatal — it must not tear down the
    // healthy terminal server, exactly as a failed bind did not.
    let env = ProcessInfo.processInfo.environment
    if env["SLOPDESK_FILE_TRANSFER"] != "0" {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dropDir: URL = {
            guard let custom = env["SLOPDESK_FILE_DROP_DIR"], !custom.isEmpty else {
                return home.appendingPathComponent("Downloads", isDirectory: true)
            }
            // Expand a leading `~` / `~/` against the daemon user's home (avoid the bridged NSString).
            if custom == "~" { return home }
            if custom.hasPrefix("~/") {
                return home.appendingPathComponent(String(custom.dropFirst(2)), isDirectory: true)
            }
            return URL(fileURLWithPath: custom, isDirectory: true)
        }()
        let ftPort = bound &+ 2
        let drops = FileDropServiceManager()
        fileDropService = drops
        if let served = await drops.start(port: ftPort, dropDirectory: dropDir) {
            log("file-drop service on 0.0.0.0:\(served) (drop dir \(dropDir.path))")
        } else {
            log("slopdesk-dropd did not come up on port \(ftPort) — continuing without file transfer")
            fileDropService = nil
        }
    }
}

// Keep the process alive for the listener + relay tasks; SIGINT drives exit().
dispatchMain()
