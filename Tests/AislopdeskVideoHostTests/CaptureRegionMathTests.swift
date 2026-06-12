#if os(macOS)
import XCTest
import CoreGraphics
@testable import AislopdeskVideoHost

/// `CaptureRegionMath` — the pure union/hysteresis logic behind DIALOG-EXPAND (a file-open dialog
/// larger than the streamed window expands the capture region so it shows in full + is clickable).
final class CaptureRegionMathTests: XCTestCase {
    typealias Snap = CaptureRegionMath.WindowSnapshot
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let target = CGRect(x: 120, y: 120, width: 700, height: 500)   // streamed window
    let targetWID: UInt32 = 1783
    let pid: Int32 = 407

    // No associated windows → region is just the (clamped) window frame.
    func testNoDialogReturnsWindowFrame() {
        let r = CaptureRegionMath.unionRegion(targetFrame: target, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [], displayBounds: display)
        XCTAssertEqual(r, target)
    }

    // The HW-measured Chrome file dialog: same pid, layer 0, overhangs left+bottom → union grows.
    func testFileDialogExpandsUnion() {
        let dialog = Snap(windowID: 1794, ownerPID: pid, layer: 0, frame: CGRect(x: 30, y: 203, width: 880, height: 448))
        let r = CaptureRegionMath.unionRegion(targetFrame: target, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [dialog], displayBounds: display)
        // union of (120,120,700,500) ∪ (30,203,880,448) = x[30,910] y[120,651]
        XCTAssertEqual(r, CGRect(x: 30, y: 120, width: 880, height: 531))
    }

    // A different app's window overlapping the target must NOT join the union (no bleed-into-region).
    func testOtherAppWindowIgnored() {
        let slack = Snap(windowID: 57, ownerPID: 388, layer: 0, frame: CGRect(x: 0, y: 0, width: 1400, height: 900))
        let r = CaptureRegionMath.unionRegion(targetFrame: target, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [slack], displayBounds: display)
        XCTAssertEqual(r, target)
    }

    // The target window itself appearing in the list must not self-union (no-op).
    func testTargetWindowItselfIgnored() {
        let selfSnap = Snap(windowID: targetWID, ownerPID: pid, layer: 0, frame: target)
        let r = CaptureRegionMath.unionRegion(targetFrame: target, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [selfSnap], displayBounds: display)
        XCTAssertEqual(r, target)
    }

    // Non-zero window layers (menu bar, Dock, tooltips) are excluded even at same pid.
    func testNonZeroLayerIgnored() {
        let tooltip = Snap(windowID: 99, ownerPID: pid, layer: 25, frame: CGRect(x: 100, y: 100, width: 900, height: 700))
        let r = CaptureRegionMath.unionRegion(targetFrame: target, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [tooltip], displayBounds: display)
        XCTAssertEqual(r, target)
    }

    // An incidental sliver overlap (a same-pid sibling window barely touching an edge) is below the
    // overlap-fraction threshold → ignored.
    func testSliverOverlapIgnored() {
        let sibling = Snap(windowID: 900, ownerPID: pid, layer: 0, frame: CGRect(x: 815, y: 120, width: 600, height: 500))
        let r = CaptureRegionMath.unionRegion(targetFrame: target, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [sibling], displayBounds: display)
        XCTAssertEqual(r, target)
    }

    // The union is clamped to the display: a dialog overhanging off the left edge can't capture
    // off-display pixels.
    func testUnionClampedToDisplay() {
        let leftEdgeTarget = CGRect(x: 0, y: 30, width: 700, height: 500)
        let dialog = Snap(windowID: 1794, ownerPID: pid, layer: 0, frame: CGRect(x: -90, y: 100, width: 880, height: 448))
        let r = CaptureRegionMath.unionRegion(targetFrame: leftEdgeTarget, targetWindowID: targetWID, targetPID: pid,
                                              windowsInFront: [dialog], displayBounds: display)
        XCTAssertEqual(r.minX, 0)           // clamped, no negative origin
        XCTAssertLessThanOrEqual(r.maxX, display.maxX)
    }

    // Hysteresis: a sub-threshold drift does not retarget; a real expansion does.
    func testShouldRetargetHysteresis() {
        let a = CGRect(x: 120, y: 120, width: 700, height: 500)
        XCTAssertFalse(CaptureRegionMath.shouldRetarget(current: a, desired: a.insetBy(dx: -3, dy: -3)))
        XCTAssertTrue(CaptureRegionMath.shouldRetarget(current: a, desired: CGRect(x: 30, y: 120, width: 880, height: 531)))
    }
}
#endif
