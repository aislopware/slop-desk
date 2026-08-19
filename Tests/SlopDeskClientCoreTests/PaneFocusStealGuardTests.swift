import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

/// The keep-all-mounted focus-steal guard: with every tab's panes mounted (so a libghostty surface survives
/// a tab switch), a BACKGROUND tab's own `activePane` must NOT own the renderer's keyboard focus — else the
/// last-mounted hidden tab would steal first responder from the visible one.
@MainActor
final class PaneFocusStealGuardTests: XCTestCase {
    func testOnlyTheActiveTabsActivePaneIsFocused() {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let tabA = Tab(root: .leaf(p1), activePane: p1)
        let tabB = Tab(root: .leaf(p2), activePane: p2)

        // Active tab's activePane → focused.
        XCTAssertTrue(PaneFocusPolicy.isPaneFocused(p1, in: tabA, activeTabID: tabA.id))

        // A BACKGROUND tab's OWN activePane → NOT focused (the focus-steal guard).
        XCTAssertFalse(PaneFocusPolicy.isPaneFocused(p2, in: tabB, activeTabID: tabA.id))

        // Active tab, but a pane that is not its activePane → not focused.
        XCTAssertFalse(PaneFocusPolicy.isPaneFocused(p3, in: tabA, activeTabID: tabA.id))

        // No active tab resolved yet → nothing focused.
        XCTAssertFalse(PaneFocusPolicy.isPaneFocused(p1, in: tabA, activeTabID: nil))
    }
}
