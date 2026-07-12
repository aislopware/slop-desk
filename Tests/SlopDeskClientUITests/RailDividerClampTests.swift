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
#endif
