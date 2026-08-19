// PromptJumpFlashOverlay — the prompt-jump "landed" flash (the vim-highlightedyank idiom).
//
// A ⌘PageUp/⌘PageDown (or navigator) prompt jump replaces the whole viewport in one frame — the eye has
// no scroll motion to follow, so the user lands with zero orientation. This overlay paints ONE
// `Slate.Anim.promptFlash` accent fade over the landed prompt row the instant the jump settles,
// anchoring the eye where the jump went. The duration is the rung's and is not restated here — the
// header carrying its own copy of the number was one of the three spellings docs/56 increment 56c
// merged. libghostty PINS the jumped-to prompt at viewport row 0 (`PageList.scrollPrompt` sets the
// viewport pin to the prompt), so row 0 is the honest target; the model's arm/settle logic
// (``TerminalViewModel/noteViewportScroll(atBottom:)``) already SUPPRESSED the epoch bump for the one
// case where that would lie (a forward jump clamped into the active area) — absent, never wrong.
//
// A DECORATION overlay like ``LinkHighlightOverlay``: coincident with the surface (origin 0,0 = cell
// grid origin), mapped through the same ``TerminalCellMetrics``, hit-transparent, and inert for a
// placeholder/headless surface (no viewport seam ⇒ nothing drawn). Motion is a plain opacity fade
// (mechanical, MERIDIAN L4 — the flash APPEARS as a hard cut and decays; nothing travels).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct PromptJumpFlashOverlay: View {
    /// The pane's terminal model — observed for ``TerminalViewModel/promptJumpFlashEpoch`` (one bump =
    /// one flash), dereferenced non-reactively for the surface's viewport snapshot at flash time.
    let model: TerminalViewModel

    /// The live flash: the landed prompt line's per-row rects (computed ONCE when the epoch bumps —
    /// the viewport is pinned for the whole of ``Slate/Anim/promptFlashHold``, so static rects are
    /// truthful) plus the shared animating opacity. Several rects when the prompt line soft-WRAPS:
    /// each wrapped row gets its own text-extent rect, and they fade as one.
    @State private var flashRects: [CGRect] = []
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(flashRects.enumerated()), id: \.offset) { _, rect in
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
            guard model.promptJumpFlashEpoch > 0 else { return }
            let rects = landedPromptRects()
            guard !rects.isEmpty else {
                Self
                    .debugLog(
                        "epoch \(model.promptJumpFlashEpoch) settled but NO RECT (alt-screen / no seam / blank rows)",
                    )
                return
            }
            Self.debugLog("painting epoch \(model.promptJumpFlashEpoch) rows=\(rects.count) first=\(rects[0])")
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                flashRects = rects
                flashOpacity = Slate.Anim.promptFlashPeak
            }
            await Task.yield()
            withAnimation(Slate.Anim.promptFlash) { flashOpacity = 0 }
            // ONE DURATION, ONE SPELLING. The fade and the beat that unmounts it are one rung now —
            // `promptFlashHold` IS `Motion.promptFlash.duration` plus its slack — so the unmount
            // cannot stop being longer than the fade when the curve is retuned. It used to be a bare
            // `300` here against a 0.24s `needle`, which was correct by arithmetic nobody was
            // checking. `Slate` owns the numbers; this file owns only the order they happen in.
            guard await (try? Task.sleep(for: .seconds(Slate.Anim.promptFlashHold))) != nil else { return }
            flashRects = []
        }
    }

    /// The landed prompt line's rects, from the pure ``PromptJumpFlashGeometry/rects(rows:metrics:isAlternateScreen:)``
    /// — the pinned prompt block's first TEXT row plus its soft-WRAP continuation rows, each spanning
    /// that row's text extent (a full-grid-width bar reads as a selection band; the line's own width
    /// reads as "this line"). Empty — no flash — for an alt-screen TUI, a placeholder surface (no
    /// viewport seam), or a blank landing (nothing to anchor to).
    private func landedPromptRects() -> [CGRect] {
        guard let snapshot = model.surface as? TerminalViewportSnapshotting else { return [] }
        return PromptJumpFlashGeometry.rects(
            rows: snapshot.viewportTextRows(),
            metrics: snapshot.cellMetrics(),
            isAlternateScreen: model.isAlternateScreen,
        )
    }

    /// stderr diagnostics gated by `SLOPDESK_BLOCKS_DEBUG == "1"` — the paint end of the one-flag
    /// jump trace (issue → arm → scrollbar echo → settle → THIS paint / no-rect drop).
    private static func debugLog(_ message: String) {
        DebugTrace.blocks.write("flash", message)
    }
}
#endif
