#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// C6 BUG C — the crash-recovery sidecar for VD-parked windows: the daemon persists the parking
/// ledger to a JSON sidecar at every park/unpark, and the NEXT launch AX-restores windows a SIGKILL
/// stranded off-screen. The AX restore itself is HW-gated; these lock the PURE parts — the
/// schema-versioned codec (no-backcompat: decode-fail ⇒ ignore) and the "should we move this
/// window" predicate (validate before moving — never yank a window the user/OS already re-homed).
final class WindowParkingSidecarTests: XCTestCase {
    private let original = CGRect(x: 120, y: 80, width: 1440, height: 900)

    // MARK: codec

    func testSnapshotRoundTrips() throws {
        let snapshot = WindowParkingSnapshot(entries: [
            WindowParkingSnapshot.Entry(windowID: 42, pid: 501, originalFrame: original),
            WindowParkingSnapshot.Entry(
                windowID: 7,
                pid: 88,
                originalFrame: CGRect(x: -1920, y: 0, width: 800, height: 600),
            ),
        ])
        let data = try XCTUnwrap(snapshot.encoded())
        let decoded = try XCTUnwrap(WindowParkingSnapshot.decoded(from: data))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.schemaVersion, WindowParkingSnapshot.currentSchemaVersion)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(WindowParkingSnapshot.decoded(from: Data("not json".utf8)))
        XCTAssertNil(WindowParkingSnapshot.decoded(from: Data()))
    }

    // No-backcompat rule: a sidecar from a DIFFERENT schema version is ignored wholesale (nil), not
    // migrated — stale data must decode-fail to "nothing to restore".
    func testSchemaVersionMismatchDecodesToNil() throws {
        var snapshot = WindowParkingSnapshot(entries: [
            WindowParkingSnapshot.Entry(windowID: 1, pid: 2, originalFrame: original),
        ])
        snapshot.schemaVersion = WindowParkingSnapshot.currentSchemaVersion + 1
        let data = try XCTUnwrap(snapshot.encoded())
        XCTAssertNil(WindowParkingSnapshot.decoded(from: data))
    }

    // MARK: restore predicate

    private let mainDisplay = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let sideDisplay = CGRect(x: 2560, y: 0, width: 1920, height: 1080)

    // The canonical stranded case: the window still sits where the (now-gone) VD used to be —
    // past the rightmost real display, intersecting nothing → restore.
    func testStrandedOffAllDisplaysRestores() {
        let strandedOnDeadVD = CGRect(x: 4480, y: 0, width: 1440, height: 900)
        XCTAssertTrue(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: strandedOnDeadVD,
            originalFrame: original,
            displayBounds: [mainDisplay, sideDisplay],
        ))
    }

    // Already (near) its recorded original frame → nothing to fix, do not touch it.
    func testAlreadyAtOriginalDoesNotRestore() {
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: original,
            originalFrame: original,
            displayBounds: [mainDisplay],
        ))
        // Within the tolerance (sub-pixel/AX rounding drift) counts as "at original" too.
        let nudged = original.offsetBy(dx: 1, dy: -1)
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: nudged,
            originalFrame: original,
            displayBounds: [mainDisplay],
        ))
    }

    // The window is visible on a REAL display (WindowServer already re-homed it after the VD
    // vanished, or the user moved it since the crash) → its position is plausible; moving it now
    // would yank a window out from under the user. Validate-then-drop.
    func testVisibleOnARealDisplayDoesNotRestore() {
        let reHomed = CGRect(x: 300, y: 200, width: 1024, height: 768)
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: reHomed,
            originalFrame: original,
            displayBounds: [mainDisplay, sideDisplay],
        ))
        // Even a partial overlap with a display edge counts as reachable — do not move.
        let halfOff = CGRect(x: 2500, y: 100, width: 800, height: 600)
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: halfOff,
            originalFrame: original,
            displayBounds: [mainDisplay],
        ))
    }

    // No display info (a CG enumeration failure) → fail SOFT: never move a window on uncertainty.
    func testEmptyDisplayListNeverRestores() {
        let stranded = CGRect(x: 9000, y: 0, width: 800, height: 600)
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: stranded,
            originalFrame: original,
            displayBounds: [],
        ))
    }
}
#endif
