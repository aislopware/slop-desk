import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind the right-click paste interception — the one that matters most here, because the
/// action crosses as a STRING: every ``RightClickAction`` case's `rawValue` must be a token the door
/// recognises, and the two that intercept must be exactly the two that paste. A case renamed on either side
/// stops intercepting silently, which is how the protection hole would reopen.
///
/// The gates themselves — a mouse-reporting program keeping its click, Copy-or-Paste pasting only with
/// nothing selected — are `slopdesk_terminal::surface::right_click_intercepts_as_paste`'s.
final class RightClickPasteInterceptPolicyTests: XCTestCase {
    private func intercepts(
        _ action: RightClickAction, selected: Bool = false, captured: Bool = false,
    ) -> Bool {
        RightClickPasteInterceptPolicy.interceptsAsPaste(
            action: action, hasSelection: selected, mouseCaptured: captured,
        )
    }

    /// Both pasting actions are recognised through their raw token, and the pointer's owner outranks them.
    func testThePastingActionsAreRecognisedThroughTheirToken() {
        XCTAssertTrue(intercepts(.paste))
        XCTAssertTrue(intercepts(.copyOrPaste))
        XCTAssertFalse(intercepts(.copyOrPaste, selected: true))
        XCTAssertFalse(intercepts(.paste, captured: true))
    }

    /// Every OTHER case is a non-paste, and must read as one rather than as an unrecognised token that
    /// happens to answer the same way — so the whole enum is walked, not just the two above.
    func testEveryNonPastingCaseIsANonInterception() {
        for action in RightClickAction.allCases where action != .paste && action != .copyOrPaste {
            XCTAssertFalse(intercepts(action), "\(action.rawValue) pastes nothing")
        }
    }
}
