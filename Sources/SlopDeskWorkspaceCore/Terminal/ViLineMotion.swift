import Foundation

/// PURE vi word/column motions over ONE terminal row's text, in display CELL columns — the
/// horizontal half of the copy-mode cursor engine (`TerminalViewModel.handleCopyModeKey`).
///
/// Columns are display cells (East-Asian-wide / fullwidth glyphs advance 2, zero-width combiners 0)
/// via ``TerminalLinkDetector/displayCellWidth(of:)`` — the SAME width logic the hint/underline
/// overlays use, so a cursor landed by `w` can never drift from the column a hint badge would claim
/// for the same character.
///
/// Word classes are vim's small-word rules: a WORD run is letters/digits/underscore, a PUNCT run is
/// any other non-blank, whitespace separates runs and is never a landing cell. All functions return
/// a landing COLUMN within this row, or `nil` when the motion runs off the row's end/start — the
/// caller (the view model) then wraps to the neighbouring row. Headless-tested by `ViLineMotionTests`.
enum ViLineMotion {
    /// One grapheme cluster with the display column it starts at. Zero-width clusters are dropped
    /// (they attach to the preceding base and never carry a cursor).
    struct CellChar: Equatable {
        let col: Int
        let char: Character
    }

    /// vim's three small-word character classes.
    enum CharClass: Equatable {
        case whitespace
        case word
        case punct
    }

    static func charClass(_ char: Character) -> CharClass {
        if char.isWhitespace { return .whitespace }
        if char.isLetter || char.isNumber || char == "_" { return .word }
        return .punct
    }

    /// Maps a row's text to its display cells (one entry per non-zero-width grapheme, carrying the
    /// column it starts at).
    static func cells(_ line: String) -> [CellChar] {
        var out: [CellChar] = []
        var col = 0
        for char in line {
            let width = TerminalLinkDetector.displayCellWidth(of: char)
            if width == 0 { continue }
            out.append(CellChar(col: col, char: char))
            col += width
        }
        return out
    }

    /// The cells index of the cell CONTAINING `col` (a cursor mid-wide-glyph belongs to that glyph),
    /// or `nil` for an empty row / a column past the last cell (the caller clamps first).
    private static func index(of col: Int, in cells: [CellChar]) -> Int? {
        var found: Int?
        for (i, cell) in cells.enumerated() where cell.col <= col {
            found = i
        }
        return found
    }

    /// `0` motion / row-wrap landing: column 0 (always valid, even on an empty row).
    static let lineStart = 0

    /// `^` — the first non-blank cell's column, or 0 on a blank row.
    static func firstNonBlank(_ line: String) -> Int {
        for cell in cells(line) where charClass(cell.char) != .whitespace {
            return cell.col
        }
        return 0
    }

    /// `$` — the LAST non-blank cell's column, or `nil` on a blank row (the caller keeps col 0).
    static func lastNonBlank(_ line: String) -> Int? {
        var found: Int?
        for cell in cells(line) where charClass(cell.char) != .whitespace {
            found = cell.col
        }
        return found
    }

    /// `w` — the start of the NEXT word/punct run after `col`, or `nil` when the motion runs off the
    /// row (wrap to the next row's first run). Leaving the current run and changing class both count
    /// as a new run (vim: `foo(bar` steps `f`→`(`→`b`).
    static func nextWordStart(_ line: String, from col: Int) -> Int? {
        let cells = cells(line)
        guard let start = index(of: col, in: cells) else { return nil }
        let startClass = charClass(cells[start].char)
        var i = start
        // Skip the rest of the current run (whitespace has no run to skip — fall straight through).
        if startClass != .whitespace {
            while i + 1 < cells.count, charClass(cells[i + 1].char) == startClass {
                i += 1
            }
        }
        // Step past the run, then past any whitespace, landing on the next run's first cell.
        i += 1
        while i < cells.count, charClass(cells[i].char) == .whitespace {
            i += 1
        }
        guard i < cells.count else { return nil }
        return cells[i].col
    }

