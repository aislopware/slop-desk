import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind the terminal's Cut (⌘X): three booleans out in the right slots, three case
/// indexes back as the three ``CutAction`` cases, and a delete count that counts CHARACTERS of the UTF-8 the
/// selection crossed as. The ladder itself — the alternate screen outranking the prompt zone, the unprovable
/// geometry degrading to a copy — is `slopdesk_terminal::surface`'s, and is tested there.
final class CutSelectionPolicyTests: XCTestCase {
    /// Each of the three answers, and each flag in its own slot: swapping `isAlternateScreen` with
    /// `isPromptZone` at the door would turn the first line into the third's answer.
    func testEachCaseIndexDecodesToItsOwnAction() {
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: true, isAlternateScreen: false, isPromptZone: true),
            .copyAndDelete,
        )
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: true, isAlternateScreen: true, isPromptZone: true),
            .copyOnly,
        )
        XCTAssertEqual(
            CutSelectionPolicy.action(hasSelection: false, isAlternateScreen: false, isPromptZone: true),
            .none,
        )
    }

    /// The count is in DEL bytes, one per CHARACTER — a count taken over the UTF-8 the selection crossed as
    /// would erase five characters' worth of a five-byte, two-character selection.
    func testTheDeleteCountIsCharactersNotBytes() {
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "héllo", selectionEndsAtCursor: true), 5)
        XCTAssertEqual(CutSelectionPolicy.deleteCount(selection: "abc", selectionEndsAtCursor: false), 0)
    }
}
