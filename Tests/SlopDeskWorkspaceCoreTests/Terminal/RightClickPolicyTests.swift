import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind the bare right-click — the one that matters most here, because the action
/// crosses as a STRING: every ``RightClickAction`` case's `rawValue` must be a token the door
/// recognises, and each must reach its OWN outcome. A case renamed on either side stops dispatching
/// silently and falls to the menu, which is how three of these arms sat dead once already.
///
/// The gates themselves — a mouse-reporting program keeping its click, Copy-or-Paste pasting only with
/// nothing selected — are `slopdesk_terminal::surface::right_click`'s.
final class RightClickPolicyTests: XCTestCase {
    private func outcome(
        _ action: RightClickAction, selected: Bool = false, captured: Bool = false,
    ) -> RightClickOutcome {
        RightClickPolicy.outcome(action: action, hasSelection: selected, mouseCaptured: captured)
    }

    /// Each case reaches its own arm through its raw token, and the pointer's owner outranks all of them.
    func testEveryCaseDispatchesThroughItsToken() {
        XCTAssertEqual(outcome(.paste), .paste)
        XCTAssertEqual(outcome(.copy), .copy)
        XCTAssertEqual(outcome(.copyOrPaste), .paste)
        XCTAssertEqual(outcome(.copyOrPaste, selected: true), .copy)
        XCTAssertEqual(outcome(.ignore), .ignore)
        XCTAssertEqual(outcome(.contextMenu), .menu)
        for action in RightClickAction.allCases {
            XCTAssertEqual(
                outcome(action, captured: true), .forward,
                "\(action.rawValue) yields to the program holding the pointer",
            )
        }
    }

    /// The menu is both a real arm and the repair for a token the door does not know, so it is the one
    /// answer that cannot prove a case crossed. Every OTHER case must therefore land somewhere else —
    /// that is what catches a rename on either side.
    func testOnlyTheMenuCaseAnswersTheRepair() {
        for action in RightClickAction.allCases where action != .contextMenu {
            XCTAssertNotEqual(
                outcome(action), .menu, "\(action.rawValue) crossed as an unrecognised token",
            )
        }
    }
}
