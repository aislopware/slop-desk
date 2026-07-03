import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// C7 improvement 3 — the pure oversized-viewport edge-hint model. Headless (no view / gesture state).
final class ViewportEdgeHintsTests: XCTestCase {
    private func compute(
        content: CGSize, viewport: CGSize, offset: CGPoint,
    ) -> ViewportEdgeHints {
        ViewportEdgeHints.compute(contentSize: content, viewportSize: viewport, offset: offset)
    }

    /// Content that fits the viewport hints on no edge.
    func testFittingContentHintsNothing() {
        let hints = compute(
            content: .init(width: 800, height: 600),
            viewport: .init(width: 800, height: 600),
            offset: .zero,
        )
        XCTAssertEqual(hints, .none)
        XCTAssertFalse(hints.any)
    }

    /// Content smaller than the viewport (over-fit) also hints nothing, and clamps a stray offset.
    func testSmallerContentHintsNothingAndClampsOffset() {
        let hints = compute(
            content: .init(width: 400, height: 300),
            viewport: .init(width: 800, height: 600),
            offset: .init(x: 999, y: 999),
        )
        XCTAssertEqual(hints, .none)
    }

    /// Larger content panned to the TOP-LEFT origin: only the trailing + bottom edges have hidden content.
    func testOversizedAtOriginHintsTrailingAndBottom() {
        let hints = compute(
            content: .init(width: 1600, height: 1200),
            viewport: .init(width: 800, height: 600),
            offset: .zero,
        )
        XCTAssertEqual(hints, ViewportEdgeHints(top: false, bottom: true, leading: false, trailing: true))
    }

    /// Panned fully to the BOTTOM-RIGHT: only the top + leading edges have hidden content.
    func testOversizedAtMaxHintsTopAndLeading() {
        // maxOffset = content − viewport = (800, 600)
        let hints = compute(
            content: .init(width: 1600, height: 1200),
            viewport: .init(width: 800, height: 600),
            offset: .init(x: 800, y: 600),
        )
        XCTAssertEqual(hints, ViewportEdgeHints(top: true, bottom: false, leading: true, trailing: false))
    }

    /// Panned to the MIDDLE: all four edges have hidden content.
    func testOversizedInMiddleHintsAllEdges() {
        let hints = compute(
            content: .init(width: 1600, height: 1200),
            viewport: .init(width: 800, height: 600),
            offset: .init(x: 400, y: 300),
        )
        XCTAssertEqual(hints, ViewportEdgeHints(top: true, bottom: true, leading: true, trailing: true))
        XCTAssertTrue(hints.any)
    }

    /// Overflow on ONE axis only hints that axis (wide-but-not-tall content).
    func testWideOnlyContentHintsHorizontalEdgesOnly() {
        let hints = compute(
            content: .init(width: 1600, height: 600),
            viewport: .init(width: 800, height: 600),
            offset: .init(x: 400, y: 0),
        )
        XCTAssertEqual(hints, ViewportEdgeHints(top: false, bottom: false, leading: true, trailing: true))
    }

    /// An overshooting offset is clamped, so it can't fabricate a phantom edge past the real max.
    func testOvershootingOffsetIsClampedToMax() {
        let hints = compute(
            content: .init(width: 1600, height: 1200),
            viewport: .init(width: 800, height: 600),
            offset: .init(x: 5000, y: 5000),
        )
        // Clamped to max → same as fully bottom-right: top + leading only.
        XCTAssertEqual(hints, ViewportEdgeHints(top: true, bottom: false, leading: true, trailing: false))
    }
}
