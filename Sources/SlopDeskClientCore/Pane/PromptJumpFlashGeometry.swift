// PromptJumpFlashGeometry — where the prompt-jump "landed" flash paints, as a value (docs/56 §3).
//
// A ⌘PageUp/⌘PageDown (or navigator) prompt jump replaces the whole viewport in one frame — the eye has
// no scroll motion to follow, so the user lands with zero orientation. The overlay paints ONE accent
// fade over the landed prompt row the instant the jump settles. WHERE that row is has nothing to do
// with SwiftUI: it is a walk over the viewport's text rows plus a `TerminalCellMetrics` mapping, and it
// was already `static` and pure inside a view for exactly that reason.
//
// It lives here rather than in `SlopDeskTerminal` because the alt-screen gate is a decision about the
// pane's MODE, not about the grid: an alt-screen TUI has no prompt block to anchor to, so the honest
// answer is no flash at all (absent, never wrong — the rule the whole decoration family keeps).

import CoreGraphics
import Foundation
import SlopDeskTerminal

/// The landed-flash anchor rules and the rects they map to.
package enum PromptJumpFlashGeometry {
    /// One anchored row: which viewport row, and how many cells of it carry text.
    package struct Anchor: Equatable, Sendable {
        package var row: Int
        package var cellCount: Int

        package init(row: Int, cellCount: Int) {
            self.row = row
            self.cellCount = cellCount
        }
    }

    /// The viewport rows the flash anchors to: the first row with visible TEXT within the top
    /// `searchDepth` rows, PLUS that line's soft-wrap continuations.
    ///
    /// libghostty pins the jumped-to prompt at row 0, but the OSC-133 `A` mark is emitted at the
    /// pre-prompt cursor position — with a spacer-printing prompt (starship's default `add_newline`
    /// blank line) the PINNED row is that BLANK spacer and the visible prompt text sits on row 1/2. A
    /// whitespace-only row never anchors (a space-flash reads as a rendering artifact); all blank ⇒
    /// empty (absent, never wrong).
    ///
    /// WRAP RULE: a row whose text fills the whole grid width soft-wrapped, so the next row continues
    /// the SAME logical prompt line — the flash walks those continuations (field report: a wrapped
    /// prompt flashed only its first row, reading as a truncated cue). The walk stops at the first
    /// non-full row (the line's true end), a blank row, or the `maxRows` cap (a pathological
    /// grid-filling line must not flash half the screen). An exactly-grid-width line over-includes at
    /// most one following row — benign versus under-flashing every wrapped prompt.
    ///
    /// `cellCount` is the row's grapheme count — under-measures a wide (2-cell) glyph's span,
    /// acceptable: the flash covers the text from column 0, just stopping a few cells early on
    /// CJK-heavy prompts (and its wrap detection errs the same safe way: a wide-glyph row reads as
    /// non-full, ending the walk early rather than over-flashing).
    package static func anchorRows(
        in rows: [String], cols: Int, searchDepth: Int = 3, maxRows: Int = 4,
    ) -> [Anchor] {
        var anchor: Int?
        for (index, text) in rows.prefix(searchDepth).enumerated()
            where !text.trimmingCharacters(in: .whitespaces).isEmpty
        {
            anchor = index
            break
        }
        guard let start = anchor else { return [] }
        var result: [Anchor] = []
        var row = start
        while row < rows.count, result.count < maxRows {
            let cellCount = rows[row].count
            guard cellCount > 0 else { break }
            result.append(Anchor(row: row, cellCount: cellCount))
            guard cols > 0, cellCount >= cols else { break } // a non-full row ends the logical line
            row += 1
        }
        return result
    }

    /// The landed prompt line's rects: each anchored row spanning that row's text extent (a
    /// full-grid-width bar reads as a selection band; the line's own width reads as "this line").
    ///
    /// Empty — no flash — for an alt-screen TUI, a surface with no usable cell metrics (a placeholder
    /// has none), or a blank landing (nothing to anchor to). The composition is the whole decision: the
    /// view's job after this is a `Rectangle` per rect and one shared opacity.
    package static func rects(
        rows: [String], metrics: TerminalCellMetrics?, isAlternateScreen: Bool,
    ) -> [CGRect] {
        guard !isAlternateScreen,
              let metrics, metrics.cellWidth > 0, metrics.cellHeight > 0
        else { return [] }
        return anchorRows(in: rows, cols: metrics.cols)
            .compactMap { metrics.clampedRect(row: $0.row, colStart: 0, colEnd: $0.cellCount) }
    }
}
