// LinkHighlightOverlay — the ⌘-hold link underline.
//
// A DECORATION overlay layered OVER the terminal surface in `TerminalLeafView` (never a content branch —
// the libghostty-freeze guardrail): while the pane model reports ⌘ is held (``TerminalViewModel/linkHighlightActive``),
// it runs the pure ``TerminalLinkDetector`` over the live VISIBLE viewport rows (the
// ``TerminalViewportSnapshotting`` seam) and draws a 1pt accent underline under every detected path / URL /
// `file://` / `mailto:` span, mapped to points by the ``TerminalCellMetrics`` (`full-path-hover.png`'s
// `CREDITS.md` underline). The renderer still resolves the hovered link's full path into the dormant
// ``TerminalViewModel/hoveredLinkFullPath`` seam, which has no status-bar consumer; this overlay only
// paints the underlines.
//
// Honest ceiling: a headless / `BuildStatusPlaceholderView` surface does NOT conform to
// ``TerminalViewportSnapshotting`` (the real surface hangs without a window server — CLAUDE.md rule #6), so
// `cellMetrics()` is absent and the overlay simply renders nothing — an ABSENT underline, never a wrong one.
//
// INERT on iOS: there is no ⌘ modifier, so the renderer never sets ``linkHighlightActive`` true on iOS and the
// overlay body short-circuits to empty (the iOS link affordance is tap-on-label / long-press). The view
// still compiles for iOS (no `#if os` here — `Canvas` is iOS 15+; the gate is runtime state, not platform).
//
// Never intercepts hits (`allowsHitTesting(false)`): clicks fall through to the renderer, which owns ⌘click /
// ⌘⇧click / right-click on a detected link. SYSTEM/theme colours only (`Slate.State.accent`).

#if canImport(SwiftUI)
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct LinkHighlightOverlay: View {
    /// The pane's terminal model — read for the OBSERVABLE ⌘-hold flag (`linkHighlightActive`) + the alt-screen
    /// gate, and dereferenced (non-reactively) for its `surface` viewport snapshot at draw time.
    let model: TerminalViewModel
    /// The pane cwd (OSC 7 `PaneSpec.lastKnownCwd`) so a RELATIVE detected path resolves — only affects the
    /// detector's `resolvedAbsolute` (used by the hover preview), never the underline rect, which is pure cells.
    let cwd: String?

    var body: some View {
        // Reading `linkHighlightActive` / `isAlternateScreen` here registers observation, so the overlay
        // reveals / clears the instant ⌘ is pressed / released (or the screen flips to a TUI). The heavy reads
        // (`bytesReceived`, the surface snapshot, the detector) live INSIDE the active branch so the dependency
        // on streaming output is only registered while the underline is actually live — no idle re-eval per
        // ingest when ⌘ is not held.
        if model.linkHighlightActive,
           SettingsKey.linkDetectionEnabled,
           !model.isAlternateScreen,
           let snapshot = model.surface as? TerminalViewportSnapshotting,
           let metrics = snapshot.cellMetrics(),
           metrics.cellWidth > 0, metrics.cellHeight > 0
        {
            // Re-detect under a held ⌘ on EITHER viewport-change signal: new streaming output (`bytesReceived`)
            // OR a LOCAL scrollback scroll (`viewportRevision`, bumped by the renderer's scroll/pan handler).
            // A local scroll moves the viewport WITHOUT new wire bytes, so `bytesReceived` alone would leave
            // the underlines stranded at their pre-scroll screen rows over unrelated text — observing both
            // re-runs detection against the moved `viewportTextRows()`. `let _` (not a bare `_ =`) is required
            // — a `@ViewBuilder` rejects a bare Void discard statement.
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.bytesReceived
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.viewportRevision
            let accent = Slate.State.accent
            let links = TerminalLinkDetector.detect(
                rows: snapshot.viewportTextRows(),
                cwd: cwd,
                schemes: SettingsKey.linkSchemePolicy,
            )
            Canvas { context, _ in
                let shading = GraphicsContext.Shading.color(accent)
                for link in links {
                    // CLAMP to the visible grid: skip a span that starts off-screen-right and trim one that
                    // overruns the grid edge, so a soft-wrap-shifted span is never drawn in the void to the
                    // right of the terminal.
                    guard let rect = metrics.clampedRect(
                        row: link.row, colStart: link.colStart, colEnd: link.colEnd,
                    ) else { continue }
                    // Underline along the cell's bottom edge (1pt inset so it sits just under the glyph, not
                    // clipped at the row boundary). Plain `-` (no `addingProduct`/`fma` — CLAUDE.md §2 habit).
                    let baseline = rect.maxY - 1
                    var underline = Path()
                    underline.move(to: CGPoint(x: rect.minX, y: baseline))
                    underline.addLine(to: CGPoint(x: rect.maxX, y: baseline))
                    context.stroke(underline, with: shading, lineWidth: 1)
                }
            }
            // DECORATION only: never swallow a click — the renderer owns ⌘click / right-click on the link.
            .allowsHitTesting(false)
        }
    }
}
#endif
