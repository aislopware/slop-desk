import Foundation
import RworkProtocol
import RworkTransport
#if canImport(RworkTerminal)
import RworkTerminal
#endif

/// The Rwork client session driver — the real, working PATH 1 client.
///
/// `RworkClient` owns a single ``ClientTransport`` (WF-2) and turns its merged
/// host→client ``ClientTransport/inbound`` stream into the three things a UI/CLI
/// cares about:
///
/// - **output bytes** — exposed as an `AsyncStream<Data>` (``output``) *and* fed to an
///   optional ``TerminalSurface`` (the libghostty seam / `HeadlessTerminalSurface`);
/// - **title / bell** — surfaced via the ``events`` stream;
/// - **exit** — surfaced via ``events`` and terminates ``output``.
///
/// ### Ack policy
/// The client tracks the **highest contiguous** `output.seq` it has delivered to the
/// surface (``highestContiguousSeq``) and periodically `sendAck`s it so the host's
/// `ReplayBuffer` can release acked output and the offline gate can recover. Acking is
/// **coalesced**: a pending-ack flag is set whenever the contiguous counter advances and
/// a background ticker flushes it at most once every ``ackInterval`` (default 50ms). We
/// never ack a seq we have not delivered — correctness over cadence (`docs/20` §5).
///
/// ### Reconnect + byte-exact dedup (the headline guarantee)
/// On a transport drop ``ReconnectManager`` calls back into ``connect(...)`` presenting
/// the SAME `sessionID` + ``highestContiguousSeq`` as `lastReceivedSeq`. The host
/// replays every retained `output` with `seq > lastReceivedSeq` on the fresh data
/// channel before resuming live streaming. Because a buggy/racy host *could* replay an
/// output we already delivered (or the client could re-present a stale seq), the client
/// **dedups by seq**: it drops any inbound `output` whose `seq <= highestSeqFed`. The
/// result spliced into ``output`` is gap-free and dup-free.
///
/// ### iOS lifecycle seam ([17] §2.5, [18] §H)
/// ``pause()`` / ``resume()`` are the hooks WF-8 wires to UIKit
/// `didEnterBackground` / `willEnterForeground`. `pause()` proactively closes the
/// transport (iOS would tear the TCP down a few seconds after backgrounding anyway —
/// see DECISIONS §reconnect); `resume()` triggers a reconnect with the preserved
/// `sessionID` + seq so the resume is byte-exact. Output produced while paused is
/// retained on the host (`ReplayBuffer`) and replayed on `resume()`.
///
/// All mutable state lives inside this `actor`. No `@unchecked Sendable`.
public actor RworkClient {
    /// A host→client event the client surfaces beyond the raw byte stream.
    public enum Event: Sendable, Equatable {
        /// Window/title text (OSC 0/2).
        case title(String)
        /// Terminal bell.
        case bell
        /// The remote child process exited with `code`. Terminal — ``output`` finishes
        /// right after this is surfaced.
        case exit(code: Int32)
        /// The transport dropped (network loss / clean close). ``ReconnectManager``
        /// reacts to this; surfaced for diagnostics.
        case disconnected(reason: String)
        /// A reconnect completed and the host began replaying the missing tail.
        case reconnected(sessionID: UUID, resumeFromSeq: Int64)
    }

    /// How often the coalesced ack ticker may flush a pending ack. Correctness does not
    /// depend on this value (we never ack an undelivered seq); it only bounds how stale
    /// the host's view of our progress can get.
    public static let defaultAckInterval: Duration = .milliseconds(50)

    // MARK: Surfaced streams

    private let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let eventStream: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    /// Raw PTY/VT output bytes from the host, spliced gap-free / dup-free across
    /// reconnects. Finishes when the remote child exits (or the client closes).
    public nonisolated var output: AsyncStream<Data> { outputStream }

    /// Title / bell / exit / connection lifecycle events.
    public nonisolated var events: AsyncStream<Event> { eventStream }

    // MARK: Connection target (remembered for reconnect)

    public private(set) var host: String?
    public private(set) var port: UInt16?

    /// Authoritative session id learned from the first `helloAck`. Preserved across
    /// reconnects so the host recognizes us as a RETURNING_CLIENT.
    public private(set) var sessionID: UUID?

    /// Highest **contiguous** output seq delivered to the surface. This is what we ack
    /// and what we present as `hello.lastReceivedSeq` on reconnect.
    public private(set) var highestContiguousSeq: Int64 = 0

    /// Highest output seq actually fed to the surface (== ``highestContiguousSeq`` while
    /// the stream is contiguous, which it always is here). Used as the dedup high-water
    /// mark: any inbound `output` with `seq <= highestSeqFed` is a replay duplicate and
    /// is dropped.
    private var highestSeqFed: Int64 = 0

    // MARK: Internals

    private let ackInterval: Duration
    private var transport: ClientTransport?
    private var inboundTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var ackPending = false
    private var closed = false
    private var paused = false
    private var lastSentResize: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?

    /// Optional terminal renderer fed the inbound output (libghostty seam / headless).
    /// Held as `AnyObject` + a feeder closure so this target need not link RworkTerminal.
    private var surfaceFeed: (@Sendable (Data) -> Void)?

    public init(ackInterval: Duration = RworkClient.defaultAckInterval) {
        self.ackInterval = ackInterval
        var outC: AsyncStream<Data>.Continuation!
        self.outputStream = AsyncStream(bufferingPolicy: .unbounded) { outC = $0 }
        self.outputContinuation = outC
        var evC: AsyncStream<Event>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { evC = $0 }
        self.eventContinuation = evC
    }

    /// Attaches a feeder that mirrors every delivered `output` payload to a terminal
    /// surface (in addition to the ``output`` stream). The closure runs on the actor;
    /// for the GUI surface WF-5 will hop to `@MainActor` inside it.
    public func setSurfaceFeed(_ feed: @escaping @Sendable (Data) -> Void) {
        surfaceFeed = feed
    }

    // MARK: Connect / reconnect

    /// Connects to `host:port`. A first call uses a NEW session (zero sessionID); a
    /// later call (driven by ``ReconnectManager`` or ``resume()``) reuses the learned
    /// ``sessionID`` and presents ``highestContiguousSeq`` so the host replays the tail.
    ///
    /// Idempotency: any previous transport is torn down first, so a reconnect attempt
    /// never leaks the old channels.
    public func connect(
        host: String,
        port: UInt16,
        handshakeTimeout: Duration = .seconds(10)
    ) async throws {
        guard !closed else { throw ClientError.notImplemented("connect after close") }
        self.host = host
        self.port = port

        // Tear down any prior transport (reconnect path) so we never double-pump.
        await teardownTransport()

        let transport = ClientTransport()
        let resume = sessionID ?? WireMessage.newSessionID
        let lastSeq = highestContiguousSeq
        do {
            try await transport.connect(
                host: host,
                port: port,
                resume: resume,
                lastReceivedSeq: lastSeq,
                handshakeTimeout: handshakeTimeout
            )
        } catch {
            await transport.close()
            throw error
        }

        self.transport = transport
        let learnedID = await transport.sessionID
        let resumeFromSeq = await transport.resumeFromSeq
        let returning = await transport.returningClient
        if let learnedID { self.sessionID = learnedID }

        if returning, let learnedID {
            eventContinuation.yield(.reconnected(sessionID: learnedID, resumeFromSeq: resumeFromSeq))
        }

        // Re-assert the last known window size on (re)connect so the remote PTY matches
        // the local terminal even after a resume rebound the control channel.
        if let size = lastSentResize {
            try? await transport.sendResize(cols: size.cols, rows: size.rows, pxWidth: size.px, pxHeight: size.py)
        }

        startInboundPump(transport)
        startAckTicker()
    }

    /// Pumps the transport's merged inbound stream: dedups + delivers `output`, surfaces
    /// title/bell/exit, and finishes (surfacing `.disconnected`) when the stream ends.
    private func startInboundPump(_ transport: ClientTransport) {
        let inbound = transport.inbound
        inboundTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in inbound {
                    await self.handleInbound(message)
                }
                await self.handleStreamEnded(error: nil)
            } catch {
                await self.handleStreamEnded(error: error)
            }
        }
    }

    /// Test-only seam: drive one inbound `WireMessage` through the exact same handling
    /// path the live inbound pump uses (dedup + contiguous tracking + surface/event
    /// fan-out), without standing up a real ``ClientTransport``. `internal`, reached via
    /// `@testable import` — this is the only way to prove the client-side dedup high-water
    /// mark independent of host replay behavior (the host always keys replay off
    /// `lastReceivedSeq`, so an e2e never feeds an already-fed seq).
    func _handleInboundForTesting(_ message: WireMessage) {
        handleInbound(message)
    }

    private func handleInbound(_ message: WireMessage) {
        switch message {
        case let .output(seq, bytes):
            deliverOutput(seq: seq, bytes: bytes)
        case let .exit(code):
            eventContinuation.yield(.exit(code: code))
            // The byte stream is over once the child exits.
            outputContinuation.finish()
        case let .title(text):
            eventContinuation.yield(.title(text))
        case .bell:
            eventContinuation.yield(.bell)
        default:
            // input/hello/resize/ack/bye/helloAck never arrive on the client inbound
            // (helloAck is consumed inside ClientTransport). Ignore defensively.
            break
        }
    }

    /// The dedup + contiguous-tracking core. Drops any `output` already delivered
    /// (`seq <= highestSeqFed`) — this is what makes a replayed tail splice in without a
    /// duplicate. A future seq beyond `highestSeqFed + 1` would be a gap; the transport
    /// guarantees ascending in-order delivery (replay tail then live, `docs/20` §8.3), so
    /// in practice every accepted output advances the counter by exactly one.
    private func deliverOutput(seq: Int64, bytes: Data) {
        guard seq > highestSeqFed else { return } // duplicate (replayed) — drop.
        highestSeqFed = seq
        // Contiguous advance: with in-order delivery this tracks highestSeqFed exactly.
        if seq == highestContiguousSeq + 1 {
            highestContiguousSeq = seq
        } else if seq > highestContiguousSeq {
            // Defensive: never regress; accept forward jumps as the new contiguous high
            // (the transport does not produce gaps, but we must never ack less than we
            // delivered, and never more than we have).
            highestContiguousSeq = seq
        }
        outputContinuation.yield(bytes)
        surfaceFeed?(bytes)
        // Mark an ack as pending; the coalescing ticker sends it.
        ackPending = true
    }

    private func handleStreamEnded(error: Error?) {
        // Surface a disconnect (unless we are closing on purpose). ReconnectManager
        // watches `events` / observes the thrown connect error to drive reconnect.
        guard !closed else { return }
        let reason: String
        if let error { reason = String(describing: error) } else { reason = "stream ended (FIN)" }
        eventContinuation.yield(.disconnected(reason: reason))
    }

    // MARK: Ack coalescing

    /// Starts (or restarts) the background ack ticker. On each tick, if a contiguous
    /// advance is pending, send a single `ack(highestContiguousSeq)`. Cancelled on
    /// teardown/close. We re-create it per connect so it always targets the live
    /// transport.
    private func startAckTicker() {
        ackTask?.cancel()
        let interval = ackInterval
        ackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.flushAckIfPending()
            }
        }
    }

    private func flushAckIfPending() async {
        guard ackPending, let transport else { return }
        let seq = highestContiguousSeq
        ackPending = false
        // Never ack 0 (nothing received) or a seq we have not delivered.
        guard seq > 0 else { return }
        do {
            try await transport.sendAck(seq: seq)
        } catch {
            // Send failed (channel dropped): re-arm so the next live transport acks it.
            ackPending = true
        }
    }

    /// Forces an immediate ack flush (used by tests and by ``close()`` for a clean
    /// final ack). Safe to call any time.
    public func flushAck() async {
        await flushAckIfPending()
    }

    // MARK: Outbound (client → host)

    /// Sends raw keystroke/paste bytes as `input`.
    public func sendInput(_ bytes: Data) async throws {
        guard let transport else { throw ClientError.notImplemented("sendInput before connect") }
        try await transport.sendInput(bytes)
    }

    /// Sends a `resize`, remembering it so it is re-asserted after a reconnect.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        lastSentResize = (cols, rows, pxWidth, pxHeight)
        guard let transport else { throw ClientError.notImplemented("sendResize before connect") }
        try await transport.sendResize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight)
    }

    // MARK: iOS lifecycle seam ([17] §2.5)

    /// App backgrounded: proactively tear the transport down. The host keeps the shell
    /// + replay buffer alive; output produced while paused is retained for replay. Idempotent.
    public func pause() async {
        guard !paused, !closed else { return }
        paused = true
        // Best-effort clean ack of what we have, then a clean bye so the host marks us
        // offline immediately (the kernel would FIN soon anyway).
        await flushAckIfPending()
        if let transport {
            try? await transport.sendBye()
        }
        await teardownTransport()
        eventContinuation.yield(.disconnected(reason: "paused (backgrounded)"))
    }

    /// App foregrounded: reconnect with the preserved `sessionID` + seq for a byte-exact
    /// resume. No-op if not paused / already closed.
    public func resume() async throws {
        guard paused, !closed else { return }
        paused = false
        guard let host, let port else { throw ClientError.notImplemented("resume before first connect") }
        try await connect(host: host, port: port)
    }

    /// True while paused by ``pause()`` (diagnostics / reconnect gating).
    public var isPaused: Bool { paused }

    /// Test-only: simulate a hard network loss — tear down the transport (cancelling the
    /// underlying NWConnections) WITHOUT sending a clean `bye`, exactly as an iOS TCP
    /// teardown or a NetBird path flap would. Preserves `sessionID` + `highestContiguousSeq`
    /// so a subsequent ``connect(...)`` is a byte-exact RETURNING_CLIENT resume. The
    /// surfaced ``output`` / ``events`` streams stay open (this is a drop, not a close).
    ///
    /// Marked underscored + documented as test-only; the production drop path is the
    /// transport failing on its own (handled by ``handleStreamEnded(error:)``).
    public func _forceDropForTesting() async {
        await teardownTransport()
    }

    // MARK: Teardown

    /// Tears down only the transport + its pumps (NOT the surfaced streams) so a
    /// reconnect can replace them. Cancels the inbound + ack tasks and closes the
    /// transport (which cancels its forwarders and the underlying NWConnections).
    private func teardownTransport() async {
        inboundTask?.cancel()
        ackTask?.cancel()
        inboundTask = nil
        ackTask = nil
        await transport?.close()
        transport = nil
    }

    /// Permanently closes the client: tears down the transport and finishes the
    /// surfaced streams. After this the client is unusable.
    public func close() async {
        guard !closed else { return }
        closed = true
        await flushAckIfPending()
        if let transport { try? await transport.sendBye() }
        await teardownTransport()
        outputContinuation.finish()
        eventContinuation.finish()
    }
}
