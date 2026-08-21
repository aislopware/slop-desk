// The logical-line → physical-row coordinate mapping the ⌘F find bar and ⇧⌘F Global Search scroll
// by, as the Swift face of `rust/slopdesk-terminal`'s `wrap_map`, reached through
// `rust/slopdesk-ffi`'s `wrap_map` door.
//
// ## What is not here any more
//
// The sum. Counting each preceding logical line's wrapped rows, the `ceil(width / columns)` that
// says how many a line takes, the "an empty line is still one row" floor, the "a line exactly
// `columns` wide has not wrapped yet" edge, the phantom rows a stale index past the mirror's end
// contributes, and the degrade-to-identity when the grid width is unknown. All Rust's, in a crate
// that forbids `unsafe`. This file owns the marshalling and nothing else.
//
// ## Why the loop moved
//
// It was already crossing the FFI boundary once per line. Each iteration asked
// `TerminalLinkDetector.displayCellWidth(of: String)` for the line's display width, and that is
// `slopdesk_link_text_cells` — a door. So mapping a match at logical line N cost N non-inlinable
// crossings to run one loop, and a ⇧⌘F hit deep in a long scrollback is exactly where N is large.
// The lines now cross ONCE, as the flat `(blob, lengths)` pair the link and hint scans already take
// their rows in, and the walk runs on the far side where a width is an ordinary function call.
//
// The other half of the argument is that the width MEASURE and the wrap arithmetic are now one file
// apart instead of one language apart, so the find bar's scroll target and the link overlay's
// columns cannot start disagreeing about how wide a CJK row is.

import CSlopDeskFFI

// MARK: - The face

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
///
/// Pinned by `ScrollbackWrapMapperTests` on this side — which now drives the whole crossing — and by
/// `rust/slopdesk-terminal/src/wrap_map.rs`'s own tests on the other.
public enum ScrollbackWrapMapper {
    /// The physical (wrapped) grid row that logical line `logicalLine` STARTS on within `lines`, given the
    /// live grid `columns`.
    ///
    /// Every rule behind the answer — the per-line `max(1, ceil(width / columns))`, the identity when
    /// `columns <= 0`, the floor at zero for a bogus index, and the one phantom row per index past the
    /// mirror's end — belongs to `slopdesk_terminal::wrap_map`. Both counts cross as `intptr_t` rather than
    /// `size_t` precisely so their SIGN survives: `columns <= 0` is how a caller says it could not resolve
    /// the grid width, and widening that to `SIZE_MAX` on the way over would ask a different question.
    ///
    /// Display width uses the SAME East-Asian-wide-aware cell measure as ``TerminalLinkDetector``, because
    /// it is literally the same table — the rule calls `slopdesk_terminal::link::text_cells` with no
    /// crossing at all.
    public static func physicalRow(forLogicalLine logicalLine: Int, in lines: [String], columns: Int) -> Int {
        // `flatten` is the boundary's list-of-strings form, shared with the link and hint scans rather
        // than copied: one UTF-8 buffer and one BYTE length per line. A second spelling of it here would
        // be a second place for a byte-versus-character mistake to live.
        let (blob, lengths) = TerminalLinkDetector.flatten(lines)
        return slopdesk_scrollback_physical_row(
            blob, blob.count,
            lengths, lengths.count,
            logicalLine, columns,
        )
    }
}
