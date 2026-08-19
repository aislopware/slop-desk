// PaneFocusCornerGateTests — pins the focus-corner visibility gate: the accent triangle marks the
// focused pane ONLY when its tab is actually split (a single-pane tab has no sibling to
// disambiguate, so the marker there is pure ornament). Headless VALUE assertions — no SwiftUI render.

import XCTest
@testable import SlopDeskClientCore

@MainActor
final class PaneFocusCornerGateTests: XCTestCase {
    func testCornerOnlyOnFocusedPaneOfASplitTab() {
        XCTAssertTrue(PaneFocusPolicy.showsFocusCorner(isFocused: true, tabPaneCount: 2))
        XCTAssertTrue(PaneFocusPolicy.showsFocusCorner(isFocused: true, tabPaneCount: 3))
        XCTAssertFalse(
            PaneFocusPolicy.showsFocusCorner(isFocused: true, tabPaneCount: 1),
            "a single-pane tab shows no focus marker — nothing to disambiguate",
        )
        XCTAssertFalse(PaneFocusPolicy.showsFocusCorner(isFocused: false, tabPaneCount: 2))
        XCTAssertFalse(PaneFocusPolicy.showsFocusCorner(isFocused: false, tabPaneCount: 1))
    }
}
