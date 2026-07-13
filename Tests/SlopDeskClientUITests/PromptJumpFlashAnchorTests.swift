// PromptJumpFlashAnchorTests — pins the landed-flash ANCHOR rule: libghostty pins the jumped-to prompt
// at viewport row 0, but the OSC-133 `A` mark sits at the pre-prompt cursor position, so with a
// spacer-printing prompt (starship's default `add_newline`) row 0 is a BLANK line and the visible
// prompt text is on row 1/2. The anchor must skip the spacer (the field bug: a `row 0 non-empty`
// guard made the flash NEVER paint on a starship host) yet stay bounded and honest (all-blank ⇒ nil).

import XCTest
@testable import SlopDeskClientUI

final class PromptJumpFlashAnchorTests: XCTestCase {
    func testDirectPromptOnRowZeroAnchorsThere() {
        let anchor = PromptJumpFlashOverlay.anchorRow(in: ["user@host ~ %", "output"])
        XCTAssertEqual(anchor?.row, 0)
        XCTAssertEqual(anchor?.cellCount, "user@host ~ %".count)
    }

    func testStarshipSpacerRowIsSkippedToTheVisiblePrompt() {
        // The exact shape that hid the flash in the field: OSC-133 A on the blank spacer, the
        // two-line starship prompt below it.
        let rows = ["", "slop-desk on  main [!] via  v6.3.2", "❯ echo AAA"]
        let anchor = PromptJumpFlashOverlay.anchorRow(in: rows)
        XCTAssertEqual(anchor?.row, 1, "the flash anchors to the block's first TEXT row, not the spacer")
        XCTAssertEqual(anchor?.cellCount, rows[1].count)
    }

    func testWhitespaceOnlyRowNeverAnchors() {
        let anchor = PromptJumpFlashOverlay.anchorRow(in: ["   ", "❯"])
        XCTAssertEqual(anchor?.row, 1, "a space-flash reads as a rendering artifact — skip it like a blank")
    }

    func testAllBlankLandingIsAbsentNeverWrong() {
        XCTAssertNil(PromptJumpFlashOverlay.anchorRow(in: ["", "  ", ""]), "nothing to anchor to ⇒ no flash")
        XCTAssertNil(PromptJumpFlashOverlay.anchorRow(in: []), "an empty snapshot (torn-down surface) is silent")
    }

    func testSearchStaysWithinThePromptBlockWindow() {
        // Text BEYOND the search depth must not anchor — flashing row 7 would highlight some
        // unrelated output line far below the pinned prompt block.
        let rows = ["", "", "", "way-below output"]
        XCTAssertNil(PromptJumpFlashOverlay.anchorRow(in: rows), "depth 3 bounds the anchor to the prompt block")
    }
}
