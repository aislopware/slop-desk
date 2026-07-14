// DividerMovabilityTests — pins `SlopDeskSplitViewController.dividerMovability`, the pure rule the
// divider hover cursor is derived from (`FlatDividerSplitView.resetCursorRects`). The point of
// owning this over AppKit's version: NO drag-to-collapse affordance (this app collapses via
// toggles only), so a divider pinned at a limit shows the one-way arrow at BOTH ends — AppKit
// kept the two-way arrow at the minimum beside a `canCollapse` item.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DividerMovabilityTests: XCTestCase {
    /// Mid-range (sidebar 270 of 220…360, content well above its floor): both directions live.
    func testMidRangeMovesBothWays() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 270, leadingMin: 220, leadingMax: 360,
            trailingWidth: 788, trailingMin: 420, trailingMax: -1,
        )
        XCTAssertTrue(m.left, "sidebar above min + content below ceiling ⇒ leftward drag lives")
        XCTAssertTrue(m.right, "sidebar below max + content above floor ⇒ rightward drag lives")
    }

    /// Leading item AT its maximum: rightward (grow it further) is dead — the limit AppKit already
    /// got right; pinned so the two ends stay consistent.
    func testLeadingAtMaxKillsRightward() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 360, leadingMin: 220, leadingMax: 360,
            trailingWidth: 738, trailingMin: 420, trailingMax: -1,
        )
        XCTAssertFalse(m.right, "the leading item is at its ceiling — no rightward drag")
        XCTAssertTrue(m.left, "it can still shrink")
    }

    /// The TRAILING item's floor kills rightward drag too (narrow window: content at its 420
    /// minimum — the divider cannot take more from it even though the sidebar has headroom).
    func testTrailingAtMinKillsRightward() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 259, leadingMin: 220, leadingMax: 360,
            trailingWidth: 420, trailingMin: 420, trailingMax: -1,
        )
        XCTAssertFalse(m.right, "content at its floor — the divider cannot shrink it further")
        XCTAssertTrue(m.left)
    }

    /// `NSSplitViewItem`'s unspecified maximum arrives as a NEGATIVE sentinel and must read as
    /// unbounded — not as "already past the ceiling" (which would kill every direction).
    func testUnspecifiedMaximumIsUnbounded() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 9999, leadingMin: 220, leadingMax: -1,
            trailingWidth: 9999, trailingMin: 420, trailingMax: -1,
        )
        XCTAssertTrue(m.left)
        XCTAssertTrue(m.right)
    }

    /// WEDGED (both neighbours at their floors in an over-tight window): neither direction lives.
    func testWedgedWindowMovesNeither() {
        let m = SlopDeskSplitViewController.dividerMovability(
            leadingWidth: 220, leadingMin: 220, leadingMax: 360,
            trailingWidth: 420, trailingMin: 420, trailingMax: -1,
        )
        XCTAssertFalse(m.left)
        XCTAssertFalse(m.right)
    }
}
#endif
