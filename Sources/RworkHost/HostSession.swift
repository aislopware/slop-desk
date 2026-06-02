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
    private var outputContinuation: AsyncStream<OutputChunk>.Continuation?
    private var readLoop: PTYReadLoop?
    private var started = false

    /// One PTY read chunk plus the CONTROL messages (`.title`/`.bell`) the
    /// ``HostTitleBellSniffer`` detected in it. The raw `bytes` are ALWAYS forwarded to
    /// the client unchanged (non-destructive sniffing — see ``HostTitleBellSniffer``); the
    /// `control` messages are sent on the control channel alongside. Carrying both through
    /// the SAME ordered FIFO keeps a chunk's control messages ordered relative to the
    /// output that produced them, on the one sequential awaiter.
    private struct OutputChunk: Sendable {
        let bytes: Data
        let control: [WireMessage]
    }

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
        var continuationOut: AsyncStream<OutputChunk>.Continuation!
        let outputStream = AsyncStream<OutputChunk>(bufferingPolicy: .unbounded) { continuationOut = $0 }
        let continuation = continuationOut!
        self.outputContinuation = continuation
        outputTask = Task {
            for await chunk in outputStream {
                // `sendOutput` itself handles channel death: if the data channel is gone
                // (cancelled/failed — e.g. the reconnect race) it retains the bytes for
                // replay AND flips the client offline (engaging the ReplayBuffer offline
                // gate) instead of throwing, so a transient channel hiccup no longer
                // silently relies on a future reconnect — the gate backpressures the PTY
                // and the next resume replays the tail. The `try?` therefore only swallows
                // a genuine transient send error on a still-live channel (the bytes stay
                // retained and replay on reconnect either way).
                _ = try? await transport.sendOutput(chunk.bytes)
                // CONTROL: emit the title/bell the sniffer found in this chunk on the
                // (head-of-line-independent) control channel, AFTER the output bytes that
                // carried them, on this same sequential awaiter so they stay in read order.
                // `sendControl` is not sequenced/replayed; a dead control channel just
                // throws and is swallowed (the bytes themselves already went out / are
                // retained — a missed title/bell is cosmetic, not a correctness loss).
                for message in chunk.control {
                    try? await transport.sendControl(message)
                }
            }
        }

        // Non-destructive OSC/BEL sniffer over the SAME outbound bytes. It only OBSERVES;
        // the raw `chunk` is yielded to the relay UNCHANGED (libghostty on the client is
        // the real terminal). `onChunk` runs on the single serial read-loop queue, so the
        // sniffer is driven in strict read order with no concurrent calls.
        let sniffer = HostTitleBellSniffer()
        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { chunk in
                let control = sniffer.observe(chunk)
                continuation.yield(OutputChunk(bytes: chunk, control: control))
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
