import XCTest
@testable import SlopDeskVideoHost

/// Regression pins for the host mux's flow / reply-stamp reap (audit B-videohost-flow-reap) —
/// the PURE ``MuxFlowTable`` decisions ``NWVideoMuxDatagramTransport`` runs under its lock, over
/// a bare-class fake flow (no socket, per the video hang-safety rule).
///
/// The two defects pinned here:
/// 1. A peer that silently vanishes (wifi switch — UDP, no FIN, no `.failed`) used to leak one
///    media + one cursor `NWConnection` per client flow rebuild, forever: the flow tables had NO
///    reap path at all.
/// 2. A cursor prime for a NEVER-admitted channelID (discovery poll whose media-socket request
///    was lost) stamped the cursor reply map unconditionally and nothing ever removed it.
final class MuxFlowTableReapTests: XCTestCase {
    /// Faux NWConnection — the table only needs object identity (same seam as
    /// `VideoMuxReadmitRoutingTests.FakeConn`).
    private final class FakeFlow {}

    /// Mirrors `KeepaliveTiming.idleTimeout` semantics; a small literal keeps the arithmetic obvious.
    private let idleTimeout: TimeInterval = 30

    private func makeTable() -> MuxFlowTable<FakeFlow> { MuxFlowTable<FakeFlow>(idleTimeout: idleTimeout) }

    // MARK: - Finding 1: orphaned flows from a silent client rebuild must be reaped

    func testOrphanedFlowPairFromClientRebuildIsReapedAfterIdleTimeout() {
        var table = makeTable()
        let mediaA = FakeFlow(), cursorA = FakeFlow()
        table.accept(mediaA, isMedia: true, now: 0)
        table.accept(cursorA, isMedia: false, now: 0)
        table.stampMediaReply(channelID: 1, flow: mediaA)
        table.stampCursorReply(channelID: 1, flow: cursorA, now: 0, isAdmitted: true)

        // Wifi switch: the client vanishes silently, then rebuilds on fresh ephemeral source ports.
        // The lane's reply stamps re-point to the NEW flows; the old pair goes silent forever.
        let mediaB = FakeFlow(), cursorB = FakeFlow()
        table.accept(mediaB, isMedia: true, now: 10)
        table.accept(cursorB, isMedia: false, now: 10)
        table.stampMediaReply(channelID: 1, flow: mediaB)
        table.stampCursorReply(channelID: 1, flow: cursorB, now: 10, isAdmitted: true)
        table.noteInbound(mediaB, now: 39) // the live client keeps talking (keepalives)

        let reaped = table.reap(now: 40, isAdmitted: { _ in true })
        XCTAssertEqual(
            Set(reaped.map(ObjectIdentifier.init)),
            [ObjectIdentifier(mediaA), ObjectIdentifier(cursorA)],
            "the orphaned pair (silent ≥ idleTimeout, referenced by no reply stamp) is reaped",
        )
        XCTAssertEqual(table.flowCount, 2, "only the rebuilt client's live pair stays tracked")
        XCTAssertTrue(table.mediaReplyFlow(for: 1) === mediaB, "the live lane's reply stamps are untouched")
        XCTAssertTrue(table.cursorReplyFlow(for: 1) === cursorB)
    }

    func testFlowReferencedByAReplyStampIsNeverReapedHoweverIdle() {
        // A live lane's cursor flow receives NOTHING after its one prime — inbound-idleness alone
        // must never kill the flow a channel's sends ride on.
        var table = makeTable()
        let cursorA = FakeFlow()
        table.accept(cursorA, isMedia: false, now: 0)
        table.stampCursorReply(channelID: 5, flow: cursorA, now: 0, isAdmitted: true)

        XCTAssertTrue(table.reap(now: 1000, isAdmitted: { _ in true }).isEmpty)
        XCTAssertEqual(table.flowCount, 1)
        XCTAssertTrue(table.cursorReplyFlow(for: 5) === cursorA)
    }

    func testUnreferencedFlowBecomesReapableOnlyAfterItsLaneRetires() {
        var table = makeTable()
        let mediaA = FakeFlow()
        table.accept(mediaA, isMedia: true, now: 0)
        table.stampMediaReply(channelID: 3, flow: mediaA)

        // Referenced → protected even when long idle.
        XCTAssertTrue(table.reap(now: 100, isAdmitted: { _ in true }).isEmpty)

        // Lane retired (bye / lane reaper) → the stamp is gone → the idle flow ages out.
        table.retireLane(3)
        let reaped = table.reap(now: 100, isAdmitted: { _ in false })
        XCTAssertEqual(reaped.map(ObjectIdentifier.init), [ObjectIdentifier(mediaA)])
        XCTAssertEqual(table.flowCount, 0)
    }

    func testInboundRefreshPreventsFlowReap() {
        var table = makeTable()
        let mediaA = FakeFlow()
        table.accept(mediaA, isMedia: true, now: 0)
        table.noteInbound(mediaA, now: 25)

        XCTAssertTrue(table.reap(now: 40, isAdmitted: { _ in false }).isEmpty, "silent 15 s < idleTimeout")
        let reaped = table.reap(now: 56, isAdmitted: { _ in false })
        XCTAssertEqual(reaped.map(ObjectIdentifier.init), [ObjectIdentifier(mediaA)], "silent 31 s ≥ idleTimeout")
    }

