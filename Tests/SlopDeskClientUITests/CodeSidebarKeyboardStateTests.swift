// Pins for `CodeSidebarKeyboardState` — the "embedded VS Code owns the keyboard" flag the pane
// tree reads to render the workspace-focused terminal UNFOCUSED while the user types in the panel.

import XCTest
@testable import SlopDeskClientUI

@MainActor
final class CodeSidebarKeyboardStateTests: XCTestCase {
    func testPaneRendersFocusedOnlyWhileTheSidebarDoesNotOwnTheKeyboard() {
        // The core invariant: two surfaces must never both show a live cursor.
        XCTAssertTrue(CodeSidebarKeyboardState.paneRendersFocused(
            workspaceFocused: true, sidebarOwnsKeyboard: false,
        ))
        XCTAssertFalse(CodeSidebarKeyboardState.paneRendersFocused(
            workspaceFocused: true, sidebarOwnsKeyboard: true,
        ))
        // An unfocused pane stays unfocused regardless — the flag only ever DIMS, never lights.
        XCTAssertFalse(CodeSidebarKeyboardState.paneRendersFocused(
            workspaceFocused: false, sidebarOwnsKeyboard: false,
        ))
        XCTAssertFalse(CodeSidebarKeyboardState.paneRendersFocused(
            workspaceFocused: false, sidebarOwnsKeyboard: true,
        ))
    }

    func testSetTracksOwnershipAndStartsReleased() {
        let state = CodeSidebarKeyboardState()
        XCTAssertFalse(state.ownsKeyboard)
        state.set(true)
        XCTAssertTrue(state.ownsKeyboard)
        state.set(false)
        XCTAssertFalse(state.ownsKeyboard)
    }
}
