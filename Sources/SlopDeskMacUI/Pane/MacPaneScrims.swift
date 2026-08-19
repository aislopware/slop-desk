// MacPaneScrims — the two pane veils, in AppKit (docs/56 wave R, batch R1).
//
// The AppKit halves of ``PaneResizeScrim`` and ``PaneRecedeScrim``. Both are one rectangle of the
// terminal's own paper colour at one alpha, and neither has any state, so the whole of each is a
// layer-backed `NSView` with a `backgroundColor` — no `draw(_:)`, no tracking area, no observation.
//
// WHY TWO NAMED CONSTRUCTORS AND NOT ONE TAKING AN ALPHA. They are veils over the same rectangle and
// they mean opposite things. The resize veil HIDES a surface whose pixels are briefly wrong (a divider
// drag commits on release, so both panes' content is frozen at the pre-drag size while the seam moves;
// a window-edge resize stretches the libghostty surface without a reflow). The recede veil keeps a
// surface LEGIBLE while marking it as not-the-subject during a ⌃⇥ walk. An initialiser taking an alpha
// would let a caller pick either number for either job, and the two numbers are the only thing that
// distinguishes them — so `init` is private and each rung is spelled once, at its own factory.
//
// NON-HIT-TESTING, both. `hitTest` returns nil rather than the view: a click during a ⌃⇥ walk
// abandons the switcher and focuses the pane under the cursor, which is the right escape and must
// not be swallowed by a decoration. This is the AppKit spelling of the SwiftUI halves'
// `.allowsHitTesting(false)` — and unlike `.allowsHitTesting`, it is NOT enough on its own for a view
// that owns an `NSTrackingArea` (tracking areas are rect-based and keep firing regardless of what
// `hitTest` answers). These two own none, which is why the plain override is sufficient HERE and is
// not the pattern the leaves may copy — see docs/56 risk 3, which is batch R9's.
//
// The caller fades them by `alphaValue`, so the view stays in the tree between gestures — the same
// bargain the SwiftUI halves make with `.opacity`, and for the same reason: a veil that is added and
// removed is a layout change, and a veil that is faded is not.

import AppKit
import SlopDeskSlate

/// A veil of one colour at one alpha, non-hit-testing.
///
/// ONE TYPE, TWO NAMED CONSTRUCTORS, and no public initialiser. A subclass pair would have said the
/// same thing, but the base's initialiser could then only have been `fileprivate` — which this repo
/// bans — and an internal one hands every caller the ability to invent a third veil at an alpha of
/// its own choosing. That is precisely what must not be available: the rung is the ONLY thing telling
/// a resize haze from a ⌃⇥ walk's dimming, so `init` is private and the two rungs are spelled here,
/// once each, where the reason for each is written down.
@MainActor
final class MacPaneVeil: NSView {
    /// The rung this veil is drawn at. Stored rather than read back off the layer, because
    /// `cgColor.alpha` on a resolved dynamic colour is not the rung that was asked for.
    private let veilAlpha: Double

    /// The "this pane is resizing" cover — a veil over content that is briefly WRONG.
    static func resize() -> MacPaneVeil { MacPaneVeil(alpha: Slate.Opacity.muted) }

    /// The "some OTHER pane is the subject right now" veil — a ⌃⇥ walk's dimming, never a resting
    /// state, and lighter than ``resize()`` because a receded pane must stay readable.
    static func recede() -> MacPaneVeil { MacPaneVeil(alpha: Slate.Opacity.recede) }

    private init(alpha: Double) {
        veilAlpha = alpha
        super.init(frame: .zero)
        wantsLayer = true
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Transparent to the pointer. See the file header — a click during a walk must reach the pane.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// The paper colour is theme-directed, so an appearance change re-resolves it. The rung does not
    /// move; only the colour under it does.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.backgroundColor = Slate.Native.Surface.terminal
            .withAlphaComponent(veilAlpha).cgColor
    }
}
