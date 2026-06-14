import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

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

    func testLostBehindExpectationIsNoOp() {
        var sq = DecodeSequencer()
        _ = sq.noteCompleted(frame(10, kf: true))
        _ = sq.noteCompleted(frame(11))
        XCTAssertEqual(ids(sq.noteLost(frameID: 5)), [])
        XCTAssertEqual(sq.nextExpected, 12)
    }
}
