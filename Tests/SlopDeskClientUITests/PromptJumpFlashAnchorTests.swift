// PromptJumpFlashAnchorTests — pins the landed-flash ANCHOR rules: libghostty pins the jumped-to prompt
// at viewport row 0, but the OSC-133 `A` mark sits at the pre-prompt cursor position, so with a
// spacer-printing prompt (starship's default `add_newline`) row 0 is a BLANK line and the visible
// prompt text is on row 1/2. The anchor must skip the spacer (the field bug: a `row 0 non-empty`
// guard made the flash NEVER paint on a starship host), then cover the line's soft-WRAP continuation
// rows (second field report: a wrapped prompt flashed only its first row) — bounded and honest
// (all-blank ⇒ empty, a pathological grid-filling line is capped).

import XCTest
@testable import SlopDeskClientUI

final class PromptJumpFlashAnchorTests: XCTestCase {
    /// A grid width comfortably wider than every unwrapped fixture row, so only the wrap tests wrap.
    private let cols = 80

    func testDirectPromptOnRowZeroAnchorsThere() {
        let anchors = PromptJumpFlashOverlay.anchorRows(in: ["user@host ~ %", "output"], cols: cols)
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors.first?.row, 0)
        XCTAssertEqual(anchors.first?.cellCount, "user@host ~ %".count)
    }

    func testStarshipSpacerRowIsSkippedToTheVisiblePrompt() {
        // The exact shape that hid the flash in the field: OSC-133 A on the blank spacer, the
        // two-line starship prompt below it.
        let rows = ["", "slop-desk on  main [!] via  v6.3.2", "❯ echo AAA"]
        let anchors = PromptJumpFlashOverlay.anchorRows(in: rows, cols: cols)
        XCTAssertEqual(anchors.first?.row, 1, "the flash anchors to the block's first TEXT row, not the spacer")
        XCTAssertEqual(anchors.count, 1, "an unwrapped info line flashes exactly one row")
        XCTAssertEqual(anchors.first?.cellCount, rows[1].count)
    }

    func testWrappedPromptLineFlashesEveryContinuationRow() {
        // The second field report: a prompt line WIDER than the grid soft-wraps — a full-width row
        // means the next row continues the same logical line, so the flash must cover them all.
        let grid = 10
        let rows = ["", String(repeating: "a", count: 10), String(repeating: "b", count: 10), "tail", "❯"]
        let anchors = PromptJumpFlashOverlay.anchorRows(in: rows, cols: grid)
        XCTAssertEqual(anchors.map(\.row), [1, 2, 3], "two full rows + the line's short tail row")
        XCTAssertEqual(anchors.map(\.cellCount), [10, 10, 4])
    }

    func testNonFullRowEndsTheLineBeforeTheInputRow() {
        // The info line does NOT fill the grid ⇒ the ❯ input row below is a NEW line, never flashed.
        let rows = ["", "short info", "❯ next line"]
        let anchors = PromptJumpFlashOverlay.anchorRows(in: rows, cols: cols)
        XCTAssertEqual(anchors.map(\.row), [1], "a non-full row is the logical line's end")
    }

    func testPathologicalGridFillingLineIsCapped() {
        let grid = 3
        let rows = Array(repeating: "xxx", count: 8)
        let anchors = PromptJumpFlashOverlay.anchorRows(in: rows, cols: grid)
        XCTAssertEqual(anchors.count, 4, "maxRows caps the walk — never flash half the screen")
    }

    func testWhitespaceOnlyRowNeverAnchors() {
        let anchors = PromptJumpFlashOverlay.anchorRows(in: ["   ", "❯"], cols: cols)
        XCTAssertEqual(anchors.first?.row, 1, "a space-flash reads as a rendering artifact — skip it like a blank")
    }

    func testAllBlankLandingIsAbsentNeverWrong() {
        XCTAssertTrue(
            PromptJumpFlashOverlay.anchorRows(in: ["", "  ", ""], cols: cols).isEmpty,
            "nothing to anchor to ⇒ no flash",
        )
        XCTAssertTrue(
            PromptJumpFlashOverlay.anchorRows(in: [], cols: cols).isEmpty,
            "an empty snapshot (torn-down surface) is silent",
        )
    }

    func testSearchStaysWithinThePromptBlockWindow() {
        // Text BEYOND the search depth must not anchor — flashing row 7 would highlight some
        // unrelated output line far below the pinned prompt block.
        let rows = ["", "", "", "way-below output"]
        XCTAssertTrue(
            PromptJumpFlashOverlay.anchorRows(in: rows, cols: cols).isEmpty,
            "depth 3 bounds the anchor to the prompt block",
        )
    }
}
