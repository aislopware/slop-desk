// TerminalLinkHitTest — which detected link a point lands on, as the Swift face of
// `rust/slopdesk-terminal`'s `link_hit`, reached through `rust/slopdesk-ffi`'s `link_hit` door.
//
// ## What is not here any more
//
// The rule. The cell division, the exclusive `colEnd`, the two-pass order that lets a slop only ever
// ADD an answer, the span rect the widened pass measures against, and the two-key `(dy, dx)`
// tie-break that keeps the earlier span. All Rust's, in a crate that forbids `unsafe`, beside the
// `link` scan that mints the very records this function is asked about.
//
// That adjacency is the whole argument for the port rather than a nicety. A ``DetectedLink`` is
// already a Rust record: `slopdesk_terminal::link` produces it and ``TerminalLinkDetector``
// reassembles it here through `slopdesk_link_scan_*`. So the hit-test was arithmetic over data Rust
// had handed across the boundary one call earlier, written in the language that merely received it —
// and `colEnd`'s exclusivity, which is the scan's own convention, was a fact two languages had to
// keep agreeing about. Now one of them knows it.
//
// ## Why the spans go over and only an INDEX comes back
//
// The caller is holding the `[DetectedLink]` it just detected, and the rule reads three numbers out
// of each — row, first cell, one past the last — and none of the text. So the door takes those
// triples packed into one `[Int]` and answers the index of the winner, `-1` for none, which is
// outside `0 ..< links.count` by construction. This side then subscripts the array it already has:
// no record is marshalled back, no string is copied, and the callers that want a path still read
// `resolvedAbsolute ?? raw` off a value that never left.
//
// ## Why this is not two functions any more
//
// (Kept, because it is the reason the file exists at all.) The question "what link is under this
// point" was once asked twice, in two places, by two spellings of the same six lines.
// `TerminalViewModel.hoveredLinkPath(…)` asked it and answered with a PATH; the embedder's
// `detectedLink(at:)` asked it inside a whole-file `#if os(macOS)` and answered with the LINK — and
// the second one's doc comment said, in as many words, that it "mirrors" the first. A mirror is a
// second implementation wearing a citation, and this one had the worse property of the two: the copy
// production actually ran was the one no test could reach, because it lived in a file no
// `Package.swift` target compiles and behind a gate the phone never sees. The Mac's hover, the Mac's
// ⌘click, the Mac's right-click menu and the phone's long-press menu are four callers of one
// function now — and as of this port, of one implementation.
//
// ## The slop, and why a parameter rather than a constant
//
// A pointer is one pixel and lands where it is aimed; a fingertip is a contact patch tens of points
// wide whose reported centre is a guess. A cell at the default face is about 8 × 17 points, so a
// touch that a person would swear landed on a path can resolve two cells off it — and the phone gets
// ONE shot at the question, on the release of a long press, with no hover to correct it. The Mac
// keeps its exact reading (`slop: 0` is bit-for-bit the old cell hit-test, and the exact-cell pass
// runs FIRST for every caller, so a slop can only ever add an answer where there was none). The
// phone passes ``TerminalTouchSelection/linkHitSlop``, which is a touch number and lives with the
// other touch numbers.
//
// ## The one thing the rule could not take with it
//
// The widened pass used to measure against ``TerminalCellMetrics/rect(row:colStart:colEnd:)`` so the
// grid geometry would not be written a third time; `link_hit.rs` derives those edges itself, and
// that module's docs record the resulting cross-language pair and why the drawing half cannot follow
// it today (`TerminalCellMetrics` lives in `SlopDeskTerminal`, which links nothing). What holds the
// two together meanwhile is that the slop cases in this module's tests are hand-computed from the
// rect's own numbers, so an edge that moved on either side fails a named case.

import CoreGraphics
import CSlopDeskFFI

/// The PURE point → detected-link hit-test both halves of the terminal renderer run.
public enum TerminalLinkHitTest {
    /// The 0-based `(row, column)` cell under a top-left-origin `point` in POINTS (the surface's own
    /// coordinate convention, the one `sendMousePos` and ``TerminalCellMetrics`` both speak), or `nil` for
    /// degenerate geometry (a zero cell size — nothing can divide) or a point above / left of the
    /// viewport origin, which is dropped rather than force-floored to cell 0.
    ///
    /// Cell `(0, 0)` is the most ordinary landing a point has, so the door cannot spend a value on "no
    /// cell": the answer crosses as a pair plus a flag, and the flag is read first.
    public static func cell(
        metrics: TerminalCellMetrics,
        pointX: CGFloat,
        pointY: CGFloat,
    ) -> (row: Int, column: Int)? {
        let answer = slopdesk_link_hit_cell(
            Double(metrics.cellWidth),
            Double(metrics.cellHeight),
            Double(metrics.originX),
            Double(metrics.originY),
            Double(pointX),
            Double(pointY),
        )
        guard answer.hit else { return nil }
        return (answer.row, answer.column)
    }

    /// The link in `links` under a top-left-origin point, or `nil` when the point is over none.
    ///
    /// Two passes, and the order is the whole contract:
    ///
    /// 1. **The exact cell.** `colEnd` is exclusive, matching ``TerminalLinkDetector``, and the first
    ///    match in the detector's row-major order wins. With the default `slop` this is the ONLY pass, so
    ///    a pointer's reading is unchanged by the existence of the second one.
    /// 2. **Within `slop` points**, when a positive one is given and the exact cell hit nothing: the
    ///    NEAREST span whose rect is within `slop` on both axes, nearest measured vertically first
    ///    (a row is the coarser mistake a finger makes) and then horizontally. A point above / left of
    ///    the origin is eligible here even though pass 1 dropped it — that is exactly the finger that
    ///    landed a hair off the first row.
    ///
    /// - Parameters:
    ///   - links: the detected spans for the SAME rows the metrics describe (the viewport snapshot).
    ///   - metrics: the live cell geometry, in points.
    ///   - slop: how far off a span the point may be and still count, in points. `0` (the default) is an
    ///     exact cell hit-test.
    public static func link(
        in links: [DetectedLink],
        metrics: TerminalCellMetrics,
        pointX: CGFloat,
        pointY: CGFloat,
        slop: CGFloat = 0,
    ) -> DetectedLink? {
        var spans: [Int] = []
        spans.reserveCapacity(links.count * 3)
        for link in links {
            spans.append(link.row)
            spans.append(link.colStart)
            spans.append(link.colEnd)
        }
        // One borrow for the whole list: the door reads `links.count` triples and nothing past them, so
        // the buffer's scope IS the safety contract and there is nothing between the two.
        let index = spans.withUnsafeBufferPointer { buffer in
            slopdesk_link_hit_span(
                buffer.baseAddress,
                links.count,
                Double(metrics.cellWidth),
                Double(metrics.cellHeight),
                Double(metrics.originX),
                Double(metrics.originY),
                Double(pointX),
                Double(pointY),
                Double(slop),
            )
        }
        // `-1` is the refusal. The upper bound is checked as well rather than trusted: an index this
        // side cannot subscript is a boundary disagreement, and answering `nil` is what the caller
        // would have got anyway.
        guard index >= 0, index < links.count else { return nil }
        return links[index]
    }
}
