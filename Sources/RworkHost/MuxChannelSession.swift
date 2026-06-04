import Foundation
import RworkProtocol
import RworkTransport

/// One logical mux channel's host-side PTY relay (TCP-mux S1).
///
/// This is the mux analogue of ``HostSession`` + ``HostSessionTransport`` collapsed for ONE
/// channel: a ``PTYProcess`` bridged to the client over a channel's data + control
/// ``MuxSubChannel`` pair, with per-channel `output` sequencing via a private ``ReplayBuffer``.
/// MANY of these ride ONE shared ``MuxNWConnection`` — so one TCP connection-pair carries N panes,
/// each with its own shell, exactly the S1 goal.
///
/// It deliberately does NOT reuse ``HostSessionTransport`` (which is hard-coupled to
/// ``NWMessageChannel`` and carries the toolchain-sensitive dead-channel-send invariant on the
/// today hot path). Reimplementing the small relay over ``MessageChannel`` keeps the OFF path 100%
/// untouched while honouring the spec's "per-channel HostSession/PTY from one shared connection".
///
/// Relay shape (mirrors ``HostSession``):
/// - OUTPUT: a no-buffer ``PTYReadLoop`` → an ordered FIFO → one sequential awaiter that assigns a
///   seq via the per-channel `ReplayBuffer` and writes `output` on the channel's DATA sub-channel;
///   `.title`/`.bell` sniffed non-destructively and written on the CONTROL sub-channel after.
/// - INPUT: the DATA sub-channel's inbound `input` → master fd.
/// - RESIZE/BYE/ACK: the CONTROL sub-channel's inbound → `TIOCSWINSZ` / offline / (ack is a no-op
///   beyond release; S1 has no per-channel reconnect replay so it just keeps the buffer bounded).
/// - EXIT: the reaper enqueues `exit(code:)` on the same FIFO so it follows the final output tail.
///
/// ### Bounded output queue (S2, sub-gated by `RWORK_TCP_MUX_FLOW`)
/// When `flowControl` is ON, the DATA sub-channel's send window already SUSPENDS the output drain
/// when a flooding channel runs out of credit — but without an upstream bound that just moves the
/// unboundedness one hop: the `PTYReadLoop` would keep buffering the whole `yes` flood into the
/// FIFO in memory. So the queue is BOUNDED by a ``RworkProtocol/BoundedQueuePolicy`` (byte
/// high-water mark): when enqueued-not-yet-sent bytes cross the bound, the ``PTYReadLoop`` is
/// PAUSED (its `NSCondition` gate stops issuing `read()`, so the kernel PTY buffer fills and
/// backpressures the shell — the real fix for the flood); it RESUMES when the drain brings the
/// queue back under the bound. With `flowControl` OFF the queue is unbounded and the read loop is
/// never paused by this path — byte-identical to S1.
///
/// `@unchecked Sendable`: mutable state is touched under `taskLock` / `replayLock` / the
/// ``PausableQueueGate``'s own lock; the PTY/channels are themselves thread-safe.
final class MuxChannelSession: @unchecked Sendable {
    let channelID: UInt32
    let pty: PTYProcess
    private let data: MuxSubChannel
    private let control: MuxSubChannel
    /// Whether per-channel flow control (`RWORK_TCP_MUX_FLOW`) is ON. OFF → unbounded FIFO + no
    /// read-loop pausing (S1 behaviour). Read once at the construction site and passed in.
    private let flowControl: Bool

    private let taskLock = NSLock()
    private var replay = ReplayBuffer()
    private let replayLock = NSLock()
    private var inputTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<OutputItem>.Continuation?
    private var readLoop: PTYReadLoop?
    private var started = false

    /// S2 bounded-queue backpressure GATE: fuses the ``BoundedQueuePolicy`` accounting with the
    /// read-loop pause/resume action ATOMICALLY under one lock (FIX #3 — see ``PausableQueueGate``).
    /// Built in ``startRelay()`` once the `readLoop` exists (so the gate can drive it). `nil` until
    /// then / when `flowControl` is OFF (the FIFO stays unbounded — S1, no pausing).
    private var outputGate: PausableQueueGate?

    /// Called once when the child exits so the owner can drop this channel from its map.
    var onExit: (@Sendable (UInt32) -> Void)?

    private enum OutputItem: Sendable {
        case chunk(bytes: Data, control: [WireMessage])
        case exit(code: Int32)
    }

    init(channelID: UInt32, pty: PTYProcess, data: MuxSubChannel, control: MuxSubChannel, flowControl: Bool = false) {
        self.channelID = channelID
        self.pty = pty
        self.data = data
        self.control = control
        self.flowControl = flowControl
    }

