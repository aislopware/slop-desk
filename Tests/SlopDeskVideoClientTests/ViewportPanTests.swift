import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

/// PURE edge-pan reachability + clamp math (zoom-aware). Regression: the footer zoom controls scale the
/// displayed window by `clientZoom`, but the navigability gate + edge-pan clamp used the UNZOOMED window
/// size, so a zoomed-in window's overflow was unreachable (gate false) or only half-reachable (clamp early).
final class ViewportPanTests: XCTestCase {
    private func size(_ w: Double, _ h: Double) -> VideoSize { VideoSize(width: w, height: h) }

    // A window SMALLER than the pane at 1× is not navigable (nothing overflows).
    func testSmallerThanPaneAtUnityIsNotNavigable() {
        XCTAssertFalse(ViewportPan.isNavigable(window: size(800, 600), pane: size(1200, 900), zoom: 1))
        let m = ViewportPan.maxPanOffset(window: size(800, 600), pane: size(1200, 900), zoom: 1)
        XCTAssertEqual(m.x, 0)
        XCTAssertEqual(m.y, 0)
    }

    // BUG 3: the SAME small window zoomed past the pane (800×1.56 = 1248 > 1200) IS navigable and its
    // overflow is reachable. Before the fix the gate compared the unzoomed 800 vs 1200 → false (dead pan).
    func testSmallerThanPaneBecomesNavigableWhenZoomedPastPane() {
        XCTAssertTrue(
            ViewportPan.isNavigable(window: size(800, 600), pane: size(1200, 900), zoom: 1.56),
            "an 800pt window zoomed to 1248pt overflows a 1200pt pane and must be pannable",
        )
        // 800×1.56 = 1248 > 1200 (x overflow 48); 600×1.56 = 936 > 900 (y overflow 36).
        let m = ViewportPan.maxPanOffset(window: size(800, 600), pane: size(1200, 900), zoom: 1.56)
        XCTAssertEqual(m.x, 800 * 1.56 - 1200, accuracy: 0.001)
        XCTAssertEqual(m.y, 600 * 1.56 - 900, accuracy: 0.001)
    }

    // BUG 3: a window LARGER than the pane, zoomed 2×, must clamp at the ZOOMED overflow (win·2 − pane),
    // not the un-zoomed (win − pane) which stopped panning ~halfway and stranded the far edge.
    func testLargerThanPaneClampsAtZoomedOverflow() {
        let win = size(1000, 800), pane = size(600, 500)
        let unzoomed = ViewportPan.maxPanOffset(window: win, pane: pane, zoom: 1)
        XCTAssertEqual(unzoomed.x, 400, accuracy: 0.001)
        XCTAssertEqual(unzoomed.y, 300, accuracy: 0.001)
        let zoomed = ViewportPan.maxPanOffset(window: win, pane: pane, zoom: 2)
        XCTAssertEqual(zoomed.x, 1000 * 2 - 600, accuracy: 0.001, "far edge reachable only if clamp uses zoom")
        XCTAssertEqual(zoomed.y, 800 * 2 - 500, accuracy: 0.001)
        XCTAssertGreaterThan(zoomed.x, unzoomed.x)
    }

    // Zoom OUT (minify) below unity shrinks the displayed window so it no longer overflows.
    func testZoomOutMakesContentFitAndNotNavigable() {
        let win = size(1000, 800), pane = size(600, 500)
        XCTAssertTrue(ViewportPan.isNavigable(window: win, pane: pane, zoom: 1))
        // 1000×0.5 = 500 ≤ 600 and 800×0.5 = 400 ≤ 500 → fits, not navigable.
        XCTAssertFalse(ViewportPan.isNavigable(window: win, pane: pane, zoom: 0.5))
        let m = ViewportPan.maxPanOffset(window: win, pane: pane, zoom: 0.5)
        XCTAssertEqual(m.x, 0)
        XCTAssertEqual(m.y, 0)
    }
}
