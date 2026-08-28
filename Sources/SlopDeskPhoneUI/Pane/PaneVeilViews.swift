// PaneVeilViews — the two pane veils and the focus mark, in UIKit (docs/62 stage E).
//
// The UIKit halves of the deleted `PaneResizeScrim`, `PaneRecedeScrim` and `PaneFocusCorner`, merged
// into one file the way `MacPaneScrims.swift` already merged the two veils: each is one rectangle (or
// one triangle) of one colour at one alpha, none of them holds state, and none of them observes
// anything. The container fades them; they draw.
//
// WHY TWO NAMED CONSTRUCTORS AND NOT ONE TAKING AN ALPHA. They are veils over the same rectangle and
// they mean opposite things. The resize veil HIDES a surface whose pixels are briefly wrong (a divider
// drag commits on release, so both panes' content is frozen at the pre-drag size while the seam moves;
// a rotation or a keyboard-driven resize stretches the libghostty surface without a reflow). The
// recede veil keeps a surface LEGIBLE while marking it as not-the-subject during a pane-switcher walk.
// An initialiser taking an alpha would let a caller pick either number for either job, and the two
// numbers are the only thing that distinguishes them — so `init` is private and each rung is spelled
// once, at its own factory.
//
// NON-INTERACTIVE, all three. `isUserInteractionEnabled = false` is the whole statement on this
// platform, and it is SMALLER than the AppKit half's: `MacPaneVeil` had to override `hitTest` AND note
// that the override is insufficient for any view owning an `NSTrackingArea`, because tracking areas
// are rect-based and keep firing regardless of the hit test. UIKit has no tracking areas, so the flag
// suppresses the whole subtree and there is no second half to get wrong. What does NOT come free is
// accessibility: a non-interactive view is still an accessibility element, so that is said separately.
//
// THE CALLER FADES THEM, and the view stays in the tree between gestures — the same bargain the
// deleted SwiftUI halves made with `.opacity`, and for the same reason: a veil that is added and
// removed is a layout change, and a veil that is faded is not. Keep-all-mounted (docs/62 §3.2) makes
// that mandatory rather than merely tidy — `layoutSubviews` does not run on a hidden subtree and the
// leaves size their drawables there.

#if os(iOS)
import SlopDeskSlate
import UIKit

/// A veil of one colour at one alpha, non-interactive.
///
/// ONE TYPE, TWO NAMED CONSTRUCTORS, and no public initialiser. A subclass pair would have said the
/// same thing, but the base's initialiser could then only have been `fileprivate` — which this repo
/// bans — and an internal one hands every caller the ability to invent a third veil at an alpha of
/// its own choosing. That is precisely what must not be available: the rung is the ONLY thing telling
/// a resize haze from a switcher walk's dimming, so `init` is private and the two rungs are spelled
/// here, once each, where the reason for each is written down.
@MainActor
final class PaneVeilView: UIView {
    /// The "this pane is resizing" cover — a veil over content that is briefly WRONG.
    static func resize() -> PaneVeilView { PaneVeilView(veil: Slate.Opacity.muted) }

    /// The "some OTHER pane is the subject right now" veil — a switcher walk's dimming, never a
    /// resting state, and lighter than ``resize()`` because a receded pane must stay readable.
    static func recede() -> PaneVeilView { PaneVeilView(veil: Slate.Opacity.recede) }

    private init(veil: Double) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        // `slateScalingAlpha`, NOT `withAlphaComponent`, and the two are not interchangeable: the
        // deleted SwiftUI half spent `.opacity(_:)`, which SCALES a colour's own alpha, while
        // `withAlphaComponent` REPLACES it. They agree only for as long as the terminal's paper stays
        // opaque — the day the profile's glass face carries alpha of its own, `withAlphaComponent`
        // would quietly make this veil the heavier of the two, in the one direction that matters (a
        // receded pane stops being readable). Scaling is what is being ported, so scaling is written.
        //
        // No re-ink on a theme flip, and that is a real difference from `MacPaneScrims`: the rung
        // lands on the VIEW's `backgroundColor`, which stays a dynamic `UIColor` and re-resolves
        // itself. Only a `CGColor` on a layer is flat, and this view hangs none.
        backgroundColor = Slate.Native.Surface.terminal.slateScalingAlpha(veil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}

// MARK: - The focus mark

/// The active-pane focus marker: a small FILLED right-triangle in the pane's top-left corner
/// (Warp-style) — the two legs run along the top and left edges, the hypotenuse cuts across.
///
/// Auto-capped at the smaller pane side, so a pane too small for the full leg keeps a proportional
/// mark instead of losing it or overflowing.
///
/// ⚠️ `minY`, NOT the AppKit half's `maxY`, and this is the one place in the pane cluster where the
/// port is not a transcription. `MacPaneFocusCorner` draws at `bounds.maxY` because AppKit's default
/// view space is y-UP, so the screen's top-left is the rect's maximum y. UIKit's is y-down and the
/// origin already IS the top-left, so the deleted SwiftUI shape's `rect.minY` is what carries over.
/// Transliterating the Mac verbatim compiles and puts the mark in the bottom-left corner.
@MainActor
final class PaneFocusCornerView: UIView {
    /// Leg length in points. The cap in `layoutSubviews` is why this is not simply the layer's size.
    private let leg = Slate.Metric.focusCornerSize
    private let triangle = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        // The mark is a statement, never a target — a tap, and the divider gesture, pass through it.
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.addSublayer(triangle)
        paint()
        // A `CGColor` on a shape layer is flat and does not follow a theme flip, so the one rung is
        // re-resolved by hand. `traitCollectionDidChange` is deprecated on iOS 17+ and banned here.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.paint() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Swift.min(leg, Swift.min(bounds.width, bounds.height))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.minX + side, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + side))
        path.closeSubpath()
        // The mark must arrive at its new place WITH the pane, not drift there behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        triangle.frame = bounds
        triangle.path = path
        CATransaction.commit()
    }

    private func paint() {
        triangle.fillColor = Slate.Native.accent.resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - The reveal

/// The pane's overlays arrive and leave by fading, and by nothing else.
///
/// `isHidden` is deliberately NOT used, unlike the chip columns' reveal: a layer-hosting leaf sizes
/// its surface and picks its `contentsScale` in `layoutSubviews`, which does not run on a hidden
/// subtree, so hiding one of these could leave a sibling presenting stale geometry after a display
/// change (docs/62 §3.2, keep-all-mounted). Every one of them already refuses touches on its own, so
/// alpha alone is safe here in a way it is not for a control.
///
/// ⚠️ `layer.opacity`, not `alpha`, and not for style: `UIView.animate` can carry this rung's DURATION
/// but not its bezier, while setting the layer property outside such a block runs the layer's implicit
/// animation, which `CATransaction` can hand both to. `alpha` and `layer.opacity` are the same stored
/// property, so the two spellings differ only in which animation the assignment picks up. The design
/// system already fades this way (`SlateRow`, `SlateEmptyState`).
@MainActor
enum PaneFade {
    static func set(_ view: UIView, shown: Bool, curve: SlateCurve = Slate.Motion.reveal) {
        let wanted: Float = shown ? 1 : 0
        guard view.layer.opacity != wanted else { return }
        CATransaction.begin()
        // Off-window there is nobody to show the crossing to, and an unattached view that animates
        // arrives mid-fade when it is finally mounted.
        if view.window != nil {
            CATransaction.setAnimationDuration(curve.duration)
            CATransaction.setAnimationTimingFunction(curve.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        view.layer.opacity = wanted
        CATransaction.commit()
    }
}
#endif
