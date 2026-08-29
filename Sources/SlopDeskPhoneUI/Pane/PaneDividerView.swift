// PaneDividerView — the draggable seam between two panes, in UIKit (docs/62 stage E.2).
//
// The UIKit half of the deleted `PaneDivider`: a thin separator hairline drawn inside a comfortable
// hit band, and a drag that resizes the panes LIVE — the layout updates every frame — while the host
// grid-resize SEND is deferred until release (the shell brackets the drag with
// `setTerminalResizeSuspended`, so the server gets ONE resize event when the drag settles, not one per
// frame). A double-tap evens out THIS seam only, never the tab.
//
// LIVE-RESIZE RULE, unchanged by the port: the drag sets the leading child's ABSOLUTE weight each
// frame — `handle.leadingWeight` captured at drag start, plus the finger translation converted to
// weight (`Δpx · flexSum / parentSpan`). A ghost-seam preview with a separate commit-on-release step
// is unnecessary and would risk a "divider chases itself, seam barely travels" mismatch; two things
// keep it finger-matched instead:
//   1. the translation is read in the SUPERVIEW's space — the tab layer, which does not move — because
//      this view's own bounds slide out from under the finger as the panes resize, so a delta measured
//      in them would under-report every frame. That is the same stable space the deleted half named
//      `PaneMoveSpace` and the AppKit half reaches through window coordinates; and
//   2. it is ABSOLUTE-from-start (not an accumulated per-frame delta), so an over-drag into the
//      min-weight clamp HOLDS and resumes exactly when the finger returns — no drift.
// The handle clamps the weight at the solver's pixel floor, so the seam stops on the neighbour by
// itself: no ghost-seam preview and no travel clamp are needed.
//
// ⚠️ NO SIGN FLIP HERE, AND THAT IS THE PORT'S ONE TRAP. `MacPaneDivider.axisTranslation` NEGATES the
// vertical arm (`grab.y - point.y`) because AppKit window coordinates are y-UP while the solver's rects
// are top-left origin. UIKit's touch coordinates are y-DOWN already, so `translation.y` is positive
// downward — exactly what `leadingWeight` (which grows the TOP child of a stacked split) needs, and
// exactly what the deleted half's `translation.height` gave. Carrying the Mac's negation across would
// make a stacked seam run away from the finger while a column seam stayed right, which is the shape of
// bug that reads as "only one of the two is broken".
//
// THE HIT BAND IS THE SOLVER'S, not a touch-sized one invented here: `bounds` is `handle.rect`, the
// FAT band emitted around the drawn hairline (`SplitLayoutSolver.dividerThickness`). Widening it for
// touch would be a LAYOUT change — the band is what the solver subtracts from the panes — so it
// belongs in the solver if it is wanted, never in the view that happens to draw it.
//
// NO POINTER CODE. `PaneCanvasMetrics.resizePointer` answers a cursor question, and the deleted half's
// `.panePointer(_:)` was already a documented iOS no-op; docs/62 stage E.2 deletes it as dead rather
// than porting it. The one-way-at-the-clamp rule it expressed survives where it is actually enforced —
// `handle.clampedLeadingWeight`.
//
// THE END-CLEANUP IS OWED ON TEARDOWN, NOT ONLY ON GESTURE END. `onResizeBegin` raises
// `setTerminalResizeSuspended(true)`, which is WORKSPACE-WIDE state on the store rather than anything
// this seam owns: every live terminal stops forwarding its grid to the host until something lowers it
// again. A seam UNMOUNTED while the finger is still down (a pane closed under the drag, the tab
// switched, the tab layer rebuilt) would leave the flag raised for the rest of the session. Every way
// this seam can vanish funnels into ``releaseDrag()``, which is idempotent on `startLead`.
//
// SYSTEM / DS colours only — the accent hairline is a drag affordance, not a hover state.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

