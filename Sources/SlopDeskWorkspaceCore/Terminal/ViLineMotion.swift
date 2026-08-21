import CSlopDeskFFI
import Foundation

/// PURE vi word/column motions over ONE terminal row's text, in display CELL columns — the
/// horizontal half of the copy-mode cursor engine (`TerminalViewModel.handleCopyModeKey`).
///
/// ## This is a call, not an implementation
/// The motions are `slopdesk_terminal::vimotion`, reached through the nine `slopdesk_vi_*` doors
/// (docs/55). What used to be here was a second cell walk: a `Character`-by-`Character` scan asking
/// `TerminalLinkDetector.displayCellWidth(of:)` per column, sitting beside the clustering
/// `slopdesk_terminal::link` already ran over the same row for the link and hint overlays. Two
/// clusterings over one row is how a cursor lands half a glyph away from the badge that claims to
/// be on it — on a CJK row, which nobody checks by hand.
///
/// All functions return a landing COLUMN within this row, or `nil` when the motion runs off the
/// row's end/start — the caller (the view model) then wraps to the neighbouring row. Word classes
/// are vim's small-word rules; the crate's header states them. Headless-tested by
/// `ViLineMotionTests`, unchanged across the port.
enum ViLineMotion {
    /// `0` motion / row-wrap landing: column 0 (always valid, even on an empty row).
    static let lineStart = 0

    /// `^` — the first non-blank cell's column, or 0 on a blank row.
    static func firstNonBlank(_ line: String) -> Int {
        landing(line) { slopdesk_vi_first_non_blank($0, $1) } ?? lineStart
    }

    /// `$` — the LAST non-blank cell's column, or `nil` on a blank row (the caller keeps col 0).
    static func lastNonBlank(_ line: String) -> Int? {
        landing(line) { slopdesk_vi_last_non_blank($0, $1) }
    }

    /// `w` — the start of the NEXT word/punct run after `col`, or `nil` when the motion runs off the
    /// row (wrap to the next row's first run).
    static func nextWordStart(_ line: String, from col: Int) -> Int? {
        landing(line) { slopdesk_vi_next_word_start($0, $1, clamped(col)) }
    }

    /// `b` — the start of the CURRENT run when the cursor sits inside one (past its first cell),
    /// else the start of the PREVIOUS run; `nil` when the motion runs off the row's start.
    static func prevWordStart(_ line: String, from col: Int) -> Int? {
        landing(line) { slopdesk_vi_prev_word_start($0, $1, clamped(col)) }
    }

    /// `e` — the END of the current run when the cursor is before it, else the end of the NEXT run;
    /// `nil` when the motion runs off the row (wrap to the next row).
    static func wordEnd(_ line: String, from col: Int) -> Int? {
        landing(line) { slopdesk_vi_word_end($0, $1, clamped(col)) }
    }

    /// The last run on a row for a backward (`b`) wrap-landing: the start of the row's final
    /// word/punct run, or `nil` on a blank row.
    static func lastWordStart(_ line: String) -> Int? {
        landing(line) { slopdesk_vi_last_word_start($0, $1) }
    }

    /// `h`/`l` — the landing column `delta` GLYPHS away over the addressable cells (a wide glyph is
    /// ONE step), clamped at the row's first/last text cell (vim: `h`/`l` never leave the row). A
    /// cursor sitting in the trailing padding steps back INTO the text; a blank row pins column 0.
    static func columnStep(_ line: String, from col: Int, by delta: Int) -> Int {
        landing(line) { slopdesk_vi_column_step($0, $1, clamped(col), delta) } ?? lineStart
    }

    /// The column of the addressable cell CONTAINING `col` — the wide-glyph/padding snap a vertical
    /// motion applies after the curswant clamp (a cursor never sits mid-glyph or in the trailing
    /// padding). Past-extent snaps to the last text cell; a blank row to column 0.
    static func snapToCell(_ line: String, col: Int) -> Int {
        landing(line) { slopdesk_vi_snap_to_cell($0, $1, clamped(col)) } ?? lineStart
    }

    /// The display width of the glyph AT `col` (blank / out-of-range cells read as 1) — the block
    /// cursor's drawn width, so a wide glyph wears a full-width block instead of half a cell.
    static func cellWidth(_ line: String, at col: Int) -> Int {
        landing(line) { slopdesk_vi_cell_width($0, $1, clamped(col)) } ?? 1
    }

    // MARK: The door

    /// A column the caller holds, as the unsigned one the doors take. A negative column is not a
    /// state the view model can reach, and clamping is cheaper than an assertion that would fire in
    /// release as a wrapped, enormous index.
    private static func clamped(_ col: Int) -> Int { max(col, 0) }

    /// One invocation over `line`'s UTF-8, with the door's `-1` wrap sentinel read back as `nil`.
    ///
    /// `withUTF8` on a mutable copy rather than `Array(line.utf8)`: a row is asked about once per
    /// keystroke and the contiguous case — every row that came off `readScreenRow` — copies nothing.
    private static func landing(
        _ line: String,
        _ call: (UnsafePointer<UInt8>?, Int) -> Int,
    ) -> Int? {
        var row = line
        let answer = row.withUTF8 { call($0.baseAddress, $0.count) }
        return answer < 0 ? nil : answer
    }
}
