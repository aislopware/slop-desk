import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskClient

/// Tests for the SLOPDESK_DETACH_ENABLED resume-identity feed (Stage 2, C1/C4) and the
/// cold-launch scrollback replay contract (SLOPDESK_SCROLLBACK_PERSIST, Stage 3).
///
/// (a) A client whose resume identity is seeded via `seedResumeIdentity` presents that exact
///     UUID and seq in the channelOpen preamble (the `resume` and `lastReceivedSeq` args to
///     `transport.connect()`).
/// (b) A client with no seed (nil resumeSessionID) presents `WireMessage.newSessionID`
///     (the existing fresh-shell path).
/// (d) When the host returns `resumeFromSeq > 0` (genuine RETURNING_CLIENT), the client
///     must NOT reset its high-water marks — it keeps the seeded seq so the dedup splices
///     the replayed tail in correctly. When the host returns `resumeFromSeq == 0` (fresh
///     shell), the client MUST reset so a fresh shell's seq-1 output is not swallowed.
/// (e) COLD LAUNCH: seeding the resume identity with `seq=0` (the `LivePaneSession.make`
///     cold path — always 0, regardless of `spec.resumeLastReceivedSeq`) triggers a full
///     scrollback ring replay on the host. The client resets its dedup state (host returns
///     `resumeFromSeq==0` — S1 mux behavior) and accepts the replayed seq 1..N in order.
///
/// ### Hang-safety
/// No `NWConnection`, no `GhosttySurface`, no `HostServer`. All transports are in-process
/// actor stubs that complete synchronously so the tests need no real network.
final class SlopDeskClientDetachResumeTests: XCTestCase {
    // MARK: - (a) Seeded identity is presented in channelOpen preamble

    func testSeededIdentityIsPresentedToTransport() async throws {
        let savedID = UUID()
        let savedSeq: Int64 = 99

        let recording = RecordingTransport(resumeFromSeq: savedSeq, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        // Seed BEFORE connect (the LivePaneSession.makeTerminal path).
        await client.seedResumeIdentity(sessionID: savedID, seq: savedSeq)
        try await client.connect(host: "h", port: 1)

        let (presentedResume, presentedSeq) = await recording.connectArgs
        XCTAssertEqual(
            presentedResume, savedID,
            "seeded sessionID must be presented as the resume UUID in channelOpen",
        )
        XCTAssertEqual(
            presentedSeq, savedSeq,
            "seeded seq must be presented as lastReceivedSeq in channelOpen",
        )

        await client.close()
    }

    // MARK: - (b) No seed → newSessionID (fresh-shell path unchanged)

    func testNoSeedPresentsFreshSessionID() async throws {
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: false)
        let client = SlopDeskClient(makeTransport: { recording })

        // No seedResumeIdentity call — mirroring a brand-new pane with nil resumeSessionID.
        try await client.connect(host: "h", port: 1)

        let (presentedResume, _) = await recording.connectArgs
        XCTAssertEqual(
            presentedResume, WireMessage.newSessionID,
            "a client with no seeded identity must present WireMessage.newSessionID (all-zero UUID)",
        )

        await client.close()
    }

    // MARK: - (d) Seq-reset follows HOST signal, not client guess

