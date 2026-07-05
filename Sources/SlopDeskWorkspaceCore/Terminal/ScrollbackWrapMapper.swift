import Foundation

// MARK: - ScrollbackWrapMapper (logical-line → physical-row coordinate mapping)

/// The PURE bridge between the two DIFFERENT row indexings the ⌘F find bar and ⇧⌘F Global Search juggle:
///
///  - The scrollback text mirror (``TerminalViewModel/searchScrollbackLines()`` →
///    `ghostty_surface_read_text` with `.unwrap = true`) returns logically-UNWRAPPED lines — a soft-wrapped
///    line spanning N grid rows collapses to ONE array entry. So a ``TerminalSearchController/Match`` /
///    ``GlobalSearchHit`` `line` is a LOGICAL line index.
///  - libghostty's `scroll_to_row:<usize>` addresses PHYSICAL grid rows (PageList rows) — every soft-wrap
///    continuation counts as its own row.
///
/// Feeding a logical index straight into `scroll_to_row` lands the viewport N rows too high, where N is the
/// number of wrap-continuation rows ABOVE the target. This maps a logical line index to the physical row it
/// STARTS on by summing each preceding logical line's wrapped-row count.
///
/// Pure + fully unit-testable — no view, no libghostty, no store. The grid column count is passed in by the
/// caller (resolved through the ``TerminalSurfaceActions`` seam); when it is unknown (headless / pre-layout,
/// `columns <= 0`) the mapping degrades to the identity (no wrap compensation) so behaviour is never worse
/// than the un-mapped path.
public enum ScrollbackWrapMapper {
    /// The physical (wrapped) grid row that logical line `logicalLine` STARTS on within `lines`, given the
    /// live grid `columns`. Each logical line of display width `W` occupies `max(1, ceil(W / columns))`
    /// physical rows (ghostty wraps at the grid edge with no continuation indent); the physical row of
    /// `logicalLine` is the sum of the physical-row counts of every line above it.
    ///
    /// Degrades to the identity (`logicalLine`) when `columns <= 0` (grid width unknown) so a caller that
    /// cannot resolve the grid width still scrolls exactly where the un-mapped code did. Display width uses
    /// the SAME East-Asian-wide-aware cell measure as ``TerminalLinkDetector`` (a fullwidth glyph is 2 cells).
    public static func physicalRow(forLogicalLine logicalLine: Int, in lines: [String], columns: Int) -> Int {
        guard columns > 0, logicalLine > 0 else { return Swift.max(0, logicalLine) }
        var row = 0
        let upper = Swift.min(logicalLine, lines.count)
        var index = 0
        while index < upper {
            row += wrappedRowCount(of: lines[index], columns: columns)
            index += 1
        }
        // A logical index past the mirror's end (a stale snapshot) contributes one physical row each — never
        // trap / under-count on a shrunk buffer.
        if logicalLine > lines.count {
            row += logicalLine - lines.count
        }
        return row
    }

    /// The number of physical grid rows a single logical line occupies at width `columns`: `1` for an empty
    /// (or zero-width) line, else `ceil(displayWidth / columns)`. `columns` is assumed `> 0` (the caller
    /// guards it).
    private static func wrappedRowCount(of line: String, columns: Int) -> Int {
        let width = TerminalLinkDetector.displayCellWidth(of: line)
        guard width > 0 else { return 1 }
        return (width + columns - 1) / columns
    }
}
