// FindBarPresentationTests — the in-pane find bar's words, its two sizing rungs, the mode chip's
// appearance verdict, and the closed vocabulary the bar speaks to libghostty with.
//
// The counter's three-way rule is the one worth having as a value: `N of M`, a verdict, or NOTHING. The
// third branch is the one a re-derivation gets wrong — "No results" under an empty field reports a
// failure nobody asked for, and it looks perfectly reasonable in code.
//
// The WIRE strings are asserted literally. `TerminalSearchSurfaceAction` exists to stop five
// interpolations drifting apart, not to become the definition of the protocol: libghostty parses these
// spellings, so a test that compared the enum to itself would pass on the day a colon went missing.

import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class FindBarPresentationTests: XCTestCase {
    // MARK: - The counter

    /// A selected match prints its 1-based position over the total.
    func testCounterPrintsThePosition() {
        XCTAssertEqual(
            FindBarPresentation.counterText(position: (current: 3, total: 12), query: "docs"),
            "3 of 12",
        )
    }

    /// A non-empty query that matched nothing gets the verdict.
    func testUnmatchedQueryGetsTheVerdict() {
        XCTAssertEqual(FindBarPresentation.counterText(position: nil, query: "zzz"), "No results")
    }

    /// AN EMPTY FIELD GETS NOTHING AT ALL — never the verdict, which would report a failure the user did
    /// not ask for. This is the branch a re-derivation loses.
    func testEmptyQueryPrintsNoCounter() {
        XCTAssertNil(FindBarPresentation.counterText(position: nil, query: ""))
    }

    // MARK: - The chips

    /// The in-pane bar offers all three chips, whole-word in the middle; the cross-tab search offers two.
    /// Whole-word is the in-pane bar's alone because the global search runs over a scrollback mirror
    /// rather than libghostty's buffer, and the two engines disagree about a word boundary.
    func testInPaneBarOffersWholeWordAndGlobalSearchDoesNot() {
        XCTAssertEqual(FindModePill.inPaneFindBar, [.caseSensitive, .wholeWord, .regex])
        XCTAssertFalse(FindModePill.globalSearch.contains(.wholeWord))
        XCTAssertTrue(FindModePill.inPaneFindBar.contains(.wholeWord))
    }

    /// ON outranks HOVER. A chip that lost its accent while the pointer sat on it would read as having
    /// been switched off BY the hover — which is exactly what the pointer is about to do, so the two
    /// states would be indistinguishable a moment before the click.
    func testOnOutranksHover() {
        XCTAssertEqual(FindTogglePillAppearance.resolve(isOn: true, hovering: true), .on)
        XCTAssertEqual(FindTogglePillAppearance.resolve(isOn: true, hovering: false), .on)
        XCTAssertEqual(FindTogglePillAppearance.resolve(isOn: false, hovering: true), .hovering)
        XCTAssertEqual(FindTogglePillAppearance.resolve(isOn: false, hovering: false), .idle)
    }

    // MARK: - The rungs

    /// A finger's rung is BIGGER on every axis than a pointer's. Pinned as an ordering rather than as
    /// four numbers, because what must never invert is which device gets the larger target.
    func testTouchRungIsLargerOnEveryAxis() {
        XCTAssertGreaterThan(FindBarMetrics.touch.plate, FindBarMetrics.pointer.plate)
        XCTAssertGreaterThan(FindBarMetrics.touch.iconSize, FindBarMetrics.pointer.iconSize)
        XCTAssertGreaterThan(FindBarMetrics.touch.fieldWidth, FindBarMetrics.pointer.fieldWidth)
    }

    /// The pointer rung restates `Slate.Metric.plate` (24) and `Slate.Metric.iconSize` (13), which this
    /// target sits below and cannot import. Pinning the two numbers here is what makes the restatement
    /// reviewable: a token ladder edit that moved either one leaves this assertion standing as the
    /// record of what the find bar still believes.
    func testPointerRungRestatesTheChromeLadder() {
        XCTAssertEqual(FindBarMetrics.pointer.plate, 24)
        XCTAssertEqual(FindBarMetrics.pointer.iconSize, 13)
    }

    // MARK: - The wire vocabulary

    /// The five spellings libghostty parses. They were five interpolations at five call sites inside one
    /// file; they are one table now, and this is the table.
    func testEveryActionSpellsItsWire() {
        XCTAssertEqual(TerminalSearchSurfaceAction.search(needle: "docs").wire, "search:docs")
        XCTAssertEqual(TerminalSearchSurfaceAction.navigate(forward: true).wire, "navigate_search:next")
        XCTAssertEqual(
            TerminalSearchSurfaceAction.navigate(forward: false).wire, "navigate_search:previous",
        )
        XCTAssertEqual(TerminalSearchSurfaceAction.end.wire, "end_search")
        XCTAssertEqual(TerminalSearchSurfaceAction.scrollToRow(42).wire, "scroll_to_row:42")
    }

    /// A needle carrying the delimiter is passed through VERBATIM — the builder never escapes, trims or
    /// re-splits what the user typed, so `http://` reaches the surface as `http://`.
    func testNeedleKeepsItsOwnColons() {
        XCTAssertEqual(TerminalSearchSurfaceAction.search(needle: "http://x").wire, "search:http://x")
    }
}
