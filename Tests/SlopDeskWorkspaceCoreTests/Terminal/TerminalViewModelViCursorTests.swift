import Foundation
import SlopDeskTerminal
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - TerminalViewModelViCursorTests (the E17 ceiling lift — cursor path)

/// Exercises the copy-mode CURSOR engine (`TerminalViewModel.handleCopyModeKey` over the
/// ``TerminalSelectionControl`` seam): cursor seeding at entry, column/word/line motions, the
/// viewport-follow scroll, keyboard-STARTED visual selections (char/line/block → native
/// `setSelection`), `o` anchor-swap, Esc leave-visual-then-exit, and the `y`/`Y` yanks — entirely
/// in-memory against ``RecordingSelectionSurface`` (staged `viewportInfo` + row text, recorded
/// selections). NO `NSEvent`, NO `GhosttySurface` (hang-safety rule). The LEGACY (seam-absent)
/// behavior stays pinned by ``TerminalViewModelViMotionTests`` over the base recorder.
@MainActor
final class TerminalViewModelViCursorTests: XCTestCase {
    /// A model over a selection-capable recorder with a staged 80×24 viewport: 100 total screen
    /// rows, viewport showing rows 76…99, terminal cursor at (col 4, row 90).
    private func makeModel(
        viewportTopRow: Int = 76,
        cursorCol: Int = 4,
        cursorRow: Int = 90,
    ) -> (TerminalViewModel, RecordingSelectionSurface) {
        let recorder = RecordingSelectionSurface()
        recorder.info = TerminalViewportInfo(
            viewportTopRow: viewportTopRow,
            viewportRows: 24,
            cols: 80,
            totalRows: 100,
            cursor: TerminalScreenPoint(col: cursorCol, row: cursorRow),
        )
        recorder.screenRows = Array(repeating: "", count: 100)
        let model = TerminalViewModel(surface: recorder)
        model.enterCopyMode()
        return (model, recorder)
    }

    private func key(_ ch: Character, control: Bool = false, shift: Bool = false) -> TerminalViewModel.CopyModeKey {
        .char(ch, control: control, shift: shift)
    }

    // MARK: Entry seeding

    /// Entering copy-mode seeds the vi cursor AT the terminal cursor (tmux parity) and publishes the
    /// viewport-relative overlay cell.
    func testEnterSeedsCursorAtTerminalCursor() {
        let (model, _) = makeModel()
        XCTAssertEqual(
            model.viCursorCell, TerminalViewModel.ViCursorCell(col: 4, row: 90 - 76),
            "the overlay cell is the terminal cursor, viewport-relative",
        )
    }

    // MARK: Column + line motions

