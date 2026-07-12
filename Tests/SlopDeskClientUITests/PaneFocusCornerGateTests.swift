// PaneFocusCornerGateTests — pins the focus-corner visibility gate: the accent triangle marks the
// focused pane ONLY when its tab is actually split (a single-pane tab has no sibling to
// disambiguate, so the marker there is pure ornament). Headless VALUE assertions — no SwiftUI render.

import XCTest
@testable import SlopDeskClientUI

@MainActor
final class PaneFocusCornerGateTests: XCTestCase {
    func testCornerOnlyOnFocusedPaneOfASplitTab() {
        XCTAssertTrue(PaneContainer.showsFocusCorner(isFocused: true, tabPaneCount: 2))
        XCTAssertTrue(PaneContainer.showsFocusCorner(isFocused: true, tabPaneCount: 3))
        XCTAssertFalse(
            PaneContainer.showsFocusCorner(isFocused: true, tabPaneCount: 1),
            "a single-pane tab shows no focus marker — nothing to disambiguate",
        )
        XCTAssertFalse(PaneContainer.showsFocusCorner(isFocused: false, tabPaneCount: 2))
        XCTAssertFalse(PaneContainer.showsFocusCorner(isFocused: false, tabPaneCount: 1))
    }
}
