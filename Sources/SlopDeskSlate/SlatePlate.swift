// SlatePlate — the selection plate's travel and its ignite, as Core Animation rather than as two
// framework spellings.
//
// A selection plate is one `CALayer` behind the chosen tab of a strip. It has exactly two behaviours
// and both shells wrote both of them out:
//
//   • TRAVEL — the plate slides from the outgoing tab's footprint to the incoming one over
//     ``Slate/Motion/selectionMorph``. One `CABasicAnimation` and a model-layer set.
//   • IGNITE — arriving from another island there is no plate on screen to move, so it APPEARS at
//     ``Slate/Anim/plateIgniteScale`` of its own height and settles into place while fading up. That
//     reads as the selection landing; a plate that teleported in at full size reads as a glitch. The
//     frame is placed with actions disabled first, or the ignite would be a travel from wherever the
//     layer happened to be (typically the origin, which draws a plate flying in from the corner).
//
// WHY THIS IS NOT PER-SHELL. QuartzCore is the SAME framework on macOS and iOS — `CALayer`,
// `CABasicAnimation` and `CATransaction` are one API with one behaviour, and the two copies of this
// block were character-identical, keys included. Nothing here is `NSView` or `UIView`: the caller
// hands over a layer and a frame it solved in its own coordinate space, which is the only part that is
// the shell's. Three call sites take it — the panel tab group on each shell and the Mac tab strip.
//
// ⚠️ TRANSCRIBED, NOT IMPROVED. `CABasicAnimation(keyPath: "frame")` is not a documented animatable
// key path (the pair is `bounds` + `position`), and it is what has been shipping on both shells for
// the plate's travel. Changing it here would be a behaviour change smuggled inside a de-duplication,
// so it stays exactly as it was; if the travel is ever re-timed, that is its own change with its own
// pixel verification.

import QuartzCore

/// The selection plate's two motions.
///
/// `package`, like every other type in this module: its three callers are the two shells' tab strips,
/// both inside this package, and a `public` `@MainActor` type owes a `@preconcurrency` annotation for
/// Swift 5 source compatibility that nothing here is asking for.
@MainActor
package enum SlatePlate {
    /// Move `plate` to `frame` — sliding if it is already on screen, igniting if this is its first
    /// appearance in this strip.
    ///
    /// Un-hides the layer itself: every caller's preceding line was the same `isHidden = false`, and a
    /// hidden layer would ignite invisibly and then snap in at the end.
    package static func travel(_ plate: CALayer, to frame: CGRect, igniting: Bool) {
        plate.isHidden = false
        guard igniting else {
            let travel = CABasicAnimation(keyPath: "frame")
            travel.duration = Slate.Motion.selectionMorph.duration
            travel.timingFunction = Slate.Motion.selectionMorph.timingFunction
            plate.frame = frame
            plate.add(travel, forKey: "travel")
            return
        }
        place(plate, at: frame, animated: false)
        let grow = CABasicAnimation(keyPath: "transform.scale.y")
        grow.fromValue = Slate.Anim.plateIgniteScale
        grow.toValue = 1
        grow.duration = Slate.Motion.selectionMorph.duration
        grow.timingFunction = Slate.Motion.selectionMorph.timingFunction
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Slate.Motion.selectionMorph.duration
        fade.timingFunction = Slate.Motion.selectionMorph.timingFunction
        plate.add(grow, forKey: "ignite")
        plate.add(fade, forKey: "igniteFade")
    }

    /// Put `plate` at `frame` with no motion of its own — the layout pass's job, which must NOT animate
    /// or every window resize drags the plate behind the tab it belongs to.
    ///
    /// `animated: true` lets the ambient transaction through instead, for the one caller that re-places
    /// the plate as part of a change that IS animated.
    package static func place(_ plate: CALayer, at frame: CGRect, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        plate.frame = frame
        CATransaction.commit()
    }
}
