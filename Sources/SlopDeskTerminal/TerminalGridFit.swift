import CoreGraphics
import Foundation
import SlopDeskProtocol

/// Where a grid the client did NOT choose goes inside the space it has (docs/45 §8.3).
///
/// iOS is size-passive host-side: a phone's window never votes in a pane's `min` fold, so the
/// resolved grid is whatever the Macs on that pane settled on. The phone therefore has to place a
/// grid that is almost never its own aspect — shrunk to fit, centred, with bars for the remainder.
///
/// A pure value: the SwiftUI path it drives compiles only under the iOS triple (`check-ios.sh`),
/// so the arithmetic lives here where it can be tested.
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
    public var isLetterboxed: Bool {
        contentRect.origin.x > 0 || contentRect.origin.y > 0
    }

    /// Fits a `cols × rows` grid, drawn at `cellWidth × cellHeight` per cell, inside `container`.
    ///
    /// SHRINK-to-fit, never magnify: `scale` is capped at `1`, so a grid smaller than the container
    /// is centred at the renderer's natural cell metrics rather than blown up. Magnifying a glyph
    /// grid is blur, and the whole point of a coding tool is that the text is exact.
    ///
    /// Plain separate `*` then `+` and `CGFloat.minimum` over `<`-ternaries, per CLAUDE.md §2 — this
    /// is view geometry rather than the codec cluster, but the habit is kept (and `.minimum` is
    /// NaN-faithful, which a degenerate container makes reachable).
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
        guard cols > 0, rows > 0,
              cellWidth > 0, cellHeight > 0,
              container.width > 0, container.height > 0 else { return nil }
        let naturalWidth = cellWidth * CGFloat(cols)
        let naturalHeight = cellHeight * CGFloat(rows)
        let widthScale = container.width / naturalWidth
        let heightScale = container.height / naturalHeight
        let scale = CGFloat.minimum(CGFloat.minimum(widthScale, heightScale), 1)
        let width = naturalWidth * scale
        let height = naturalHeight * scale
        let originX = (container.width - width) / 2
        let originY = (container.height - height) / 2
        return Self(
            contentRect: CGRect(x: originX, y: originY, width: width, height: height),
            scale: scale,
        )
    }
}

/// What the pane says about a grid it did not choose — docs/45 §8.3 rule 7's readout, verbatim:
/// `120×40 · sized by MacBook Pro`.
///
/// This is what makes the size policy debuggable on hardware. Without it a user on a phone sees a
/// pane that is the wrong size for no stated reason, and the min-fold looks like a bug rather than
/// a rule.
public enum TerminalGridReadout {
    /// What an attachment with no roster label is called — `slopdesk-client` opens no workspace
    /// channel, so the host publishes its attachment with the all-zero id and nothing can name it.
    public static let unlabelledContributor = "another client"

    /// The readout for `pane`, or `nil` when the host has not resolved a grid for it (0×0) and
    /// there is nothing honest to say.
    ///
    /// The clamping contributor is the first CONTRIBUTING attachment whose standing offer equals the
    /// resolved grid — the roster's own order decides, so the answer does not flicker between tied
    /// clients on every presence frame. `selfClientInstanceID` is omitted from the attribution: a
    /// client that chose the grid needs no explanation of it.
    public static func text(
        for pane: WorkspaceRosterPane,
        labels: [UUID: String],
        selfClientInstanceID: UUID?,
    ) -> String? {
        guard pane.resolvedCols > 0, pane.resolvedRows > 0 else { return nil }
        let grid = "\(pane.resolvedCols)×\(pane.resolvedRows)"
        let clamping = pane.attachments.first {
            $0.contributes && $0.cols == pane.resolvedCols && $0.rows == pane.resolvedRows
        }
        guard let clamping, clamping.clientInstanceID != selfClientInstanceID else { return grid }
        let label = labels[clamping.clientInstanceID] ?? unlabelledContributor
        return grid + " · sized by " + label
    }
}