/// One resize seam between two adjacent panes: the hit band, the hairline in it, and the drag.
///
/// The mounter owns the FRAME — it sets `frame` to the handle's solved rect in its own coordinate
/// space each solve, and re-assigns ``handle`` with it. Identity is the handle's
/// ``SplitTreeRenderModel/DividerHandle/key``, which pins `axis`, so the axis of a live instance never
/// changes and the seam's orientation is decided once. Re-using the instance across solves is not an
/// optimisation: rebuilding the view under a live drag would destroy the tracking gesture recogniser.
@MainActor
final class PaneDividerView: UIView {
    /// The live seam. Re-assigned on every solve — the pair weights inside it are what the drag's
    /// clamp and the readout are both read from, so they are never a frame behind.
    ///
    /// ⚠️ Guarded on the VALUE. The mounter re-assigns this on every solve for every seam in the tab,
    /// and a live divider drag solves at the display's rate — but only the seam under the finger
    /// actually moves, so the guard turns "N handles updated per frame" into "one". What it saves is
    /// real work: the readout's three instrument runs, each of which cuts a CoreText run.
    /// `DividerHandle` is `Equatable`, and everything ``handleUpdated()`` reads is either this value or
    /// `startLead` — whose own two transitions call ``applyReadout()`` directly — so an equal handle
    /// has nothing left to say.
    var handle: SplitTreeRenderModel.DividerHandle {
        didSet {
            guard handle != oldValue else { return }
            applyReadout()
        }
    }

    /// What this seam's four gestures are wired to — ``DecorationDividerActions``, one vocabulary for
    /// both shells. Each arm's meaning is documented there; what is decided here is only which gesture
    /// reports which arm.
    var actions = DecorationDividerActions()

    /// The drawn seam, centred in the band.
    ///
    /// A `CALayer` rather than a subview, and that is a simplification the Mac could not take: its
    /// `Hairline` is an `NSView` that must override `hitTest` to nil, or the line down the middle of
    /// the band — the part a user actually aims at — would swallow the press and the seam would only
    /// be grabbable beside itself. A layer is not in the responder chain at all, so the whole band
    /// belongs to the gesture recognisers by construction. It also puts the thickness and the colour on
    /// the SAME `CATransaction`, which is what the AppKit half needs `allowsImplicitAnimation` for.
    private let seam = CALayer()
    /// The seam's current thickness, so a re-layout that is not a state change re-places it where it
    /// already is instead of snapping it back to the resting hairline mid-drag.
    private var seamThickness = Slate.Metric.hairline

    /// The live `62 · 38` readout, mounted for the drag and hidden the rest of the time.
    private let readout = RatioReadoutView()

    /// The leading child's weight captured when the drag STARTED — the absolute anchor for the whole
    /// gesture, and the latch that makes ``releaseDrag()`` idempotent. `nil` between drags.
    private var startLead: Double?

    private let pan = UIPanGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()

