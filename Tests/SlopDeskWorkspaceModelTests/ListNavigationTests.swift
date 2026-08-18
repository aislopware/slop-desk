// ListNavigationTests — the crossing for where a keyboard selection goes.
//
// The rules are `rust/slopdesk-workspace`'s `list_nav` and pinned there; what these check is the
// door: that a Swift `Int` reaches it and comes back as an index (or, for the two that can decline,
// as `nil` rather than the `-1` sentinel the C answer carries).
//
// They were the picker's tests. The clamp behind them is now also the palette's and the command
// navigator's, which each carried their own copy of it.

import SlopDeskWorkspaceModel
import XCTest

final class ListNavigationTests: XCTestCase {
    // MARK: Arrow / page / Home / End

    func testAnArrowMovesOneRowAndClampsAtBothEdges() {
        XCTAssertEqual(ListNavigation.clampedSelection(current: 2, delta: 1, count: 10), 3)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 2, delta: -1, count: 10), 1)
        // No wrap, no underflow: holding an arrow down parks the highlight on the end row.
        XCTAssertEqual(ListNavigation.clampedSelection(current: 0, delta: -1, count: 10), 0)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 9, delta: 1, count: 10), 9)
    }

    func testPagingAndHomeEndAreTheSameClampWithABiggerDelta() {
        XCTAssertEqual(ListNavigation.clampedSelection(current: 0, delta: 9, count: 30), 9)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 9, delta: 9, count: 30), 18)
        XCTAssertEqual(
            ListNavigation.clampedSelection(current: 25, delta: 9, count: 30), 29,
            "PageDown clamps to last",
        )
        XCTAssertEqual(
            ListNavigation.clampedSelection(current: 4, delta: -9, count: 30), 0,
            "PageUp clamps to first",
        )
        // Home = delta 0 from index 0; End = the whole list as the delta → the last row.
        XCTAssertEqual(ListNavigation.clampedSelection(current: 0, delta: 0, count: 30), 0)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 0, delta: 30, count: 30), 29)
    }

    func testAnEmptyListPinsToZeroWhicheverKeyArrives() {
        XCTAssertEqual(ListNavigation.clampedSelection(current: 5, delta: -9, count: 0), 0)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 0, delta: 0, count: 0), 0)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 0, delta: -1, count: 0), 0)
    }

    func testAnExtremeDeltaSaturatesRatherThanWrappingIntoAnIndex() {
        // A page stride is derived from a viewport, and Home/End send the whole count: nothing a
        // caller can pass may come back as a negative or an out-of-range row.
        XCTAssertEqual(ListNavigation.clampedSelection(current: 1, delta: .max, count: 5), 4)
        XCTAssertEqual(ListNavigation.clampedSelection(current: 1, delta: .min, count: 5), 0)
    }

    // MARK: ⌘1–9

    func testAQuickPickNamesTheRowUnderTheDigit() {
        XCTAssertEqual(ListNavigation.quickPickIndex(1, rowCount: 5), 0)
        XCTAssertEqual(ListNavigation.quickPickIndex(3, rowCount: 5), 2)
    }

    func testTheFilterChordAndEverythingOffScreenPickNothing() {
        XCTAssertNil(ListNavigation.quickPickIndex(0, rowCount: 5), "⌘0 is a filter chord, never a pick")
        XCTAssertNil(ListNavigation.quickPickIndex(10, rowCount: 20), "only ⌘1–9 are quick-pick chords")
        XCTAssertNil(ListNavigation.quickPickIndex(4, rowCount: 3), "past the visible rows → no pick")
        XCTAssertNil(ListNavigation.quickPickIndex(1, rowCount: 0))
    }

    // MARK: The ring

    func testARingComesBackAroundAtBothEnds() {
        XCTAssertEqual(ListNavigation.wrappedIndex(0, delta: 1, count: 4), 1)
        XCTAssertEqual(ListNavigation.wrappedIndex(3, delta: 1, count: 4), 0)
        XCTAssertEqual(ListNavigation.wrappedIndex(0, delta: -1, count: 4), 3)
    }

    func testARingWithNothingToStepFromDeclines() {
        XCTAssertNil(ListNavigation.wrappedIndex(0, delta: 1, count: 0))
        XCTAssertNil(ListNavigation.wrappedIndex(7, delta: 1, count: 4), "not in the ring → nothing to step from")
        XCTAssertNil(ListNavigation.wrappedIndex(-1, delta: 1, count: 4))
    }
}
