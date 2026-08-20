// TerminalTouchSelectionTests — the ramp a selection drag scrolls at, and the one release it stays quiet on.
//
// The gesture itself is UIKit's to recognize and libghostty's to interpret; what is pinnable without a
// finger is the arithmetic between them. Two things are worth pinning and both are sign/edge traps: the
// autoscroll ramp is signed AGAINST the screen (positive reveals OLDER lines, so reaching UP scrolls
// positive — the same convention the embedder's pan-to-scroll documents), and it must be inert in the middle
// of the surface, because a ramp that leaks a non-zero delta at rest would scroll the viewport under every
// selection drag that never reaches an edge.

import CoreGraphics
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class TerminalTouchSelectionTests: XCTestCase {
    private let height = 600.0

    func testAFingerInTheMiddleScrollsNothing() {
        XCTAssertEqual(TerminalTouchSelection.autoScrollDelta(y: 300, viewHeight: height), 0)
        XCTAssertEqual(
            TerminalTouchSelection.autoScrollDelta(y: TerminalTouchSelection.autoScrollEdgeInset, viewHeight: height),
            0,
            "the band is exclusive at its inner edge — a drag that grazes it must not creep",
        )
    }

    func testReachingUpRevealsOlderLinesAndReachingDownRevealsNewer() {
        XCTAssertGreaterThan(TerminalTouchSelection.autoScrollDelta(y: 2, viewHeight: height), 0)
        XCTAssertLessThan(TerminalTouchSelection.autoScrollDelta(y: height - 2, viewHeight: height), 0)
    }

    func testTheRampIsLinearInTheOvershootAndClampsAtOneInset() {
        let inset = TerminalTouchSelection.autoScrollEdgeInset
        let full = TerminalTouchSelection.autoScrollPointsPerTick
        XCTAssertEqual(TerminalTouchSelection.autoScrollDelta(y: 0, viewHeight: height), full, accuracy: 0.0001)
        XCTAssertEqual(
            TerminalTouchSelection.autoScrollDelta(y: inset / 2, viewHeight: height),
            full / 2,
            accuracy: 0.0001,
        )
        XCTAssertEqual(
            TerminalTouchSelection.autoScrollDelta(y: -1000, viewHeight: height),
            full,
            accuracy: 0.0001,
            "a finger dragged off the glass runs at the ceiling, never faster",
        )
    }

    func testAShortSurfaceNeverOverlapsItsTwoBands() {
        // Half the height, so the two bands meet exactly in the middle and neither can claim the other's
        // side: at the midpoint of a 20pt surface both overshoots are 0.
        XCTAssertEqual(TerminalTouchSelection.autoScrollDelta(y: 10, viewHeight: 20), 0)
        XCTAssertGreaterThan(TerminalTouchSelection.autoScrollDelta(y: 1, viewHeight: 20), 0)
        XCTAssertLessThan(TerminalTouchSelection.autoScrollDelta(y: 19, viewHeight: 20), 0)
        XCTAssertEqual(TerminalTouchSelection.autoScrollDelta(y: 0, viewHeight: 0), 0, "a zero-height surface")
    }

    func testACapturedPointerKeepsTheMenuAwayBecauseTheGestureWasTheProgramsDrag() {
        XCTAssertFalse(TerminalTouchSelection.presentsMenuOnRelease(mouseCaptured: true))
        XCTAssertTrue(
            TerminalTouchSelection.presentsMenuOnRelease(mouseCaptured: false),
            "off capture the menu shows with or without a selection, matching the Mac's empty right-click",
        )
    }

    // MARK: - The link slop, against a real grid

    // `linkHitSlop` is only meaningful as a distance measured against cells, and the cells are
    // `TerminalLinkHitTest`'s to measure — so what is pinned here is the pair: a press one cell off a path,
    // at a face the app actually renders, still opens that path's menu items, and a press across the line
    // does not. A slop tuned to a number rather than to a grid would pass one of these and fail the other.

    /// An 8 × 17pt cell is a realistic default face; the span is the one `"see /tmp/x"` produces — row 0,
    /// cells 4..<10, i.e. x ∈ [32, 80) and y ∈ [0, 17). Hand-built rather than detected: what the scanner
    /// finds is `TerminalLinkDetectorTests`' business, and this is about the distance.
    private let grid = TerminalCellMetrics(cellWidth: 8, cellHeight: 17, cols: 80, rows: 24)
    private let path = DetectedLink(
        row: 0,
        colStart: 4,
        colEnd: 10,
        kind: .absolutePath,
        raw: "/tmp/x",
        resolvedAbsolute: "/tmp/x",
    )

    private func pressed(x: CGFloat, y: CGFloat, slop: CGFloat) -> String? {
        TerminalLinkHitTest.link(in: [path], metrics: grid, pointX: x, pointY: y, slop: slop)?.raw
    }

    func testAFingerOneCellPastThePathStillPressesIt() {
        let slop = CGFloat(TerminalTouchSelection.linkHitSlop)
        // x = 86 is cell 10 — one cell past an exclusive `colEnd`, and 6 points off the span's edge.
        XCTAssertNil(pressed(x: 86, y: 8, slop: 0), "a pointer lands where it is aimed and misses")
        XCTAssertEqual(pressed(x: 86, y: 8, slop: slop), "/tmp/x", "a fingertip is forgiven one cell")
    }

    func testTheSlopStopsWellShortOfTheNextWordAndTheNextLine() {
        let slop = CGFloat(TerminalTouchSelection.linkHitSlop)
        XCTAssertNil(pressed(x: 120, y: 8, slop: slop), "five cells off is a different word, not bad aim")
        XCTAssertNil(pressed(x: 60, y: 40, slop: slop), "a whole row below is a different line of output")
    }

    func testTheSlopIsNarrowerThanTheDriftThePressWasAlreadyAllowed() {
        XCTAssertGreaterThan(TerminalTouchSelection.linkHitSlop, 0)
        XCTAssertLessThan(
            TerminalTouchSelection.linkHitSlop,
            TerminalTouchSelection.longPressAllowableMovement,
            "a press that held still enough to be recognized must not be re-aimed further than it may wander",
        )
    }
}