    init(handle: SplitTreeRenderModel.DividerHandle, actions: DecorationDividerActions = .init()) {
        self.handle = handle
        self.actions = actions
        super.init(frame: handle.rect)
        build()
        applyReadout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ `translatesAutoresizingMaskIntoConstraints` is deliberately left TRUE on this view, which is
    /// the one place in this directory it is. The seam's position is re-solved on every frame of a live
    /// drag, so the mounter places it by assigning `frame` — a constraint pair rewritten 60 times a
    /// second is the same placement bought through the solver. Everything INSIDE the band is Auto
    /// Layout as usual, which works unchanged under a manually-framed container.
    private func build() {
        // The readout is WIDER than the band it is centred on — a seam is a few points across and a
        // two-number chip is not. Explicit rather than inherited: an ancestor that clipped would leave
        // a sliver of chip and no way to see it was there.
        clipsToBounds = false
        backgroundColor = .clear
        layer.addSublayer(seam)
        addSubview(readout)
        NSLayoutConstraint.activate([
            readout.centerXAnchor.constraint(equalTo: centerXAnchor),
            readout.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        pan.addTarget(self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap))
        addGestureRecognizer(doubleTap)

        paintSeam()
        // A `CGColor` on a layer is flat and does not follow a theme flip, so the seam is re-inked by
        // hand. `traitCollectionDidChange` is deprecated on iOS 17+ and banned here.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.paintSeam()
        }
    }

    // MARK: - The drag

    /// ⚠️ THE SLOP IS UIKIT'S, NOT THE `minimumDistance: 1` THE OTHER TWO HALVES SPELL. A
    /// `UIPanGestureRecognizer` does not reach `.began` until the touch has travelled its own
    /// hysteresis, which is the platform's answer to the same question the SwiftUI half asked with a
    /// minimum distance and the AppKit half with a one-point check: a press alone begins nothing, so a
    /// double-tap never spends a suspend/commit round trip on the way to ``onReset``. The translation
    /// is ZEROED at `.began` for the other half of that bargain — without it the first live frame would
    /// jump by the whole hysteresis and the seam would leap out from under the finger.
    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // The stable space, per the header. `superview` is the tab layer, which does not move while
        // the panes resize; falling back to `self` keeps a detached view's arithmetic finite rather
        // than correct, and a detached view is being released on the next line anyway.
        let space: UIView = superview ?? self
        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: space)
            startLead = handle.leadingWeight
            actions.onResizeBegin()
            setDragging(true)
        case .changed:
            guard startLead != nil else { return }
            let translation = gesture.translation(in: space)
            actions.onResizeChange(targetLeadingWeight(
                translation: handle.axis == .horizontal ? translation.x : translation.y,
            ))
        case .ended,
             .cancelled,
             .failed:
            releaseDrag()
        default:
            break
        }
    }

    /// Evens THIS seam only. The tap that carried it began nothing (see the slop note), so there is no
    /// in-flight resize to unwind first.
    @objc
    private func handleDoubleTap() {
        actions.onReset()
    }

    /// THE TEARDOWN SAFETY NET, and the reason it is not redundant with the gesture's `.cancelled`:
    /// removing a view from the hierarchy cancels its recognisers ASYNCHRONOUSLY, and the tab layer
    /// that owned this seam may be gone by then. Every way this seam can vanish under a live drag ends
    /// here — the divider band is mounted only for the ACTIVE tab, so a tab switch removes it;
    /// `layout.dividers` loses this handle's key when the pane on either side closes; and an evicted
    /// tab takes the whole layer with it.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseDrag() }
    }

    /// The drag's end-cleanup, spelled ONCE because two different events owe it: the gesture ending or
    /// cancelling, and this view being torn out of the tree while the finger is still down. `startLead`
    /// is both the anchor and the latch — set at `.began`, right after `onResizeBegin`, so it is
    /// exactly the "there is something to release" bit, and clearing it before the callback makes a
    /// second arrival a no-op. That also makes a release with no matching begin harmless, which is what
    /// a plain unmount at rest (every tab switch, every pane close) delivers: `onResizeEnd` unsuspends
    /// the whole workspace's terminals and stages a commit, so calling it on a seam that was never
    /// dragged would spend a reconcile per divider per tab switch and could lower a suspend a DIFFERENT
    /// drag is holding.
    private func releaseDrag() {
        guard startLead != nil else { return }
        startLead = nil
        setDragging(false)
        actions.onResizeEnd()
    }

    /// The absolute leading weight for a finger translation of `translation` points along the split
    /// axis: `startLead +` the translation converted to weight via
    /// ``SplitTreeRenderModel/DividerHandle/weightDelta(pixelIncrement:)`` (`Δpx · flexSum /
    /// parentSpan` — the inverse of a flex child's `extent = weight/flexSum·span`, and the same
    /// conversion the keyboard resize uses). It returns 0 for a zero/non-finite span, leaving `base`
    /// unchanged. Clamped by the handle so BOTH panes keep the solver's pixel floor; over-drags hold at
    /// the floor and resume when the finger returns.
    private func targetLeadingWeight(translation: CGFloat) -> Double {
        let base = startLead ?? handle.leadingWeight
        return handle.clampedLeadingWeight(base + handle.weightDelta(pixelIncrement: translation))
    }

    // MARK: - The drawing

    // A new solve arrives at ``applyReadout()`` directly. The Mac half routes it through a
    // `handleUpdated()` because AppKit also owes the window an `invalidateCursorRects(for:)` on a
    // seam whose movability changed; there is no pointer here and so no second statement, and a
    // one-line forwarder named after the other shell's two-line one was mirroring rather than
    // sharing.

    /// The seam's two states, in one transaction: the accent line and the extra point of weight arrive
    /// together, on the hover rung.
    ///
    /// The readout is mounted OUTSIDE the animation — MERIDIAN L3 status is present only while the drag
    /// is working and hard-cut on release, never faded in behind the thing it measures.
    private func setDragging(_ active: Bool) {
        applyReadout()
        seamThickness = active ? Slate.Metric.dividerHoverWidth : Slate.Metric.hairline
        CATransaction.begin()
        CATransaction.setAnimationDuration(Slate.Motion.dividerHover.duration)
        CATransaction.setAnimationTimingFunction(Slate.Motion.dividerHover.timingFunction)
        layoutSeam()
        seam.backgroundColor = seamInk(active: active)
        CATransaction.commit()
    }

    /// The live ratio readout's whole visibility rule, in one place so the two conditions cannot fight:
    /// it shows while the drag is working AND the pair is non-degenerate. A `.fixed` side reports no
    /// percentages, and the cue is then ABSENT rather than wrong.
    private func applyReadout() {
        let percents = handle.splitPercents
        let shown = startLead != nil && percents != nil
        readout.isHidden = !shown
        // ⚠️ The hide comes FIRST and the text is cut only for a readout that is actually up. This runs
        // once per divider per solve — and the canvas re-assigns `handle` on every frame of a divider
        // drag. Cutting three instrument runs for the N−1 seams that are not the one being dragged was
        // three uncached CoreText run builds per divider per frame, for pixels that are hidden.
        guard shown else { return }
        readout.percents = percents
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A solve is not a state change: the seam arrives at its new place with the panes rather than
        // easing there behind them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSeam()
        CATransaction.commit()
    }

    /// A `.horizontal` split lays its children out in columns, so its seam is a VERTICAL line that
    /// spans the band's height and is dragged left/right; `.vertical` is the quarter turn.
    private func layoutSeam() {
        seam.frame = handle.axis == .horizontal
            ? CGRect(
                x: (bounds.width - seamThickness) / 2, y: 0,
                width: seamThickness, height: bounds.height,
            )
            : CGRect(
                x: 0, y: (bounds.height - seamThickness) / 2,
                width: bounds.width, height: seamThickness,
            )
    }

    /// The crisp resting hairline — the profile's edge tone, one step off the glass (the
    /// JetBrains-Islands internal divider, never a chrome-coloured gap), and the accent while the drag
    /// is actually working.
    private func seamInk(active: Bool) -> CGColor {
        (active ? Slate.Native.accent : Slate.Native.Terminal.edge)
            .resolvedColor(with: traitCollection).cgColor
    }

    private func paintSeam() {
        seam.backgroundColor = seamInk(active: startLead != nil)
    }
}

