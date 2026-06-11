#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import AislopdeskClient
import AislopdeskProtocol
import AislopdeskTerminal
import AislopdeskTransport
import AislopdeskTTY

// aislopdesk-client — a genuinely usable interactive remote terminal over Aislopdesk PATH 1.
//
// Usage:
//   aislopdesk-client --host <h> --port <n> [--no-raw]
//
// Interactive mode (default, when stdin is a TTY): puts the local terminal into raw mode
// (restoring it on EVERY exit path, including signals), relays local stdin → host input
// and host output → local stdout, sends an initial + SIGWINCH-driven resize, and exits
// 0 on the remote shell exit or the disconnect key (Ctrl-]).
//
// Non-interactive mode (stdin not a TTY, or --no-raw): relays stdin → input and
// output → stdout without raw mode; exits when the session exits. Scriptable via pipes.
//
// Connection / exit status is printed to stderr (stdout carries terminal bytes only).

// MARK: - Disconnect key

/// Ctrl-] (GS, 0x1d) — the classic telnet escape. Pressing it cleanly disconnects,
/// restores the terminal, and exits 0. Documented in --help.
private let kDisconnectKey: UInt8 = 0x1d

// MARK: - Shared mux connection pool

/// Owns the single process-wide ``ConnectionRegistry`` (the per-host shared-connection pool). The
/// `ConnectionRegistry` is `@MainActor`, so this `@MainActor` holder constructs it lazily on first
/// acquire (reached from `MuxClientTransport.connect`, already in async context) and reuses it
/// across reconnects. `acquire`/`release` simply forward to the registry — they exist so the
/// non-isolated top-level transport closures have a `@MainActor` entry point to call.
@MainActor
enum CLIMux {
    static let shared = ConnectionRegistry(makeConnection: LiveMuxConnectionFactory.makeConnection)
}

// MARK: - Arg parsing

struct Args {
    var host: String
    var port: UInt16
    var noRaw: Bool
}

let programName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "aislopdesk-client"

