import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

/// In-order decode admission (the `frontier = N−2` -12909 class fix). Pure, wrap-aware.
final class DecodeSequencerTests: XCTestCase {
    private func frame(_ id: UInt32, kf: Bool = false) -> ReassembledFrame {
        ReassembledFrame(frameID: id, keyframe: kf, crisp: false, avcc: Data([0x1]))
    }

    private func ids(_ frames: [ReassembledFrame]) -> [UInt32] { frames.map(\.frameID) }

    func testInOrderCompletionsReleaseImmediately() {
        var sq = DecodeSequencer()
        XCTAssertEqual(ids(sq.noteCompleted(frame(10, kf: true))), [10])
        XCTAssertEqual(ids(sq.noteCompleted(frame(11))), [11])
        XCTAssertEqual(ids(sq.noteCompleted(frame(12))), [12])
        XCTAssertEqual(sq.nextExpected, 13)
    }

    /// THE MEASURED CLASS: small frame N completes while big N−1 still reassembles (late parity).
    func testOutOfOrderHeldThenReleasedInOrder() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        XCTAssertEqual(ids(sq.noteCompleted(frame(12))), [], "N completed ahead of N−1 — held, not VT-fed")
        XCTAssertEqual(ids(sq.noteCompleted(frame(11))), [11, 12], "gap closes → both release, in order")
        XCTAssertEqual(sq.nextExpected, 13)
    }

    func testDeclaredLossSkipsTheHole() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        XCTAssertEqual(ids(sq.noteCompleted(frame(12))), [])
        XCTAssertEqual(ids(sq.noteCompleted(frame(13))), [])
        // The reassembler declares 11 unrecoverable: the hole resolves, 12+13 release in order.
        XCTAssertEqual(ids(sq.noteLost(frameID: 11)), [12, 13])
        XCTAssertEqual(sq.nextExpected, 14)
    }

    func testLossAheadRemembersOutOfOrderDeclarations() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        // Losses can be declared out of order (drain loop): 12 declared before 11.
        XCTAssertEqual(ids(sq.noteLost(frameID: 12)), [])
        XCTAssertEqual(ids(sq.noteCompleted(frame(13))), [])
        XCTAssertEqual(ids(sq.noteLost(frameID: 11)), [13], "11 closes the gap, 12 skips via lostAhead")
        XCTAssertEqual(sq.nextExpected, 14)
    }

    func testKeyframeBypassesGapAndDropsObsoleteHeld() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        XCTAssertEqual(ids(sq.noteCompleted(frame(12))), []) // held behind missing 11
        // An IDR lands (recovery): releases NOW; held #12 (older than the kf) is obsolete.
        XCTAssertEqual(ids(sq.noteCompleted(frame(20, kf: true))), [20])
        XCTAssertEqual(sq.nextExpected, 21)
        XCTAssertEqual(ids(sq.noteCompleted(frame(21))), [21], "stream continues past the kf")
    }

    func testKeyframeKeepsNewerHeldFrames() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true)) // expected 11
        XCTAssertEqual(ids(sq.noteCompleted(frame(16))), [], "held behind the 11..15 gap (within maxGap)")
        XCTAssertEqual(
            ids(sq.noteCompleted(frame(15, kf: true))),
            [15, 16],
            "kf releases immediately AND the newer held frame follows in order",
        )
        XCTAssertEqual(sq.nextExpected, 17)
    }

    func testOverflowValveFlushesInOrder() {
        var sq = DecodeSequencer(maxHeld: 2, maxGap: 6)
        _ = sq.noteCompleted(frame(10, kf: true))
        XCTAssertEqual(ids(sq.noteCompleted(frame(13))), [])
        XCTAssertEqual(ids(sq.noteCompleted(frame(12))), [])
        // 3rd held frame trips maxHeld=2: everything flushes ascending (degrade to old behaviour).
        XCTAssertEqual(ids(sq.noteCompleted(frame(14))), [12, 13, 14])
        XCTAssertEqual(sq.nextExpected, 15)
    }

    func testGapSpanValveFlushes() {
        var sq = DecodeSequencer(maxHeld: 8, maxGap: 3)
        _ = sq.noteCompleted(frame(10, kf: true))
        // id 15 is 4 past the expectation (11) — over maxGap=3 → immediate flush.
        XCTAssertEqual(ids(sq.noteCompleted(frame(15))), [15])
        XCTAssertEqual(sq.nextExpected, 16)
    }

    func testLateStragglerReleasesWithoutRegressingExpectation() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        _ = sq.noteCompleted(frame(11))
        XCTAssertEqual(ids(sq.noteCompleted(frame(9))), [9], "older frame passes through")
        XCTAssertEqual(sq.nextExpected, 12, "expectation never regresses")
    }

    func testWrapAwareOrdering() {
        var sq = DecodeSequencer()
        let last = UInt32.max
        _ = sq.noteCompleted(frame(last - 1, kf: true))
        XCTAssertEqual(ids(sq.noteCompleted(frame(0))), [], "post-wrap frame held behind missing \(last)")
        XCTAssertEqual(ids(sq.noteCompleted(frame(last))), [last, 0], "wrap gap closes in order")
        XCTAssertEqual(sq.nextExpected, 1)
    }

    /// NACK/retransmit regression: with `SLOPDESK_NACK=1` the reassembler HOLDS a
    /// FEC-unrecoverable frame N for `nackGraceFrames` (default 8) frame-ids — neither `.completed`
    /// nor `.dropped`, so the sequencer is never notified about N — while newer completions pile into
    /// `held`. The sequencer's patience must out-wait that grace: nothing may release before N
    /// completes (retransmit lands) or the grace's worth of frames has passed. With the pre-fix wiring
    /// (stock maxHeld=4 < grace=8) the overflow valve flushed at N+5, feeding VT frames that reference
    /// the still-missing N → -12909 → invalidateSession/forced-IDR churn.
    func testNackRetransmitHoldOutwaitsGraceWindow() {
        let grace: Int32 = 8 // production default — SlopDeskVideoClientSession.nackGraceFrames
        // EXACT production wiring for SLOPDESK_NACK=1 (the session's stored-property initializer).
        var sq = SlopDeskVideoClientSession.makeSequencer(nackEnabled: true, nackGraceFrames: grace)
        _ = sq.noteCompleted(frame(10, kf: true)) // expected = 11; frame 11 = N, held for retransmit
        // Frames N+1..N+grace-1 complete in order while N pends. NONE may release out of order.
        for id in UInt32(12)...UInt32(11 + UInt32(grace) - 1) {
            XCTAssertEqual(
                ids(sq.noteCompleted(frame(id))),
                [],
                "frame #\(id) released before missing #11 completed or the \(grace)-frame grace passed",
            )
        }
        // The retransmit lands inside the grace: N completes → everything releases, in order.
        XCTAssertEqual(
            ids(sq.noteCompleted(frame(11))),
            Array(UInt32(11)...UInt32(11 + UInt32(grace) - 1)),
            "retransmitted #11 closes the gap → contiguous run releases in frameID order",
        )
        XCTAssertEqual(sq.nextExpected, 11 + UInt32(grace))
    }

    /// The NACK-derived patience is a FLOOR, not unbounded: a gap that never resolves (retransmit
    /// lost too) still trips the overflow valve once past the grace-derived caps — the pane
    /// degrades to the pre-sequencer flush instead of stalling.
    func testNackPatienceStillBoundedPastGrace() {
        var sq = SlopDeskVideoClientSession.makeSequencer(nackEnabled: true, nackGraceFrames: 8)
        _ = sq.noteCompleted(frame(10, kf: true)) // expected = 11; 11 never completes NOR drops
        for id in UInt32(12)...UInt32(21) { // 10 held = derived maxHeld — still waiting
            XCTAssertEqual(ids(sq.noteCompleted(frame(id))), [], "frame #\(id) inside derived patience")
        }
        // The 11th held frame exceeds derived maxHeld=grace+2 → bounded flush, ascending order.
        XCTAssertEqual(ids(sq.noteCompleted(frame(22))), Array(UInt32(12)...UInt32(22)))
        XCTAssertEqual(sq.nextExpected, 23)
    }

    /// Pins the wiring derivation itself: NACK off = stock values (default path byte-identical);
    /// NACK on = both valves floored to grace + 2 (maxHeld is a held-COUNT, maxGap an id-SPAN —
    /// the grace is denominated in frame-ids, and up to `grace` newer frames can complete while
    /// the hole pends, so both need the same floor); a tiny grace never LOWERS the stock values.
    func testMakeSequencerPatienceDerivation() {
        let stock = SlopDeskVideoClientSession.makeSequencer(nackEnabled: false, nackGraceFrames: 8)
        XCTAssertEqual(stock.maxHeld, DecodeSequencer.defaultMaxHeld)
        XCTAssertEqual(stock.maxGap, DecodeSequencer.defaultMaxGap)
        XCTAssertEqual(stock.maxHeld, 4, "stock defaults moved — the non-NACK path must not change")
        XCTAssertEqual(stock.maxGap, 6, "stock defaults moved — the non-NACK path must not change")

        let nack = SlopDeskVideoClientSession.makeSequencer(nackEnabled: true, nackGraceFrames: 8)
        XCTAssertEqual(nack.maxHeld, 10, "grace 8 + 2 margin")
        XCTAssertEqual(nack.maxGap, 10, "grace 8 + 2 margin")

        let bigGrace = SlopDeskVideoClientSession.makeSequencer(nackEnabled: true, nackGraceFrames: 20)
        XCTAssertEqual(bigGrace.maxHeld, 22)
        XCTAssertEqual(bigGrace.maxGap, 22)

        let tinyGrace = SlopDeskVideoClientSession.makeSequencer(nackEnabled: true, nackGraceFrames: 1)
        XCTAssertEqual(tinyGrace.maxHeld, 4, "floor never lowers the stock patience")
        XCTAssertEqual(tinyGrace.maxGap, 6, "floor never lowers the stock patience")
    }

    /// Pins the DEFAULT (non-NACK) valve behaviour: stock patience still trips at 4 held frames —
    /// the opt-in NACK floor provably did not change the default path.
    func testDefaultPatienceValveStillTripsAtFourHeld() {
        var sq = SlopDeskVideoClientSession.makeSequencer(nackEnabled: false, nackGraceFrames: 8)
        _ = sq.noteCompleted(frame(10, kf: true)) // expected = 11
        for id in UInt32(12)...UInt32(15) { // 4 held = stock maxHeld — no flush yet
            XCTAssertEqual(ids(sq.noteCompleted(frame(id))), [])
        }
        // The 5th held frame exceeds stock maxHeld=4 → flush, exactly today's default behaviour.
        XCTAssertEqual(ids(sq.noteCompleted(frame(16))), [12, 13, 14, 15, 16])
        XCTAssertEqual(sq.nextExpected, 17)
    }

    func testLostBehindExpectationIsNoOp() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        _ = sq.noteCompleted(frame(11))
        XCTAssertEqual(ids(sq.noteLost(frameID: 5)), [])
        XCTAssertEqual(sq.nextExpected, 12)
    }
}
