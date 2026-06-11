import Foundation
import AislopdeskHost
import AislopdeskInspector

// aislopdesk-hostd — headless Aislopdesk host daemon (PTY + transport).
//
// Wires up HostServer: bind a TCP listener (0.0.0.0 / OS-chosen — no interface pin,
// per [13]), spawn the user's login shell per session, relay PTY bytes over the dual
// data/control channels with replay-buffer reconnect, and survive client disconnects.
// Runs until SIGINT.

let arguments = CommandLine.arguments
let programName = (arguments.first as NSString?)?.lastPathComponent ?? "aislopdesk-hostd"

guard let parsed = HostdArguments.parse(arguments) else {
    FileHandle.standardError.write(Data(
        (HostdArguments.usage(programName: programName) + "\n").utf8))
    exit(2)
}

let log: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
}

let server = HostServer(
    port: parsed.port,
    shellPath: parsed.shell,
    launchMode: parsed.launchMode
)
server.onLog = log

// Inspector server (NWConnection #2, port + 1) — read-only structured companion.
// Constructed when --inspector / --claude / --transcript is set. The replay log is the
// replay-then-live fan-out; the engine feeds it. PIECE C (live per-PTY transcript-path
// discovery via the SessionStart hook) is DEFERRED — for now the path is the injected
// --transcript value (if any), tailed straight into the engine. Without a path the
// server still binds (so a client can connect) and the replay log stays empty until
// PIECE C wires the per-session tailer.
let inspectorEngine = InspectorEngine()
let inspectorReplayLog = InspectorReplayLog()
inspectorReplayLog.ingest(inspectorEngine.events)

let inspectorServer: InspectorServer?
if parsed.inspectorEnabled {
    let inspector = InspectorServer(
        terminalPort: parsed.port,
        replayLog: inspectorReplayLog,
        transcriptPath: parsed.transcriptPath
    )
    inspector.onLog = log
    inspectorServer = inspector

    // If a transcript path was injected, tail it into the engine now (PIECE C will
    // replace this with per-PTY discovery). The tailer tolerates the file not existing
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
// (atexit handlers / stdio flush run twice). R16 HOSTD-1.
final class ShutdownLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns `true` exactly once (the first call); `false` thereafter.
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
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
    guard shutdownLatch.tryFire() else { return }   // ignore repeated Ctrl-C during the async drain
    log("SIGINT — shutting down")
    Task {
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
        let mode: String
        switch parsed.launchMode {
        case .shell:
            mode = "shell"
        case let .claudeCode(profile):
            mode = "claude (TERM=\(profile.term.rawValue))"
        }
        log("listening on 0.0.0.0:\(bound) (shell=\(server.shellPath), mode=\(mode))")
    } catch {
        log("failed to start: \(error)")
        exit(1)
    }

    // Bring up the inspector listener (port + 1) once the terminal server is up. This is SEPARATE from
    // the terminal-server bring-up above: by now the terminal server is already bound + accepting, so
    // an inspector-bind failure (e.g. EADDRINUSE on port+1 while the main port was free) must tear the
    // terminal server down CLEANLY — the orderly child-reap / `bye` path — before exiting, not `exit(1)`
    // and leak a just-accepted shell un-reaped. R16 HOSTD-2.
    if let inspectorServer {
        do {
            try await inspectorServer.start()
        } catch {
            // R16-deferred completion: route this exit(1) through the SAME one-shot latch as the SIGINT
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