func stderrLine(_ s: String) {
    FileHandle.standardError.write(Data("\(programName): \(s)\n".utf8))
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: \(programName) --host <h> --port <n> [--no-raw]

      --host, -h <host>   host running aislopdesk-hostd
      --port, -p <port>   TCP port aislopdesk-hostd listens on
      --no-raw            do not put the local terminal in raw mode (pipe/scripting)

    Disconnect key (interactive mode): Ctrl-] cleanly disconnects and exits 0.

    """.utf8))
    exit(2)
}

func parseArgs(_ argv: [String]) -> Args? {
    var host: String?
    var port: UInt16?
    var noRaw = false
    var it = argv.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--host", "-h":
            guard let v = it.next() else { return nil }
            host = v
        case "--port", "-p":
            guard let v = it.next(), let p = UInt16(v) else { return nil }
            port = p
        case "--no-raw":
            noRaw = true
        case "--help":
            return nil
        default:
            return nil
        }
    }
    guard let host, let port else { return nil }
    return Args(host: host, port: port, noRaw: noRaw)
}

guard let args = parseArgs(CommandLine.arguments) else { usage() }

// MARK: - Output writer (host → local stdout)

/// Writes all of `data` to `fd`, looping over partial writes / EINTR. Used for the
/// host→stdout path so a large burst is never truncated.
func writeAll(fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        let total = raw.count
        while offset < total {
            let n = write(fd, base + offset, total - offset)
            if n > 0 {
                offset += n
            } else if n < 0 {
                if errno == EINTR { continue }
                return
            } else {
                return
            }
        }
    }
}

// MARK: - SIGWINCH (terminal resize) plumbing

/// A tiny Sendable box so the SIGWINCH DispatchSource handler can hand the new size to
/// the async world without capturing the actor-isolated client directly.
final class ResizeBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    let stream: AsyncStream<Void>
    init() {
        var c: AsyncStream<Void>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.continuation = c
    }
    func signal() {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(())
    }
    func finish() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
    }
}

// MARK: - Run

let interactive = (isatty(STDIN_FILENO) != 0) && !args.noRaw

// The per-host shared-connection pool, owned by the @MainActor `CLIMux` holder. ONE registry for
// the whole process so every reconnect (ReconnectManager re-calls client.connect →
// MuxClientTransport.connect → registry.acquire) reuses the same pool and opens a fresh channel on
// the surviving shared connection. The transport's acquire/release @Sendable closures are async, so
// they hop onto the main actor to call the @MainActor registry.
let client = AislopdeskClient(makeTransport: {
    MuxClientTransport(
        acquire: { host, port, sessionID, lastReceivedSeq in
            try await CLIMux.shared.acquire(
                host: host, port: port, sessionID: sessionID, lastReceivedSeq: lastReceivedSeq
            )
        },
        release: { host, port, channelID in
            await CLIMux.shared.release(host: host, port: port, channelID: channelID)
        }
    )
})
let reconnect = ReconnectManager(client: client, onLog: { stderrLine($0) })

// Headless surface so the client also drives a TerminalSurface (the libghostty seam);
// in the CLI we render via the raw `output` stream, but wiring the surface proves the
// path and is what the GUI client (WF-5/8) will use.
let surface = HeadlessTerminalSurface()

// The exit-code the process will return; set when the remote shell exits.
final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var _code: Int32 = 0
    private var _done = false
    func setExit(_ c: Int32) { lock.lock(); _code = c; _done = true; lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    var code: Int32 { lock.lock(); defer { lock.unlock() }; return _code }
}
let exitState = ExitState()

// Raw mode (interactive only). Saved attrs restored on EVERY exit path: defer below,
// signal handlers, and the explicit restore on disconnect/exit.
if interactive {
    do {
        // Install the restoring handlers FIRST (they are a no-op while raw mode is not
        // yet active), then apply raw attributes. This closes the enable-time window where
        // a SIGTERM/SIGHUP arriving after tcsetattr(raw) took effect but before a handler
        // existed would kill the process with the terminal left in raw mode.
        TerminalRawMode.installRestoreOnSignals()
        try TerminalRawMode.enableRaw(fd: STDIN_FILENO)
    } catch {
        stderrLine("could not enter raw mode: \(error)")
        exit(1)
    }
}

/// Coordinates a deterministic shutdown so `finish()` stops the foreign producers (the
/// dedicated stdin read thread and the SIGWINCH `DispatchSource`) BEFORE it flips the tty
/// back to cooked mode and calls `exit()`. Without this, `restore()`'s `tcsetattr` runs
/// while the input thread is mid-`read(STDIN_FILENO)` on the same fd, and `exit()` runs
/// process-wide teardown concurrently with a live foreign thread still touching stdin — a
/// genuine data race that can also swallow a stray keystroke.
///
/// `shuttingDown` is a `sig_atomic_t` the input thread re-checks after an interrupted
/// read so it returns instead of issuing another `read`. Closing STDIN makes any in-flight
/// blocking `read` return immediately.
final class Shutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var winchSource: DispatchSourceSignal?
    private var didStop = false
    var shuttingDown: sig_atomic_t = 0

    func register(winchSource: DispatchSourceSignal) {
        lock.lock(); self.winchSource = winchSource; lock.unlock()
    }

    /// Stop the producers deterministically. Idempotent. Called by `finish()` before the
    /// final tty restore so `restore()` is guaranteed to be the last tty mutation.
    func stopProducers() {
        lock.lock()
        if didStop { lock.unlock(); return }
        didStop = true
        let source = winchSource
        winchSource = nil
        lock.unlock()

        shuttingDown = 1
        source?.cancel()
        // Wake the blocked stdin read so the input thread observes `shuttingDown` and
        // returns instead of consuming/losing a stray keystroke during teardown.
        close(STDIN_FILENO)
    }
}
let shutdown = Shutdown()

/// Restore the terminal and exit with `code`. Centralizes the "never leave the terminal
/// corrupted" guarantee for the normal/disconnect exit paths (signals are covered by
/// `installRestoreOnSignals`). Stops the foreign producers first so `restore()` is the
/// final tty mutation and no live thread is touching stdin as the process exits.
func finish(_ code: Int32) -> Never {
    shutdown.stopProducers()
    TerminalRawMode.restore()
    exit(code)
}

let resizeBridge = ResizeBridge()

// SIGWINCH → resize. DispatchSource so the handler runs off the signal context.
signal(SIGWINCH, SIG_IGN)
let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
winchSource.setEventHandler { resizeBridge.signal() }
shutdown.register(winchSource: winchSource)
winchSource.resume()

// The main driver task: connect, wire the relay, and run until exit/disconnect.
Task {
    // 1. Connect.
    do {
        try await client.connect(host: args.host, port: args.port)
        let sid = await client.sessionID.map { $0.uuidString } ?? "?"
        stderrLine("connected to \(args.host):\(args.port) (session \(sid))")
    } catch {
        stderrLine("connect failed: \(error)")
        finish(1)
    }

    // 2. Start the reconnect supervisor (byte-exact resume on drop). RETAIN the task so the shutdown
    //    sequence can CANCEL it (R16 CLI-1) — otherwise it free-runs and can pop a buffered
    //    `.disconnected` (which `handleStreamEnded` yields on EVERY clean stream end, remote-shell-exit
    //    included) and fire a doomed `connect()` racing the process `exit()`, orphaning a freshly
    //    spawned host shell. (The client's own `isClosed` guard from R15 #1 also defends this, but the
    //    supervisor can win the `isClosed` read before `close()` sets it; cancelling is the clean stop.)
    let supervisor = reconnect.start(host: args.host, port: args.port)

    // 3. Initial resize from the local terminal size.
    if let ws = TerminalRawMode.windowSize(fd: STDIN_FILENO) {
        try? await client.sendResize(cols: ws.cols, rows: ws.rows, pxWidth: ws.pxWidth, pxHeight: ws.pxHeight)
    }

    // 4. Feed the headless surface as well as stdout (proves the TerminalSurface seam).
    await client.setSurfaceFeed { bytes in
        surface.feed(bytes)
    }

    // 5. OUTPUT pump: host output → local stdout, immediately.
    let outputTask = Task {
        for await chunk in client.output {
            writeAll(fd: STDOUT_FILENO, chunk)
        }
        // Output finished → remote child exited (or transport permanently closed).
    }

    // 6. EVENTS pump: surface title/bell to stderr; capture exit code.
    let eventsTask = Task {
        for await event in client.events {
            switch event {
            case let .title(t):
                // In interactive raw mode the host's OSC title rides the output stream and the
                // local terminal sets the window/tab title directly — echoing it to stderr only
                // smears the rendered screen. Surface it only in non-interactive (pipe/scripting)
                // mode, where stderr is separate and the title is useful diagnostic output.
                if !interactive { stderrLine("title: \(t)") }
            case .bell:
                // Forward the bell to the local terminal.
                writeAll(fd: STDOUT_FILENO, Data([0x07]))
            case .commandStatus:
                // OSC 133 command status is a GUI-client affordance (per-pane running/idle dot +
                // long-command notification). In raw-mode interactive CLI the OSC 133 marks ride
                // the output stream and the local terminal renders them natively, so the structured
                // control event is a no-op here.
                break
            case let .exit(code):
                exitState.setExit(code)
                stderrLine("remote shell exited (code \(code))")
            case let .disconnected(reason):
                stderrLine("disconnected: \(reason) — reconnecting…")
            case let .reconnected(sid, seq):
                stderrLine("reconnected (session \(sid.uuidString), resumed from seq \(seq))")
            }
        }
    }

    // 7. RESIZE pump: SIGWINCH → sendResize from the current terminal size.
    let resizeTask = Task {
        for await _ in resizeBridge.stream {
            if let ws = TerminalRawMode.windowSize(fd: STDIN_FILENO) {
                try? await client.sendResize(cols: ws.cols, rows: ws.rows, pxWidth: ws.pxWidth, pxHeight: ws.pxHeight)
            }
        }
    }

    // 8. INPUT pump: local stdin → host input. Runs on a dedicated thread because
    //    read(2) on stdin is a blocking syscall (raw mode: VMIN=1) — we must not block a
    //    cooperative-pool thread. The interactive disconnect key (Ctrl-]) is detected here.
    //
    //    Ordering: each read chunk is YIELDED into a single ordered AsyncStream that one
    //    consumer task drains sequentially (awaiting `sendInput` one at a time). A `Task`
    //    per chunk would NOT preserve order — independent tasks hop onto the actor in
    //    scheduler order, not creation order — which would scramble keystrokes. (Same
    //    lesson as the WF-3 host output relay.)
    let (stdinDone, stdinDoneCont) = AsyncStream.makeStream(of: Void.self)
    let (inputChunks, inputChunksCont) = AsyncStream.makeStream(of: Data.self)
    let inputSenderTask = Task {
        for await chunk in inputChunks {
            try? await client.sendInput(chunk)
        }
    }
    let inputThread = Thread {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            // If a shutdown began (finish() closed STDIN), return without issuing another
            // read so we never touch the fd while the tty is being restored.
            if shutdown.shuttingDown != 0 {
                inputChunksCont.finish()
                stdinDoneCont.yield(()); stdinDoneCont.finish()
                return
            }
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n > 0 {
                let slice = Data(buf[0..<n])
                if interactive, let idx = slice.firstIndex(of: kDisconnectKey) {
                    // Send everything before the disconnect key, then stop.
                    let before = Data(slice[slice.startIndex..<idx])
                    if !before.isEmpty { inputChunksCont.yield(before) }
                    inputChunksCont.finish()
                    stdinDoneCont.yield(()); stdinDoneCont.finish()
                    return
                }
                inputChunksCont.yield(slice)
            } else if n == 0 {
                // EOF on stdin (pipe closed): stop relaying input. In non-interactive
                // mode this is the normal end of the piped script.
                inputChunksCont.finish()
                stdinDoneCont.yield(()); stdinDoneCont.finish()
                return
            } else {
                // EINTR during normal operation: retry. But if a shutdown began (STDIN was
                // closed by finish()), the read will fail with EBADF/EINTR — re-check the
                // flag and return rather than spinning or re-reading a closed/cooked fd.
                if errno == EINTR, shutdown.shuttingDown == 0 { continue }
                inputChunksCont.finish()
                stdinDoneCont.yield(()); stdinDoneCont.finish()
                return
            }
        }
    }
    inputThread.name = "aislopdesk-client.stdin"
    inputThread.start()

    // 9. Wait for a terminating condition.
    //    - Interactive: terminate on EITHER the remote shell exit (output finished) OR
    //      the disconnect key (stdin pump finished) — whichever comes first.
    //    - Non-interactive (pipe/scripting): the piped script ends with EOF on stdin,
    //      but the remote `exit` output still has to round-trip back. So we wait ONLY for
    //      the session to actually end (output finished); stdin EOF alone must NOT cut the
    //      tail off (otherwise a piped `echo X\nexit\n` could race and lose `X`).
    if interactive {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await outputTask.value; return "output" }
            group.addTask { for await _ in stdinDone { break }; return "stdin (disconnect)" }
            if let first = await group.next() {
                stderrLine("session ending (\(first))")
            }
            group.cancelAll()
        }
    } else {
        // Drain stdin-done in the background so the continuation never leaks, but block on
        // the session output finishing (remote shell exit).
        let drain = Task { for await _ in stdinDone { break } }
        await outputTask.value
        drain.cancel()
        stderrLine("session ending (output)")
    }

    supervisor.cancel()   // R16 CLI-1: stop the reconnect supervisor BEFORE close() so it can't dial during exit.
    eventsTask.cancel()
    resizeTask.cancel()
    inputSenderTask.cancel()
    await client.close()

    let code = exitState.done ? exitState.code : 0
    finish(code)
}

// Keep the process alive for the async driver; finish()/signals drive exit().
dispatchMain()
