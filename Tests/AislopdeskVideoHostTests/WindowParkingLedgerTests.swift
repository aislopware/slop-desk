#if os(macOS)
import CoreGraphics
import XCTest
@testable import AislopdeskVideoHost

/// PURE refcount + channel→window bookkeeping for the VD window-parking lifecycle (feature #1). The
/// AX move/restore is HW-gated and not unit-tested; this locks the decision logic that decides when
/// to move, reuse, and restore — the part most prone to a leak / double-restore regression.
final class WindowParkingLedgerTests: XCTestCase {
    private let frameA = CGRect(x: 100, y: 200, width: 1600, height: 1000)
    private let sizeA = CGSize(width: 1600, height: 1000)

    // First park of a window → needsMove; after recordMove it is counted.
    func testFirstParkNeedsMoveThenRecorded() {
        var l = WindowParkingLedger()
        XCTAssertEqual(l.park(channelID: 1, windowID: 42), .needsMove)
        XCTAssertEqual(l.parkedCount, 0, "needsMove alone does not record (the AX move may still fail)")
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertEqual(l.parkedCount, 1)
    }

    // A failed move (recordMove never called) leaves NO orphan record.
    func testFailedMoveLeavesNoRecord() {
        var l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42) // .needsMove, caller's AX move then "fails" → no recordMove
        XCTAssertEqual(l.parkedCount, 0)
        XCTAssertNil(l.unpark(channelID: 1), "an un-recorded channel has nothing to restore")
    }

    // Same lane re-parking the same window (hello retransmit) reuses WITHOUT bumping the refcount.
    func testRetransmitDoesNotDoubleCount() {
        var l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42)
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertEqual(l.park(channelID: 1, windowID: 42), .reuse(sizeA))
        // One unpark fully releases (refcount stayed 1 despite the retransmit) → restore target.
        let t = l.unpark(channelID: 1)
        XCTAssertEqual(t, WindowParkingLedger.RestoreTarget(windowID: 42, pid: 7, originalFrame: frameA))
        XCTAssertEqual(l.parkedCount, 0)
    }

    // Two lanes naming the SAME window: moved once, restored once (last release).
    func testTwoLanesShareOneWindow() {
        var l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42)
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertEqual(l.park(channelID: 2, windowID: 42), .reuse(sizeA), "second lane reuses, no move")
        XCTAssertEqual(l.parkedCount, 1)
        // First lane releasing does NOT restore (still held by lane 2).
        XCTAssertNil(l.unpark(channelID: 1))
        XCTAssertEqual(l.parkedCount, 1)
        // Last lane releasing restores.
        XCTAssertEqual(l.unpark(channelID: 2)?.windowID, 42)
        XCTAssertEqual(l.parkedCount, 0)
    }

    // Double-unpark of one channel restores exactly ONCE (idempotent — locks the invariant the
    // redundant onReapLane/onRetire/SIGINT callers rely on).
    func testDoubleUnparkRestoresOnce() {
        var l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42)
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertNotNil(l.unpark(channelID: 1), "first unpark restores")
        XCTAssertNil(l.unpark(channelID: 1), "second unpark is a no-op")
        XCTAssertEqual(l.parkedCount, 0)
    }

    // unpark of an unknown channel is a harmless no-op.
    func testUnparkUnknownChannel() {
        var l = WindowParkingLedger()
        XCTAssertNil(l.unpark(channelID: 99))
    }

    // drainAll returns every parked window once and clears state; a second drain is empty.
    func testDrainAll() {
        var l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42)
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        _ = l.park(channelID: 2, windowID: 43)
        l.recordMove(
            channelID: 2,
            windowID: 43,
            pid: 8,
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            achievedSize: CGSize(width: 800, height: 600),
        )
        let drained = l.drainAll()
        XCTAssertEqual(Set(drained.map(\.windowID)), [42, 43])
        XCTAssertEqual(l.parkedCount, 0)
        XCTAssertTrue(l.drainAll().isEmpty, "second drain is empty")
        XCTAssertNil(l.unpark(channelID: 1), "channel bindings cleared by drain")
    }
}
#endif
