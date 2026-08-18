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

    // The rule is `slopdesk_video::window_restore`; what is tested here is that a `[CGRect]` reaches
    // it as the display list it means.
    private let mainDisplay = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let sideDisplay = CGRect(x: 2560, y: 0, width: 1920, height: 1080)

    func testTheDisplayListCrossesAsTheOneTheWindowIsJudgedAgainst() {
        let strandedOnDeadVD = CGRect(x: 4480, y: 0, width: 1440, height: 900)
        // Past the rightmost real display, so no display reaches it.
        XCTAssertTrue(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: strandedOnDeadVD,
            originalFrame: original,
            displayBounds: [mainDisplay, sideDisplay],
        ))
        // The SAME window, once a display covers where it sits — the second rect has to cross for
        // this to flip, which is what pins the four-doubles-per-display packing.
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: strandedOnDeadVD,
            originalFrame: original,
            displayBounds: [mainDisplay, sideDisplay, CGRect(x: 4480, y: 0, width: 1920, height: 1080)],
        ))
    }

    // An empty list has no base address to pass; the door must still be asked and still answer no.
    func testAnEmptyDisplayListStillCrosses() {
        XCTAssertFalse(StrandedWindowRestorePolicy.shouldRestore(
            currentFrame: CGRect(x: 9000, y: 0, width: 800, height: 600),
            originalFrame: original,
            displayBounds: [],
        ))
    }
}
#endif
