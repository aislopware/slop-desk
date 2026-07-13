// PromptJumpFlashOverlay — the prompt-jump "landed" flash (the vim-highlightedyank idiom).
//
// A ⌘PageUp/⌘PageDown (or navigator) prompt jump replaces the whole viewport in one frame — the eye has
// no scroll motion to follow, so the user lands with zero orientation. This overlay paints ONE ~240ms
// accent fade over the landed prompt row the instant the jump settles, anchoring the eye where the jump
// went. libghostty PINS the jumped-to prompt at viewport row 0 (`PageList.scrollPrompt` sets the
// viewport pin to the prompt), so row 0 is the honest target; the model's arm/settle logic
// (``TerminalViewModel/noteViewportScroll(atBottom:)``) already SUPPRESSED the epoch bump for the one
// case where that would lie (a forward jump clamped into the active area) — absent, never wrong.
//
// A DECORATION overlay like ``LinkHighlightOverlay``: coincident with the surface (origin 0,0 = cell
// grid origin), mapped through the same ``TerminalCellMetrics``, hit-transparent, and inert for a
// placeholder/headless surface (no viewport seam ⇒ nothing drawn). Motion is a plain opacity fade
// (mechanical, MERIDIAN L4 — the flash APPEARS as a hard cut and decays; nothing travels).

#if canImport(SwiftUI)
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct PromptJumpFlashOverlay: View {
    /// The pane's terminal model — observed for ``TerminalViewModel/promptJumpFlashEpoch`` (one bump =
    /// one flash), dereferenced non-reactively for the surface's viewport snapshot at flash time.
    let model: TerminalViewModel

    /// The peak flash opacity over the accent fill — loud enough to catch a saccade, quiet enough to
    /// read as light, not selection.
    private static let peak: Double = 0.28

    /// The live flash: the landed row's rect (computed ONCE when the epoch bumps — the viewport is
    /// pinned for the fade's ~240ms, so a static rect is truthful) plus its animating opacity.
    @State private var flashRect: CGRect?
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = flashRect {
                Rectangle()
                    .fill(Slate.State.accent)
                    .opacity(flashOpacity)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // One task per settled jump: paint at peak instantly (hard cut ON), yield a tick so the fade
        // animates from the committed peak, decay over `Slate.Anim.needle`, then unmount the rect.
        // Epoch 0 is the mount state — no jump has settled, so the task exits without painting.
        // A cancelled sleep (pane torn down / rapid re-jump retargeting the task) just stops — the
        // successor task repaints from scratch, so no cleanup is owed here.
        .task(id: model.promptJumpFlashEpoch) {
            guard model.promptJumpFlashEpoch > 0, let rect = landedPromptRect() else { return }
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                flashRect = rect
                flashOpacity = Self.peak
            }
            await Task.yield()
            withAnimation(Slate.Anim.needle) { flashOpacity = 0 }
            guard await (try? Task.sleep(for: .milliseconds(300))) != nil else { return }
            flashRect = nil
        }
    }

    /// The landed prompt row's rect: viewport row 0 (where the jump pinned the prompt), spanning the
    /// row's TEXT extent (a full-grid-width bar reads as a selection band; the prompt's own width reads
    /// as "this line"). `nil` — no flash — for an alt-screen TUI, a placeholder surface (no viewport
    /// seam), or an empty row 0 (nothing to anchor to).
    private func landedPromptRect() -> CGRect? {
        guard !model.isAlternateScreen,
              let snapshot = model.surface as? TerminalViewportSnapshotting,
              let metrics = snapshot.cellMetrics(),
              metrics.cellWidth > 0, metrics.cellHeight > 0
        else { return nil }
        // Grapheme count under-measures a wide (2-cell) glyph's span — acceptable: the flash still
        // covers the row's text from column 0, just stopping a few cells early on CJK-heavy prompts.
        let rowText = snapshot.viewportTextRows().first ?? ""
        let cellCount = rowText.count
        guard cellCount > 0 else { return nil }
        return metrics.clampedRect(row: 0, colStart: 0, colEnd: cellCount)
    }
}
#endif
