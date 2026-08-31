// DecorationPromptFlash — one settled prompt jump, decided once for both shells.
//
// The prompt-jump flash (the vim-highlightedyank idiom) is written twice — `MacPromptJumpFlashOverlay`
// paints `NSBezierPath`s into a `draw(_:)`, `PromptJumpFlashOverlayView` hands one `CGPath` to a
// `CAShapeLayer` — and those two sentences are the whole of the difference. Everything BEFORE the
// paint was character-identical in both files, which `no-cross-target-clone` counted as three windows
// (docs/56 §3, docs/62 stage I):
//
//   * the epoch guard and the `paintedEpoch` bump,
//   * the two `SLOPDESK_BLOCKS_DEBUG` trace lines, which are the paint end of a one-flag jump trace
//     and must therefore say the same words at both ends,
//   * the landed rects, which are `PromptJumpFlashGeometry`'s already and were only being ASKED for
//     twice,
//   * and the decay, which is five `CABasicAnimation` properties — QuartzCore, one API on both
//     platforms, reading two `Slate` rungs neither half decides.
//
// ⚠️ THE GATE HOLDS `paintedEpoch`, SO IT IS AN OBJECT AND NOT A NAMESPACE. The comparison is `>`
// rather than `!=` so a re-arm that re-reads the same epoch cannot double-paint it, and epoch 0 is
// the mount state — no jump has settled. That counter is per-OVERLAY state (one pane can be flashing
// while another is not), so it lives in an instance the view owns, not in a static.
//
// ⚠️ WHAT DOES NOT COME DOWN HERE is the view resting invisible. `layer.opacity` is 0 at mount and 0
// again the instant the decay ends — the flash is entirely the animation's `fromValue`, so no model
// state can be left raised by a cancelled sleep, a torn-down pane or a jump that retargets mid-fade.
// That is a property of how each shell MOUNTS its layer, and each header states it.

import QuartzCore
import SlopDeskSlate
import SlopDeskWorkspaceCore

/// One overlay's flash gate: which epochs paint, what they paint, and how the paint decays.
@MainActor
package final class DecorationPromptFlash {
    /// The last epoch that was allowed to paint. Epoch 0 is the mount state.
    private var paintedEpoch = 0

    /// The animation key both shells add the decay under. One spelling, so a re-jump mid-fade removes
    /// the animation it is replacing rather than stacking a second curve beside it.
    private static let fadeKey = "slopdesk.promptFlash"

    package init() {}

    /// The rects this epoch should paint, or `nil` when it must not paint at all.
    ///
    /// `nil` for two different reasons and the trace tells them apart: an epoch at or below the last
    /// painted one is a re-arm and says nothing, while a settled epoch with no rect is logged —
    /// alt-screen, no viewport seam, or a blank landing — because that is the case worth seeing in
    /// the jump trace.
    package func landing(epoch: Int, model: TerminalViewModel) -> [CGRect]? {
        guard epoch > paintedEpoch else { return nil }
        paintedEpoch = epoch
        let rects = Self.rects(for: model)
        guard !rects.isEmpty else {
            DebugTrace.blocks.write(
                "flash", "epoch \(epoch) settled but NO RECT (alt-screen / no seam / blank rows)",
            )
            return nil
        }
        DebugTrace.blocks.write("flash", "painting epoch \(epoch) rows=\(rects.count) first=\(rects[0])")
        return rects
    }

    /// The landed prompt line's rects, from the pure
    /// ``PromptJumpFlashGeometry/rects(rows:metrics:isAlternateScreen:)`` — the pinned prompt block's
    /// first TEXT row plus its soft-WRAP continuation rows, each spanning that row's text extent (a
    /// full-grid-width bar reads as a selection band; the line's own width reads as "this line").
    private static func rects(for model: TerminalViewModel) -> [CGRect] {
        guard let snapshot = model.surface as? TerminalViewportSnapshotting else { return [] }
        return PromptJumpFlashGeometry.rects(
            rows: snapshot.viewportTextRows(),
            metrics: snapshot.cellMetrics(),
            isAlternateScreen: model.isAlternateScreen,
        )
    }

    /// Restart the decay on `layer`: a hard cut to the peak, then the curve back to the zero the
    /// layer's model opacity never left.
    ///
    /// The peak is the animation's `fromValue` and nothing else, so there is nothing to reset when it
    /// ends. A re-jump mid-fade removes the running animation first rather than cross-fading two
    /// decays — the flash is one cut per landing, and two overlapping curves read as a stutter.
    package static func decay(on layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Slate.Anim.promptFlashPeak
        fade.toValue = 0
        fade.duration = Slate.Motion.promptFlash.duration
        fade.timingFunction = Slate.Motion.promptFlash.timingFunction
        layer.removeAnimation(forKey: fadeKey)
        layer.add(fade, forKey: fadeKey)
    }
}
