#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// PURE refcount + channel→window bookkeeping for the VD window-parking lifecycle (feature #1). The
/// AX move/restore is HW-gated and not unit-tested; this locks the decision logic that decides when
/// to move, reuse, and restore — the part most prone to a leak / double-restore regression.
final class WindowParkingLedgerTests: XCTestCase {
    private let frameA = CGRect(x: 100, y: 200, width: 1600, height: 1000)
    private let sizeA = CGSize(width: 1600, height: 1000)

    // First park of a window → needsMove; after recordMove it is counted.
    func testFirstParkNeedsMoveThenRecorded() {
        let l = WindowParkingLedger()
        XCTAssertEqual(l.park(channelID: 1, windowID: 42), .needsMove)
        XCTAssertEqual(l.parkedCount, 0, "needsMove alone does not record (the AX move may still fail)")
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertEqual(l.parkedCount, 1)
    }

    // A failed move (recordMove never called) leaves NO orphan record.
    func testFailedMoveLeavesNoRecord() {
        let l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42) // .needsMove, caller's AX move then "fails" → no recordMove
        XCTAssertEqual(l.parkedCount, 0)
        XCTAssertNil(l.unpark(channelID: 1), "an un-recorded channel has nothing to restore")
    }

    // Same lane re-parking the same window (hello retransmit) reuses WITHOUT bumping the refcount.
    func testRetransmitDoesNotDoubleCount() {
        let l = WindowParkingLedger()
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
        let l = WindowParkingLedger()
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
        let l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42)
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertNotNil(l.unpark(channelID: 1), "first unpark restores")
        XCTAssertNil(l.unpark(channelID: 1), "second unpark is a no-op")
        XCTAssertEqual(l.parkedCount, 0)
    }

    // unpark of an unknown channel is a harmless no-op.
    func testUnparkUnknownChannel() {
        let l = WindowParkingLedger()
        XCTAssertNil(l.unpark(channelID: 99))
    }

    // A channel re-parking a DIFFERENT window (retarget) must release its old hold — decrement
    // refcount, produce a restore target — not silently overwrite the binding and orphan window A's
    // refcount forever.
    func testRetargetReleasesOldWindowAndCountsNewOnce() {
        let l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42) // park A
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertEqual(l.parkedCount, 1)

        let frameB = CGRect(x: 0, y: 0, width: 800, height: 600)
        let sizeB = CGSize(width: 800, height: 600)
        XCTAssertEqual(l.park(channelID: 1, windowID: 43), .needsMove) // retarget same channel to B
        XCTAssertEqual(
            l.takePendingRetargetRestore(),
            WindowParkingLedger.RestoreTarget(windowID: 42, pid: 7, originalFrame: frameA),
            "A's refcount was released (last lane) — restorable",
        )
        XCTAssertNil(l.takePendingRetargetRestore(), "draining clears it — a second read is nil")
        XCTAssertEqual(l.parkedCount, 0, "A released; B not yet recorded (needsMove)")
        XCTAssertNil(l.unpark(channelID: 1), "A's binding is already gone — a stale unpark must not double-restore it")

        l.recordMove(channelID: 1, windowID: 43, pid: 8, originalFrame: frameB, achievedSize: sizeB)
        XCTAssertEqual(l.parkedCount, 1, "B counted exactly once")
        XCTAssertEqual(l.parkedChannelIDs, [1])
        XCTAssertEqual(l.unpark(channelID: 1)?.windowID, 43, "channel 1 now releases B, not A")
    }

    // Retargeting away from a window still held by ANOTHER lane must NOT restore it — only decrement.
    func testRetargetOfSharedWindowDoesNotRestoreWhileStillHeld() {
        let l = WindowParkingLedger()
        _ = l.park(channelID: 1, windowID: 42)
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        _ = l.park(channelID: 2, windowID: 42) // channel 2 shares window 42 (refcount 2)
        XCTAssertEqual(l.parkedCount, 1)

        _ = l.park(channelID: 1, windowID: 99) // channel 1 retargets away from 42
        XCTAssertNil(l.takePendingRetargetRestore(), "42 is still held by channel 2 — not restorable yet")
        XCTAssertEqual(l.parkedCount, 1, "42 remains parked for channel 2")
        XCTAssertEqual(l.unpark(channelID: 2)?.windowID, 42, "channel 2 still solely holds 42")
    }

    // drainAll returns every parked window once and clears state; a second drain is empty.
    func testDrainAll() {
        let l = WindowParkingLedger()
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

    // C6 BUG A: `parkedChannelIDs` is the VD-termination policy's "which lanes hold a parked
    // window" snapshot input — it must track park/share/unpark/drain exactly.
    func testParkedChannelIDsTrackLifecycle() {
        let l = WindowParkingLedger()
        XCTAssertEqual(l.parkedChannelIDs, [])
        _ = l.park(channelID: 1, windowID: 42)
        XCTAssertEqual(l.parkedChannelIDs, [], "needsMove alone binds nothing (the AX move may fail)")
        l.recordMove(channelID: 1, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        XCTAssertEqual(l.parkedChannelIDs, [1])
        _ = l.park(channelID: 2, windowID: 42) // second lane SHARES the parked window
        XCTAssertEqual(l.parkedChannelIDs, [1, 2])
        _ = l.unpark(channelID: 1)
        XCTAssertEqual(l.parkedChannelIDs, [2])
        _ = l.drainAll()
        XCTAssertEqual(l.parkedChannelIDs, [])
    }

    // C6 BUG C: the sidecar persists one entry per DISTINCT parked window (refcount is a live-only
    // concern — a crash restore puts each window back once), sorted for a stable on-disk file.
    func testSidecarEntriesOnePerDistinctWindowSorted() {
        let l = WindowParkingLedger()
        XCTAssertEqual(l.sidecarEntries(), [])
        _ = l.park(channelID: 1, windowID: 43)
        l.recordMove(
            channelID: 1,
            windowID: 43,
            pid: 8,
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            achievedSize: CGSize(width: 800, height: 600),
        )
        _ = l.park(channelID: 2, windowID: 42)
        l.recordMove(channelID: 2, windowID: 42, pid: 7, originalFrame: frameA, achievedSize: sizeA)
        _ = l.park(channelID: 3, windowID: 42) // shared — must NOT duplicate the entry
        XCTAssertEqual(l.sidecarEntries(), [
            WindowParkingSnapshot.Entry(windowID: 42, pid: 7, originalFrame: frameA),
            WindowParkingSnapshot.Entry(
                windowID: 43,
                pid: 8,
                originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ),
        ])
        _ = l.unpark(channelID: 1)
        XCTAssertEqual(l.sidecarEntries().map(\.windowID), [42], "last-lane release drops the entry")
    }
}
#endif
