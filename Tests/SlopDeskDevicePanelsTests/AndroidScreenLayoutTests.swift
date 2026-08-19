// AndroidScreenLayoutTests — the ONE thing about this panel's geometry that is not shared.
//
// The fit, the hit test, the clamps, the scroll scale and the pinch are `DevicePanelGeometry`'s and
// are pinned by `DevicePanelGeometryTests` (and, exhaustively, by `rust/slopdesk-devicepanel`). What
// is only Android's is the SURFACE: which size rides on the wire beside a positional message.
//
// It is worth its own file because getting it wrong is silent. `scrcpy`'s `PositionMapper` compares
// the pair on the wire against the size it is CURRENTLY encoding and DROPS the event on any
// difference — it reads a mismatch as a touch generated against a stale geometry. Sending the
// panel's own size is what made every touch a no-op while the toolbar's keycodes still worked.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskDevicePanels

final class AndroidScreenLayoutTests: XCTestCase {
    private let fitted = CGRect(x: 12, y: 30, width: 200, height: 400)

    func testTheSurfaceReportsTheVideoRatherThanThePanel() {
        let surface = AndroidScreenLayout.Surface(fitted: fitted, video: CGSize(width: 460, height: 1024))
        XCTAssertEqual(surface.width, 460)
        XCTAssertEqual(surface.height, 1024)
        // The fitted rect's ORIGIN is not in the conversion: a point handed to `pixels` has already
        // been rebased by `devicePoint`, and subtracting the origin twice would drag every touch up
        // and to the left by however far the frame is inset.
        XCTAssertEqual(surface.pixels(.zero), .zero)
        XCTAssertEqual(surface.pixels(CGPoint(x: 100, y: 200)), CGPoint(x: 230, y: 512))
    }

    func testTheSurfaceSizeSaturatesRatherThanWrapping() {
        // The field is 16 bits; a video past 65535 pixels would otherwise wrap and place every touch
        // in the top-left corner.
        let huge = AndroidScreenLayout.Surface(fitted: fitted, video: CGSize(width: 70000, height: 10))
        XCTAssertEqual(huge.width, .max)
        XCTAssertEqual(huge.height, 10)
    }

    func testAnUnusableSurfaceConvertsToTheOriginRatherThanDividingByZero() {
        let blank = AndroidScreenLayout.Surface(fitted: .zero, video: .zero)
        XCTAssertFalse(blank.isUsable)
        XCTAssertEqual(blank.pixels(CGPoint(x: 10, y: 10)), .zero)
        // A frame drawn but not yet named by a session packet is just as unusable.
        XCTAssertFalse(AndroidScreenLayout.Surface(fitted: fitted, video: .zero).isUsable)
    }
}
#endif