// MARK: - The live ratio readout

/// The instrument-voice split percentages, centred on the seam: the answer to "am I at the ratio I was
/// aiming for?" while the eye is already on the divider (feedback at the trigger — never a HUD
/// elsewhere). Each frame's re-solve rebuilds the handle with fresh pair weights, so the numbers track
/// the seam live.
///
/// ⚠️ ON-GLASS VOCABULARY (``Slate/Native/Terminal``), not the semantic chrome tiers — the rule for
/// anything drawn inside the pane area. The semantic set is pinned on the LIGHT side only, so on the
/// glass it would draw `#585751` ink on a system fill over `#22212C`: a chip that is there but
/// unreadable. The rim is ``Slate/Native/Terminal/rim`` and NOT `edge`, because `edge` and `raised` are
/// the SAME profile tone — a border in `edge` on a `raised` plate is literally invisible, which is how
/// the deleted SwiftUI chips ended up floating unbounded over terminal output.
@MainActor
private final class RatioReadoutView: UIView {
    var percents: (leading: Int, trailing: Int)? {
        didSet {
            // A labelled optional tuple has no synthesized `==`, so the two fields are compared by
            // hand. Without the guard a drag frame that moved the seam by less than a whole percent —
            // most of them — re-cut all three runs to print the same two numbers.
            guard percents?.leading != oldValue?.leading
                || percents?.trailing != oldValue?.trailing
            else { return }
            applyText()
        }
    }

