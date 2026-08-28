// PromptJumpFlashOverlayView — the prompt-jump "landed" flash, in UIKit (docs/62, the pane-leaf cluster).
//
// The vim-highlightedyank idiom. A prompt jump (⌘PageUp/⌘PageDown, or the navigator) replaces the whole
// viewport in one frame — the eye has no scroll motion to follow, so the user lands with zero
// orientation. This overlay paints ONE accent fade over the landed prompt row the instant the jump
// settles, anchoring the eye where the jump went. libghostty PINS the jumped-to prompt at viewport row 0,
// so row 0 is the honest target, and the model's arm/settle logic already SUPPRESSED the epoch bump for
// the one case where that would lie (a forward jump clamped into the active area) — absent, never wrong.
//
// A DECORATION coincident with the surface (origin 0,0 = the cell grid's top-left), mapped through the
// same ``TerminalCellMetrics``, hit-transparent, and inert for a placeholder/headless surface (no viewport
// seam ⇒ nothing drawn). WHERE it paints is ``PromptJumpFlashGeometry``'s — the anchor walk and the
// soft-wrap continuation rule are values with their own tests.
//
// MOTION: a plain opacity decay (mechanical, MERIDIAN L4 — the flash APPEARS as a hard cut and decays;
// nothing travels). The rung, the curve and the hold are `Slate`'s and are not restated here.
//
// ⚠️ THE VIEW RESTS INVISIBLE, AND THAT IS THE WHOLE ANSWER TO A HAZARD docs/62 §2.1 NAMES BY NAME. The
// SwiftUI original was a state machine wearing a `View`: an epoch-keyed `.task` that set a peak inside a
// `disablesAnimations` transaction, yielded a tick, ran `withAnimation` to zero, slept, and unmounted.
// Every step of that existed to stop a peak from being STRANDED in `@State` by a cancelled sleep, a torn
// down pane or a jump that retargeted mid-fade. Here `layer.opacity` is 0 at mount and 0 again the
// instant the decay ends — the flash is entirely the `CABasicAnimation`'s `fromValue`, so there is no
// state that CAN be left raised. The transaction, the `Task.yield()` and the two-phase animation all
// dissolve; what is left is the order the events happen in, which is the only thing this file ever owned.
//
// ⚠️ NO FLIP. ``TerminalCellMetrics`` answers in the surface's TOP-LEFT-origin space, which is `UIView`'s
// own — the Mac half's `isFlipped { true }` has no counterpart and the rects are used verbatim. Unflipped,
// an `NSView` would flash the BOTTOM row of the pane for a jump that pins the prompt at row 0: the one
// place the eye is certain the prompt is not.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class PromptJumpFlashOverlayView: UIView {
    /// The pane's terminal model — observed for ``TerminalViewModel/promptJumpFlashEpoch`` (one bump = one
    /// flash), dereferenced non-reactively for the surface's viewport snapshot at flash time.
    private let model: TerminalViewModel

    /// The landed prompt line's per-row rects, drawn as ONE path. Several when the prompt line
    /// soft-WRAPS: each wrapped row gets its own text-extent rect and they fade as one, which is why the
    /// decay is on the view's layer and not per rect. Static rects are truthful for the whole of the hold
    /// because the viewport is PINNED for it.
    private let painter = CAShapeLayer()

    /// The last epoch that reached ``flash(epoch:)``. Epoch 0 is the mount state — no jump has settled —
    /// and the comparison is `>` so a re-arm that re-reads the same epoch cannot double-paint it.
    private var paintedEpoch = 0

    /// The beat that unmounts the rects. Cancelled by a rapid re-jump, which repaints from scratch and
    /// owes the predecessor no cleanup.
    private var unmount: Task<Void, Never>?

    /// Guards the observation re-arm against a stale `onChange` firing after this view is gone.
    private var generation = 0

    private static let fadeKey = "slopdesk.promptFlash"

    init(model: TerminalViewModel) {
        self.model = model
        super.init(frame: .zero)
        isAccessibilityElement = false
        // Transparent to touch. A jump lands and the user's next act is to tap into the pane it landed in
        // — a decoration that took that touch would eat exactly it, for the whole quarter-second the flash
        // is up.
        isUserInteractionEnabled = false
        layer.opacity = 0
        painter.strokeColor = nil
        layer.addSublayer(painter)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.reink()
        }
        reink()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Bump the generation so an already-scheduled re-arm drops itself, and cancel the beat that would
    /// otherwise fire into a torn-down pane.
    ///
    /// The `Task` is the one lifetime UIKit does not end for us — docs/62 hazard 6 is exactly this shape,
    /// and the countermeasure it names is a stored task cancelled from an explicit teardown rather than
    /// only from `deinit`.
    func teardown() {
        generation &+= 1
        unmount?.cancel()
        unmount = nil
    }

    // ⚠️ NO `deinit` CANCEL, and that is docs/62 hazard 6's ruling rather than an omission: the beat holds
    // a `weak self`, so it cannot keep this view alive to be deinitialised in the first place, and a
    // cancel that could only run once the view was already gone would be cancelling nothing. The teardown
    // above is the mechanism, and the leaf calls it.

    /// The accent is appearance-dynamic and a `CGColor` on a shape layer is frozen at whichever appearance
    /// was current when it was assigned.
    private func reink() {
        painter.fillColor = Slate.Native.accent.resolvedColor(with: traitCollection).cgColor
    }

    // MARK: The live read

    /// ONE-SHOT observation, re-armed by its own `onChange`. Only the epoch is tracked: the viewport
    /// snapshot and the alt-screen gate are read non-reactively at flash time.
    private func follow() {
        generation &+= 1
        let token = generation
        var epoch = 0
        withObservationTracking {
            epoch = model.promptJumpFlashEpoch
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.follow()
                }
            }
        }
        flash(epoch: epoch)
    }

    /// One settled jump: paint at peak instantly, decay, then unmount the rects.
    private func flash(epoch: Int) {
        guard epoch > paintedEpoch else { return }
        paintedEpoch = epoch
        let rects = landedPromptRects()
        guard !rects.isEmpty else {
            Self.debugLog("epoch \(epoch) settled but NO RECT (alt-screen / no seam / blank rows)")
            return
        }
        Self.debugLog("painting epoch \(epoch) rows=\(rects.count) first=\(rects[0])")
        unmount?.cancel()
        let path = UIBezierPath()
        for rect in rects { path.append(UIBezierPath(rect: rect)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        painter.path = path.cgPath
        CATransaction.commit()
        decay()
        // ONE DURATION, ONE SPELLING. `promptFlashHold` IS the fade's duration plus its slack, so the beat
        // that tears the rects out cannot stop being longer than the fade when the curve is retuned.
        // `Slate` owns the numbers; this file owns only the order they happen in.
        unmount = Task { [weak self] in
            guard await (try? Task.sleep(for: .seconds(Slate.Anim.promptFlashHold))) != nil else { return }
            self?.clear()
        }
    }

    /// The decay, on the layer's opacity — the UIKit view of the rung ``Slate/Anim/promptFlash`` names,
    /// which is why the curve is taken from `Slate.Motion` and never re-typed as control points here.
    ///
    /// The peak is the animation's `fromValue` and nothing else: the layer's model opacity stays 0
    /// throughout, so the presentation rises to the peak on the first frame (the hard cut ON), decays over
    /// the curve, and lands back on a value that was already correct. Nothing to reset, nothing to strand.
    private func decay() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Slate.Anim.promptFlashPeak
        fade.toValue = 0
        fade.duration = Slate.Motion.promptFlash.duration
        fade.timingFunction = Slate.Motion.promptFlash.timingFunction
        // A re-jump mid-fade restarts from the peak rather than cross-fading two decays — the flash is one
        // cut per landing, and two overlapping curves read as a stutter.
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.add(fade, forKey: Self.fadeKey)
    }

    private func clear() {
        guard painter.path != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        painter.path = nil
        CATransaction.commit()
    }

    /// The landed prompt line's rects, from the pure
    /// ``PromptJumpFlashGeometry/rects(rows:metrics:isAlternateScreen:)`` — the pinned prompt block's first
    /// TEXT row plus its soft-WRAP continuation rows, each spanning that row's text extent (a
    /// full-grid-width bar reads as a selection band; the line's own width reads as "this line"). Empty —
    /// no flash — for an alt-screen TUI, a placeholder surface (no viewport seam), or a blank landing
    /// (nothing to anchor to).
    private func landedPromptRects() -> [CGRect] {
        guard let snapshot = model.surface as? TerminalViewportSnapshotting else { return [] }
        return PromptJumpFlashGeometry.rects(
            rows: snapshot.viewportTextRows(),
            metrics: snapshot.cellMetrics(),
            isAlternateScreen: model.isAlternateScreen,
        )
    }

    /// stderr diagnostics gated by `SLOPDESK_BLOCKS_DEBUG == "1"` — the paint end of the one-flag jump
    /// trace (issue → arm → scrollbar echo → settle → THIS paint / no-rect drop). One flag, both ends,
    /// which is the point of it being one flag: a renderer that dropped its half would make the trace go
    /// quiet at exactly the step being debugged.
    private static func debugLog(_ message: String) {
        DebugTrace.blocks.write("flash", message)
    }
}
#endif
