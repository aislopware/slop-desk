// TerminalTouchSelectionTests — the ramp a selection drag scrolls at, and the one release it stays quiet on.
//
// The gesture itself is UIKit's to recognize and libghostty's to interpret; what is pinnable without a
// finger is the arithmetic between them. Two things are worth pinning and both are sign/edge traps: the
// autoscroll ramp is signed AGAINST the screen (positive reveals OLDER lines, so reaching UP scrolls
// positive — the same convention the embedder's pan-to-scroll documents), and it must be inert in the middle
// of the surface, because a ramp that leaks a non-zero delta at rest would scroll the viewport under every
// selection drag that never reaches an edge.

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
}
