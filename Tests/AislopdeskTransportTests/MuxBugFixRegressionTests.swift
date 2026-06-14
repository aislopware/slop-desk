import AislopdeskProtocol
import XCTest
@testable import AislopdeskTransport

/// Regression tests for the overnight bug-hunt fixes at the ``MuxNWConnection`` layer (headless,
/// in-memory links — no socket, no `HostServer`):
///   • [3] a DUPLICATE `channelOpen` for a live channel must NOT re-fire the host open hook
///     (double-spawn / orphaned-PTY leak).
///   • [4] a `channelClose` arriving BEFORE `setHostCloseHandler` must be BUFFERED + replayed
///     (else the pane's shell leaks — the open path buffered, the close path used to drop).
///   • [5] a HARD link failure must mark the connection `isDead` and make `openChannel` reject reuse
///     (so a reconnecting pane never opens onto a corpse the registry still pools).
final class MuxBugFixRegressionTests: XCTestCase {
    // MARK: - [3] duplicate channelOpen does not double-fire the host open hook

    func testDuplicateChannelOpenFiresHostOpenHandlerExactlyOnce() async throws {
        let (_, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)

        let opens = AtomicCounter()
        await host.setHostOpenHandler { _ in opens.bump() }
        await host.start()

        // Drive TWO identical channelOpen frames for the SAME id straight onto the host's DATA link
        // (a retransmit / duplicate). The first registers + spawns; the second must be suppressed.
        let frame = MuxEnvelopeCodec.encode(
            .channelOpen(channelID: 1, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0),
        )
        try await clientData.send(frame)
        try await clientData.send(frame)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(
            opens.value,
            1,
            "a duplicate channelOpen must not re-invoke the host open hook (no double-spawn)",
        )
    }

    // MARK: - [4] channelClose before setHostCloseHandler is buffered + replayed

    func testChannelCloseArrivingBeforeHandlerInstallIsBufferedAndReplayed() async throws {
        let (_, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.start()

        // An open then a close for the same id arrive in the accept→install gap (NO handler yet).
        try await clientData.send(MuxEnvelopeCodec.encode(
            .channelOpen(channelID: 1, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0),
        ))
        try await clientData.send(MuxEnvelopeCodec.encode(.channelClose(channelID: 1)))
        try await Task.sleep(for: .milliseconds(80)) // let the receive loop route both frames

        // Install the handlers in production order (open first, then close): the buffered open replays
        // (would spawn the shell), then the buffered close replays (reaps it — no leaked PTY).
        let opened = AtomicList()
        let closed = AtomicList()
        await host.setHostOpenHandler { open in opened.append(open.channelID) }
        await host.setHostCloseHandler { id in closed.append(id) }

        XCTAssertEqual(opened.value, [1], "the buffered open replays when the open handler installs")
        XCTAssertEqual(
            closed.value,
            [1],
            "the buffered close replays when the close handler installs (no leaked shell)",
        )
    }

    // MARK: - [5] hard link failure marks the connection dead and rejects reuse

    func testHardLinkFailureMarksConnectionDeadAndRejectsOpenChannel() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let client = MuxNWConnection(role: .client, controlLink: clientControl, dataLink: clientData)
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.setHostOpenHandler { open in Task { await host.sendOpenAck(open.channelID, accepted: true) } }
        await client.start()
        await host.start()

        _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
        let liveBefore = await client.isDead
        XCTAssertFalse(liveBefore, "a freshly-opened connection is not dead")

        // Simulate a TCP RST / NetBird flap on the DATA link → both ends' data receive loops error.
        clientData.fail()
        try await Self.waitUntil { await client.isDead }

        let dead = await client.isDead
        XCTAssertTrue(dead, "a hard link failure marks the connection dead (isDead)")

        do {
            _ = try await client.openChannel(sessionID: UUID(), lastReceivedSeq: 0)
            XCTFail("openChannel must reject a dead (link-failed) connection")
        } catch {
            // expected — a reconnecting pane must not open onto the corpse
        }
    }

    // MARK: - [R11] channelOpen on the CONTROL link is never legitimate → dropped (memory-DoS cap)

    /// A `channelOpen` only ever arrives on the DATA link (`openChannel` → `dataLink.send`). The
    /// per-connection cap that bounds the router table is `link == .data`, so a hostile peer could
    /// spam channelOpen frames on the CONTROL link to grow `controlTable` without bound (the last
    /// router-table memory-DoS vector). The R11 guard drops a control-link channelOpen BEFORE it
    /// reaches `MuxRoutingCore.route` — so neither the control table grows NOR the host open hook fires.
    func testChannelOpenOnControlLinkIsDroppedAndDoesNotGrowControlTable() async throws {
        let (clientControl, hostControl) = InMemoryMuxLink.pair()
        let (_, hostData) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)

        let opens = AtomicCounter()
        await host.setHostOpenHandler { _ in opens.bump() }
        await host.start()

        // Storm distinct channelOpen ids straight onto the host's CONTROL link.
        for id in UInt32(1)...50 {
            try await clientControl.send(MuxEnvelopeCodec.encode(
                .channelOpen(channelID: id, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0),
            ))
        }
        try await Task.sleep(for: .milliseconds(120)) // let the control receive loop route them all

