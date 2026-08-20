// TerminalLinkHitTest — which detected link a point lands on, answered once for a cursor and for a
// fingertip.
//
// ## Why this is not two functions any more
//
// The question "what link is under this point" was asked twice, in two places, by two spellings of the
// same six lines. `TerminalViewModel.hoveredLinkPath(rows:cwd:schemes:metrics:pointX:pointY:)` asked it
// and answered with a PATH; the embedder's `detectedLink(at:)` asked it inside a whole-file
// `#if os(macOS)` and answered with the LINK — and the second one's doc comment said, in as many words,
// that it "mirrors" the first. A mirror is a second implementation wearing a citation, and this one had
// the worse property of the two: the copy that production actually ran was the one no test could reach,
// because it lived in a file no `Package.swift` target compiles and behind a gate the phone never sees.
//
// So the cell math is HERE, once, in the shape the callers actually want — the link itself, from which a
// path is `resolvedAbsolute ?? raw` at the one call site that still wants a path. The Mac's hover, the
// Mac's ⌘click, the Mac's right-click menu and the phone's long-press menu are now four callers of one
// function instead of two functions serving three-and-a-half callers.
//
// ## The slop, and why a parameter rather than a constant
//
// A pointer is one pixel and lands where it is aimed; a fingertip is a contact patch tens of points wide
// whose reported centre is a guess. A cell at the default face is about 8 × 17 points, so a touch that a
// person would swear landed on a path can resolve two cells off it — and the phone gets ONE shot at the
// question, on the release of a long press, with no hover to correct it. The Mac keeps its exact reading
// (`slop: 0` is bit-for-bit the old cell hit-test, and the exact-cell pass runs FIRST for every caller,
// so a slop can only ever add an answer where there was none). The phone passes
// ``TerminalTouchSelection/linkHitSlop``, which is a touch number and lives with the other touch numbers.
//
// Plain separate `*`/`+`/`/` and `CGFloat.maximum`, never `addingProduct` / a `<` ternary (CLAUDE.md's
// bit-exact habit — view geometry keeps it too), and the widened pass measures against
// ``TerminalCellMetrics/rect(row:colStart:colEnd:)`` rather than re-deriving a span's edges, so there is
// no third copy of the grid geometry either.

import CoreGraphics
import SlopDeskTerminal

/// The PURE point → detected-link hit-test both halves of the terminal renderer run.
public enum TerminalLinkHitTest {
    /// The 0-based `(row, column)` cell under a top-left-origin `point` in POINTS (the surface's own
    /// coordinate convention, the one `sendMousePos` and ``TerminalCellMetrics`` both speak), or `nil` for
    /// degenerate geometry (a zero cell size — nothing can divide) or a point above / left of the
    /// viewport origin, which is dropped rather than force-floored to cell 0.
    ///
    /// `Int(_:)` of a guaranteed-non-negative ratio truncates toward zero, i.e. floors.
    public static func cell(
        metrics: TerminalCellMetrics,
        pointX: CGFloat,
        pointY: CGFloat,
    ) -> (row: Int, column: Int)? {
        guard metrics.cellWidth > 0, metrics.cellHeight > 0 else { return nil }
        guard pointX >= metrics.originX, pointY >= metrics.originY else { return nil }
        let column = Int((pointX - metrics.originX) / metrics.cellWidth)
        let row = Int((pointY - metrics.originY) / metrics.cellHeight)
        guard row >= 0, column >= 0 else { return nil }
        return (row, column)
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
        if let hit = cell(metrics: metrics, pointX: pointX, pointY: pointY) {
            let exact = links.first { $0.row == hit.row && hit.column >= $0.colStart && hit.column < $0.colEnd }
            if let exact { return exact }
        }
        guard slop > 0, metrics.cellWidth > 0, metrics.cellHeight > 0 else { return nil }
        // The candidate's distance is a pair, not a scalar: collapsing it to one number would need a
        // weighting nobody can defend, and a pair orders the two mistakes in the order a finger makes
        // them. `<=` on the running best keeps the EARLIER span (row-major, like pass 1) on a tie.
        var best: (link: DetectedLink, dy: CGFloat, dx: CGFloat)?
        for candidate in links {
            let rect = metrics.rect(row: candidate.row, colStart: candidate.colStart, colEnd: candidate.colEnd)
            let dx = CGFloat.maximum(CGFloat.maximum(rect.minX - pointX, pointX - rect.maxX), 0)
            let dy = CGFloat.maximum(CGFloat.maximum(rect.minY - pointY, pointY - rect.maxY), 0)
            guard dx <= slop, dy <= slop else { continue }
            if let current = best, (current.dy, current.dx) <= (dy, dx) { continue }
            best = (candidate, dy, dx)
        }
        return best?.link
    }
}