    /// `l`/`h` move the cursor column over the row's TEXT (no scroll action — the cursor is client
    /// state) and the repeat-count scales the step.
    func testColumnMotionsMoveCursorWithoutScrolling() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "swift build --verbose"
        model.handleCopyModeKey(key("3"))
        model.handleCopyModeKey(key("l"))
        XCTAssertEqual(model.viCursorCell?.col, 7, "3l steps three columns right")
        model.handleCopyModeKey(key("h"))
        XCTAssertEqual(model.viCursorCell?.col, 6)
        XCTAssertTrue(rec.actions.isEmpty, "column motions never scroll")
    }

    /// `h`/`l` clamp at the row's TEXT extent (vim: the cursor never wanders the grid's trailing
    /// padding) and a blank row pins the cursor to column 0.
    func testColumnMotionsClampToRowText() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "swift"
        model.handleCopyModeKey(key("9"))
        model.handleCopyModeKey(key("l"))
        XCTAssertEqual(model.viCursorCell?.col, 4, "l clamps on the last glyph, not the grid edge")
        rec.screenRows[90] = ""
        model.handleCopyModeKey(key("l"))
        XCTAssertEqual(model.viCursorCell?.col, 0, "a blank row pins column 0")
    }

    /// `j`/`k` move the cursor ROW; inside the viewport no scroll is issued (the pre-lift behavior
    /// scrolled the viewport — the cursor path must not).
    func testLineMotionMovesCursorInsideViewportWithoutScroll() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(model.viCursorCell?.row, 90 - 76 + 1, "j moves the cursor row down")
        XCTAssertTrue(rec.actions.isEmpty, "no scroll while the cursor stays visible")
    }

    /// vim's curswant: a vertical motion clamps to each row's TEXT extent but REMEMBERS the desired
    /// column, so passing through a short line and back restores the original column.
    func testVerticalMotionClampsToRowTextAndRestoresWantColumn() {
        let (model, rec) = makeModel(cursorCol: 10)
        rec.screenRows[90] = "swift build --verbose"
        rec.screenRows[91] = "ok"
        rec.screenRows[92] = "make check golden"
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(model.viCursorCell?.col, 1, "the short row clamps the cursor to its last glyph")
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(model.viCursorCell?.col, 10, "the longer row restores the remembered column")
        model.handleCopyModeKey(key("k"))
        XCTAssertEqual(model.viCursorCell?.col, 1, "…and the clamp re-applies on the way back")
    }

    /// `$` seeds a STICKY end-of-line curswant: subsequent `j` keeps hugging each row's line end.
    func testDollarStickyEndHugsLineEnds() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "swift build --verbose"
        rec.screenRows[91] = "ok"
        rec.screenRows[92] = "make check golden"
        model.handleCopyModeKey(key("$"))
        XCTAssertEqual(model.viCursorCell?.col, 20)
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(model.viCursorCell?.col, 1, "after $ the cursor rides the next row's end")
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(model.viCursorCell?.col, 16, "…and the end of every row after that")
    }

    /// A wide (CJK) glyph is ONE `h`/`l` step, is never straddled, and the drawn block wears its
    /// full 2-cell width.
    func testWideGlyphStepsWholeGlyphsAndWidensTheBlock() {
        // "chào 世界": c0 h1 à2 o3 ␠4 世5–6 界7–8.
        let (model, rec) = makeModel(cursorCol: 5)
        rec.screenRows[90] = "chào 世界"
        model.handleCopyModeKey(key("l"))
        XCTAssertEqual(model.viCursorCell?.col, 7, "l steps one GLYPH (2 cells)")
        XCTAssertEqual(model.viCursorCell?.width, 2, "the block covers the whole wide glyph")
        model.handleCopyModeKey(key("h"))
        XCTAssertEqual(model.viCursorCell?.col, 5)
        XCTAssertEqual(model.viCursorCell?.width, 2)
    }

    /// A line motion past the viewport edge scrolls JUST the overflow (`scroll_page_lines:<delta>`)
    /// — the vi viewport-follows-cursor rule.
    func testLineMotionPastViewportBottomScrollsTheOverflow() {
        // Viewport rows 60…83 (top 60), cursor row 70 → 20j lands on 90, overshooting the bottom by 7.
        let (model, rec) = makeModel(viewportTopRow: 60, cursorRow: 70)
        model.handleCopyModeKey(key("2"))
        model.handleCopyModeKey(key("0"))
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(rec.actions, ["scroll_page_lines:7"], "only the overflow scrolls")
    }

    /// `0`, `^`, `$` land on the row-text columns (read through the seam).
    func testZeroCaretDollarColumnMotions() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "  swift build   "
        model.handleCopyModeKey(key("$"))
        XCTAssertEqual(model.viCursorCell?.col, 12, "$ lands on the last glyph")
        model.handleCopyModeKey(key("0"))
        XCTAssertEqual(model.viCursorCell?.col, 0, "a bare 0 is line-start")
        model.handleCopyModeKey(key("^"))
        XCTAssertEqual(model.viCursorCell?.col, 2, "^ lands on the first non-blank")
        XCTAssertTrue(rec.actions.isEmpty)
    }

    /// `w` steps by vim small-words over the seam's row text and wraps to the next row's first run.
    func testWordMotionStepsAndWrapsRows() {
        let (model, rec) = makeModel(cursorCol: 0)
        rec.screenRows[90] = "make check"
        rec.screenRows[91] = "  done"
        model.handleCopyModeKey(key("w"))
        XCTAssertEqual(model.viCursorCell?.col, 5, "w lands on `check`")
        model.handleCopyModeKey(key("w"))
        XCTAssertEqual(model.viCursorCell?.row, 91 - 76, "w off the row wraps to the next row")
        XCTAssertEqual(model.viCursorCell?.col, 2, "…landing on its first non-blank")
    }

    // MARK: Visual modes drive the NATIVE selection

    /// `v` anchors at the cursor; motions re-issue `setSelection(anchor → cursor)` so libghostty
    /// renders a keyboard-STARTED char selection (the lifted ceiling).
    func testCharVisualStartsSelectionFromCursor() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "swift build"
        model.handleCopyModeKey(key("v"))
        model.handleCopyModeKey(key("l"))
        model.handleCopyModeKey(key("l"))
        XCTAssertEqual(model.viVisualMode, .char)
        XCTAssertEqual(rec.selections.last, RecordingSelectionSurface.SelectionCall(
            anchor: TerminalScreenPoint(col: 4, row: 90),
            head: TerminalScreenPoint(col: 6, row: 90),
            rectangle: false,
        ), "the selection grows from the anchor to the moved cursor")
    }

    /// `V` spans FULL rows regardless of the cursor columns.
    func testLineVisualSpansFullRows() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(key("V", shift: true))
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(rec.selections.last, RecordingSelectionSurface.SelectionCall(
            anchor: TerminalScreenPoint(col: 0, row: 90),
            head: TerminalScreenPoint(col: 79, row: 91),
            rectangle: false,
        ), "line-visual selects whole rows")
    }

    /// `⌃v` sets the rectangle flag (block selection).
    func testBlockVisualSetsRectangle() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "swift build"
        rec.screenRows[91] = "swift test"
        model.handleCopyModeKey(key("v", control: true))
        model.handleCopyModeKey(key("l"))
        model.handleCopyModeKey(key("j"))
        XCTAssertEqual(rec.selections.last, RecordingSelectionSurface.SelectionCall(
            anchor: TerminalScreenPoint(col: 4, row: 90),
            head: TerminalScreenPoint(col: 5, row: 91),
            rectangle: true,
        ), "block-visual is a rectangle from anchor to cursor")
    }

    /// vim `o` swaps anchor↔cursor so motions grow the OTHER end (a real motion since the lift —
    /// the pre-lift `o` was a documented no-op).
    func testAnchorSwapMovesCursorToOtherEnd() {
        let (model, rec) = makeModel()
        rec.screenRows[90] = "swift build"
        model.handleCopyModeKey(key("v"))
        model.handleCopyModeKey(key("l"))
        model.handleCopyModeKey(key("o"))
        XCTAssertEqual(model.viCursorCell?.col, 4, "o moves the cursor to the (former) anchor")
        model.handleCopyModeKey(key("h"))
        XCTAssertEqual(rec.selections.last, RecordingSelectionSurface.SelectionCall(
            anchor: TerminalScreenPoint(col: 5, row: 90),
            head: TerminalScreenPoint(col: 3, row: 90),
            rectangle: false,
        ), "after o the selection grows from the new anchor (the old cursor)")
    }

    /// Esc in a visual mode LEAVES the visual (clearing the native selection) but stays in
    /// copy-mode; a second Esc exits (vim parity).
    func testEscapeLeavesVisualThenExits() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(key("v"))
        model.handleCopyModeKey(.escape)
        XCTAssertEqual(model.viVisualMode, .none, "the first Esc collapses the visual selection")
        XCTAssertEqual(rec.clearSelectionCount, 1, "…clearing the native selection")
        XCTAssertTrue(model.isCopyMode, "…but copy-mode stays armed")
        model.handleCopyModeKey(.escape)
        XCTAssertFalse(model.isCopyMode, "the second Esc exits")
    }

    /// Re-pressing the SAME visual key toggles it off and clears the selection.
    func testSameVisualKeyTogglesOffAndClears() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(key("v"))
        model.handleCopyModeKey(key("v"))
        XCTAssertEqual(model.viVisualMode, .none)
        XCTAssertEqual(rec.clearSelectionCount, 1)
    }

    // MARK: Yank

    /// `y` copies the LIVE selection (the cursor-driven visual range IS libghostty's selection),
    /// exits, and clears the selection on the way out.
    func testYankCopiesLiveSelectionAndExits() {
        let (model, rec) = makeModel()
        var copied: [String] = []
        model.copyToPasteboard = { copied.append($0) }
        model.handleCopyModeKey(key("v"))
        model.handleCopyModeKey(key("l"))
        rec.selectionText = "swif" // what libghostty reads back for the set range
        model.handleCopyModeKey(key("y"))
        XCTAssertEqual(copied, ["swif"], "y yanks the selection libghostty reports")
        XCTAssertFalse(model.isCopyMode, "yank exits the mode")
        XCTAssertEqual(rec.clearSelectionCount, 1, "the cursor-driven selection is cleared on exit")
    }

    /// `Y` yanks the CURSOR ROW's text and exits; a blank row yanks nothing and stays in the mode.
    func testYankLineCopiesCursorRow() {
        let (model, rec) = makeModel()
        var copied: [String] = []
        model.copyToPasteboard = { copied.append($0) }
        model.handleCopyModeKey(key("Y", shift: true))
        XCTAssertTrue(copied.isEmpty, "a blank cursor row yanks nothing")
        XCTAssertTrue(model.isCopyMode, "…and the mode stays put")
        rec.screenRows[90] = "git push"
        model.handleCopyModeKey(key("Y", shift: true))
        XCTAssertEqual(copied, ["git push"], "Y yanks the cursor row's text")
        XCTAssertFalse(model.isCopyMode)
    }

    // MARK: Absolute + page jumps keep cursor and viewport together

    /// `g`/`G` land the cursor on the first / last TEXT row (the active grid's blank tail rows are
    /// padding, never a landing — vim's `G`) alongside the native scroll action, on the row's first
    /// non-blank glyph.
    func testAbsoluteJumpsMoveCursor() {
        let (model, rec) = makeModel()
        rec.screenRows[97] = "  ❯ make check"
        model.handleCopyModeKey(key("g"))
        XCTAssertEqual(rec.actions, ["scroll_to_top"])
        XCTAssertNil(model.viCursorCell, "row 0 is off the (staged) viewport — the overlay hides, never lies")
        model.handleCopyModeKey(key("G", shift: true))
        XCTAssertEqual(rec.actions, ["scroll_to_top", "scroll_to_bottom"])
        XCTAssertEqual(model.viCursorCell?.row, 97 - 76, "G lands on the LAST TEXT row, skipping blank tail rows")
        XCTAssertEqual(model.viCursorCell?.col, 2, "…on its first non-blank glyph")
    }

    /// `[` re-anchors the cursor to the landed prompt row's first glyph (the viewport top after the
    /// native `jump_to_prompt:` pinned the prompt there).
    func testPromptJumpLandsOnPromptRowFirstGlyph() {
        let (model, rec) = makeModel()
        rec.screenRows[76] = "  ❯ swift test"
        model.handleCopyModeKey(key("["))
        XCTAssertEqual(rec.actions, ["jump_to_prompt:-1"])
        XCTAssertEqual(model.viCursorCell?.row, 0, "the cursor re-anchors to the landed viewport top")
        XCTAssertEqual(model.viCursorCell?.col, 2, "…on the prompt row's first non-blank glyph")
    }

    /// `⌃d` scrolls a half page in LINES (cursor + viewport move together on the cursor path).
    func testHalfPageMovesCursorAndViewportTogether() {
        let (model, rec) = makeModel()
        model.handleCopyModeKey(key("d", control: true))
        XCTAssertEqual(rec.actions, ["scroll_page_lines:12"], "⌃d = half the viewport, as a line delta")
    }

    // MARK: Overlay honesty

    /// A renderer scroll echo re-derives the overlay cell from fresh truth (a wheel scroll during
    /// copy-mode moves the drawn cursor without any key).
    func testScrollEchoResyncsOverlayCell() {
        let (model, rec) = makeModel()
        XCTAssertEqual(model.viCursorCell?.row, 14)
        rec.info?.viewportTopRow = 80 // the user wheel-scrolled down 4 rows
        model.noteViewportScroll(atBottom: false)
        XCTAssertEqual(model.viCursorCell?.row, 10, "the overlay cell follows the fresh viewport readback")
    }
}
