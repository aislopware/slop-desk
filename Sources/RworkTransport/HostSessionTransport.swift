import Foundation
import RworkProtocol

/// One logical host-side session's transport: the DATA + CONTROL channels plus the
/// per-session ``ReplayBuffer``, with thin inbound/outbound APIs for the WF-3 PTY relay.
///
/// The relay (WF-3) drives this as:
/// - PTY master read → ``sendOutput(_:)`` (assigns seq via the ``ReplayBuffer``,
///   retains for replay, frames as `output`, writes on the data channel).
/// - ``inboundInput`` → bytes to write to the PTY master (`input` on data).
/// - ``inboundResize`` → `TIOCSWINSZ` (`resize` on control).
/// - ``inboundAck`` → release replay-buffer entries (handled here; also surfaced).
/// - ``drainPauses`` → an `AsyncStream<Bool>` the relay consumes to pause/resume
///   reading the PTY (the ET `SKIPPED`/`BUFFERED_ONLY` decision).
///
/// A NEW session is set up with ``bind(data:control:)``. On reconnect the host calls
/// ``resume(data:control:after:)``, which atomically swaps in the fresh channels and
/// replays the missing `output` tail (`seq > lastReceivedSeq`) in order before live
/// streaming resumes — guaranteeing strictly ascending seq on the data channel.
///
/// All mutable state (replay buffer, current channels, continuations) lives inside
/// this `actor`. No `@unchecked Sendable`.
public actor HostSessionTransport {
    /// The stable session id (echoed in `helloAck`, used for RETURNING_CLIENT lookup).
    /// Immutable, so `nonisolated` — readable without hopping onto the actor.
    public nonisolated let sessionID: UUID

    /// Per-session replay buffer (pure value-type logic; see ``ReplayBuffer``).
    private var replay = ReplayBuffer()

    private var dataChannel: NWMessageChannel?
    private var controlChannel: NWMessageChannel?

    // Inbound de-multiplexed streams for the relay.
    private let inputStream: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let resizeStream: AsyncStream<WireMessage>
    private let resizeContinuation: AsyncStream<WireMessage>.Continuation
    private let ackStream: AsyncStream<Int64>
    private let ackContinuation: AsyncStream<Int64>.Continuation

    // Drain pause/resume observable (true = pause PTY drain, false = resume).
    private let drainStream: AsyncStream<Bool>
    private let drainContinuation: AsyncStream<Bool>.Continuation
    /// Last published pause value, so we only emit on transitions.
    private var lastPublishedPause = false

    // Receive-loop forwarders for the currently-bound channels.
    private var dataForwarder: Task<Void, Never>?
    private var controlForwarder: Task<Void, Never>?

    /// True while a reconnect replay is in flight. While set, live ``sendOutput`` does
    /// NOT write to the wire (the bytes are still retained); ``resume(data:control:after:)``
    /// flushes them, in order, right after the replayed tail. Guarantees strictly
    /// ascending seq on the data channel across a reconnect.
    private var isResuming = false
    /// Highest seq already written to the *current* data channel (replay + live). Used
    /// by the resume flush to avoid re-sending anything the replay loop already sent.
    private var highestSentSeq: Int64 = 0

    /// The child's exit code, once it has exited. `exit` is a lifecycle marker and is
    /// **not** sequenced/replayed via the ``ReplayBuffer`` (only `.output` is). We still
    /// must deliver it across a reconnect, otherwise a client that was offline when the
    /// shell exited would replay the final output but never the exit marker — its byte
    /// stream would never terminate (a "zombie session"). So we record the code here and
    /// re-send it after the resume tail flush (see ``resume(data:control:after:)``).
    private var exitCode: Int32?

    public init(sessionID: UUID) {
        self.sessionID = sessionID
        var inputC: AsyncStream<Data>.Continuation!
        self.inputStream = AsyncStream { inputC = $0 }
        self.inputContinuation = inputC
        var resizeC: AsyncStream<WireMessage>.Continuation!
        self.resizeStream = AsyncStream { resizeC = $0 }
        self.resizeContinuation = resizeC
        var ackC: AsyncStream<Int64>.Continuation!
        self.ackStream = AsyncStream { ackC = $0 }
        self.ackContinuation = ackC
        var drainC: AsyncStream<Bool>.Continuation!
        self.drainStream = AsyncStream { drainC = $0 }
        self.drainContinuation = drainC
    }

    // MARK: Inbound streams (for the WF-3 relay)

    /// Bytes the client sent as `input` (write these to the PTY master).
    public nonisolated var inboundInput: AsyncStream<Data> { inputStream }
    /// `resize` messages the client sent (map to `TIOCSWINSZ`).
    public nonisolated var inboundResize: AsyncStream<WireMessage> { resizeStream }
    /// The highest contiguous output seq the client has acked (replay already released).
    public nonisolated var inboundAck: AsyncStream<Int64> { ackStream }
    /// Pause/resume transitions for the PTY drain (`true` = pause, `false` = resume).
    /// Emits only on transitions. The relay must stop reading the PTY while paused so
    /// the kernel backpressures the shell (never-drop invariant — see ``ReplayBuffer``).
    public nonisolated var drainPauses: AsyncStream<Bool> { drainStream }

    // MARK: Outbound (host → client)

    /// Sequences `bytes` via the ``ReplayBuffer`` and writes them as `output` on the
    /// data channel. Retains the bytes for replay until acked. Returns the assigned seq.
    ///
    /// Publishes a drain pause/resume transition if this append crossed the gate. If
    /// the data channel is currently down (between reconnects) the bytes are still
    /// retained — they replay when the client returns.
    @discardableResult
    public func sendOutput(_ bytes: Data) async throws -> Int64 {
        let seq = replay.append(bytes: bytes)
        publishDrainStateIfChanged()
        // While a resume replay is in flight we MUST NOT write a live (higher-seq)
        // output ahead of the replayed tail — the data channel must carry output in
        // strictly ascending seq. The bytes are already retained in the ReplayBuffer;
        // `finishResume()` flushes everything appended during the resume window, in
        // order, right after the tail. (If the client drops again before that, the
        // next reconnect replays it anyway.)
        if isResuming { return seq }
        if let dataChannel {
            try await dataChannel.send(.output(seq: seq, bytes: bytes))
            highestSentSeq = max(highestSentSeq, seq)
        }
        return seq
    }

    /// Sends a control message (`title`/`bell`/`exit`-as-control is not used; `exit`
    /// goes on data). Control messages are **not** sequenced/replayed.
    public func sendControl(_ message: WireMessage) async throws {
        guard let controlChannel else { throw RworkTransportError.invalidState("no control channel") }
        try await controlChannel.send(message)
    }

    /// Sends `exit(code:)` on the data channel (terminates the byte stream cleanly).
    ///
    /// Records the code so a reconnecting client that missed it still gets it: if a
    /// resume is in flight the live send is withheld (it must not jump ahead of the
    /// replay tail flush) and ``resume(data:control:after:)`` re-sends it after the tail;
    /// likewise if the data channel is currently down the recorded code replays on the
    /// next resume.
    public func sendExit(code: Int32) async throws {
        exitCode = code
        // Hold the exit behind a resume the same way live output is: the exit marker must
        // come AFTER the replayed output tail, never ahead of it. resume() flushes it.
        if isResuming { return }
        // If the client is offline (no bound data channel) we do NOT throw — the code is
        // already recorded above and resume() re-sends it after the tail on reconnect.
        // Throwing here would only be swallowed by the relay's `try?` and lose nothing,
        // but recording-and-returning makes the offline-exit path explicit.
        guard let dataChannel else { return }
        try await dataChannel.send(.exit(code: code))
    }

    // MARK: Reconnect support

    /// Marks the client offline/online (drives the ``ReplayBuffer`` offline gate). The
    /// connection layer calls this when a channel fails (`false`) or rebinds (`true`).
    public func setClientOnline(_ online: Bool) {
        replay.isClientOnline = online
        publishDrainStateIfChanged()
    }

    /// Records a client ack: releases replay entries with `seq <= seq` and republishes
    /// the drain state (an ack can drop below the gate and resume draining).
    public func acknowledge(upTo seq: Int64) {
        replay.ack(upTo: seq)
        publishDrainStateIfChanged()
    }

    /// The retained tail to replay on reconnect: `output` with `seq > lastReceivedSeq`.
    public func replayTail(after lastReceivedSeq: Int64) -> [WireMessage] {
        replay.replay(after: lastReceivedSeq)
    }

    /// The highest seq assigned so far.
    public var highestSeq: Int64 { replay.highestSeq }

    /// Snapshot of whether the PTY drain should currently be paused.
    public var shouldPauseDrain: Bool { replay.shouldPauseDrain }

    /// Binds the DATA + CONTROL channels for a **new** session and starts
    /// de-multiplexing their inbound streams. No replay (nothing retained yet).
    public func bind(data: NWMessageChannel, control: NWMessageChannel) {
        swapChannels(data: data, control: control, online: true)
    }

    /// Atomically rebinds the fresh channels for a **returning client** and replays the
    /// missing tail (`seq > lastReceivedSeq`) in order, then flushes any live output
    /// that was produced during the replay — all before clearing the resume gate.
    ///
    /// This is the single entry point for reconnect so that no live ``sendOutput`` can
    /// interleave ahead of the replayed tail: while ``isResuming`` is set, live output
    /// is retained but not written to the wire (see ``sendOutput(_:)``), and this method
    /// drains it in strict seq order after the tail.
    public func resume(data: NWMessageChannel, control: NWMessageChannel, after lastReceivedSeq: Int64) async throws {
        isResuming = true
        // Always clear the gate, even if a send throws (the new channel dropped again):
        // otherwise live sendOutput would be silently withheld forever. The retained
        // bytes survive in the ReplayBuffer for the *next* reconnect's replay.
        defer { isResuming = false }

        highestSentSeq = lastReceivedSeq
        swapChannels(data: data, control: control, online: true)

        guard let channel = dataChannel else {
            throw RworkTransportError.invalidState("no data channel for resume")
        }
        // Replay loop: send the retained tail in order. New live output appended during
        // this loop is retained (isResuming withholds it from the wire) and picked up by
        // re-reading the buffer until nothing past highestSentSeq remains — so the data
        // channel carries output in strictly ascending seq across the reconnect.
        while true {
            let pending = replay.messages(after: highestSentSeq)
            if pending.isEmpty { break }
            for entry in pending {
                try await channel.send(.output(seq: entry.seq, bytes: entry.bytes))
                highestSentSeq = entry.seq
            }
        }

        // If the child already exited while the client was offline, re-deliver the exit
        // marker AFTER the replayed output tail so the reconnecting client's byte stream
        // terminates cleanly instead of showing a live session behind a dead shell.
        if let code = exitCode {
            try await channel.send(.exit(code: code))
        }
    }

    /// Tears the session down: cancel the inbound forwarders, close both channels, and
    /// finish the inbound streams so any relay consumers terminate. Called by the owner
    /// (e.g. ``HostTransport`` when a NEW session is orphaned because its shell failed to
    /// spawn) to release the bound channels + forwarder tasks instead of leaking them.
    public func close() async {
        dataForwarder?.cancel()
        controlForwarder?.cancel()
        dataForwarder = nil
        controlForwarder = nil
        let oldData = dataChannel
        let oldControl = controlChannel
        dataChannel = nil
        controlChannel = nil
        await oldData?.close()
        await oldControl?.close()
        inputContinuation.finish()
        resizeContinuation.finish()
        ackContinuation.finish()
        drainContinuation.finish()
    }

    /// Common channel swap: cancel old forwarders, close old channels, install new ones.
    private func swapChannels(data: NWMessageChannel, control: NWMessageChannel, online: Bool) {
        dataForwarder?.cancel()
        controlForwarder?.cancel()
        let oldData = dataChannel
        let oldControl = controlChannel

        dataChannel = data
        controlChannel = control
        setClientOnline(online)

        dataForwarder = makeForwarder(for: data)
        controlForwarder = makeForwarder(for: control)

        Task {
            await oldData?.close()
            await oldControl?.close()
        }
    }

    // MARK: Internals

    private func makeForwarder(for channel: NWMessageChannel) -> Task<Void, Never> {
        // The Task is created inside this actor, so its body is actor-isolated: calls
        // into `self` are synchronous (no cross-actor hop, no data race).
        Task {
            do {
                for try await message in channel.inbound {
                    self.handleInbound(message)
                }
            } catch {
                // Channel failed: the client went offline. Reconnect will rebind.
                self.setClientOnline(false)
                return
            }
            // Clean finish (FIN) also means offline.
            self.setClientOnline(false)
        }
    }

    private func handleInbound(_ message: WireMessage) {
        switch message {
        case let .input(bytes):
            inputContinuation.yield(bytes)
        case .resize:
            resizeContinuation.yield(message)
        case let .ack(seq):
            acknowledge(upTo: seq)
            ackContinuation.yield(seq)
        case .bye:
            // Client leaving cleanly; surface as offline. Lifecycle/teardown is the
            // owner's call (HostTransport / WF-3).
            setClientOnline(false)
        default:
            // hello arrives during handshake (handled by HostTransport before bind/resume);
            // host→client types never arrive inbound. Ignore defensively.
            break
        }
    }

    /// Emits a drain transition only when the boolean actually flips.
    private func publishDrainStateIfChanged() {
        let pause = replay.shouldPauseDrain
        if pause != lastPublishedPause {
            lastPublishedPause = pause
            drainContinuation.yield(pause)
        }
    }
}
