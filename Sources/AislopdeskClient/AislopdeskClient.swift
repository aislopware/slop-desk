import AislopdeskProtocol
import AislopdeskTransport
import Foundation

/// The Aislopdesk client session driver — the real, working PATH 1 client.
///
/// `AislopdeskClient` owns a single ``ClientTransporting`` and turns its merged
/// host→client ``ClientTransporting/inbound`` stream into the three things a UI/CLI
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
/// ### Reconnect + seq dedup
/// On a transport drop ``ReconnectManager`` calls back into ``connect(...)`` presenting the
/// SAME `sessionID` + ``highestContiguousSeq`` as `lastReceivedSeq`. The seq **dedup** mechanism
/// itself is robust: the client drops any inbound `output` whose `seq <= highestSeqFed`, so were a
/// host to replay an already-delivered tail (or were the client to re-present a stale seq), the
/// result spliced into ``output`` would be gap-free and dup-free.
///
/// IMPORTANT — what reconnect actually does TODAY: the mux transport (the sole terminal
/// connectivity) has **no per-channel server-side resume**. A real drop kills the host shell and
/// the reconnect spawns a BRAND-NEW one whose `output` restarts at seq 1 — there is no replay (see
/// `MuxChannelSession` "S1 has no per-channel reconnect/resume", `HostServer.spawnMuxChannel`). So
/// reconnect is the **ssh model (fresh shell)**, NOT a byte-exact resume, and ``connect(...)``
/// therefore RESETS the dedup/ack high-water marks on every (re)connect so the fresh shell renders
/// from seq 1. Client-side scrollback is preserved across a SwiftUI surface rebuild (tab switch)
/// via the view model's replay ring, but NOT across a transport drop. Host-side survival + true
/// `seq > lastReceivedSeq` replay (`docs/20` §8.3) is a designed-but-unimplemented later stage; if
/// it lands, the unconditional reset in ``connect(...)`` must become conditional on a
/// host-authoritative returning flag.
///
/// ### iOS lifecycle seam ([17] §2.5, [18] §H)
/// ``pause()`` / ``resume()`` are the hooks WF-8 wires to UIKit
/// `didEnterBackground` / `willEnterForeground`. `pause()` proactively closes the
/// transport (iOS would tear the TCP down a few seconds after backgrounding anyway —
/// see DECISIONS §reconnect); `resume()` triggers a reconnect with the preserved
/// `sessionID` + seq. Per the reconnect note above, on the mux path this yields a FRESH shell (not
/// a byte-exact resume) — the renderer is reset and the new shell repaints from its first prompt.
///
/// All mutable state lives inside this `actor`. No `@unchecked Sendable`.
public actor AislopdeskClient {
    /// A host→client event the client surfaces beyond the raw byte stream.
    public enum Event: Sendable, Equatable {
        /// Window/title text (OSC 0/2).
        case title(String)
        /// Terminal bell.
        case bell
        /// Per-command shell status (OSC 133 C/D, sniffed host-side). Drives the per-pane
        /// running/idle indicator + the long-command completion notification.
        case commandStatus(WireMessage.CommandStatus)
        /// An EXPLICIT desktop notification the child requested (OSC 9 / OSC 777, sniffed
        /// host-side). The client posts it as a local notification; clicking focuses the pane.
        case notification(title: String, body: String)
        /// The remote child process exited with `code`. Terminal — ``output`` finishes
        /// right after this is surfaced.
        case exit(code: Int32)
        /// A fresh smoothed app-layer RTT sample (EWMA over ping/pong on the CONTROL
        /// channel). Surfaced so the chrome can show a latency badge and lag can be
        /// attributed (network RTT vs host stall vs client render).
        case rtt(milliseconds: Double)
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

    /// RTT probe cadence (docs/26 D1). 3s: cheap (one 14-byte control frame each way) yet
    /// fresh enough for a latency badge / typing-lag attribution.
    public static let pingInterval: Duration = .seconds(3)

    /// EWMA-smoothed app-layer RTT in milliseconds (`nil` until the first pong). α = 0.25
    /// (≈ TCP SRTT's 1/8–1/4 family): responsive to weather changes without flapping on
    /// one outlier.
    public private(set) var smoothedRTTMS: Double?

    // MARK: Surfaced streams

    /// Inbox of delivered-but-not-yet-consumed `output` payloads, drained in batches by
    /// the single consumer via ``takeOutputBatch()``. Replaces the old per-chunk
    /// `AsyncStream<Data>` so a backlog crosses to the consumer as ONE batch (one
    /// MainActor hop, one render flush) instead of one job per wire chunk. Each entry
    /// carries its message's wire byte count: taking a batch CREDITS those bytes back to
    /// the host (credit-at-consumption), so the inbox can never hold more than ~one mux
    /// window and the host's PTY-pause backpressure finally engages from a slow client.
    private var outputInbox: [(bytes: Data, wireBytes: Int)] = []
    private let outputWakeStream: AsyncStream<Void>
    private let outputWakeContinuation: AsyncStream<Void>.Continuation

    /// Multicast hub for events: each ``events`` access subscribes a fresh child stream so
    /// `ReconnectManager` and the view-models can all observe the SAME events concurrently
    /// without stealing them from one another (a plain `AsyncStream` is single-consumer /
    /// fan-in; see ``EventBroadcaster``).
    private let eventBroadcaster = EventBroadcaster<Event>()

    /// Wakeups for the output inbox: one (coalesced) signal per append burst.
    ///
    /// **SINGLE consumer only** (same contract the old `output` stream had): the consumer
    /// loops `for await _ in outputWakeups { await takeOutputBatch() … }` and MUST do one
    /// final ``takeOutputBatch()`` after the loop exits — a tail appended immediately
    /// before the stream finishes (exit/close) is otherwise lost. `bufferingNewest(1)`
    /// coalesces redundant wakes; appends always happen BEFORE the yield, so a pending
    /// wake always observes a complete inbox.
    public nonisolated var outputWakeups: AsyncStream<Void> { outputWakeStream }

    /// Atomically takes the whole pending output backlog (FIFO order preserved) and
    /// CREDITS the taken bytes back to the host (credit-at-consumption: "taken" means the
    /// single consumer is about to feed them — the next take cannot happen until that
    /// ingest returns, so client-side un-rendered bytes stay bounded by ~one window plus
    /// the batch in hand). Raw PTY/VT output bytes from the host, spliced gap-free /
    /// dup-free across reconnects by ``deliverOutput(seq:bytes:)``'s dedup.
    public func takeOutputBatch() async -> [Data] {
        guard !outputInbox.isEmpty else { return [] }
        let batch = outputInbox
        outputInbox.removeAll(keepingCapacity: true)
        let wireBytes = batch.reduce(0) { $0 + $1.wireBytes }
        await transport?.noteOutputConsumed(wireBytes: wireBytes)
        return batch.map(\.bytes)
    }

    /// Title / bell / exit / connection lifecycle events.
    ///
    /// **Each access returns a NEW broadcasting child stream** — every concurrent consumer
    /// (the reconnect supervisor, the chrome view-model, …) sees *every* event. This is a
    /// live multicast: a late subscriber sees only events from its subscription point on.
    /// (It is NOT a single shared `AsyncStream`; that would deliver each event to exactly
    /// one of the loops, nondeterministically — the bug this replaces.)
    public nonisolated var events: AsyncStream<Event> { eventBroadcaster.subscribe() }

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
    /// bound — any inbound `output` with `seq <= highestSeqFed` is a replay duplicate and
    /// is dropped.
    private var highestSeqFed: Int64 = 0

    // MARK: Internals

    private let ackInterval: Duration
    /// Factory for the session transport, injected so a pane is backed by a logical channel over a
    /// shared ``MuxNWConnection`` (a `MuxClientTransport`, supplied by
    /// ``WorkspaceStore/liveMakeSession`` bound to the per-host ``ConnectionRegistry``).
    private let makeTransport: @Sendable () -> any ClientTransporting
    private var transport: (any ClientTransporting)?
    private var inboundTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var ackPending = false
    private var closed = false
    private var paused = false

    /// Monotonic connect-attempt counter. Each ``connect(...)`` captures its value at entry; if a
    /// NEWER connect starts during this one's `await transport.connect(...)` suspension (the actor is
    /// reentrant at every await), the older invocation observes its captured generation is now stale
    /// and DISCARDS its just-built transport instead of adopting it. Without this, two overlapping
    /// connects (e.g. the reconnect supervisor racing iOS `resume()`) both reach `self.transport =
    /// transport`; the second overwrites the first WITHOUT tearing it down, leaking a fully-live
    /// transport (2 sockets + inbound pump + ack ticker) and its ``ConnectionRegistry`` refcount — the
    /// "zombie transport" race. Paired with the post-handshake `closed`/`paused` re-check below for the
    /// close()/pause()-during-reconnect variants.
    private var connectGeneration: UInt64 = 0

    /// Set while we are deliberately replacing the transport (reconnect entry / pause).
    /// `teardownTransport()` closes the OLD transport, which finishes the OLD inbound
    /// stream and lands the old pump in ``handleStreamEnded(error:)`` with `nil` — a
    /// SELF-INFLICTED end, not a real drop. This flag lets `handleStreamEnded` suppress
    /// that spurious `.disconnected` (mirror of the `closed` guard), so `ReconnectManager`
    /// does not queue a redundant reconnect campaign. The real drop path
    /// (``forceDropForTesting()`` / transport failing on its own) leaves this `false`.
    /// DEPTH counter (not a bare Bool) so two overlapping teardowns — a reentrant connect()/pause() whose
    /// teardownTransport awaits across another connect()/pause() — cannot clobber each other's suppression
    /// window: a shared Bool let the inner scope's `= false` clear the outer's `= true`, briefly un-
    /// suppressing handleStreamEnded so a self-inflicted old-pump stream-end surfaced a spurious
    /// `.disconnected` + a redundant reconnect. Each scope inc/decrements only its own, so the depth stays
    /// > 0 for the whole span any teardown is in flight (R13 #11).
    private var tearingDownDepth = 0
    private var tearingDown: Bool { tearingDownDepth > 0 }
    private var lastSentResize: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?

    /// Optional terminal renderer fed the inbound output (libghostty seam / headless).
    /// Held as `AnyObject` + a feeder closure so this target need not link AislopdeskTerminal.
    private var surfaceFeed: (@Sendable (Data) -> Void)?

    /// - Parameters:
    ///   - ackInterval: how often the coalesced ack ticker may flush (correctness-independent).
    ///   - makeTransport: the session-transport factory. Vends a logical channel over a shared
    ///     ``MuxNWConnection`` (a `MuxClientTransport`) — wired at the
    ///     `WorkspaceStore.liveMakeSession` construction site, never on the hot path.
    @preconcurrency
    public init(
        ackInterval: Duration = AislopdeskClient.defaultAckInterval,
        makeTransport: @escaping @Sendable () -> any ClientTransporting,
    ) {
        self.ackInterval = ackInterval
        self.makeTransport = makeTransport
        (outputWakeStream, outputWakeContinuation) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Attaches a feeder that mirrors every delivered `output` payload to a terminal
    /// surface (in addition to the ``output`` stream). The closure runs on the actor;
    /// for the GUI surface WF-5 will hop to `@MainActor` inside it.
    @preconcurrency
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
        handshakeTimeout: Duration = .seconds(10),
    ) async throws {
        guard !closed else { throw ClientError.invalidState("connect after close") }
        self.host = host
        self.port = port

        // Claim a generation BEFORE the first suspension (teardown). A concurrent connect that starts
        // while we are suspended will claim a HIGHER one, marking us stale at the post-handshake check.
        connectGeneration &+= 1
        let myGeneration = connectGeneration

        // Tear down any prior transport (reconnect path) so we never double-pump. Guard the
        // teardown so the old inbound pump's self-inflicted stream-end (the OLD transport
        // closing finishes the OLD inbound stream) does NOT surface a spurious `.disconnected`
        // that would make ReconnectManager queue a redundant reconnect campaign.
        tearingDownDepth += 1
        await teardownTransport()
        tearingDownDepth -= 1

        let transport = makeTransport()
        let resume = sessionID ?? WireMessage.newSessionID
        let lastSeq = highestContiguousSeq
        do {
            try await transport.connect(
                host: host,
                port: port,
                resume: resume,
                lastReceivedSeq: lastSeq,
                handshakeTimeout: handshakeTimeout,
            )
        } catch {
            await transport.close()
            throw error
        }

        // POST-HANDSHAKE re-check — the actor was reentrant across `await transport.connect(...)`.
        // If, during that suspension, the client was closed (deliberate disconnect) or paused (iOS
        // background), OR a NEWER connect() superseded us (claimed a higher `connectGeneration`), OR our
        // driving task was cancelled, we must DISCARD this freshly-built transport rather than adopt it.
        // Adopting it would assign `self.transport = transport` over the other live/closing one WITHOUT
        // tearing this one down — leaking a live transport + its inbound pump + ack ticker + the
        // ConnectionRegistry channel refcount (the zombie-transport bug). `transport.close()` releases
        // the channel (refcount--), so nothing leaks. We RETURN rather than throw: a thrown error would
        // make ``ReconnectManager``'s loop RETRY and fight whichever connect legitimately won — returning
        // tells it "the client is handled, stop the campaign."
        if closed || paused || Task.isCancelled || myGeneration != connectGeneration {
            await transport.close()
            return
        }

        self.transport = transport
        let learnedID = await transport.sessionID
        let resumeFromSeq = await transport.resumeFromSeq
        let returning = await transport.returningClient
        if let learnedID { sessionID = learnedID }

        // RESET DEDUP / ACK STATE ON EVERY (RE)CONNECT. The mux transport — the SOLE terminal
        // connectivity — has NO per-channel server-side resume: `HostServer.spawnMuxChannel` mints a
        // BRAND-NEW PTY on every channelOpen and `MuxChannelSession` documents "S1 has no per-channel
        // reconnect/resume … the shell MUST die" on any drop. So the host's `output` ALWAYS restarts at
        // seq 1, even on a "reconnect". Our `highestSeqFed`/`highestContiguousSeq` high-water marks
        // belong to the OLD (now-dead) session and MUST be reset here, before the pumps start —
        // otherwise:
        //   • `deliverOutput` drops every fresh `output` with seq <= the stale `highestSeqFed`,
        //     SILENTLY SWALLOWING the new shell's first prompt until its seq passes the old mark; and
        //   • the ack ticker sends `ack(stale highestContiguousSeq)` against the fresh session.
        // (On a first connect these are already 0 — a harmless no-op.)
        //
        // WHY UNCONDITIONAL (not gated on `returning`): `MuxClientTransport.returningClient` is computed
        // CLIENT-SIDE as `resume != newSessionID`, so it is `true` on EVERY reconnect — but the host
        // never actually preserved anything (it always spawned a fresh shell). Gating the reset on
        // `!returning` (the old code) therefore SKIPPED it on the exact path that needs it most. The
        // reset is correct as long as no transport performs a real server-side resume-with-replay; IF
        // host-side per-channel survival ever lands (docs/20 §8.3 / an openAck-carried returning flag),
        // this must become conditional on that HOST-AUTHORITATIVE signal, not the client-side guess.
        highestSeqFed = 0
        highestContiguousSeq = 0
        ackPending = false
        // Drop the DEAD session's undrained inbox entries with the seq marks. Two reasons
        // (night-review findings): (a) a consumer drain racing the reconnect could paint
        // the old session's tail AFTER the fresh-session wipe; (b) takeOutputBatch credits
        // taken entries to the CURRENT transport — stale entries would emit a phantom
        // windowAdjust over-grant on the NEW channel (its peer never sent those bytes).
        outputInbox.removeAll(keepingCapacity: true)

        if returning, let learnedID {
            // Surface the reconnect so the UI flips `.reconnecting` → `.connected`
            // (ConnectionViewModel folds this event). NOTE: despite the name, this is NOT a byte-exact
            // resume on the mux path — the shell is fresh; the event only conveys "the link came back".
            eventBroadcaster.yield(.reconnected(sessionID: learnedID, resumeFromSeq: resumeFromSeq))
        }

        // Re-assert the last known window size on (re)connect so the remote PTY matches
        // the local terminal even after a resume rebound the control channel.
        if let size = lastSentResize {
            try? await transport.sendResize(cols: size.cols, rows: size.rows, pxWidth: size.px, pxHeight: size.py)
        }

        // POST-ADOPTION re-check (R13 #2): the line-238 check ran BEFORE four more cross-actor awaits
        // (transport.sessionID/resumeFromSeq/returningClient/sendResize), each a reentrancy window. If a
        // deliberate close()/pause() landed during any of them, teardownTransport() already cancelled +
        // niled the pumps and closed this transport — re-creating the pumps here would leak a forever-
        // spinning ack ticker (its loop has no closed/transport guard). Bail before starting them.
        if closed || paused || Task.isCancelled || myGeneration != connectGeneration {
            await transport.close()
            return
        }

        startInboundPump(transport)
        startAckTicker()
        startPingTicker()
    }

    /// Pumps the transport's merged inbound stream: dedups + delivers `output`, surfaces
    /// title/bell/exit, and finishes (surfacing `.disconnected`) when the stream ends.
    private func startInboundPump(_ transport: any ClientTransporting) {
        let inbound = transport.inbound
        inboundTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in inbound {
                    await handleInbound(message)
                }
                await handleStreamEnded(error: nil)
            } catch {
                await handleStreamEnded(error: error)
            }
        }
    }

    /// Test-only seam: drive one inbound `WireMessage` through the exact same handling
    /// path the live inbound pump uses (dedup + contiguous tracking + surface/event
    /// fan-out), without standing up a real transport. `internal`, reached via
    /// `@testable import` — this is the only way to prove the client-side dedup high-water
    /// mark independent of host replay behavior (the host always keys replay off
    /// `lastReceivedSeq`, so an e2e never feeds an already-fed seq).
    func handleInboundForTesting(_ message: WireMessage) async {
        await handleInbound(message)
    }

    /// Test-only: whether a transport is currently adopted (`self.transport != nil`). Used by the
    /// reconnect-race regression suite to assert that a connect superseded/closed/paused mid-handshake
    /// does NOT leave a zombie transport adopted on the client.
    var hasLiveTransportForTesting: Bool { transport != nil }

    private func handleInbound(_ message: WireMessage) async {
        switch message {
        case let .output(seq, bytes):
            await deliverOutput(seq: seq, bytes: bytes, wireBytes: message.wireByteCount)
        case let .exit(code):
            eventBroadcaster.yield(.exit(code: code))
            // The byte stream is over once the child exits. Finishing the wake stream ends
            // the consumer's wake loop; its final takeOutputBatch() drains any tail.
            outputWakeContinuation.finish()
            // `.exit` is data-class (it rode the windowed DATA sub-channel): credit it
            // immediately — it never enters the inbox.
            await transport?.noteOutputConsumed(wireBytes: message.wireByteCount)
        case let .title(text):
            eventBroadcaster.yield(.title(text))
        case .bell:
            eventBroadcaster.yield(.bell)
        case let .commandStatus(status):
            eventBroadcaster.yield(.commandStatus(status))
        case let .notification(title, body):
            eventBroadcaster.yield(.notification(title: title, body: body))
        case let .pong(timestampMS):
            recordPong(sentAtMS: timestampMS)
        default:
            // input/hello/resize/ack/bye/helloAck never arrive on the client inbound.
            // Ignore defensively.
            break
        }
    }

    /// Folds one pong into the smoothed RTT (EWMA α=0.25) and broadcasts the fresh value.
    /// The timestamp is OUR monotonic clock echoed verbatim, so the math never involves
    /// the host's clock. A stale pong from before a suspend can yield a huge sample; the
    /// EWMA absorbs it (and the next samples correct it).
    private func recordPong(sentAtMS: UInt64) {
        let nowMS = DispatchTime.now().uptimeNanoseconds / 1_000_000
        guard nowMS >= sentAtMS else { return }
        let sample = Double(nowMS - sentAtMS)
        let smoothed = smoothedRTTMS.map { $0 * 0.75 + sample * 0.25 } ?? sample
        smoothedRTTMS = smoothed
        eventBroadcaster.yield(.rtt(milliseconds: smoothed))
    }

    /// The dedup + contiguous-tracking core. Drops any `output` already delivered
    /// (`seq <= highestSeqFed`) — this is what makes a replayed tail splice in without a
    /// duplicate. A future seq beyond `highestSeqFed + 1` would be a gap; the transport
    /// guarantees ascending in-order delivery (replay tail then live, `docs/20` §8.3), so
    /// in practice every accepted output advances the counter by exactly one.
    private func deliverOutput(seq: Int64, bytes: Data, wireBytes: Int) async {
        guard seq > highestSeqFed else {
            // Duplicate (replayed) — drop, but still CREDIT it: the bytes crossed the wire
            // and were fully processed (by discarding); withholding the credit would leak
            // window capacity on every replay.
            await transport?.noteOutputConsumed(wireBytes: wireBytes)
            return
        }
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
        // Append-then-yield: the pending wake (bufferingNewest(1)) always observes a
        // complete inbox, so no chunk can be stranded without a wake. The wire byte count
        // rides along so takeOutputBatch can credit the consumption.
        outputInbox.append((bytes: bytes, wireBytes: wireBytes))
        outputWakeContinuation.yield(())
        surfaceFeed?(bytes)
        // Mark an ack as pending; the coalescing ticker sends it.
        ackPending = true
    }

    private func handleStreamEnded(error: Error?) {
        // Surface a disconnect (unless we are closing on purpose, or we ourselves are
        // tearing the old transport down to reconnect — in which case this end is
        // self-inflicted and a real `.disconnected` would queue a redundant reconnect).
        // ReconnectManager watches `events` / observes the thrown connect error.
        guard !closed, !tearingDown else { return }
        let reason = if let error { String(describing: error) } else { "stream ended (FIN)" }
        eventBroadcaster.yield(.disconnected(reason: reason))
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
                await flushAckIfPending()
            }
        }
    }

    /// Starts (or restarts) the RTT probe ticker: one `ping(now)` on the CONTROL channel
    /// every ``pingInterval``. Best-effort (`try?`) — a dropped probe just skips a sample.
    /// Re-created per connect so it always targets the live transport; cancelled on
    /// teardown/close beside the ack ticker.
    private func startPingTicker() {
        pingTask?.cancel()
        let interval = Self.pingInterval
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await sendPingProbe()
            }
        }
    }

    private func sendPingProbe() async {
        guard let transport else { return }
        let nowMS = DispatchTime.now().uptimeNanoseconds / 1_000_000
        try? await transport.sendPing(timestampMS: nowMS)
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
        guard let transport else { throw ClientError.invalidState("sendInput before connect") }
        try await transport.sendInput(bytes)
    }

    /// Sends a `resize`, remembering it so it is re-asserted after a reconnect.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        lastSentResize = (cols, rows, pxWidth, pxHeight)
        guard let transport else { throw ClientError.invalidState("sendResize before connect") }
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
        // Guard the teardown so the old inbound pump's self-inflicted end does not add a
        // spurious `.disconnected` on top of the explicit "paused" one we yield below.
        tearingDownDepth += 1
        await teardownTransport()
        tearingDownDepth -= 1
        eventBroadcaster.yield(.disconnected(reason: "paused (backgrounded)"))
    }

    /// App foregrounded: reconnect with the preserved `sessionID` + seq for a byte-exact
    /// resume. No-op if not paused / already closed.
    public func resume() async throws {
        guard paused, !closed else { return }
        paused = false
        guard let host, let port else { throw ClientError.invalidState("resume before first connect") }
        try await connect(host: host, port: port)
    }

    /// True while paused by ``pause()`` (diagnostics / reconnect gating).
    public var isPaused: Bool { paused }

    /// True once ``close()`` has permanently retired the client (diagnostics / reconnect gating).
    /// ``ReconnectManager`` consults this ALONGSIDE ``isPaused`` because the two deliberate-shutdown
    /// paths are NOT symmetric: ``pause()`` yields an explicit `.disconnected` AND sets `paused`,
    /// but ``close()`` sets `closed` and `finish()`es the event stream WITHOUT yielding `.disconnected`.
    /// A real transport drop that yielded `.disconnected` just before `close()` leaves that event
    /// BUFFERED in a subscriber ahead of the stream's finish — so a reconnect supervisor that gated
    /// only on `isPaused` would pop the stale drop after close and run a doomed `connect`-after-close
    /// campaign. Gating on `isClosed` too closes that race.
    public var isClosed: Bool { closed }

    /// Test-only: simulate a hard network loss — tear down the transport (cancelling the
    /// underlying NWConnections) WITHOUT sending a clean `bye`, exactly as an iOS TCP
    /// teardown or a NetBird path flap would. Preserves `sessionID` + `highestContiguousSeq`
    /// so a subsequent ``connect(...)`` is a byte-exact RETURNING_CLIENT resume. The
    /// surfaced ``output`` / ``events`` streams stay open (this is a drop, not a close).
    ///
    /// Marked underscored + documented as test-only; the production drop path is the
    /// transport failing on its own (handled by ``handleStreamEnded(error:)``).
    public func forceDropForTesting() async {
        await teardownTransport()
    }

    // MARK: Teardown

    /// Tears down only the transport + its pumps (NOT the surfaced streams) so a
    /// reconnect can replace them. Cancels the inbound + ack tasks and closes the
    /// transport (which cancels its forwarders and the underlying NWConnections).
    private func teardownTransport() async {
        let oldInbound = inboundTask
        inboundTask?.cancel()
        ackTask?.cancel()
        pingTask?.cancel()
        inboundTask = nil
        ackTask = nil
        pingTask = nil
        await transport?.close()
        transport = nil
        // Drain the old inbound pump to completion. `close()` above finished the old
        // inbound stream, so the pump is unwinding into `handleStreamEnded(error: nil)`.
        // Awaiting its `.value` here guarantees that self-inflicted end is fully processed
        // BEFORE the caller clears `tearingDown` — so its `.disconnected` is suppressed
        // deterministically (not by timing). The task never throws (`Task<Void, Never>`).
        await oldInbound?.value
    }

    /// Permanently closes the client: tears down the transport and finishes the
    /// surfaced streams. After this the client is unusable.
    public func close() async {
        guard !closed else { return }
        closed = true
        await flushAckIfPending()
        if let transport { try? await transport.sendBye() }
        await teardownTransport()
        outputWakeContinuation.finish()
        eventBroadcaster.finish()
    }
}