        XCTAssertEqual(opens.value, 0, "a control-link channelOpen must NOT spawn a session (never legitimate there)")
        let controlTableCount = await host.controlTableStateCountForTesting
        XCTAssertEqual(controlTableCount, 0, "a control-link channelOpen storm must not grow the control router table")
    }

    // MARK: - [R12 #1] channelOpen/channelClose churn does not grow the router tables unbounded

    /// On the HOST the PEER chooses channel ids. A hostile/buggy peer that repeatedly opens then closes
    /// a channel with a FRESH id each cycle keeps the LIVE channel count at ~0 (so the per-connection cap
    /// never trips) yet, before the fix, left a permanent `.halfClosed` dataTable entry AND — because the
    /// attacker omits the control-link close — a zombie `.open` controlTable entry + an orphaned control
    /// sub-channel per cycle: unbounded growth driven by tiny frames. The ChannelTable eviction ring +
    /// the symmetric control-side close on the DATA-link close bound BOTH tables.
    func testChannelOpenCloseChurnDoesNotGrowRouterTablesUnbounded() async throws {
        let (_, hostControl) = InMemoryMuxLink.pair()
        let (clientData, hostData) = InMemoryMuxLink.pair()
        let host = MuxNWConnection(role: .host, controlLink: hostControl, dataLink: hostData)
        await host.setHostOpenHandler { _ in }
        await host.setHostCloseHandler { _ in }
        await host.start()

        // Churn well past the eviction-ring capacity (1024), DATA-link ONLY (the attacker omits the
        // control-link close), with a fresh distinct id every cycle.
        for id in stride(from: UInt32(2), through: 4000, by: 2) {
            try await clientData.send(MuxEnvelopeCodec.encode(
                .channelOpen(channelID: id, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0),
            ))
            try await clientData.send(MuxEnvelopeCodec.encode(.channelClose(channelID: id)))
        }
        // A sentinel OPEN left live: FIFO on the data link guarantees every churn frame was processed
        // before it goes live, so observing it bounds the whole burst as drained.
        let sentinel: UInt32 = 99999
        try await clientData.send(MuxEnvelopeCodec.encode(
            .channelOpen(channelID: sentinel, sessionID: UUID(), lastReceivedSeq: 0, channelClass: 0),
        ))
        try await Self.waitUntil(timeout: 20) { await host.hasLiveChannels }

        let dataCount = await host.dataTableStateCountForTesting
        let controlCount = await host.controlTableStateCountForTesting
        // ~2000 cycles ran; without the fix each table would hold ~2000 entries. Bounded now to
        // (ring cap 1024) + (the 1 live sentinel), with headroom.
        XCTAssertLessThanOrEqual(dataCount, 1100, "dataTable bounded by the eviction ring, not ~2000")
        XCTAssertLessThanOrEqual(controlCount, 1100, "controlTable bounded (symmetric close + ring), not ~2000")
        let dead = await host.isDead
        XCTAssertFalse(dead, "the connection stays healthy throughout the churn")
    }

    // MARK: - [R12 #2] duplicate same-side mux preamble closes the displaced half (fd-leak guard)

    /// The pure pairing decision behind `HostTransport.associateMux`: a CONTROL+DATA pair completes, but
    /// a SECOND same-side half (two CONTROLs / two DATAs before the opposite peer arrives) is a re-park
    /// that DISPLACES the already-parked half — which must be closed so its NWConnection/fd does not leak.
    func testMuxPairingClosesDisplacedSameSideHalf() {
        // First arrival of either side: parks, nothing displaced.
        XCTAssertEqual(
            MuxPairing.decide(existingHasControl: false, existingHasData: false, isControl: true),
            .init(paired: false, closesDisplacedSameSide: false),
        )
        XCTAssertEqual(
            MuxPairing.decide(existingHasControl: false, existingHasData: false, isControl: false),
            .init(paired: false, closesDisplacedSameSide: false),
        )

        // Opposite side arrives → pair completes, nothing displaced.
        XCTAssertEqual(
            MuxPairing.decide(existingHasControl: true, existingHasData: false, isControl: false),
            .init(paired: true, closesDisplacedSameSide: false),
        )
        XCTAssertEqual(
            MuxPairing.decide(existingHasControl: false, existingHasData: true, isControl: true),
            .init(paired: true, closesDisplacedSameSide: false),
        )

        // SAME side arrives again (duplicate) → re-park AND close the displaced half (the leak guard).
        XCTAssertEqual(
            MuxPairing.decide(existingHasControl: true, existingHasData: false, isControl: true),
            .init(paired: false, closesDisplacedSameSide: true),
        )
        XCTAssertEqual(
            MuxPairing.decide(existingHasControl: false, existingHasData: true, isControl: false),
            .init(paired: false, closesDisplacedSameSide: true),
        )
    }

    // MARK: - helpers

    /// Polls `condition` (an async predicate) until true or the timeout elapses.
    private static func waitUntil(timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out")
    }
}

/// A trivial thread-safe counter usable from `@Sendable` hooks (the host open hook fires off-actor).
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock()
        n += 1
        lock.unlock()
    }

    var value: Int { lock.lock()
        defer { lock.unlock() }
        return n
    }
}

/// A thread-safe ordered list usable from `@Sendable` hooks.
final class AtomicList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UInt32] = []
    func append(_ x: UInt32) { lock.lock()
        items.append(x)
        lock.unlock()
    }

    var value: [UInt32] { lock.lock()
        defer { lock.unlock() }
        return items
    }
}
