// ViCursorOverlay — the copy-mode BLOCK CURSOR (the E17 ceiling lift's one client-drawn element).
//
// A DECORATION overlay layered OVER the terminal surface in `TerminalLeafView` (never a content branch —
// the libghostty-freeze guardrail), coincident with the surface so ``TerminalCellMetrics`` maps the cell
// straight to points. It draws ONE accent-outlined cell at the vi cursor while copy-mode is armed. The
// SELECTION is deliberately NOT drawn here — a keyboard-started visual range goes through the fork's
// `set_selection` ABI and libghostty paints it natively; only the cursor (client state by design) needs a
// view.
//
// HONESTY: the drawn position is ``TerminalViewModel/viCursorCell`` — a VIEWPORT-relative cell the model
// re-derives from a fresh `viewportInfo()` readback after every copy-mode key and on every renderer scroll
// echo, and clears when the cursor is scrolled off-viewport. So the overlay is absent, never wrong (the
// anti-jitter rule); a headless / placeholder surface conforms to neither seam and draws nothing.
//
// `Slate.*` tokens only; hit-transparent; no libghostty / Metal touched (CLAUDE.md rule #6).

#if canImport(SwiftUI)
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct ViCursorOverlay: View {
    /// The pane's terminal model — observed for ``TerminalViewModel/viCursorCell`` (+ the copy-mode
    /// badge gate), dereferenced non-reactively for the surface's cell geometry at draw time.
    let model: TerminalViewModel

    var body: some View {
        // Reading `copyModeBadgeActive` / `viCursorCell` registers observation, so the cursor moves the
        // instant a motion lands. The geometry read lives inside the active branch (the hint-overlay
        // idiom) so the snapshot is only taken while there is actually a cursor to draw.
        if model.copyModeBadgeActive, let cell = model.viCursorCell,
           let snapshot = model.surface as? TerminalViewportSnapshotting,
           let metrics = snapshot.cellMetrics(),
           metrics.cellWidth > 0, metrics.cellHeight > 0,
           let rect = metrics.clampedRect(row: cell.row, colStart: cell.col, colEnd: cell.col + cell.width)
        {
            ZStack(alignment: .topLeading) {
                // A terminal-authentic BLOCK cursor: one sharp-cornered accent block, exactly the
                // glyph's cell footprint (`cell.width` = 2 on a wide glyph). A real terminal block
                // inverts the glyph; an overlay can't, so the roles split: the FULL-strength edge is
                // the visibility (the crisp silhouette the eye finds across a busy buffer) and the
                // interior wash stays LIGHT so the glyph underneath reads clearly. Sharp corners,
                // no glow (the Meridian at-rest zero-ornament law).
                Rectangle()
                    .fill(Slate.State.accent.opacity(0.3))
                    .overlay(Rectangle().strokeBorder(Slate.State.accent, lineWidth: 1.5))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
