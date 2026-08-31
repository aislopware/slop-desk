// TerminalDecorationGeometry — the two cell-grid decorations' arm predicates and their path math.
//
// The ⌘-hold link underline and the copy-mode block cursor are both DECORATION overlays coincident
// with the terminal surface (never a content branch — the libghostty-freeze guardrail). Both had the
// same defect before this file existed: their whole decision lived inside a SwiftUI `if` in a `body`,
// and — worse for the underline — the underline's own geometry (`baseline = rect.maxY - 1`,
// `lineWidth: 1`) lived inside a `Canvas` closure, which is a place no test can reach at all. A rule
// nothing can call is a rule nothing can pin.
//
// So the ARM predicate and the PATH are values here and the drawing stays in whichever framework is
// drawing. Both keep the family's one law: ABSENT, never wrong. Every input can legitimately be
// missing — a headless / `BuildStatusPlaceholderView` surface conforms to no viewport seam, an
// alt-screen TUI has no prompt/link ground truth, a pre-layout surface has no cell metrics — and in
// each case the honest answer is that nothing is drawn.
//
// Plain separate `-` (never `addingProduct`/`fma`), per CLAUDE.md §2.

import CoreGraphics
import Foundation
import SlopDeskWorkspaceCore

/// One straight decoration stroke in the surface's coordinate space (origin 0,0 = the cell grid's
/// top-left, the space ``TerminalCellMetrics`` already answers in).
package struct TerminalStroke: Equatable, Sendable {
    package var start: CGPoint
    package var end: CGPoint
    package var lineWidth: CGFloat

    package init(start: CGPoint, end: CGPoint, lineWidth: CGFloat) {
        self.start = start
        self.end = end
        self.lineWidth = lineWidth
    }
}

/// The ⌘-hold link underline: when it is armed, and where each stroke goes.
package enum LinkUnderlineGeometry {
    /// The underline sits this far ABOVE the cell's bottom edge, so it reads as belonging to the glyph
    /// rather than being clipped at the row boundary.
    package static let baselineInset: CGFloat = 1
    /// A 1pt hairline — the underline is a property of the text, not a highlight over it.
    package static let lineWidth: CGFloat = 1

    /// Whether the underline is live at all.
    ///
    /// THREE independent gates and each one is a different question. `highlightActive` is the pane
    /// model's ⌘-hold mirror — false forever on iOS, which has no ⌘ modifier and answers links by
    /// tap-on-label instead, so the overlay is inert there without a platform gate. `detectionEnabled`
    /// is the user's `SettingsKey.linkDetectionEnabled`, which used to be read inside a view body —
    /// a setting consulted where nothing can call it. `isAlternateScreen` is the TUI gate: a
    /// full-screen application owns its own cells, and underlining what looks like a path inside vim's
    /// status line is a wrong decoration, which this family never draws.
    package static func isArmed(
        highlightActive: Bool, detectionEnabled: Bool, isAlternateScreen: Bool,
    ) -> Bool {
        highlightActive && detectionEnabled && !isAlternateScreen
    }

    /// The stroke under one already-clamped cell span.
    package static func stroke(under rect: CGRect) -> TerminalStroke {
        // Plain `-` (no `addingProduct`/`fma` — CLAUDE.md §2 habit).
        let baseline = rect.maxY - baselineInset
        return TerminalStroke(
            start: CGPoint(x: rect.minX, y: baseline),
            end: CGPoint(x: rect.maxX, y: baseline),
            lineWidth: lineWidth,
        )
    }

    /// Every underline stroke for `links` against `metrics`.
    ///
    /// CLAMPED to the visible grid through ``TerminalCellMetrics/clampedRect(row:colStart:colEnd:)``:
    /// a span that starts off-screen-right is skipped and one that overruns the grid edge is trimmed,
    /// so a soft-wrap-shifted span is never drawn in the void to the right of the terminal.
    package static func strokes(links: [DetectedLink], metrics: TerminalCellMetrics) -> [TerminalStroke] {
        guard metrics.cellWidth > 0, metrics.cellHeight > 0 else { return [] }
        return links.compactMap { link in
            metrics.clampedRect(row: link.row, colStart: link.colStart, colEnd: link.colEnd)
                .map(stroke(under:))
        }
    }
}

/// The copy-mode BLOCK cursor: whether there is one to draw, and the cell footprint it wears.
package enum ViCursorGeometry {
    /// The interior wash stays LIGHT so the glyph underneath still reads — an overlay cannot invert a
    /// cell the way a real terminal block cursor does, so the roles split between fill and edge.
    package static let fillOpacity: Double = 0.3
    /// The FULL-strength edge is the visibility: the crisp silhouette the eye finds across a busy
    /// buffer. Sharp corners, no glow (the Meridian at-rest zero-ornament law).
    package static let strokeWidth: CGFloat = 1.5

    /// The block's rect, or `nil` when there is nothing honest to draw.
    ///
    /// Four ways to be absent, and they are all real: copy mode is not armed; the model has cleared
    /// the cursor because it scrolled off-viewport (``TerminalViewModel/viCursorCell`` is re-derived
    /// from a fresh `viewportInfo()` readback after every copy-mode key, so a stale position is never
    /// painted); the surface is a placeholder with no cell metrics; or the clamp rejects the span.
    ///
    /// WIDE-GLYPH SPAN RULE: `colEnd = cell.col + cell.width`, so a fullwidth CJK glyph gets a
    /// two-cell block and wears the whole character instead of half of it.
    package static func rect(
        copyModeActive: Bool,
        cell: TerminalViewModel.ViCursorCell?,
        metrics: TerminalCellMetrics?,
    ) -> CGRect? {
        guard copyModeActive, let cell, let metrics,
              metrics.cellWidth > 0, metrics.cellHeight > 0
        else { return nil }
        return metrics.clampedRect(row: cell.row, colStart: cell.col, colEnd: cell.col + cell.width)
    }
}