    func testFlowDidResetForgetsEverythingAndReapNeverReportsItAgain() {
        // A reaper cancel() re-enters flowDidReset via `.cancelled` — the double-removal must be
        // idempotent, and a reset flow must leave no dangling last-inbound record for later ticks.
        var table = makeTable()
        let mediaA = FakeFlow()
        table.accept(mediaA, isMedia: true, now: 0)
        table.stampMediaReply(channelID: 9, flow: mediaA)

        table.flowDidReset(mediaA, isMedia: true)
        XCTAssertEqual(table.flowCount, 0)
        XCTAssertNil(table.mediaReplyFlow(for: 9), "reply stamps pointing at the dead flow are dropped")
        XCTAssertTrue(table.reap(now: 100, isAdmitted: { _ in false }).isEmpty, "no dangling record to re-reap")
        table.flowDidReset(mediaA, isMedia: true) // idempotent re-entry
        XCTAssertEqual(table.flowCount, 0)
    }

    // MARK: - Finding 2: never-admitted reply stamps must be TTL-swept, admitted ones kept

    func testNeverAdmittedCursorStampIsSweptAfterIdleTimeout() {
        // Discovery poll on a lossy link: the cursor prime lands, every media-socket list-request
        // retransmit is lost → the lane is never admitted, never retired. The stamp must not
        // outlive idleTimeout.
        var table = makeTable()
        let cursor = FakeFlow()
        table.accept(cursor, isMedia: false, now: 0)
        for channelID: UInt32 in 100...140 {
            table.stampCursorReply(channelID: channelID, flow: cursor, now: 0, isAdmitted: false)
        }

        _ = table.reap(now: idleTimeout, isAdmitted: { _ in false })
        for channelID: UInt32 in 100...140 {
            XCTAssertNil(table.cursorReplyFlow(for: channelID), "never-admitted stamp \(channelID) must be swept")
        }
    }

    func testCursorPrimeRacingAheadOfHelloKeepsItsStampOnceAdmitted() {
        // The one legitimate unadmitted stamp: the prime beats the media hello. The client never
        // re-primes, so once the lane IS admitted the stamp must survive the sweep.
        var table = makeTable()
        let cursor = FakeFlow()
        table.accept(cursor, isMedia: false, now: 0)
        table.stampCursorReply(channelID: 7, flow: cursor, now: 0, isAdmitted: false)

        // Hello arrived moments later; the daemon minted + admitted lane 7.
        _ = table.reap(now: idleTimeout, isAdmitted: { $0 == 7 })
        XCTAssertTrue(table.cursorReplyFlow(for: 7) === cursor, "an admitted lane's primed flow is durable")
        // And the record is discarded, not re-checked forever: a later un-admission (retire) is
        // handled by retireLane, not by this sweep.
    }

    func testNeverAdmittedMediaBootstrapStampIsSweptAfterIdleTimeout() {
        // Symmetric media-side hole: a hello/list bootstrap stamp whose mint/answer never completed.
        var table = makeTable()
        let media = FakeFlow()
        table.accept(media, isMedia: true, now: 0)
        table.stampMediaBootstrap(channelID: 55, flow: media, now: 0)

        _ = table.reap(now: idleTimeout, isAdmitted: { _ in false })
        XCTAssertNil(table.mediaReplyFlow(for: 55))
    }

    func testStaleStampSweepUnprotectsItsOrphanFlowInTheSameTick() {
        // Ordering pin: rule 1 (stamp sweep) must run BEFORE rule 2's reference computation, or a
        // leaked never-admitted stamp would shield its orphaned flow from the reap forever.
        var table = makeTable()
        let cursor = FakeFlow()
        table.accept(cursor, isMedia: false, now: 0)
        table.stampCursorReply(channelID: 200, flow: cursor, now: 0, isAdmitted: false)

        let reaped = table.reap(now: idleTimeout, isAdmitted: { _ in false })
        XCTAssertEqual(reaped.map(ObjectIdentifier.init), [ObjectIdentifier(cursor)])
        XCTAssertNil(table.cursorReplyFlow(for: 200))
        XCTAssertEqual(table.flowCount, 0)
    }

    // MARK: - Shutdown

    func testRemoveAllReturnsEveryTrackedFlowExactlyOnce() {
        var table = makeTable()
        let media = FakeFlow(), cursor = FakeFlow()
        table.accept(media, isMedia: true, now: 0)
        table.accept(cursor, isMedia: false, now: 0)
        table.stampMediaReply(channelID: 1, flow: media)

        let all = table.removeAll()
        XCTAssertEqual(
            Set(all.map(ObjectIdentifier.init)),
            [ObjectIdentifier(media), ObjectIdentifier(cursor)],
        )
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(table.flowCount, 0)
        XCTAssertNil(table.mediaReplyFlow(for: 1))
    }
}
