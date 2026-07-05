import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``PaneDropZoneLayout`` (E18 WI-1) — the pure overlay geometry that both the overlay DRAWS
/// and the drop receiver HIT-TESTS, so draw == hit (the `.contentShape`-before-`.position` trap is
/// mooted by sharing one source of truth). Geometry matches `screenshots/drop-overlay-frame-action.png`:
/// a central column (New Tab → Insert Path → Open In-Place, top-to-bottom) plus two side-edge ellipses.
final class PaneDropZoneLayoutTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 600)
    private var layout: PaneDropZoneLayout { PaneDropZoneLayout(size: size) }

    // MARK: - Zone geometry (topology, not exact pixels)

    func testCentralColumnIsHorizontallyCentered() {
        for zone in [DropZone.newTab, .insertPath, .openInPlace] {
            XCTAssertEqual(
                layout.shape(for: zone).center.x,
                size.width / 2,
                accuracy: 1e-9,
                "\(zone) should sit on the pane's horizontal center",
            )
        }
    }

    func testCentralColumnIsOrderedTopToBottom() {
        let newTabY = layout.shape(for: .newTab).center.y
        let insertY = layout.shape(for: .insertPath).center.y
        let openY = layout.shape(for: .openInPlace).center.y
        XCTAssertLessThan(newTabY, insertY, "New Tab is above Insert Path")
        XCTAssertLessThan(insertY, openY, "Insert Path is above Open In-Place")
    }

    func testSplitZonesAreCenteredOnTheSideEdgesAtMidHeight() {
        let left = layout.shape(for: .splitLeft)
        let right = layout.shape(for: .splitRight)
        XCTAssertEqual(left.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(right.center.x, size.width, accuracy: 1e-9)
        XCTAssertEqual(left.center.y, size.height / 2, accuracy: 1e-9)
        XCTAssertEqual(right.center.y, size.height / 2, accuracy: 1e-9)
    }

    func testSplitZonesAreEllipsesNotCircles() {
        // The side zones have distinct x/y radii (here rx = .26·1000 = 260, ry = .30·600 = 180), so the
        // shape is a genuine ellipse, not a circle — that is what spills off the side edge in the spec.
        let left = layout.shape(for: .splitLeft)
        XCTAssertNotEqual(
            left.radiusX,
            left.radiusY,
            "Split zones are elliptical (distinct x/y radii), matching the off-screen blobs",
        )
    }

    // MARK: - Hit-test: draw == hit (every center resolves to its own zone)

    func testEachZoneCenterHitsItsOwnZone() {
        for zone in DropZone.allCases {
            let center = layout.shape(for: zone).center
            XCTAssertEqual(
                layout.zone(at: center),
                zone,
                "the drawn center of \(zone) must hit-test back to \(zone)",
            )
        }
    }

    // MARK: - Hit-test: gaps miss

    func testTopLeftCornerIsAGap() {
        // (0,0) is above the left ellipse's vertical reach and far from the central column.
        XCTAssertNil(layout.zone(at: .zero))
    }

    func testPointBetweenLeftEdgeAndCentreColumnIsAGap() {
        XCTAssertNil(layout.zone(at: CGPoint(x: 250, y: 100)))
    }

    // MARK: - Hit-test: side ellipses

    func testPointNearLeftEdgeHitsSplitLeft() {
        XCTAssertEqual(layout.zone(at: CGPoint(x: size.width * 0.05, y: size.height / 2)), .splitLeft)
    }

    func testPointNearRightEdgeHitsSplitRight() {
        XCTAssertEqual(layout.zone(at: CGPoint(x: size.width * 0.95, y: size.height / 2)), .splitRight)
    }

    func testSplitLeftReachesFurtherInXThanInY() {
        // A point well inside along x (200 < rx=260) hits; the same offset along y (200 > ry=180) misses
        // — proving the elliptical extent (a circle of either radius would not split this way).
        XCTAssertEqual(layout.zone(at: CGPoint(x: 200, y: size.height / 2)), .splitLeft)
        XCTAssertNil(layout.zone(at: CGPoint(x: 0, y: size.height / 2 + 200)))
    }

    // MARK: - Degenerate size never crashes / never falsely hits

    func testZeroSizePaneHasNoZones() {
        let empty = PaneDropZoneLayout(size: .zero)
        XCTAssertNil(empty.zone(at: .zero))
        XCTAssertNil(empty.zone(at: CGPoint(x: 10, y: 10)))
    }
}
