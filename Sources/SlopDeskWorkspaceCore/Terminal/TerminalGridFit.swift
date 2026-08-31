import CoreGraphics
import CSlopDeskFFI
import Foundation

/// Where a grid the client did NOT choose goes inside the space it has (docs/45 §8.3).
///
/// iOS is size-passive host-side: a phone's window never votes in a pane's `min` fold, so the
/// resolved grid is whatever the Macs on that pane settled on. The phone therefore has to place a
/// grid that is almost never its own aspect — shrunk to fit, centred, with bars for the remainder.
///
/// The arithmetic is `slopdesk_terminal`'s `geometry`. It went there with
/// ``TerminalCellMetrics/rect(row:colStart:colEnd:)``, and the two moved together for a reason
/// neither could have carried alone: `rect` had a live Rust twin in `link_hit::span_rect` —
/// recorded there as docs/55 §8's drift class and left open because facing two multiplies and two
/// adds would have put `CSlopDeskFFI` into a target that linked nothing. The letterbox is the same
/// target's other geometry, with the same bit-exactness discipline, so one dependency now buys a
/// cluster and closes the drift pair on the way.
public struct TerminalLetterbox: Sendable, Equatable {
    /// Where the grid draws, in the container's own coordinate space (points, top-left origin).
    public var contentRect: CGRect
    /// The factor the renderer's natural size is drawn at. `1` = natural cell metrics; `< 1` = the
    /// grid is wider or taller than the container and is shrunk to fit. Never `> 1`.
    public var scale: CGFloat

    public init(contentRect: CGRect, scale: CGFloat) {
        self.contentRect = contentRect
        self.scale = scale
    }

    /// Whether any bar is drawn — i.e. the content does not fill the container in at least one axis.
    /// An exact fit reports `false` so a pane that is already right gains no hairline.
    ///
    /// Asked of the door rather than stored beside the rect: a cached answer is a second thing to
    /// keep in step, and an exact fit that grew a hairline is what that drift would look like.
    public var isLetterboxed: Bool {
        slopdesk_grid_is_letterboxed(contentRect.origin.x, contentRect.origin.y)
    }

    /// Fits a `cols × rows` grid, drawn at `cellWidth × cellHeight` per cell, inside `container`.
    ///
    /// SHRINK-to-fit, never magnify: `scale` is capped at `1`, so a grid smaller than the container
    /// is centred at the renderer's natural cell metrics rather than blown up. Magnifying a glyph
    /// grid is blur, and the whole point of a coding tool is that the text is exact.
    ///
    /// - Returns: `nil` for any degenerate input — a zero grid, unknown cell metrics (a headless or
    ///   pre-layout surface), or a zero-area container. The caller renders as it always did rather
    ///   than placing a zero-area or infinite rect.
    public static func fit(
        cols: Int,
        rows: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        in container: CGSize,
    ) -> Self? {
        let box = slopdesk_grid_fit(
            Int64(cols),
            Int64(rows),
            cellWidth,
            cellHeight,
            container.width,
            container.height,
        )
        return box.present ? Self(box) : nil
    }

    /// A verdict, read back. The `present` flag is read FIRST and the coordinates only after it:
    /// an absent placement leaves them untouched, and that is the one mistake the shape exists to
    /// make visible rather than plausible.
    private init(_ verdict: SlopDeskGridPlacement) {
        self.init(
            contentRect: CGRect(
                x: verdict.content_x,
                y: verdict.content_y,
                width: verdict.content_width,
                height: verdict.content_height,
            ),
            scale: verdict.scale,
        )
    }
}

public extension TerminalLetterbox {
    /// The fit, PLUS the natural (unscaled) size the surface must be framed at.
    ///
    /// The pair is one value because the two numbers are only correct together. The renderer is framed
    /// at `natural` and then transformed by `fit.scale`; framing it at the SCALED rect instead would
    /// make the renderer derive a different grid from its own bounds — the phone would reflow to its
    /// own window, which is the exact thing size-passivity exists to stop (docs/45 §8.3).
    struct Placement: Equatable, Sendable {
        /// Where the grid lands, and at what scale.
        public var fit: TerminalLetterbox
        /// The grid's size at the renderer's NATURAL cell metrics, before the scale is applied.
        public var natural: CGSize

        public init(fit: TerminalLetterbox, natural: CGSize) {
            self.fit = fit
            self.natural = natural
        }
    }

    /// Places a host-resolved `grid` drawn at `cellSize` inside `container`.
    ///
    /// DEGRADES TO FULL-BLEED, and that is the whole contract: `nil` whenever ANYTHING it depends on is
    /// unknown. Every input can legitimately be absent — the roster has not landed, the document is
    /// off, the renderer is a placeholder with no cell metrics, or the layout pass has not run — and in
    /// each of those cases the caller draws the content at full bleed exactly as it always did. An
    /// absent letterbox, never a wrong one, which is the rule this whole decoration family keeps.
    ///
    /// One door, not two: the fit and the natural size come back together because they are only
    /// correct together, and deriving the second here would be the multiply this file no longer
    /// spells.
    static func placement(
        grid: (cols: Int, rows: Int)?, cellSize: CGSize?, in container: CGSize,
    ) -> Placement? {
        guard let grid, let cellSize else { return nil }
        let verdict = slopdesk_grid_placement(
            Int64(grid.cols),
            Int64(grid.rows),
            cellSize.width,
            cellSize.height,
            container.width,
            container.height,
        )
        guard verdict.present else { return nil }
        return Placement(
            fit: TerminalLetterbox(verdict),
            natural: CGSize(width: verdict.natural_width, height: verdict.natural_height),
        )
    }
}
