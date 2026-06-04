import Foundation
import RworkProtocol

/// One logical Rwork channel multiplexed over a shared physical mux connection.
///
/// A `MuxSubChannel` is the mux-layer analogue of ``NWMessageChannel``: it conforms to the
/// SAME ``MessageChannel`` protocol (so ``MuxClientTransport`` / a host relay can drive it
/// exactly like a real one-TCP-pair channel), but instead of owning an `NWConnection` it is
/// backed by:
/// - a `channelID` (its logical address on the shared connection), and
/// - a `muxSend` closure — given the channel's framed ``WireMessage`` bytes, the owner wraps
///   them in a `.channelData` mux envelope and writes them on the shared physical connection.
///
/// Its ``inbound`` is an `AsyncThrowingStream<WireMessage>` fed by a PER-CHANNEL
/// ``RworkProtocol/FrameDecoder``: the owning ``MuxNWConnection`` demuxes the shared byte
/// stream into per-channel `.channelData` payloads and calls ``deliver(payload:)``, which
/// reassembles whole inner ``WireMessage`` frames for THIS channel and yields them here. So
/// interleaved frames from many channels on one connection land on the correct per-channel
/// inbound stream — the headline mux property.
///
/// ### Framing (two nested length-prefixed layers)
/// The inner ``WireMessage`` is framed by `msg.encode()` exactly as on a real channel; that
/// opaque inner frame becomes the BODY of an OUTER ``MuxFrame/channelData`` envelope. The mux
/// layer never parses the inner bytes — see ``MuxEnvelopeCodec``. This nesting is what lets the
/// existing per-channel `FrameDecoder` work unchanged inside the mux.
///
/// ### Flow control (S2, sub-gated by `RWORK_TCP_MUX_FLOW`)
/// When `flowControl` is ON, the DATA sub-channel carries a per-channel SSH-style send window
/// (``FlowCreditPolicy``): ``send(_:)`` debits the wire byte-count of each frame and, when the
/// window is exhausted, SUSPENDS (await a continuation) until a peer `windowAdjust` calls
/// ``grantCredit(_:)`` — so one flooding channel cannot monopolise the shared socket and starve
/// a sibling. The CONTROL sub-channel is built with flow OFF (infinite window) so resize / ack /
/// bye / keepalive NEVER block behind a full data window (foot-gun #1/#3). With `flowControl`
/// OFF the window is infinite and ``send`` never blocks — byte-identical to S1.
///
/// All mutable state (the decoder, the inbound continuation, the credit window) lives inside
/// this `actor`.
public actor MuxSubChannel: MessageChannel {
    /// Which logical channel kind this carries (advisory — framing is identical, mirroring
    /// ``NWMessageChannel``). The mux carries data + control over the SAME physical pair.
    public nonisolated let channel: Channel

    /// This channel's logical id on the shared mux connection (odd = client-allocated).
    public nonisolated let channelID: UInt32

    /// Writes one channel's framed ``WireMessage`` bytes out on the shared connection (the owner
    /// wraps them in a `.channelData` envelope). `@Sendable` so it can be captured across actors.
    private let muxSend: @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void

    /// Per-channel streaming frame decoder. Lives inside the actor (not `Sendable`) — one per
    /// logical channel, exactly as ``NWMessageChannel`` owns one per physical connection.
    private var decoder = FrameDecoder()

    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inboundContinuation: AsyncThrowingStream<WireMessage, Error>.Continuation

    // MARK: Flow control (S2 — only armed when flowControl is ON)

    /// The per-channel SEND window. `nil` when flow control is OFF (S1: infinite window, no
    /// gating). Wraps the pure ``FlowCreditPolicy`` decider — the actor only owns the suspension.
    private var sendWindow: FlowCreditPolicy?
    /// Senders parked because the window was exhausted, in FIFO order. Resumed (oldest first) when
    /// ``grantCredit(_:)`` replenishes the window or ``finish()`` tears the channel down.
    private var blockedSenders: [CheckedContinuation<Void, Never>] = []
    /// Set once the channel is finished so a sender that suspends after close is not stranded.
    private var finished = false
    /// Send-serialisation gate (S2 chunking). Only ONE multi-chunk send may emit at a time on this
    /// channel: an `actor` does NOT hold isolation across the credit-park suspension, so without this
    /// a second concurrently-issued `send` could interleave its `.channelData` chunks mid-frame and
    /// corrupt the receiver's per-channel `FrameDecoder` reassembly. `send` takes this FIFO gate
    /// before emitting any chunk and hands it off when the whole frame is on the wire. Only the flow-ON
    /// path chunks/parks, so the OFF (S1) path never touches it.
    private var sendActive = false
    private var sendGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - channelID: the logical channel id on the shared connection.
    ///   - channel: the advisory ``Channel`` kind (data/control).
    ///   - flowControl: when `true`, arm the per-channel send window (S2). The owner passes ON
    ///     for the DATA sub-channel and OFF for the CONTROL sub-channel so control frames never
    ///     block behind a full data window. Defaults to OFF (S1 infinite-window behaviour).
    ///   - muxSend: writes this channel's framed bytes out, wrapped in a `.channelData` envelope.
    public init(
        channelID: UInt32,
        channel: Channel,
        flowControl: Bool = false,
        muxSend: @escaping @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void
    ) {
        self.init(channelID: channelID, channel: channel,
                  sendWindowBytes: flowControl ? MuxFlowControl.initialWindowBytes : nil,
                  muxSend: muxSend)
    }

    /// Designated init taking an explicit send-window size (`nil` = flow OFF / infinite window).
    /// Tests use this to seed a SMALL window so the suspend/wake path is exercised without pushing
    /// 256 KiB of bytes. Production callers use the `flowControl:` convenience above.
    init(
        channelID: UInt32,
        channel: Channel,
        sendWindowBytes: Int?,
        muxSend: @escaping @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void
    ) {
        self.channelID = channelID
        self.channel = channel
        self.muxSend = muxSend
        self.sendWindow = sendWindowBytes.map { FlowCreditPolicy(initialWindow: $0) }
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> { inboundStream }

    /// Frames `message` (`msg.encode()`) and hands it to `muxSend` to write — wrapped by the owner
    /// in a `.channelData` envelope for this channel. Suspends until the write is accepted; throws
    /// on a write failure or a closed shared connection.
    ///
    /// ### Flow OFF (S1, byte-identical)
    /// The whole framed ``WireMessage`` is written as ONE `.channelData` envelope, never blocking.
    ///
    /// ### Flow ON (S2)
    /// The framed bytes are CHUNKED across the per-channel send window (yamux / RFC 9113 §5.2
    /// DATA-across-windows): each iteration consumes `min(remaining, bytesLeftInFrame)` credit — a
    /// PARTIAL consume that is ALWAYS `.allowed` (≤ remaining) — and writes that sub-slice as its
    /// own `.channelData`; when the window is exhausted (`remaining == 0`) the send SUSPENDS until a
    /// peer `windowAdjust` grants more (or the channel finishes). This is what makes an oversized
    /// frame (one larger than the whole 256 KiB window) deliverable instead of a permanent park: a
    /// `> window` frame can NEVER all-or-nothing-consume, so it would wait forever for a grant the
    /// receiver only emits AFTER consuming bytes that never arrive (the FIX #1 deadlock).
    ///
    /// The receiver's per-channel ``RworkProtocol/FrameDecoder`` (see ``deliver(payload:)``)
    /// REASSEMBLES the inner ``WireMessage`` across these `.channelData` boundaries, so no
    /// inner-framing change is needed and the split is transparent to the consumer.
    ///
    /// ORDER is preserved by the per-channel SEND GATE (``acquireSendGate()``): a send takes the gate
    /// before emitting any chunk and a concurrently-issued send waits its turn (FIFO), so two sends
    /// can never interleave their chunks mid-frame (which would corrupt the receiver's reassembly —
    /// an `actor` does NOT hold isolation across the credit-park suspension, so call-serialisation
    /// alone is insufficient). A `finish()` mid-chunk throws (the partial-but-stranded frame is never
    /// followed by more) — the receiver's half-reassembled frame is discarded with its decoder on close.
    public func send(_ message: WireMessage) async throws {
        let framed = message.encode()
        // Flow OFF → infinite window: write the WHOLE frame as ONE .channelData (S1-identical). No
        // gate (the OFF path emits one envelope per send, never chunks → no interleave to prevent).
        guard sendWindow != nil else {
            try await muxSend(channelID, framed)
            return
        }
        // Flow ON → take the per-channel send gate so a concurrent send waits its turn (FIFO) instead
        // of interleaving its chunks with ours mid-frame. `acquireSendGate` throws if the channel
        // finished while waiting; the `defer` (registered only AFTER a successful acquire) hands the
        // gate to the next waiter on completion OR on a mid-chunk throw.
        try await acquireSendGate()
        defer { releaseSendGate() }
        // Chunk `framed` across the window. `framed` is non-empty (encode() always emits at least the
        // length prefix + type byte), so the loop makes progress on the first credit.
        var offset = 0
        let total = framed.count
        while offset < total {
            let granted = try await awaitChunkCredit(maxWanted: total - offset)
            // `granted` ∈ [1, total-offset]: ship exactly that many bytes as their own envelope.
            let slice = framed.subdata(in: offset..<(offset + granted))
            try await muxSend(channelID, slice)
            offset += granted
        }
    }

    /// Reserves and returns a chunk of send credit in `1...maxWanted`. Parks while the window is
    /// exhausted (await a `windowAdjust` grant / `finish()`), then PARTIAL-consumes
    /// `min(remaining, maxWanted)` — always `.allowed` since ≤ `remaining`. Throws if the channel is
    /// finished while waiting. Precondition: `sendWindow != nil` (flow ON) and `maxWanted >= 1`.
    private func awaitChunkCredit(maxWanted: Int) async throws -> Int {
        while true {
            if finished { throw RworkTransportError.notConnected("mux channel closed") }
            let available = sendWindow!.remaining
            if available > 0 {
                let take = min(available, maxWanted)
                // PARTIAL consume: `take <= remaining` ⇒ always .allowed; never the all-or-nothing
                // park that stranded an oversized frame (FIX #1).
                guard case .allowed = sendWindow!.consume(take) else {
                    // Unreachable (take <= remaining); re-loop defensively rather than trap.
                    continue
                }
                return take
            }
            // Window exhausted (remaining == 0): park until a windowAdjust grants more, then retry.
            // CONTROL frames are never here (flow OFF on control), so a windowAdjust / ack / bye can
            // always flow and wake us — no deadlock.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                blockedSenders.append(continuation)
            }
        }
    }

    /// Grants `bytesToAdd` of send credit (a peer `CHANNEL_WINDOW_ADJUST`) and wakes every parked
    /// sender so each can retry its ``FlowCreditPolicy/consume(_:)``. A no-op when flow is OFF.
    func grantCredit(_ bytesToAdd: Int) {
        guard sendWindow != nil else { return }
        sendWindow!.adjust(bytesToAdd: bytesToAdd)
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
        if finished { throw RworkTransportError.notConnected("mux channel closed") }
        if !sendActive {
            sendActive = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sendGateWaiters.append(continuation)
        }
        // Woken either by `finish()` (drains all waiters → we throw) or by `releaseSendGate()` handing
        // us the gate (sendActive stays true — it is now ours).
        if finished { throw RworkTransportError.notConnected("mux channel closed") }
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
    /// complete inner ``WireMessage`` frame. Called by the owning ``MuxNWConnection`` after it
    /// demuxes the shared stream. A decode fault is fatal for this channel only (it finishes the
    /// inbound stream with the error) — other channels on the shared connection are untouched.
    ///
    /// Returns the number of inbound `.channelData` BODY bytes consumed (the wire payload length),
    /// so the owner can feed its ``ReceiveWindowAccountant`` and emit a `windowAdjust` once the
    /// half-window threshold is crossed. (The receive-side replenish decision lives in the owner,
    /// beside the link it writes the grant on — same "decider beside the actor" split.)
    @discardableResult
    func deliver(payload: Data) -> Int {
        decoder.append(payload)
        do {
            while let message = try decoder.nextMessage() {
                inboundContinuation.yield(message)
            }
        } catch {
            inboundContinuation.finish(throwing: error)
        }
        return payload.count
    }

    /// Finishes the inbound stream cleanly (the channel closed / the shared connection FIN'd).
    /// S2 (foot-gun #2): also wakes any sender parked on an exhausted window so a close while the
    /// window is full does not leak a suspended task — the woken sender sees `finished` and throws.
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
}
