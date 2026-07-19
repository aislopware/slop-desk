import Foundation
import SlopDeskProtocol

/// One logical SlopDesk channel multiplexed over a shared physical mux connection.
///
/// Conforms to ``MessageChannel`` (so ``MuxClientTransport`` / a host relay drives it like a framed
/// channel), but instead of owning an `NWConnection` it is backed by:
/// - a `channelID` (its logical address on the shared connection), and
/// - a `muxSend` closure — the owner wraps this channel's framed ``WireMessage`` bytes in a
///   `.channelData` mux envelope and writes them on the shared connection.
///
/// ``inbound`` is fed by a PER-CHANNEL ``SlopDeskProtocol/FrameDecoder``: the owning
/// ``MuxNWConnection`` demuxes the shared byte stream into per-channel `.channelData` payloads and
/// calls ``deliver(payload:)``, which reassembles whole inner frames for THIS channel and yields
/// them here — so interleaved frames from many channels land on the correct inbound stream.
///
/// ### Framing (two nested length-prefixed layers)
/// The inner ``WireMessage`` (`msg.encode()`) becomes the BODY of an OUTER ``MuxFrame/channelData``
/// envelope. The mux layer never parses the inner bytes (see ``MuxEnvelopeCodec``) — that nesting is
/// what lets the per-channel `FrameDecoder` work unchanged.
///
/// ### Flow control (always on for DATA)
/// The DATA sub-channel carries a per-channel SSH-style send window (``FlowCreditPolicy``):
/// ``send(_:)`` debits each frame's wire byte-count and SUSPENDS when the window is exhausted until
/// a peer `windowAdjust` calls ``grantCredit(_:)`` — so one flooding channel cannot starve a sibling
/// on the shared socket. The CONTROL sub-channel uses an INFINITE window (`sendWindowBytes: nil`) so
/// resize / ack / bye / keepalive NEVER block behind a full data window (foot-gun #1/#3).
///
/// All mutable state (decoder, inbound continuation, credit window) lives inside this `actor`.
public actor MuxSubChannel: MessageChannel {
    /// Which logical channel kind this carries (advisory — framing is identical; data + control
    /// share the SAME physical pair).
    public nonisolated let channel: Channel

    /// This channel's logical id on the shared mux connection (odd = client-allocated).
    public nonisolated let channelID: UInt32

    /// Writes this channel's framed ``WireMessage`` bytes on the shared connection (owner wraps them
    /// in a `.channelData` envelope). `@Sendable` so it can be captured across actors.
    private let muxSend: @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void

    /// Reports CONSUMED inbound bytes to the owner so it can feed its
    /// ``SlopDeskProtocol/ReceiveWindowAccountant`` and re-grant the peer's send window. Wired by
    /// ``MuxNWConnection`` for the DATA sub-channel (`nil` for CONTROL — unwindowed).
    /// Credit-at-CONSUMPTION: the consumer (client render drain / host PTY writer) calls
    /// ``noteConsumed(_:)`` AFTER processing a message — not at demux time — so un-consumed bytes
    /// downstream of the demux stay bounded by the window. The byte-sum is commutative → no ordering
    /// needed.
    private let consumedSink: (@Sendable (_ bytes: Int) async -> Void)?

    /// Per-channel streaming frame decoder, one per logical channel. Lives inside the actor (not
    /// `Sendable`). A `final class` owning a Rust core handle, so it is `let` — the reference is
    /// fixed; the Rust-side buffer mutates behind the handle.
    private let decoder = FrameDecoder()

    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inboundContinuation: AsyncThrowingStream<WireMessage, Error>.Continuation

    // MARK: Flow control (DATA armed; CONTROL infinite)

    /// The per-channel SEND window. `nil` = INFINITE window (CONTROL sub-channel, no gating). Wraps
    /// the pure ``FlowCreditPolicy`` decider — the actor only owns the suspension.
    private var sendWindow: FlowCreditPolicy?
    /// Senders parked because the window was exhausted, in FIFO order. Resumed (oldest first) when
    /// ``grantCredit(_:)`` replenishes the window or ``finish()`` tears the channel down.
    private var blockedSenders: [CheckedContinuation<Void, Never>] = []
    /// Set once the channel is finished so a sender that suspends after close is not stranded.
    /// Backed by the lock-guarded ``FinishedBox`` (not a plain actor var) so ``isFinished`` can
    /// read it synchronously without an actor hop — the host's `rebindRelay` must refuse a
    /// reattach onto sub-channels whose link already died, and it runs under an `NSLock` that
    /// cannot suspend into this actor.
    private var finished: Bool {
        get { finishedBox.value }
        set { finishedBox.value = newValue }
    }

    private let finishedBox = FinishedBox()

    /// Nonisolated synchronous read of the channel's finished state. `MuxNWConnection.finishLink`
    /// finishes every sub-channel BEFORE it fires `linkDownHandler`, so "finished" reliably means
    /// the carrying link is dead — every future `send` throws. The host reads this from inside its
    /// session lock to refuse rebinding a detached session onto a dead channel pair.
    public nonisolated var isFinished: Bool { finishedBox.value }

    /// Minimal lock-guarded Bool so the actor-owned `finished` flag has a nonisolated read
    /// (`isFinished`). Writes stay actor-serialised; the lock only publishes them safely.
    private final class FinishedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return flag
            }
            set {
                lock.lock()
                flag = newValue
                lock.unlock()
            }
        }
    }

    /// Send-serialisation gate (S2 chunking). Only ONE multi-chunk send may emit at a time: an
    /// `actor` does NOT hold isolation across the credit-park suspension, so without this a second
    /// concurrent `send` could interleave its `.channelData` chunks mid-frame and corrupt the
    /// receiver's `FrameDecoder` reassembly. `send` takes this FIFO gate before any chunk and hands
    /// it off once the whole frame is on the wire. Only the armed (DATA) path chunks/parks; the
    /// infinite-window CONTROL channel returns early and never touches the gate.
    private var sendActive = false
    private var sendGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - channelID: the logical channel id on the shared connection.
    ///   - channel: the advisory ``Channel`` kind (data/control).
    ///   - muxSend: writes this channel's framed bytes, wrapped in a `.channelData` envelope.
    ///
    /// Arms the send window with ``MuxFlowControl/initialWindowBytes`` (the DATA sub-channel path).
    /// The CONTROL sub-channel (infinite, never gated) uses the designated init below with
    /// `sendWindowBytes: nil`.
    @preconcurrency
    public init(
        channelID: UInt32,
        channel: Channel,
        consumedSink: (@Sendable (_ bytes: Int) async -> Void)? = nil,
        muxSend: @escaping @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void,
    ) {
        self.init(
            channelID: channelID,
            channel: channel,
            sendWindowBytes: MuxFlowControl.initialWindowBytes,
            consumedSink: consumedSink,
            muxSend: muxSend,
        )
    }

    /// Designated init taking an explicit send-window size (`nil` = infinite window, never gated).
    /// CONTROL uses `nil`; tests seed a SMALL window to exercise the suspend/wake path without
    /// pushing a whole window of bytes.
    init(
        channelID: UInt32,
        channel: Channel,
        sendWindowBytes: Int?,
        consumedSink: (@Sendable (_ bytes: Int) async -> Void)? = nil,
        muxSend: @escaping @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void,
    ) {
        self.channelID = channelID
        self.channel = channel
        self.muxSend = muxSend
        self.consumedSink = consumedSink
        sendWindow = sendWindowBytes.map { FlowCreditPolicy(initialWindow: $0) }
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation?
        inboundStream = AsyncThrowingStream { continuation = $0 }
        guard let continuation else {
            preconditionFailure("AsyncThrowingStream runs its build closure synchronously, so the continuation is set")
        }
        inboundContinuation = continuation
    }

    /// Reports that `bytes` wire bytes were CONSUMED by the channel's real consumer (rendered /
    /// written to the PTY) — forwards to the owner's receive accountant, which emits the
    /// `windowAdjust` grant once its threshold is crossed. No-op for CONTROL (unwindowed). EVERY
    /// data-sub-channel consumer MUST call this per consumed message, or its peer parks after one
    /// window.
    public func noteConsumed(_ bytes: Int) async {
        await consumedSink?(bytes)
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> { inboundStream }

    /// Frames `message` (`msg.encode()`) and hands it to `muxSend` — wrapped by the owner in a
    /// `.channelData` envelope. Suspends until the write is accepted; throws on write failure or a
    /// closed shared connection.
    ///
    /// ### Infinite window (CONTROL sub-channel)
    /// The whole framed ``WireMessage`` is written as ONE `.channelData` envelope, never blocking.
    ///
    /// ### Armed window (DATA sub-channel)
    /// The framed bytes are CHUNKED across the send window (yamux / RFC 9113 §5.2
    /// DATA-across-windows): each iteration consumes `min(remaining, bytesLeftInFrame)` credit — a
    /// PARTIAL consume, ALWAYS `.allowed` (≤ remaining) — and writes that sub-slice as its own
    /// `.channelData`; when `remaining == 0` the send SUSPENDS until a peer `windowAdjust` grants
    /// more (or the channel finishes). This makes an oversized frame (larger than the whole 256 KiB
    /// window) deliverable instead of parked forever: a `> window` frame can NEVER
    /// all-or-nothing-consume, so it would wait forever for a grant the receiver only emits AFTER
    /// consuming bytes that never arrive (the FIX #1 deadlock).
    ///
    /// The receiver's ``SlopDeskProtocol/FrameDecoder`` (see ``deliver(payload:)``) REASSEMBLES the
    /// inner ``WireMessage`` across these `.channelData` boundaries, so the split is transparent to
    /// the consumer with no inner-framing change.
    ///
    /// ORDER is preserved by the per-channel SEND GATE (``acquireSendGate()``): a send takes the gate
    /// before any chunk and a concurrent send waits its turn (FIFO), so two sends can never
    /// interleave chunks mid-frame (which would corrupt reassembly — an `actor` does NOT hold
    /// isolation across the credit-park suspension, so call-serialisation alone is insufficient). A
    /// `finish()` mid-chunk throws; the receiver's half-reassembled frame is discarded with its
    /// decoder on close.
    public func send(_ message: WireMessage) async throws {
        let framed = message.encode()
        // Infinite window (CONTROL): write the WHOLE frame as ONE .channelData. No gate (one
        // envelope per send, never chunks → no interleave to prevent).
        guard sendWindow != nil else {
            try await muxSend(channelID, framed)
            return
        }
        // Armed window (DATA): take the send gate so a concurrent send waits its turn (FIFO) instead
        // of interleaving chunks mid-frame. `acquireSendGate` throws if the channel finished while
        // waiting; the `defer` (registered only AFTER a successful acquire) hands the gate to the
        // next waiter on completion OR on a mid-chunk throw.
        try await acquireSendGate()
        defer { releaseSendGate() }
        // Chunk `framed` across the window. `framed` is non-empty (encode() always emits ≥ length
        // prefix + type byte), so the loop makes progress on the first credit.
        var offset = 0
        let total = framed.count
        while offset < total {
            let granted = try await awaitChunkCredit(maxWanted: total - offset)
            // `granted` ∈ [1, total-offset]: ship exactly that many bytes as their own envelope.
            if offset == 0, granted == total {
                // Whole frame fits the granted credit (>99% common case): ship `framed` directly.
                // `framed.subdata(in: 0..<total)` would be a byte-identical copy that muxSend copies
                // AGAIN into the envelope — pure waste. `framed` is a COW `let` not mutated after
                // this, so handing it to the @Sendable closure is safe.
                try await muxSend(channelID, framed)
            } else {
                let slice = framed.subdata(in: offset..<(offset + granted))
                try await muxSend(channelID, slice)
            }
            offset += granted
        }
    }

    /// Reserves and returns a chunk of send credit in `1...maxWanted`. Parks while the window is
    /// exhausted (await a `windowAdjust` grant / `finish()`), then PARTIAL-consumes
    /// `min(remaining, maxWanted)` — always `.allowed` since ≤ `remaining`. Throws if the channel is
    /// finished while waiting. Precondition: `sendWindow != nil` (flow ON) and `maxWanted >= 1`.
    private func awaitChunkCredit(maxWanted: Int) async throws -> Int {
        while true {
            if finished { throw SlopDeskTransportError.notConnected("mux channel closed") }
            // A CANCELLED sender unblocks here. Without it, a drain Task parked on an exhausted window
            // (below) could only be woken by a `windowAdjust` grant or `finish()` — so a teardown that
            // merely `cancel()`s the drain Task (e.g. `HostServer.stop()` → `MuxChannelSession.shutdown`,
            // which does NOT route through `MuxNWConnection.close()` and so never `finish()`es the
            // sub-channel) would leak the parked task + its retained actors forever. The park's
            // cancellation handler wakes us; this re-check then throws.
            try Task.checkCancellation()
            guard let available = sendWindow?.remaining else {
                preconditionFailure("awaitChunkCredit requires flow ON (sendWindow != nil)")
            }
            if available > 0 {
                let take = min(available, maxWanted)
                // PARTIAL consume: `take <= remaining` ⇒ always .allowed; never the all-or-nothing
                // park that stranded an oversized frame (FIX #1).
                guard case .allowed = sendWindow?.consume(take) else {
                    // Unreachable (take <= remaining); re-loop defensively rather than trap.
                    continue
                }
                return take
            }
            // Window exhausted (remaining == 0): park until a windowAdjust grants more, `finish()`
            // closes, OR this task is CANCELLED, then retry. CONTROL frames are never here (flow OFF),
            // so a windowAdjust / ack / bye always flows and wakes us — no deadlock. Cancellation-aware:
            // `onCancel` wakes every parked sender so a cancelled one re-loops and the
            // `Task.checkCancellation()` above throws (no leaked sender on teardown).
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled {
                        continuation.resume() // already cancelled — do not park; re-check + throw above
                    } else {
                        blockedSenders.append(continuation)
                    }
                }
            } onCancel: {
                // Runs OFF the actor; hop in to wake the parked senders so the cancelled one proceeds.
                Task { await self.wakeBlockedSenders() }
            }
        }
    }

    /// Grants `bytesToAdd` of send credit (a peer `CHANNEL_WINDOW_ADJUST`) and wakes every parked
    /// sender so each can retry its ``FlowCreditPolicy/consume(_:)``. A no-op when flow is OFF.
    func grantCredit(_ bytesToAdd: Int) {
        guard sendWindow != nil else { return }
        sendWindow?.adjust(bytesToAdd: bytesToAdd)
        wakeBlockedSenders()
    }

    /// Resumes every parked sender (they re-check the window / finished flag and either proceed or
    /// throw). Drains the queue so a continuation is resumed exactly once.
    private func wakeBlockedSenders() {
        let waiters = blockedSenders
        blockedSenders.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Acquires the per-channel send gate (FIFO). Returns once this send may emit its chunks; throws
    /// if the channel finished while waiting. Pairs with ``releaseSendGate()``.
    private func acquireSendGate() async throws {
        if finished { throw SlopDeskTransportError.notConnected("mux channel closed") }
        if !sendActive {
            sendActive = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sendGateWaiters.append(continuation)
        }
        // Woken either by `finish()` (drains all waiters → we throw) or by `releaseSendGate()` handing
        // us the gate (sendActive stays true — it is now ours).
        if finished { throw SlopDeskTransportError.notConnected("mux channel closed") }
    }

    /// Releases the send gate, handing it FIFO to the next waiting send (sendActive stays true) or
    /// clearing it if none wait. Synchronous so it is `defer`-safe.
    private func releaseSendGate() {
        if let next = sendGateWaiters.first {
            sendGateWaiters.removeFirst()
            next.resume() // hand the gate to `next` — sendActive remains true
        } else {
            sendActive = false
        }
    }

    /// Wakes every send-gate waiter on ``finish()`` (each re-checks `finished` and throws) so a close
    /// while a send is queued does not leak a suspended task.
    private func wakeSendGateWaiters() {
        let waiters = sendGateWaiters
        sendGateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Feeds an inbound `.channelData` payload for THIS channel into its decoder and yields every
    /// complete inner ``WireMessage`` frame. Called by ``MuxNWConnection`` after it demuxes the
    /// shared stream. A decode fault is fatal for this channel only — the channel is FINISHED with
    /// the error (`isFinished` flips, parked senders wake and throw), which the owner's `route`
    /// reads to stop feeding it and unregister it — other channels on the shared connection are
    /// untouched. The per-channel decoder poisons itself on the fault, so a payload that races in
    /// before the owner unregisters is dropped, never re-buffered.
    ///
    /// Returns the `.channelData` BODY byte count (the wire payload length) so the owner can feed its
    /// ``ReceiveWindowAccountant`` and emit a `windowAdjust` once the half-window threshold is
    /// crossed. (The replenish decision lives in the owner, beside the link it writes the grant on —
    /// same "decider beside the actor" split.)
    @discardableResult
    func deliver(payload: Data) -> Int {
        decoder.append(payload)
        do {
            while let message = try decoder.nextMessage() {
                inboundContinuation.yield(message)
            }
        } catch {
            finish(throwing: error)
        }
        return payload.count
    }

    /// Finishes the inbound stream cleanly (channel closed / shared connection FIN'd). S2 (foot-gun
    /// #2): also wakes any sender parked on an exhausted window so a close with a full window does not
    /// leak a suspended task — the woken sender sees `finished` and throws.
    func finish() {
        finished = true
        inboundContinuation.finish()
        wakeBlockedSenders()
        wakeSendGateWaiters()
    }

    /// Finishes the inbound stream with `error` (the shared connection failed under this channel).
    /// Also wakes any parked sender (it sees `finished` and throws) so the failure does not leak it.
    func finish(throwing error: Error) {
        finished = true
        inboundContinuation.finish(throwing: error)
        wakeBlockedSenders()
        wakeSendGateWaiters()
    }

    /// Creates a *null* `MuxSubChannel` whose inbound stream is already finished (no messages arrive)
    /// and whose outbound sends are no-ops (bytes silently dropped).
    ///
    /// Used by the agent-control `spawn` verb: standalone panes have no real client connection, so
    /// their `data`/`control` sub-channels are null stubs. The relay's receive loops exit immediately
    /// (finished stream), driving `setClientOnline(false)` (the ReplayBuffer offline gate engages),
    /// letting the PTY drain flow to the replay ring instead of the wire.
    ///
    /// `channelID 0` is a sentinel (the protocol allocates from 1): uniquely identifies a null
    /// channel, never confused with a real sub-channel id.
    public static func makeNull(channel: Channel) async -> MuxSubChannel {
        let ch = MuxSubChannel(
            channelID: 0,
            channel: channel,
            sendWindowBytes: nil, // infinite window — no flow control, no parking
            consumedSink: nil,
            muxSend: { _, _ in }, // drop all sends silently (no real connection)
        )
        await ch.finish() // closes inbound stream immediately → relay loops exit
        return ch
    }
}
