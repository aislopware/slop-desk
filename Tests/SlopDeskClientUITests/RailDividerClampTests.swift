// RailDividerClampTests — pins the manual rail-divider drag clamp
// (`SlopDeskSplitViewController.clampedRailDividerPosition`). The rail divider is tracked BY HAND
// in `FlatDividerSplitView.mouseDown` (AppKit's constraint-based divider tracking cannot grow a
// trailing item whose holding priority exceeds its leading neighbour's — the rail holds at 260
// over the content's 250, so the built-in drag left the rail frozen at its minimum). The manual
// loop's only arithmetic is this clamp; these tests pin its limits so the drag can never shove the
// content below its floor, the rail outside min…max, or (over-constrained window) the rail below
// its minimum.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class RailDividerClampTests: XCTestCase {
    /// The standard 1280-wide window with the sidebar at 220: divider positions between the
    /// content floor and the rail minimum pass through UNCHANGED — the drag tracks the mouse 1:1.
    func testInRangePositionsPassThrough() {
        // sidebar 220 + 1px divider → content starts at 221; split 1280 wide, thin divider 1pt.
        // The rail spans 220…320, so legal divider positions run 1280−1−320 = 959 … 1280−1−220 = 1059.
        for proposed: CGFloat in [959, 1000, 1030, 1059] {
            XCTAssertEqual(
                SlopDeskSplitViewController.clampedRailDividerPosition(
                    proposed: proposed, contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
                ),
                proposed,
                "an in-range divider position is not the clamp's business",
            )
        }
    }

    /// Dragging far LEFT stops where the rail reaches `hostRailMaxWidth` (the binding limit in a
    /// wide window — the content floor is verified separately below).
    func testLeftwardDragStopsAtRailMax() {
        let clamped = SlopDeskSplitViewController.clampedRailDividerPosition(
            proposed: 0, contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
        )
        XCTAssertEqual(clamped, 1280 - 1 - Slate.Metric.hostRailMaxWidth, "rail stops at its max width")
    }

    /// Dragging far RIGHT stops where the rail reaches `hostRailMinWidth` — there is deliberately
    /// no drag-to-collapse (the rail collapses via its toggle, never by shoving the divider).
    func testRightwardDragStopsAtRailMin() {
        let clamped = SlopDeskSplitViewController.clampedRailDividerPosition(
            proposed: 5000, contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
        )
        XCTAssertEqual(clamped, 1280 - 1 - Slate.Metric.hostRailMinWidth, "rail stops at its min width")
    }

    /// A NARROW window where the content floor binds before the rail max: the leftward limit is
    /// the content minimum, not the rail max (content + rail share one window; content wins the
    /// wider claim).
    func testContentFloorBindsInNarrowWindow() {
        // split 900 wide: rail max would allow position 900−1−320 = 579, but content needs
        // 221 + 420 = 641 — the content floor is the binding limit.
        let clamped = SlopDeskSplitViewController.clampedRailDividerPosition(
            proposed: 0, contentMinX: 221, splitWidth: 900, dividerThickness: 1,
        )
        XCTAssertEqual(
            clamped, 221 + SlopDeskSplitViewController.contentMinWidth,
            "the content floor out-claims the rail max in a narrow window",
        )
    }

    /// OVER-CONSTRAINED window (content floor + rail minimum cannot both hold): the rail's
    /// MINIMUM wins — the clamp resolves to the rail-min position so the divider can never push
    /// the rail below its floor, whatever the proposal.
    func testOverConstrainedWindowKeepsRailAtMin() {
        // split 700 wide: content floor says ≥ 641, rail min says ≤ 700−1−220 = 479.
        let railMinPosition = 700 - 1 - Slate.Metric.hostRailMinWidth
        for proposed: CGFloat in [0, 479, 641, 5000] {
            XCTAssertEqual(
                SlopDeskSplitViewController.clampedRailDividerPosition(
                    proposed: proposed, contentMinX: 221, splitWidth: 700, dividerThickness: 1,
                ),
                railMinPosition,
                "rail minimum wins when the window cannot honour both floors",
            )
        }
    }
}

/// Pins `SlopDeskSplitViewController.dividerMovability` — the pure width-range movability the
/// divider hover cursor is derived from (`FlatDividerSplitView.resetCursorRects`). The point of
/// owning this over AppKit's version: NO drag-to-collapse affordance (this app collapses via
/// toggles only), so a divider pinned at a limit shows the one-way arrow at BOTH ends — AppKit
/// kept the two-way arrow at the minimum beside a `canCollapse` item.
@MainActor
final class DividerMovabilityTests: XCTestCase {
    /// Mid-range (rail 270 of 220…320, content well above its floor): both directions live.
    func testMidRangeMovesBothWays() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 788, leadingMin: 420, leadingMax: -1,
            trailingWidth: 270, trailingMin: 220, trailingMax: 320,
        )
        XCTAssertTrue(m.left, "content above floor + rail below max ⇒ leftward drag lives")
        XCTAssertTrue(m.right, "content below ceiling + rail above min ⇒ rightward drag lives")
    }

    /// Rail AT its minimum: rightward (shrink rail further) is dead — the case AppKit lied about
    /// (its two-way arrow counted drag-to-collapse as movement).
    func testTrailingAtMinKillsRightward() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 838, leadingMin: 420, leadingMax: -1,
            trailingWidth: 220, trailingMin: 220, trailingMax: 320,
        )
        XCTAssertTrue(m.left, "the rail can still grow")
        XCTAssertFalse(m.right, "the rail is at its floor — no rightward drag, no two-way arrow")
    }

    /// Rail AT its maximum: leftward (grow rail further) is dead — the limit AppKit already got
    /// right; pinned so the two ends stay consistent.
    func testTrailingAtMaxKillsLeftward() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 738, leadingMin: 420, leadingMax: -1,
            trailingWidth: 320, trailingMin: 220, trailingMax: 320,
        )
        XCTAssertFalse(m.left, "the rail is at its ceiling — no leftward drag")
        XCTAssertTrue(m.right, "the rail can still shrink")
    }

    /// The LEADING item's floor kills leftward drag too (narrow window: content at its 420
    /// minimum — the divider cannot take more from it even though the rail has headroom).
    func testLeadingAtMinKillsLeftward() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 420, leadingMin: 420, leadingMax: -1,
            trailingWidth: 259, trailingMin: 220, trailingMax: 320,
        )
        XCTAssertFalse(m.left, "content at its floor — the divider cannot shrink it further")
        XCTAssertTrue(m.right)
    }

    /// `NSSplitViewItem`'s unspecified maximum arrives as a NEGATIVE sentinel and must read as
    /// unbounded — not as "already past the ceiling" (which would kill every direction).
    func testUnspecifiedMaximumIsUnbounded() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 9999, leadingMin: 420, leadingMax: -1,
            trailingWidth: 9999, trailingMin: 220, trailingMax: -1,
        )
        XCTAssertTrue(m.left)
        XCTAssertTrue(m.right)
    }

    /// WEDGED (both neighbours at their floors in an over-tight window): neither direction lives.
    func testWedgedWindowMovesNeither() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 420, leadingMin: 420, leadingMax: -1,
            trailingWidth: 220, trailingMin: 220, trailingMax: 320,
        )
        XCTAssertFalse(m.left)
        XCTAssertFalse(m.right)
    }
}
#endif
