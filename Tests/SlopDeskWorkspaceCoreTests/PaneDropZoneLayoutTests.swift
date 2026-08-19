import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// The crossing for ``PaneDropZoneLayout`` — the overlay geometry both the overlay DRAWS and the drop
/// receiver HIT-TESTS. The proportions themselves are pinned in `slopdesk_workspace::drop_zone`; what is
/// checked here is that a pane's size reaches the door, that the answer comes back in the caller's own
/// vocabulary, and that draw == hit across the boundary.
final class PaneDropZoneLayoutTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 600)
    private var layout: PaneDropZoneLayout { PaneDropZoneLayout(size: size) }

    // MARK: - The shapes come back in the pane's own coordinates

    func testCentralColumnIsHorizontallyCenteredAndOrderedTopToBottom() {
        for zone in [DropZone.newTab, .insertPath, .openInPlace] {
            XCTAssertEqual(
                layout.shape(for: zone).center.x,
                size.width / 2,
                accuracy: 1e-9,
                "\(zone) should sit on the pane's horizontal center",
            )
        }
        XCTAssertLessThan(layout.shape(for: .newTab).center.y, layout.shape(for: .insertPath).center.y)
        XCTAssertLessThan(layout.shape(for: .insertPath).center.y, layout.shape(for: .openInPlace).center.y)
    }

    func testSplitZonesAreEllipsesCenteredOnTheSideEdgesAtMidHeight() {
        let left = layout.shape(for: .splitLeft)
        let right = layout.shape(for: .splitRight)
        XCTAssertEqual(left.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(right.center.x, size.width, accuracy: 1e-9)
        XCTAssertEqual(left.center.y, size.height / 2, accuracy: 1e-9)
        XCTAssertEqual(right.center.y, size.height / 2, accuracy: 1e-9)
        // Distinct x/y radii — a genuine ellipse, which is what spills off the side edge in the spec.
        XCTAssertNotEqual(left.radiusX, left.radiusY)
    }

    // MARK: - Hit-test: draw == hit, across the boundary

    func testEachZoneCenterHitsItsOwnZone() {
        for zone in DropZone.allCases {
            XCTAssertEqual(
                layout.zone(at: layout.shape(for: zone).center),
                zone,
                "the drawn center of \(zone) must hit-test back to \(zone)",
            )
        }
    }

    func testGapsMiss() {
        // (0,0) is above the left ellipse's vertical reach and far from the central column.
        XCTAssertNil(layout.zone(at: .zero))
        XCTAssertNil(layout.zone(at: CGPoint(x: 250, y: 100)))
    }

    func testTheSideEllipsesReachFurtherInXThanInY() {
        // A point well inside along x (200 < rx = 260) hits; the same offset along y (200 > ry = 180)
        // misses — proving the elliptical extent survived the crossing as an ellipse.
        XCTAssertEqual(layout.zone(at: CGPoint(x: 200, y: size.height / 2)), .splitLeft)
        XCTAssertEqual(layout.zone(at: CGPoint(x: size.width * 0.95, y: size.height / 2)), .splitRight)
        XCTAssertNil(layout.zone(at: CGPoint(x: 0, y: size.height / 2 + 200)))
    }

    // MARK: - Degenerate size never crashes / never falsely hits

    func testZeroSizePaneHasNoZones() {
        let empty = PaneDropZoneLayout(size: .zero)
        XCTAssertNil(empty.zone(at: .zero))
        XCTAssertNil(empty.zone(at: CGPoint(x: 10, y: 10)))
    }
}
