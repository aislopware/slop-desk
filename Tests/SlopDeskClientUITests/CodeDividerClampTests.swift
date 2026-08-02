#if os(macOS)
import XCTest
@testable import SlopDeskClientUI

/// ``SlopDeskSplitViewController/clampedCodeDividerPosition(proposed:contentMinX:splitWidth:dividerThickness:)``
/// — the manual code-divider drag's clamp (the host-rail machinery, restored for the CODE panel).
/// AppKit's constraint drag cannot grow a trailing item that holds harder than its leading
/// neighbour, so the drag is hand-tracked and every step runs through this pure clamp.
final class CodeDividerClampTests: XCTestCase {
    /// A 1600pt window with the sidebar at 220: divider positions inside the band pass through.
    private let contentMinX: CGFloat = 221
    private let splitWidth: CGFloat = 1600
    private let divider: CGFloat = 1

    private func clamp(_ proposed: CGFloat) -> CGFloat {
        SlopDeskSplitViewController.clampedCodeDividerPosition(
            proposed: proposed, contentMinX: contentMinX, splitWidth: splitWidth,
            dividerThickness: divider,
        )
    }

    func testInBandProposalPassesThrough() {
        XCTAssertEqual(clamp(900), 900)
    }

    func testContentFloorBindsOnTheLeft() {
        // Dragging far left stops where the content column hits its minimum width.
        XCTAssertEqual(clamp(100), contentMinX + SlopDeskSplitViewController.contentMinWidth)
    }

    func testPanelFloorBindsOnTheRight() {
        // Dragging toward the window edge stops where the panel hits its minimum width — never a
        // drag-collapse (the panel hides via its toggle only).
        XCTAssertEqual(
            clamp(1590),
            splitWidth - divider - SlopDeskSplitViewController.codeSidebarMinWidth,
        )
    }

    func testOverConstrainedWindowLetsThePanelFloorWin() {
        // A window too narrow for both floors: the panel's floor wins (the divider can only sit at
        // the panel-floor position, the content goes below its own minimum).
        let narrow = SlopDeskSplitViewController.contentMinWidth
            + SlopDeskSplitViewController.codeSidebarMinWidth - 100
        let clamped = SlopDeskSplitViewController.clampedCodeDividerPosition(
            proposed: 700, contentMinX: 0, splitWidth: narrow, dividerThickness: divider,
        )
        XCTAssertEqual(clamped, narrow - divider - SlopDeskSplitViewController.codeSidebarMinWidth)
    }
}
#endif