    /// `b` — the start of the CURRENT run when the cursor sits inside one (past its first cell),
    /// else the start of the PREVIOUS run; `nil` when the motion runs off the row's start (wrap to
    /// the previous row's last run).
    static func prevWordStart(_ line: String, from col: Int) -> Int? {
        let cells = cells(line)
        guard var i = index(of: col, in: cells) else { return nil }
        let startClass = charClass(cells[i].char)
        let runStart = runStartIndex(cells, at: i)
        if startClass != .whitespace, cells[runStart].col < col {
            // Inside a run past its first cell → land on this run's start.
            return cells[runStart].col
        }
        // At a run's first cell (or on whitespace) → walk left past whitespace to the previous run.
        i = runStart
        i -= 1
        while i >= 0, charClass(cells[i].char) == .whitespace {
            i -= 1
        }
        guard i >= 0 else { return nil }
        return cells[runStartIndex(cells, at: i)].col
    }

    /// `e` — the END of the current run when the cursor is before it, else the end of the NEXT run;
    /// `nil` when the motion runs off the row (wrap to the next row).
    static func wordEnd(_ line: String, from col: Int) -> Int? {
        let cells = cells(line)
        guard var i = index(of: col, in: cells) else { return nil }
        let startClass = charClass(cells[i].char)
        if startClass != .whitespace {
            let end = runEndIndex(cells, at: i)
            if cells[end].col > col { return cells[end].col }
            i = end
        }
        // At the current run's end (or on whitespace) → step to the next run and land on ITS end.
        i += 1
        while i < cells.count, charClass(cells[i].char) == .whitespace {
            i += 1
        }
        guard i < cells.count else { return nil }
        return cells[runEndIndex(cells, at: i)].col
    }

    /// The row's cursor-ADDRESSABLE cells: the display cells trimmed of TRAILING whitespace. A
    /// terminal row right-pads to the grid width, so trailing blanks are padding, never text — the
    /// vi cursor lives on these cells only (vim/tmux: the cursor follows the line, not the grid).
    static func addressableCells(_ line: String) -> [CellChar] {
        var cells = cells(line)
        while let last = cells.last, charClass(last.char) == .whitespace {
            cells.removeLast()
        }
        return cells
    }

    /// `h`/`l` — the landing column `delta` GLYPHS away over the addressable cells (a wide glyph is
    /// ONE step), clamped at the row's first/last text cell (vim: `h`/`l` never leave the row). A
    /// cursor sitting in the trailing padding steps back INTO the text; a blank row pins column 0.
    static func columnStep(_ line: String, from col: Int, by delta: Int) -> Int {
        let cells = addressableCells(line)
        guard !cells.isEmpty else { return 0 }
        var index = 0
        for (i, cell) in cells.enumerated() where cell.col <= col {
            index = i
        }
        let landed = min(max(index + delta, 0), cells.count - 1)
        return cells[landed].col
    }

    /// The column of the addressable cell CONTAINING `col` — the wide-glyph/padding snap a vertical
    /// motion applies after the curswant clamp (a cursor never sits mid-glyph or in the trailing
    /// padding). Past-extent snaps to the last text cell; a blank row to column 0.
    static func snapToCell(_ line: String, col: Int) -> Int {
        var found = 0
        for cell in addressableCells(line) where cell.col <= col {
            found = cell.col
        }
        return found
    }

    /// The display width of the glyph AT `col` (blank / out-of-range cells read as 1) — the block
    /// cursor's drawn width, so a wide glyph wears a full-width block instead of half a cell.
    static func cellWidth(_ line: String, at col: Int) -> Int {
        for cell in cells(line) where cell.col == col {
            return max(1, TerminalLinkDetector.displayCellWidth(of: cell.char))
        }
        return 1
    }

    /// The last run on a row for a backward (`b`) wrap-landing: the start of the row's final
    /// word/punct run, or `nil` on a blank row.
    static func lastWordStart(_ line: String) -> Int? {
        let cells = cells(line)
        var i = cells.count - 1
        while i >= 0, charClass(cells[i].char) == .whitespace {
            i -= 1
        }
        guard i >= 0 else { return nil }
        return cells[runStartIndex(cells, at: i)].col
    }

    /// The index of the first cell of the same-class run containing `i` (whitespace is its own run).
    private static func runStartIndex(_ cells: [CellChar], at i: Int) -> Int {
        let cls = charClass(cells[i].char)
        var j = i
        while j - 1 >= 0, charClass(cells[j - 1].char) == cls {
            j -= 1
        }
        return j
    }

    /// The index of the last cell of the same-class run containing `i`.
    private static func runEndIndex(_ cells: [CellChar], at i: Int) -> Int {
        let cls = charClass(cells[i].char)
        var j = i
        while j + 1 < cells.count, charClass(cells[j + 1].char) == cls {
            j += 1
        }
        return j
    }
}