    /// Three labels rather than one string, because the `·` is a TIER and not a character: the numbers
    /// are the reading and the dot is the punctuation between them, so they are set in different inks
    /// and separated by the grid step.
    private let leadPct = UILabel()
    private let dot = UILabel()
    private let trailPct = UILabel()

    init() {
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // Hit-transparent, so the drag beneath is untouched: the chip sits centred ON the seam and is
        // at its widest exactly where the finger is holding the divider.
        isUserInteractionEnabled = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        // The cast has to fall OUTSIDE the plate — a chip clipped to its own bounds keeps the rim and
        // loses the lift that makes it legible over busy terminal output.
        layer.masksToBounds = false

        for label in [leadPct, dot, trailPct] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 1
            // The chip carries ONE accessibility label ("62 to 38 percent split"); three separate
            // labels would read as three unrelated numbers mid-drag.
            label.isAccessibilityElement = false
            // ⚠️ NOT ``SlateCapsLabelView``, which is the CAPS micro-heading recipe: this run is
            // numbers, never uppercased, so it shares the instrument FACE and the engraving but not
            // that component's case fold or its ink.
            label.font = Slate.Typeface.instrumentNative(Slate.Typeface.footnote, weight: .regular)
            addSubview(label)
        }

        // Where the three runs sit is ``DecorationRatioReadout``'s — an arrangement, and the same one on
        // both shells down to the rung each gap spends.
        NSLayoutConstraint.activate(DecorationRatioReadout.constraints(
            in: self, leading: leadPct, dot: dot, trailing: trailPct,
        ))
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        applyText()
        paint()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in view.paint() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A shadow with no path rasterises the whole layer's alpha every frame, and this chip redraws
        // on every drag frame — the one place that cost would actually be paid.
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, cornerRadius: Slate.Metric.radiusControl,
        ).cgPath
    }

    private func applyText() {
        guard let percents else { return }
        leadPct.attributedText = Self.run("\(percents.leading)", ink: Slate.Native.Text.primary)
        dot.attributedText = Self.run("·", ink: Slate.Native.Text.tertiary)
        trailPct.attributedText = Self.run("\(percents.trailing)", ink: Slate.Native.Text.primary)
        accessibilityLabel = "\(percents.leading) to \(percents.trailing) percent split"
    }

    /// One run of the instrument voice. TRACKING IS AN ATTRIBUTE, NOT A PROPERTY — letter spacing
    /// reaches a `UILabel` only as `.kern` on the string, which is why the numbers go through an
    /// attributed run rather than straight onto `text`.
    private static func run(_ text: String, ink: UIColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.kern: Slate.Typeface.instrumentTracking, .foregroundColor: ink],
        )
    }

    private func paint() {
        backgroundColor = Slate.Native.Terminal.raised
        layer.borderColor = Slate.Native.Terminal.rim.resolvedColor(with: traitCollection).cgColor
        // The rung is the API — the radius and the offset never appear at a call site. Positive y,
        // because UIKit's is a y-DOWN space: `MacPaneDivider` spells `-Slate.Elevation.chip.y` by hand
        // for the opposite reason, and copying its sign would cast the chip's shadow upward.
        layer.slateShadow(.chip, color: Slate.Native.State.overlayShadow, in: traitCollection)
    }
}
#endif
