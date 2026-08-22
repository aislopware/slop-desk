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

    // ── The ZOOM LADDER, which was four numbers spelled inline at four sites until the carve ──────
    // These are not new behaviour: each asserts what `applyZoom` / `applyFitToPane` did arithmetically
    // before `ViewportZoom` existed, so a regression here means the extraction changed the ladder.

    func testTheLadderClampsToItsFloorAndCeiling() {
        XCTAssertEqual(ViewportZoom.bounded(0.01), ViewportZoom.minimum)
        XCTAssertEqual(ViewportZoom.bounded(99), ViewportZoom.maximum)
        XCTAssertEqual(ViewportZoom.bounded(2), 2)
    }

    // The snap is what makes repeated +/− steps settle EXACTLY on actual-size instead of drifting past
    // it: 1.25 × (1/1.25) is not bit-exactly 1 for every starting rung.
    func testSteppingSnapsToExactlyUnityNearIt() {
        XCTAssertEqual(ViewportZoom.clamped(1.03), 1.0, "inside the snap band")
        XCTAssertEqual(ViewportZoom.clamped(0.97), 1.0, "inside the band from below")
        XCTAssertNotEqual(ViewportZoom.clamped(1.2), 1.0, "outside the band is left alone")
    }

    func testOneStepInAndBackOutReturnsToUnity() {
        let up = ViewportZoom.stepped(1.0, stepIn: true)
        XCTAssertEqual(up, ViewportZoom.stepFactor, accuracy: 0.0001)
        XCTAssertEqual(ViewportZoom.stepped(up, stepIn: false), 1.0, "the snap closes the round trip")
    }

    func testSteppingCannotLeaveTheLadder() {
        var zoom = 1.0
        for _ in 0..<20 { zoom = ViewportZoom.stepped(zoom, stepIn: true) }
        XCTAssertEqual(zoom, ViewportZoom.maximum)
        for _ in 0..<40 { zoom = ViewportZoom.stepped(zoom, stepIn: false) }
        XCTAssertEqual(zoom, ViewportZoom.minimum)
    }

    // FIT takes the SMALLER per-axis ratio, so the whole window lands inside the pane on both axes.
    func testFitTakesTheSmallerAxisRatio() {
        // 600/1000 = 0.6 horizontally, 500/800 = 0.625 vertically → 0.6 wins (both axes then fit).
        XCTAssertEqual(ViewportZoom.fitted(window: size(1000, 800), pane: size(600, 500)), 0.6, accuracy: 0.0001)
    }

    // THE ONE PLACE FIT AND STEP DIVERGE, and the reason it is a separate entry point: a fit of 0.97
    // unity-snapped to 1.0 would leave the window NOT fitting, which is the only thing fit promises.
    func testFitNearUnityIsNotSnappedAway() {
        let fit = ViewportZoom.fitted(window: size(1000, 800), pane: size(970, 800))
        XCTAssertEqual(fit, 0.97, accuracy: 0.0001)
        XCTAssertNotEqual(fit, 1.0)
        XCTAssertEqual(ViewportZoom.clamped(fit), 1.0, "…which the stepping ladder WOULD have snapped")
    }

    // A window more than 4× the pane cannot be fitted — the floor clips it and the caller re-anchors.
    func testFitClipsAtTheFloorForAHugelyOversizedWindow() {
        XCTAssertEqual(ViewportZoom.fitted(window: size(10000, 8000), pane: size(600, 500)), ViewportZoom.minimum)
    }

    func testFitIsInertUntilBothSizesAreKnown() {
        XCTAssertEqual(ViewportZoom.fitted(window: size(0, 0), pane: size(600, 500)), 1.0)
        XCTAssertEqual(ViewportZoom.fitted(window: size(1000, 800), pane: size(0, 0)), 1.0)
    }

    // The displayed size is the ONE product the layer frame, the navigability gate and the pan clamp
    // all key off — `layoutVideoLayer` used to recompute it inline, which is how they drift apart.
    func testDisplayedSizeAgreesWithWhatThePanClampMeasures() {
        let win = size(1000, 800), pane = size(600, 500)
        let displayed = ViewportZoom.displayedSize(window: win, zoom: 2)
        XCTAssertEqual(displayed.width, 2000)
        XCTAssertEqual(displayed.height, 1600)
        let maxPan = ViewportPan.maxPanOffset(window: win, pane: pane, zoom: 2)
        XCTAssertEqual(maxPan.x, displayed.width - pane.width, accuracy: 0.001)
        XCTAssertEqual(maxPan.y, displayed.height - pane.height, accuracy: 0.001)
    }
}
