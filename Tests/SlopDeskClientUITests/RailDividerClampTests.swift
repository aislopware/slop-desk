// RailDividerClampTests — pins the manual rail-divider drag clamp
// (`SlopDeskSplitViewController.clampedRailDividerPosition`). The rail divider is tracked BY HAND
// in `FlatDividerSplitView.mouseDown` (AppKit's constraint-based divider tracking cannot grow a
// trailing item whose holding priority exceeds its leading neighbour's — the rail holds at 260
// over the content's 250, so the built-in drag left the rail frozen at its minimum). The manual
// loop's only arithmetic is this clamp; these tests pin its limits AND the compact/wide drag-snap:
// a proposed rail width below the snap midpoint POPS to the compact icon-strip width (live, the
// Finder-sidebar drag-collapse feel), everything else stays inside the wide band — the dead zone
// between the two flavours is never a width, even mid-drag.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class RailDividerClampTests: XCTestCase {
    /// The standard 1280-wide window with the sidebar at 220: divider positions inside the WIDE
    /// band pass through UNCHANGED — the drag tracks the mouse 1:1.
    func testInRangeWidePositionsPassThrough() {
        // sidebar 220 + 1px divider → content starts at 221; split 1280 wide, thin divider 1pt.
        // The wide rail spans 220…320, so legal positions run 1280−1−320 = 959 … 1280−1−220 = 1059.
        for proposed: CGFloat in [959, 1000, 1030, 1059] {
            XCTAssertEqual(
                SlopDeskSplitViewController.clampedRailDividerPosition(
                    proposed: proposed, contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
                ),
                proposed,
                "an in-band divider position is not the clamp's business",
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

    /// Dragging RIGHT past the snap midpoint POPS the rail to its COMPACT width — the drag-snap
    /// that makes compact reachable by divider (hide-entirely still belongs to the ⌘⇧R toggle,
    /// never the divider).
    func testRightwardDragSnapsToCompact() {
        for proposed: CGFloat in [
            1280 - 1 - 100, // rail would be 100 — below the midpoint, pops compact
            1280 - 1 - 60, // just above compact
            5000, // past the window edge entirely
        ] {
            XCTAssertEqual(
                SlopDeskSplitViewController.clampedRailDividerPosition(
                    proposed: proposed, contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
                ),
                1280 - 1 - Slate.Metric.hostRailCompactWidth,
                "below the snap midpoint the rail pops to its compact width",
            )
        }
    }

    /// The DEAD ZONE between the snap midpoint and the wide minimum resolves to the wide minimum —
    /// no width between compact and wide-min ever exists, even mid-drag.
    func testDeadZoneResolvesToWideMinimum() {
        // Proposed rail width 150: at/above the midpoint (138), below wide-min (220) → wide-min.
        let clamped = SlopDeskSplitViewController.clampedRailDividerPosition(
            proposed: 1280 - 1 - 150, contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
        )
        XCTAssertEqual(clamped, 1280 - 1 - Slate.Metric.hostRailMinWidth)
        // Exactly AT the midpoint stays on the wide side (strictly-below pops compact).
        let atMidpoint = SlopDeskSplitViewController.clampedRailDividerPosition(
            proposed: 1280 - 1 - SlopDeskSplitViewController.railSnapMidpoint,
            contentMinX: 221, splitWidth: 1280, dividerThickness: 1,
        )
        XCTAssertEqual(atMidpoint, 1280 - 1 - Slate.Metric.hostRailMinWidth)
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

    /// OVER-CONSTRAINED window (content floor + wide minimum cannot both hold): WIDE-band
    /// proposals resolve to the wide minimum (the rail's floor beats the content floor, as
    /// before); a below-midpoint proposal still pops compact — which hands the content MORE room,
    /// so the compact position is always legal.
    func testOverConstrainedWindowKeepsWideFloorAndCompactPop() {
        // split 700 wide: content floor says ≥ 641, wide-min says ≤ 700−1−220 = 479.
        let wideMinPosition = 700 - 1 - Slate.Metric.hostRailMinWidth
        for proposed: CGFloat in [0, 479, 700 - 1 - 150] {
            XCTAssertEqual(
                SlopDeskSplitViewController.clampedRailDividerPosition(
                    proposed: proposed, contentMinX: 221, splitWidth: 700, dividerThickness: 1,
                ),
                wideMinPosition,
                "wide minimum wins when the window cannot honour both floors",
            )
        }
        XCTAssertEqual(
            SlopDeskSplitViewController.clampedRailDividerPosition(
                proposed: 5000, contentMinX: 221, splitWidth: 700, dividerThickness: 1,
            ),
            700 - 1 - Slate.Metric.hostRailCompactWidth,
            "the compact pop stays available in the over-constrained window",
        )
    }
}

/// Pins the rail's two STICKY thickness ranges (`railThicknessRange`) + the chrome flag that picks
/// between them. Compact pins the icon strip rigid (min = max) so window-resize can never squish
/// or stretch it; wide keeps the min…max band. The flavour persists via `Defaults` (per-PID store
/// under XCTest — writes here never leak into the real app domain).
@MainActor
final class RailCompactModeTests: XCTestCase {
    func testThicknessRanges() {
        let compact = SlopDeskSplitViewController.railThicknessRange(compact: true)
        XCTAssertEqual(compact.min, Slate.Metric.hostRailCompactWidth)
        XCTAssertEqual(compact.max, Slate.Metric.hostRailCompactWidth, "compact is pinned rigid")

        let wide = SlopDeskSplitViewController.railThicknessRange(compact: false)
        XCTAssertEqual(wide.min, Slate.Metric.hostRailMinWidth)
        XCTAssertEqual(wide.max, Slate.Metric.hostRailMaxWidth)
    }

    /// The snap midpoint sits strictly between the two flavours — the invariant the drag-snap and
    /// the width-driven rendering both lean on (rendered-compact ⟺ width below wide-min).
    func testSnapMidpointSitsBetweenFlavours() {
        XCTAssertGreaterThan(
            SlopDeskSplitViewController.railSnapMidpoint, Slate.Metric.hostRailCompactWidth,
        )
        XCTAssertLessThan(
            SlopDeskSplitViewController.railSnapMidpoint, Slate.Metric.hostRailMinWidth,
        )
    }

    /// Defaults: the rail is VISIBLE and COMPACT out of the box (the 56pt strip earns its pixels
    /// as the always-on window tracker; wide is one divider drag away).
    func testFreshChromeDefaultsToVisibleCompact() {
        let chrome = WorkspaceChromeState()
        XCTAssertFalse(chrome.hostRailCollapsed, "the compact rail shows by default")
        XCTAssertTrue(chrome.hostRailCompact, "the default flavour is the icon strip")
    }

    /// `setHostRailCompact` persists the sticky flavour and survives a fresh chrome (relaunch
    /// shape); collapse and flavour are orthogonal — hiding the rail never forgets the flavour.
    func testSetHostRailCompactPersists() {
        let chrome = WorkspaceChromeState()
        chrome.setHostRailCompact(false)
        XCTAssertFalse(chrome.hostRailCompact)
        XCTAssertFalse(
            WorkspaceChromeState().hostRailCompact,
            "a fresh chrome (relaunch) seeds from the persisted flavour",
        )

        chrome.toggleHostWindows() // hide…
        chrome.toggleHostWindows() // …and reopen
        XCTAssertFalse(chrome.hostRailCompact, "collapse round-trip keeps the flavour")

        chrome.setHostRailCompact(true) // restore the tested default for sibling tests
        XCTAssertTrue(WorkspaceChromeState().hostRailCompact)
    }
}

/// Pins `SlopDeskSplitViewController.dividerMovability` — the pure width-range movability the
/// divider hover cursor is derived from (`FlatDividerSplitView.resetCursorRects`). The point of
/// owning this over AppKit's version: NO drag-to-collapse affordance (this app collapses via
/// toggles only), so a divider pinned at a limit shows the one-way arrow at BOTH ends — AppKit
/// kept the two-way arrow at the minimum beside a `canCollapse` item. The RAIL divider feeds this
/// its DRAG span (compact…wide-max), so the compact strip correctly reads "can expand leftward".
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

    /// The COMPACT rail at rest, evaluated over the DRAG span (56…320) the cursor derivation
    /// feeds for the rail divider: leftward (expand toward wide) lives, rightward is dead — the
    /// one-way arrow, not "wedged".
    func testCompactRestReadsExpandOnly() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 1002, leadingMin: 420, leadingMax: -1,
            trailingWidth: Slate.Metric.hostRailCompactWidth,
            trailingMin: Slate.Metric.hostRailCompactWidth,
            trailingMax: Slate.Metric.hostRailMaxWidth,
        )
        XCTAssertTrue(m.left, "compact can grow toward the wide band")
        XCTAssertFalse(m.right, "nothing below compact — no rightward drag")
    }

    /// The WIDE rail at its 220 minimum, over the drag span: rightward is now LIVE (it snaps to
    /// compact) — the flavour-crossing drag the old per-mode range would have hidden.
    func testWideMinimumStillShrinksTowardCompact() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 838, leadingMin: 420, leadingMax: -1,
            trailingWidth: 220,
            trailingMin: Slate.Metric.hostRailCompactWidth,
            trailingMax: Slate.Metric.hostRailMaxWidth,
        )
        XCTAssertTrue(m.left, "the rail can still grow")
        XCTAssertTrue(m.right, "shrinking past wide-min snaps to compact — the drag is live")
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
