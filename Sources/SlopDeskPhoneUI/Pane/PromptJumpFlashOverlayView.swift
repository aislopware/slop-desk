// PromptJumpFlashOverlayView — the prompt-jump "landed" flash, in UIKit (docs/62, the pane-leaf cluster).
//
// The vim-highlightedyank idiom. A prompt jump (⌘PageUp/⌘PageDown, or the navigator) replaces the whole
// viewport in one frame — the eye has no scroll motion to follow, so the user lands with zero
// orientation. This overlay paints ONE accent fade over the landed prompt row the instant the jump
// settles, anchoring the eye where the jump went. `libghostty-vt` PINS the jumped-to prompt at viewport row 0,
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

    /// Which epochs may paint, what they paint, and the trace they leave — ``DecorationPromptFlash``,
    /// one implementation for both shells. It holds the `paintedEpoch` counter this file used to.
    private let gate = DecorationPromptFlash()

    /// The beat that unmounts the rects. Cancelled by a rapid re-jump, which repaints from scratch and
    /// owes the predecessor no cleanup.
    private var unmount: Task<Void, Never>?

    /// The live following. Stored for ``teardown()`` alone — the overlay can outlive the pane it reads,
    /// which is the one case ``ObservationFollow/stop()`` exists for.
    private var flashFollow: ObservationFollow?

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

    /// End the following, and cancel the beat that would otherwise fire into a torn-down pane.
    ///
    /// The `Task` is the one lifetime UIKit does not end for us — docs/62 hazard 6 is exactly this shape,
    /// and the countermeasure it names is a stored task cancelled from an explicit teardown rather than
    /// only from `deinit`.
    func teardown() {
        flashFollow?.stop()
        flashFollow = nil
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

    /// The following, through ``ObservationFollow/arm(_:read:apply:)``. Only the epoch is tracked: the
    /// viewport snapshot and the alt-screen gate are read non-reactively at flash time.
    private func follow() {
        flashFollow = ObservationFollow.arm(self) { view in
            view.model.promptJumpFlashEpoch
        } apply: { view, epoch in
            view.flash(epoch: epoch)
        }
    }

    /// One settled jump: paint at peak instantly, decay, then unmount the rects.
    private func flash(epoch: Int) {
        guard let rects = gate.landing(epoch: epoch, model: model) else { return }
        unmount?.cancel()
        let path = UIBezierPath()
        for rect in rects { path.append(UIBezierPath(rect: rect)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        painter.path = path.cgPath
        CATransaction.commit()
        // The decay, on the layer's opacity — ``DecorationPromptFlash/decay(on:)``, which owns the curve,
        // the peak and the animation key. A `UIView` always has its layer, so unlike the Mac half there is
        // no optional to unwrap and no wrapper method to unwrap it in.
        DecorationPromptFlash.decay(on: layer)
        // ONE DURATION, ONE SPELLING. `promptFlashHold` IS the fade's duration plus its slack, so the beat
        // that tears the rects out cannot stop being longer than the fade when the curve is retuned.
        // `Slate` owns the numbers; this file owns only the order they happen in.
        unmount = Task { [weak self] in
            guard await (try? Task.sleep(for: .seconds(Slate.Anim.promptFlashHold))) != nil else { return }
            self?.clear()
        }
    }

    private func clear() {
        guard painter.path != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        painter.path = nil
        CATransaction.commit()
    }
}
#endif