    func startRelay() {
        taskLock.lock()
        guard !started else { taskLock.unlock(); return }
        started = true
        taskLock.unlock()

        let pty = self.pty
        let data = self.data
        let control = self.control
        let masterFD = pty.masterFD

        var continuationOut: AsyncStream<OutputItem>.Continuation!
        let outputStream = AsyncStream<OutputItem>(bufferingPolicy: .unbounded) { continuationOut = $0 }
        let continuation = continuationOut!
        self.outputContinuation = continuation
        outputTask = Task { [weak self] in
            for await item in outputStream {
                guard let self else { return }
                switch item {
                case let .chunk(bytes, controlMessages):
                    let seq = self.nextSeq(for: bytes)
                    // `data.send` SUSPENDS on the per-channel credit window when flow is ON (S2), so
                    // a flooding channel naturally slows here. After the write is accepted we
                    // dequeue the bytes and resume the read loop if the FIFO drained below the bound.
                    try? await data.send(.output(seq: seq, bytes: bytes))
                    self.dequeueOutput(bytes.count)
                    for message in controlMessages {
                        try? await control.send(message)
                    }
                case let .exit(code):
                    try? await data.send(.exit(code: code))
                }
            }
        }

        let sniffer = HostTitleBellSniffer()
        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { [weak self] chunk in
                let controlMsgs = sniffer.observe(chunk)
                // S2: account the chunk in the bounded queue BEFORE enqueueing; if it pushes the
                // FIFO to/over the bound, PAUSE the read loop so the kernel PTY buffer fills and
                // backpressures the shell (the real flood fix). No-op when flow is OFF (unbounded).
                self?.enqueueOutput(chunk.count)
                continuation.yield(.chunk(bytes: chunk, control: controlMsgs))
            },
            onEOF: { /* exit is reaper-driven, like HostSession */ }
        )
        self.readLoop = readLoop
        // S2 (FIX #3): build the bounded-queue gate now that the read loop exists, so pause/resume is
        // applied ATOMICALLY with the accounting (no lost-wakeup freeze). OFF → no gate (unbounded).
        if flowControl {
            self.outputGate = PausableQueueGate(capacity: MuxFlowControl.hostQueueCapacityBytes) { paused in
                readLoop.setPaused(paused)
            }
        }
        readLoop.start()

        // INPUT: the DATA sub-channel carries `input`.
        inputTask = Task.detached {
            do {
                for try await message in data.inbound {
                    if case let .input(bytes) = message {
                        Self.writeAll(fd: masterFD, data: bytes)
                    }
                }
            } catch { /* channel gone — the daemon keeps the shell alive (keep-alive) */ }
        }

        // CONTROL: resize / bye / ack on the CONTROL sub-channel.
        controlTask = Task {
            do {
                for try await message in control.inbound {
                    switch message {
                    case let .resize(cols, rows, px, py):
                        pty.setWindowSize(cols: cols, rows: rows, pxWidth: px, pxHeight: py)
                    case let .ack(seq):
                        self.acknowledge(upTo: seq)
                    case .bye:
                        break // client leaving cleanly; keep-alive shell survives for resume.
                    default:
                        break
                    }
                }
            } catch { /* control gone */ }
        }

        let id = channelID
        exitTask = Task { [weak self] in
            let code = await pty.waitForExit()
            continuation.yield(.exit(code: code))
            self?.onExit?(id)
        }
    }

    func shutdown() {
        taskLock.lock()
        readLoop?.stop()
        outputContinuation?.finish()
        outputContinuation = nil
        inputTask?.cancel()
        controlTask?.cancel()
        exitTask?.cancel()
        outputTask?.cancel()
        taskLock.unlock()
        pty.terminate()
        pty.closeMaster()
    }

    // MARK: - S2 bounded-output-queue backpressure (lock-guarded; the value type is not Sendable)

    /// Accounts `count` enqueued output bytes; pauses the read loop if the FIFO crossed the bound.
    /// No-op when flow control is OFF (the FIFO stays unbounded — S1). FIX #3: the accounting + the
    /// pause action are applied ATOMICALLY inside ``PausableQueueGate`` (under one lock) so a
    /// concurrent ``dequeueOutput(_:)`` can never interleave a stale resume after this pause and leave
    /// the loop frozen below capacity.
    private func enqueueOutput(_ count: Int) {
        outputGate?.enqueue(count)
    }

    /// Accounts `count` sent output bytes; resumes a paused read loop if the FIFO drained below the
    /// bound. No-op when flow control is OFF. FIX #3: atomic with the accounting (see
    /// ``PausableQueueGate``).
    private func dequeueOutput(_ count: Int) {
        outputGate?.dequeue(count)
    }

    // MARK: - Per-channel replay bookkeeping (lock-guarded; the value type is not Sendable)

    private func nextSeq(for bytes: Data) -> Int64 {
        replayLock.lock(); defer { replayLock.unlock() }
        return replay.append(bytes: bytes)
    }

    private func acknowledge(upTo seq: Int64) {
        replayLock.lock(); defer { replayLock.unlock() }
        replay.ack(upTo: seq)
    }

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
                    return
                } else {
                    return
                }
            }
        }
        #endif
    }
}
