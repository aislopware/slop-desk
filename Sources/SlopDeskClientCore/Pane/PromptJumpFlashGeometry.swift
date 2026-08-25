// PromptJumpFlashGeometry — the FACE over `slopdesk_terminal::prompt_flash` (docs/56 §3).
//
// A ⌘PageUp/⌘PageDown (or navigator) prompt jump replaces the whole viewport in one frame — the eye
// has no scroll motion to follow, so the user lands with zero orientation. The overlay paints ONE
// accent fade over the landed prompt row the instant the jump settles.
//
// WHERE that row is is the crate's: the spacer skip, the soft-wrap walk, the row cap and the
// grapheme count all live in `prompt_flash` and are pinned there. What is left here is the two
// things a Rust crate has no business deciding — the alt-screen GATE, which is a fact about the
// pane's mode rather than about the grid (an alt-screen TUI has no prompt block to anchor to, so
// the honest answer is no flash at all), and the CELL→RECT mapping, which is the surface's own
// metrics.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import SlopDeskTerminal
import SlopDeskWorkspaceModel

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

    /// The viewport rows the flash anchors to, walked across the door in one crossing.
    ///
    /// Empty for an all-blank landing or a torn-down surface — absent, never wrong.
    package static func anchorRows(in rows: [String], cols: Int) -> [Anchor] {
        var arena = WsStrings()
        let spans = rows.map { arena.span($0) }
        let blob = spans.withUnsafeBufferPointer { lentSpans in
            arena.bytes.withUnsafeBufferPointer { lent in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_prompt_flash_anchors(
                        lentSpans.baseAddress, lentSpans.count,
                        lent.baseAddress, lent.count,
                        Swift.max(0, cols), out, cap,
                    ))
                }
            }
        }
        // `[u32 anchor_count]` then that many `[u32 row][u32 cell_count]`.
        guard blob.count >= 4 else { return [] }
        let word = { (at: Int) -> Int in
            Int(blob[at]) << 24 | Int(blob[at + 1]) << 16 | Int(blob[at + 2]) << 8 | Int(blob[at + 3])
        }
        let count = word(0)
        guard blob.count >= 4 + count * 8 else { return [] }
        return (0..<count).map { Anchor(row: word(4 + $0 * 8), cellCount: word(8 + $0 * 8)) }
    }

    /// The landed prompt line's rects: each anchored row spanning that row's text extent (a
    /// full-grid-width bar reads as a selection band; the line's own width reads as "this line").
    ///
    /// Empty — no flash — for an alt-screen TUI, a surface with no usable cell metrics (a
    /// placeholder has none), or a blank landing. The composition is the whole decision: the view's
    /// job after this is a `Rectangle` per rect and one shared opacity.
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
