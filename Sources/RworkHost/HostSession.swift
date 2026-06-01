import Foundation
import RworkProtocol
import RworkTransport

/// One live host session: a ``PTYProcess`` bridged to a client through a
/// ``HostSessionTransport`` (which owns the dual data/control channels + the
/// per-session `ReplayBuffer`), wired by the no-buffer relay.
///
/// ## Relay shape (`DECISIONS.md` / [17] / [12] Part B)
/// - **Output:** ``PTYReadLoop`` reads the master fd at `QOS_CLASS_USER_INTERACTIVE`
///   and yields each chunk into an ordered FIFO `AsyncStream` whose single consumer task
///   awaits ``HostSessionTransport/sendOutput(_:)`` sequentially (which assigns the seq
///   via the `ReplayBuffer`, retains for replay, and writes `output` on the data
///   channel). The single sequential awaiter guarantees actor-arrival order == PTY read
///   order, so seqs are assigned in true byte order. No intermediate ring buffer (the
///   FIFO carries no data the `ReplayBuffer` would not).
/// - **Input:** ``HostSessionTransport/inboundInput`` → `write()` to the master fd.
/// - **Resize:** ``HostSessionTransport/inboundResize`` →
///   ``PTYProcess/setWindowSize(cols:rows:pxWidth:pxHeight:)`` (`TIOCSWINSZ` + `SIGWINCH`).
/// - **Backpressure:** ``HostSessionTransport/drainPauses`` → ``PTYReadLoop/setPaused(_:)``.
/// - **Exit:** the child's exit code is surfaced as `WireMessage.exit(code:)` on the
///   data channel.
///
/// ## Session survival across reconnect ([12] §6 / [18] §H)
/// The daemon keeps the `PTYProcess` (master fd + child shell) and the relay tasks
/// ALIVE when the client disconnects — it does **not** kill the shell on channel
/// failure. `HostTransport` rebinds the fresh channels onto the **same**
/// `HostSessionTransport` (and replays the un-acked tail via its `resume()`) on a
/// RETURNING_CLIENT reconnect, so the inbound streams and `drainPauses` this session
/// consumes are stable across the reconnect: nothing here needs to be re-wired. The
/// shell never learns the client left (the kernel backpressures it while offline).
///
/// `@unchecked Sendable`: the only mutable state (`relayTasks`, `started`) is touched
/// under `taskLock`; the PTY/transport/read-loop are themselves thread-safe.
public final class HostSession: @unchecked Sendable {
    /// Stable session identity (== the transport's `sessionID`).
    public let sessionID: UUID

    /// The child process + its PTY.
    public let pty: PTYProcess

    /// The transport for this session (replay buffer + dual channels), owned by
    /// `HostTransport` and rebound in place on reconnect.
    public let transport: HostSessionTransport

    private let taskLock = NSLock()
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var readLoop: PTYReadLoop?
    private var started = false

    /// Builds a session around an already-spawned PTY and an already-bound transport.
    public init(sessionID: UUID, pty: PTYProcess, transport: HostSessionTransport) {
        self.sessionID = sessionID
        self.pty = pty
        self.transport = transport
    }

    /// Starts the bidirectional relay. Call once, after ``PTYProcess/spawn(_:arguments:environment:argv0:cols:rows:)``
    /// and after the transport has been bound. Idempotent.
    public func startRelay() {
        taskLock.lock()
        guard !started else { taskLock.unlock(); return }
        started = true
        taskLock.unlock()

        let pty = self.pty
        let transport = self.transport
        let masterFD = pty.masterFD

        // OUTPUT: no-buffer read loop → sendOutput, bridged through a single ordered
        // FIFO. `onChunk` runs synchronously on the user-interactive read queue in strict
        // read order and yields each chunk into an AsyncStream; ONE consumer task awaits
        // sendOutput sequentially, so the actor-arrival order == read order and the
        // ReplayBuffer assigns seqs in true byte order. (A per-chunk detached Task would
        // NOT preserve order: independent tasks hop onto the actor in scheduler order, not
        // creation order — that corrupts both the live stream and the replayed tail. See
        // the WF-3 review.)
        var continuationOut: AsyncStream<Data>.Continuation!
        let outputStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuationOut = $0 }
        let continuation = continuationOut!
        self.outputContinuation = continuation
        outputTask = Task {
            for await chunk in outputStream {
                _ = try? await transport.sendOutput(chunk)
            }
        }

        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { chunk in
                continuation.yield(chunk)
            },
            onEOF: {
                // EOF on the master: child closed its tty. The reaper Task surfaces the
                // real exit code; nothing to do here (we don't synthesize an exit).
            }
        )
        self.readLoop = readLoop

        // BACKPRESSURE: drain-pause transitions gate the read loop. Start this BEFORE
        // the read loop so an early pause is honored.
        drainTask = Task {
            for await pause in transport.drainPauses {
                readLoop.setPaused(pause)
            }
        }

        readLoop.start()

        // INPUT: client input bytes → master fd. A blocking write on the (blocking)
        // master is fine: keystrokes/paste are tiny and the kernel tty buffer is large.
        inputTask = Task.detached {
            for await bytes in transport.inboundInput {
                Self.writeAll(fd: masterFD, data: bytes)
            }
        }

        // RESIZE: client resize → TIOCSWINSZ.
        resizeTask = Task {
            for await message in transport.inboundResize {
                if case let .resize(cols, rows, px, py) = message {
                    pty.setWindowSize(cols: cols, rows: rows, pxWidth: px, pxHeight: py)
                }
            }
        }

        // ACK: drained inside the transport's `acknowledge(upTo:)`; we consume the
        // surfaced stream so it does not back up (the release already happened).
        ackTask = Task {
            for await _ in transport.inboundAck { /* release handled in transport */ }
        }

        // EXIT: when the child exits, surface `exit(code:)` on the data channel so the
        // client's byte stream terminates cleanly. `sendExit` records the code so a client
        // that was offline when the shell exited still receives the exit marker after the
        // replayed output tail on reconnect (resume() re-sends it) — no zombie session.
        exitTask = Task {
            let code = await pty.waitForExit()
            try? await transport.sendExit(code: code)
        }
    }

    /// Tears down the relay and the PTY. The daemon calls this only when it actually
    /// wants the session gone (NOT on a client disconnect — see session survival).
    public func shutdown() {
        taskLock.lock()
        // Stop the read loop FIRST so no concurrent read() can race the master fd close
        // below. Finish the output FIFO so its single consumer task drains and exits.
        readLoop?.stop()
        outputContinuation?.finish()
        outputContinuation = nil
        inputTask?.cancel()
        resizeTask?.cancel()
        ackTask?.cancel()
        drainTask?.cancel()
        exitTask?.cancel()
        outputTask?.cancel()
        taskLock.unlock()
        pty.terminate()
        // Close the master fd now that the read loop is stopped (deinit is only a safety
        // net). Without this every spawned session leaks one master fd — a long-running
        // daemon exhausts the 256-fd soft limit after ~250 sessions (openpty -> EMFILE).
        pty.closeMaster()
    }

    // MARK: Helpers

    /// Writes all of `data` to `fd`, looping over partial writes / EINTR.
    private static func writeAll(fd: Int32, data: Data) {
        #if canImport(Darwin)
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
                    return // fd closed / errored; drop (session likely tearing down).
                } else {
                    return
                }
            }
        }
        #endif
    }
}