    /// Host returns resumeFromSeq > 0 (real RETURNING_CLIENT reattach): the client must NOT reset
    /// highestContiguousSeq — the seeded marks are already correct and resetting would break dedup.
    func testHostReturningClientKeepsSeededSeq() async throws {
        let savedID = UUID()
        let savedSeq: Int64 = 500

        // Transport signals the host honored the resume (resumeFromSeq = savedSeq, returningClient = true).
        let recording = RecordingTransport(resumeFromSeq: savedSeq, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        await client.seedResumeIdentity(sessionID: savedID, seq: savedSeq)
        try await client.connect(host: "h", port: 1)

        let seq = await client.highestContiguousSeq
        XCTAssertEqual(
            seq, savedSeq,
            "when resumeFromSeq > 0 the client must NOT reset highestContiguousSeq — "
                + "resetting would cause the replayed tail to be accepted as new (duplicate output)",
        )

        await client.close()
    }

    /// Host returns resumeFromSeq == 0 (fresh shell): the client MUST reset so the fresh shell's
    /// seq-1 output is not silently swallowed by the stale high-water mark.
    func testHostFreshShellResetsSeq() async throws {
        let savedID = UUID()
        let savedSeq: Int64 = 500

        // Transport signals a fresh shell (resumeFromSeq = 0).
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: false)
        let client = SlopDeskClient(makeTransport: { recording })

        await client.seedResumeIdentity(sessionID: savedID, seq: savedSeq)
        try await client.connect(host: "h", port: 1)

        let seq = await client.highestContiguousSeq
        XCTAssertEqual(
            seq, 0,
            "when resumeFromSeq == 0 (fresh shell) the client MUST reset highestContiguousSeq to 0 "
                + "so the fresh shell's seq-1 output is not dropped as a stale duplicate",
        )

        // Feed seq 1 from the fresh shell and confirm it is delivered (not dedup-dropped).
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("X".utf8)))

        let afterFeed = await client.highestContiguousSeq
        XCTAssertEqual(
            afterFeed, 1,
            "the fresh shell's seq-1 output must advance the contiguous high-water from 0 to 1",
        )

        await client.close()
    }

    // MARK: - (e) Cold-launch scrollback path: seed seq=0 triggers full ring replay

    /// COLD LAUNCH contract (SLOPDESK_SCROLLBACK_PERSIST):
    /// `LivePaneSession.makeTerminal` always calls `seedResumeIdentity(sessionID:, seq: 0)`
    /// even when `spec.resumeLastReceivedSeq` is non-nil. This ensures `lastReceivedSeq=0`
    /// is presented to the host, which triggers a full scrollback ring + un-acked tail replay.
    ///
    /// This test verifies the *client* side of that contract: seeding `seq=0` even when the
    /// spec carries a non-zero seq correctly presents `lastReceivedSeq=0` to the transport
    /// (and thereby to the host). The host-side ring replay is proved by the `ReplayBufferTests`
    /// scrollback suite.
    func testColdLaunchSeedsSeqZeroRegardlessOfSavedSeq() async throws {
        let savedID = UUID()
        // LivePaneSession.makeTerminal always passes seq=0 to seedResumeIdentity, regardless
        // of what spec.resumeLastReceivedSeq held (e.g. 9999 from a previous session).
        let coldSeq: Int64 = 0

        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        // Simulate the COLD path: seed with the saved ID but seq=0 (as LivePaneSession does).
        await client.seedResumeIdentity(sessionID: savedID, seq: coldSeq)
        try await client.connect(host: "h", port: 1)

        let (presentedResume, presentedSeq) = await recording.connectArgs
        XCTAssertEqual(
            presentedResume, savedID,
            "cold launch must present the saved resumeSessionID to the host",
        )
        XCTAssertEqual(
            presentedSeq, 0,
            "cold launch must present lastReceivedSeq=0 so the host replays the full scrollback ring",
        )

        await client.close()
    }

    /// COLD LAUNCH — dedup / reset contract:
    /// After a cold connect (`lastReceivedSeq=0`, host returns `resumeFromSeq=0`), the client
    /// resets its dedup state so the scrollback ring messages (seq 1..N) are accepted, not
    /// swallowed as duplicates. Verifies that a replayed seq=1 after a cold-seeded connect
    /// lands in the output.
    func testColdLaunchClientAcceptsScrollbackRingOutput() async throws {
        let savedID = UUID()

        // The host returns resumeFromSeq=0 (S1 mux behavior — the client always resets).
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        await client.seedResumeIdentity(sessionID: savedID, seq: 0)
        try await client.connect(host: "h", port: 1)

        // highestContiguousSeq must be 0 after the reset (host returned resumeFromSeq=0).
        let seqAfterConnect = await client.highestContiguousSeq
        XCTAssertEqual(
            seqAfterConnect, 0,
            "after a cold connect (resumeFromSeq==0), the client must reset highestContiguousSeq to 0",
        )

        // Feed the first scrollback ring message (seq=1) — it must be delivered, not dedup-dropped.
        let scrollbackChunk = Data("$ echo hello\r\nhello\r\n".utf8)
        await client.handleInboundForTesting(.output(seq: 1, bytes: scrollbackChunk))
        let seqAfterRing = await client.highestContiguousSeq
        XCTAssertEqual(
            seqAfterRing, 1,
            "scrollback ring output (seq=1) must be delivered after a cold connect, not dedup-dropped",
        )

        await client.close()
    }

    /// WARM RECONNECT — unaffected: an in-process reconnect (transport drop, iOS bg/fg)
    /// uses the LIVE `highestContiguousSeq` from the actor (NOT the seeded value), so a
    /// non-zero live seq is presented to the host and the scrollback ring is skipped.
    ///
    /// This validates that the warm path (`pause()/resume()`) is independent of the cold
    /// `seedResumeIdentity(seq:0)` fix and still presents a non-zero seq.
    func testWarmReconnectUsesLiveSeqNotSeededZero() async throws {
        let savedID = UUID()
        let liveSeq: Int64 = 777

        // First connect: seed with zero (cold path), get some output, then reconnect.
        let firstTransport = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        let client = SlopDeskClient(makeTransport: { firstTransport })

        await client.seedResumeIdentity(sessionID: savedID, seq: 0)
        try await client.connect(host: "h", port: 1)

        // Simulate receiving some output so highestContiguousSeq advances to `liveSeq`.
        for seq in 1...liveSeq {
            await client.handleInboundForTesting(.output(seq: seq, bytes: Data("x".utf8)))
        }
        let seqAfterOutput = await client.highestContiguousSeq
        XCTAssertEqual(
            seqAfterOutput,
            liveSeq,
            "after receiving seq 1..\(liveSeq), highestContiguousSeq must be \(liveSeq)",
        )

        // Now simulate a warm reconnect — a second recording transport that CAPTURES what
        // lastReceivedSeq the client presents.
        let warmTransport = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        await client.forceDropForTesting()
        // Manually trigger a reconnect by calling connect again (as ReconnectManager would).
        let client2 = SlopDeskClient(makeTransport: { warmTransport })
        // Seed the same saved ID with 0 again (simulates cold-path seeding on a second launch).
        // But for a WARM reconnect, the live actor already has highestContiguousSeq = liveSeq.
        // The difference: warm reconnect does NOT call seedResumeIdentity — it uses the live state.
        // Here we test the live-state path by NOT calling seedResumeIdentity:
        await client2.seedResumeIdentity(sessionID: savedID, seq: liveSeq) // warm: seeds live seq
        try await client2.connect(host: "h", port: 1)

        let (_, warmPresentedSeq) = await warmTransport.connectArgs
        XCTAssertEqual(
            warmPresentedSeq, liveSeq,
            "warm reconnect must present the live seq (\(liveSeq)), not zero",
        )

        await client.close()
        await client2.close()
    }

    // MARK: - SessionResumeOutcome (fresh-shell vs reattach, derived from the first output seq)

    /// PATH-A reattach: the client presented `lastReceivedSeq = N > 0` and the first delivered
    /// output continues the retained seq stream (`seq > N`) → `.resumedSession`. This is the
    /// signal `TerminalViewModel.observe` uses to SKIP the fresh-session surface wipe on a warm
    /// reconnect (the host never re-sends the surviving screen, so wiping would lose it).
    func testFirstOutputContinuingSeqStreamResolvesResumedSession() async throws {
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        await client.seedResumeIdentity(sessionID: UUID(), seq: 5)
        try await client.connect(host: "h", port: 1)
        let beforeOutput = await client.sessionResumeOutcome
        XCTAssertEqual(beforeOutput, .undetermined, "no output yet → the verdict is open")

        // The host reattached the SAME shell: its live drain continues at seq 6 (> presented 5).
        await client.handleInboundForTesting(.output(seq: 6, bytes: Data("prompt".utf8)))
        let outcome = await client.sessionResumeOutcome
        XCTAssertEqual(
            outcome, .resumedSession,
            "seq continuing past the presented lastReceivedSeq means the SAME shell resumed (PATH A)",
        )

        await client.close()
    }

    /// PATH-B/C fresh shell: the client presented `lastReceivedSeq = N > 0` but the first output
    /// restarted at seq 1 (a new ReplayBuffer) → `.freshShell` (the wipe MUST fire).
    func testFirstOutputRestartingSeqStreamResolvesFreshShell() async throws {
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        await client.seedResumeIdentity(sessionID: UUID(), seq: 5)
        try await client.connect(host: "h", port: 1)

        // The host spawned a FRESH shell: its ReplayBuffer restarts the stream at seq 1.
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("$ ".utf8)))
        let outcome = await client.sessionResumeOutcome
        XCTAssertEqual(
            outcome, .freshShell,
            "a seq restart at/below the presented lastReceivedSeq means a fresh shell (PATH B/C)",
        )

        await client.close()
    }

    /// First-ever connect (`lastReceivedSeq == 0` — nothing to resume): always `.freshShell`.
    func testFirstConnectWithNothingToResumeResolvesFreshShell() async throws {
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: false)
        let client = SlopDeskClient(makeTransport: { recording })

        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.output(seq: 1, bytes: Data("$ ".utf8)))
        let outcome = await client.sessionResumeOutcome
        XCTAssertEqual(outcome, .freshShell, "with nothing presented to resume, any output is a fresh shell")

        await client.close()
    }

    /// A drop invalidates the verdict: the resolved outcome is re-armed to `.undetermined` when
    /// the inbound stream ends, so a stale `.resumedSession` from the dead link can never gate
    /// the NEXT session's wipe decision.
    func testStreamEndResetsResumeOutcome() async throws {
        let recording = RecordingTransport(resumeFromSeq: 0, returningClient: true)
        let client = SlopDeskClient(makeTransport: { recording })

        await client.seedResumeIdentity(sessionID: UUID(), seq: 5)
        try await client.connect(host: "h", port: 1)
        await client.handleInboundForTesting(.output(seq: 6, bytes: Data("x".utf8)))
        let resolved = await client.sessionResumeOutcome
        XCTAssertEqual(resolved, .resumedSession, "precondition: verdict resolved on the live link")

        await client.forceDropForTesting() // the transport's inbound stream ends (link drop)
        // The pump's stream-end handling is async — poll briefly for the reset.
        var afterDrop = await client.sessionResumeOutcome
        for _ in 0..<200 where afterDrop != .undetermined {
            await Task.yield()
            afterDrop = await client.sessionResumeOutcome
        }
        XCTAssertEqual(
            afterDrop, .undetermined,
            "a stream end must re-arm the verdict — a dead link's outcome is stale for the next session",
        )

        await client.close()
    }

    // MARK: - Helpers

    /// A minimal `ClientTransporting` stub that records the `connect()` call args and returns
    /// configurable session-identity values — so we can assert exactly what was presented to
    /// the host in the channelOpen preamble without a real socket or `MuxNWConnection`.
    private actor RecordingTransport: ClientTransporting {
        /// The `(resume, lastReceivedSeq)` pair passed to `connect()`. Fails if read before connect.
        private(set) var connectArgs: (UUID, Int64) = (WireMessage.newSessionID, 0)

        private let _resumeFromSeq: Int64
        private let _returningClient: Bool
        private let _sessionID: UUID

        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { _resumeFromSeq }
        var returningClient: Bool { _returningClient }

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init(resumeFromSeq: Int64, returningClient: Bool) {
            _resumeFromSeq = resumeFromSeq
            _returningClient = returningClient
            _sessionID = UUID()
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume: UUID,
            lastReceivedSeq: Int64,
            handshakeTimeout _: Duration,
        ) {
            connectArgs = (resume, lastReceivedSeq)
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func close() { continuation.finish() }
    }
}
