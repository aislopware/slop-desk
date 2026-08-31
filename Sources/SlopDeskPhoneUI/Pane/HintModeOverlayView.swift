// HintModeOverlayView — the Vimium-style Hint Mode overlay, in UIKit (docs/62, the pane-leaf cluster).
//
// A DECORATION layered OVER the terminal surface, never a content branch (the surface-teardown/
// focus-freeze guardrail): while the pane model has an armed intent (``TerminalViewModel/hintMode``) it DIMS the
// surface so the labels pop, draws a yellow 2-letter badge at each detected target, and shows a
// `HINTS · <intent> · ×` badge top-trailing — the `hint-mode.png` chrome, floated in the pane because
// slopdesk has no titlebar, exactly like the vi-mode and read-only chips beside it.
//
// KEYSTROKES ARE NOT THIS VIEW'S. The renderer's key handling routes them to
// ``TerminalViewModel/handleHintKey(_:)`` while hint mode is up (NOT to the PTY); that dims the
// non-matching labels on the first letter and runs the action on the second, with no Return. This overlay
// only RENDERS the pure state it leaves behind. Nothing here taps the event stream, and nothing here may:
// a second reader of the same key is how a chord ends up handled twice.
//
// TAP IS THE PHONE'S ACTUATION, and it is the one place this overlay is not a decoration. Typing two
// keys on a software keyboard with the overlay up is awkward, so a tap on a badge resolves its target
// directly through the SAME ``TerminalViewModel/confirmHintTarget(_:)`` seam a two-key resolve fires, and
// a tap on the dim plate cancels the mode. That is why ``armed`` gates `isUserInteractionEnabled` rather
// than the whole view being inert like its four decoration siblings.
//
// EVERY DECISION AND EVERY WORD IS ``HintPresentation``'s (`SlopDeskClientCore`) — the arm predicate, the
// per-letter fade rule, the uppercasing, the dim predicate over ``HintLabelAssigner/filter(typed:labels:)``
// and the five strings. WHICH letters a label gets, in what order, and which spans are eligible at all
// are one floor further down (``HintLabelAssigner``), assigned ONCE per session by
// ``TerminalViewModel/beginHint(_:)`` and stable for its life. What is left here is the ink and the
// placement.
//
// ⚠️ NO FLIP, AND THAT IS THE WHOLE OF THE COORDINATE STORY. ``TerminalCellMetrics`` reports points in a
// TOP-LEFT-origin space (the convention the surface's own pointer reporting uses), which is `UIView`'s
// default — so the Mac half's `isFlipped { true }` and the arithmetic it protects transliterate here
// VERBATIM. The trap is the reverse of the Mac's: nothing has to be said, and the temptation is to
// "correct" a badge origin that is already right.
//
// ⚠️ THE RE-PLACE ON RESIZE IS THIS HALF'S OWN, and it fixes a defect docs/62 §2.1 recorded in the
// SwiftUI original. A font-size change or a pane resize moves every cell without bumping a single
// observable property (`cellMetrics()` is a renderer readback, not observable state), so an overlay
// that only re-placed on an observation callback left every badge at its pre-resize point — labels
// pointing at the wrong words, which is the one failure mode the honest-ceiling rule below exists to rule
// out. ``layoutSubviews`` therefore re-reads the metrics, and the ``Session`` equality is what keeps that
// from rebuilding anything on the passes where nothing moved.
//
// Honest ceiling: a headless / placeholder surface does not conform to ``TerminalViewportSnapshotting``
// (the real surface hangs without a window server — CLAUDE.md rule #6), so `cellMetrics()` is absent and
// the overlay draws NOTHING. Labels are ABSENT, never wrong. The actuation itself is the leaf's
// (``TerminalViewModel/onHintConfirmed``).
//
// `Slate.*` tokens for the chrome; the badge is a FIXED yellow plate with BLACK text — the hint-mode
// spec's "yellow background / black text", theme-independent so it reads over any terminal background,
// the secure-input-pill rationale. Black and white are the two rungs ``Slate/Native`` deliberately does
// NOT carry (see its header): they are not colours the platform has an opinion about.

#if os(iOS)
import SFSafeSymbols // the mark's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // HintPresentation — the arm predicate, the fade rule and the five strings
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

/// The hint chrome's two PINNED values, spelled once for the file that draws them all.
///
/// ``Slate/Native`` deliberately carries no rung for black or white — see its header: they are not
/// colours the platform has an opinion about. Both the label badges and the mode badge stand on the SAME
/// pinned yellow, so both read their ink from here rather than one of them reaching into the other's type
/// for it.
@MainActor
private enum HintPlate {
    /// Ink ON the pinned yellow plate — theme-independent, so it reads over any terminal background (the
    /// hint-mode spec, the secure-input-pill rationale).
    static let ink = SlateNativeColor.black
    /// The plate itself.
    static var fill: UIColor { Slate.Native.Status.warn }
}

@MainActor
final class HintModeOverlayView: UIView {
    /// The pane's terminal model — read for the OBSERVABLE armed intent (`hintMode`) and typed prefix
    /// (`hintTyped`), and dereferenced (non-reactively) for its `surface` viewport geometry at placement
    /// time. The targets and the labels are `@ObservationIgnored` on purpose: they are set ONCE per
    /// session, and re-detecting per keystroke would re-shuffle every label under the user's eye.
    private let model: TerminalViewModel

    private let dim = HintDimPlateView()
    private let badge: HintModeBadgeView
    private var marks: [HintLabelBadgeView] = []

    /// Whether the overlay is up. It gates `isUserInteractionEnabled` as well as the drawing, because the
    /// dim plate is deliberately OPAQUE to touch while hint mode is live (a stray tap must not reach the
    /// terminal under it) and must be equally deliberately transparent when it is not.
    private var armed = false
    /// The session this view is currently drawn for. The labels are stable for a session, so a keystroke
    /// re-inks the mounted badges instead of rebuilding them.
    private var session: Session?
    /// The live following. Stored for ``teardown()`` alone — the overlay can outlive the pane it reads,
    /// which is the one case ``ObservationFollow/stop()`` exists for.
    private var hintFollow: ObservationFollow?

    /// What makes two drawings the same drawing. The METRICS are in it because a font-size change or a
    /// resize moves every badge without changing a single label — which is the whole reason
    /// ``layoutSubviews`` can call ``refresh()`` without rebuilding on every pass.
    private struct Session: Equatable {
        let intent: HintIntent
        let labels: [String]
        let metrics: TerminalCellMetrics
    }

    init(model: TerminalViewModel) {
        self.model = model
        badge = HintModeBadgeView(onExit: { [weak model] in model?.cancelHintMode() })
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // Every child is placed from CELL GEOMETRY rather than from constraints — a badge's position is
        // arithmetic over `(row, colStart)` that Auto Layout has no way to express — so the subviews are
        // frame-placed and this view does the placing in `layoutSubviews`.
        dim.onCancel = { [weak model] in model?.cancelHintMode() }
        addSubview(dim)
        addSubview(badge)
        isHidden = true
        isUserInteractionEnabled = false
    }

    /// End the following, and let the badges go.
    ///
    /// Called by the leaf when the pane is torn down. Nothing else is owed: `Observation`'s registration
    /// dies with the closure, so there is no observer to remove — only the wake that is already in
    /// flight, which ``ObservationFollow/stop()`` turns into a no-op.
    func teardown() {
        hintFollow?.stop()
        hintFollow = nil
        retire()
    }

    // MARK: The live read

    /// Re-read the two observable properties and re-place, through
    /// ``ObservationFollow/arm(_:read:apply:)``.
    ///
    /// The geometry read sits in ``refresh()``, OUTSIDE `read`, and deliberately: `surface` is
    /// `@ObservationIgnored` and a weak reference to a live renderer, so making it part of the
    /// dependency would register nothing and cost a retain cycle's worth of confusion for it. `apply`
    /// therefore discards the reading and asks ``refresh()`` for the values again — the same recompute
    /// `layoutSubviews` needs with no reading in hand.
    private func follow() {
        hintFollow = ObservationFollow.arm(self) { view in
            (intent: view.model.hintMode, typed: view.model.hintTyped)
        } apply: { view, _ in
            view.refresh()
        }
    }

    /// Read the model and the live cell geometry, mount or retire, and place.
    ///
    /// ⚠️ READS ONLY. It is reached from ``layoutSubviews``, and a mutating `model.` / `store.` call
    /// there would invalidate observation, schedule a relayout, and land back here — an unbounded loop
    /// with no `setNeedsLayout` in sight to blame (docs/62 hazard 7).
    private func refresh() {
        let snapshot = model.surface as? TerminalViewportSnapshotting
        guard let intent = model.hintMode, let metrics = snapshot?.cellMetrics(),
              HintPresentation.isArmed(
                  intent: intent, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
              )
        else {
            retire()
            return
        }
        let typed = model.hintTyped
        let next = Session(intent: intent, labels: model.hintLabels, metrics: metrics)
        if next != session {
            session = next
            mount(next)
        }
        armed = true
        isHidden = false
        isUserInteractionEnabled = true
        badge.apply(intent: intent, typed: typed)
        // The typed prefix admits a SET of labels, asked once per keystroke rather than once per badge:
        // `matchedLabels` builds it, and every badge then answers about itself in O(1).
        let matched = HintPresentation.matchedLabels(typed: typed, labels: next.labels)
        for mark in marks {
            mark.apply(typed: typed, dimmed: HintPresentation.dimmed(label: mark.label, matched: matched))
        }
        place()
    }

    /// Build one badge per target whose first cell is actually ON the visible grid.
    ///
    /// ⚠️ CLAMPED, not merely offset: a target whose `colStart` lands off-screen-right (a
    /// soft-wrap-shifted span) is SKIPPED rather than anchored in the void, which is
    /// ``TerminalCellMetrics/clampedRect(row:colStart:colEnd:)``'s whole reason for existing. A badge in
    /// the margin points at nothing while still claiming a letter.
    private func mount(_ session: Session) {
        for mark in marks { mark.removeFromSuperview() }
        marks = []
        for (target, label) in zip(model.hintTargets, session.labels) {
            guard let rect = session.metrics.clampedRect(
                row: target.row, colStart: target.colStart, colEnd: target.colEnd,
            ) else { continue }
            let mark = HintLabelBadgeView(label: label, anchor: rect.origin)
            mark.onConfirm = { [weak model] in model?.confirmHintTarget(target) }
            marks.append(mark)
            // BELOW the mode badge. A target in the pane's top-trailing corner would otherwise be drawn
            // over the chip that says which mode you are in and how to leave it — the one thing on screen
            // that must never be occluded by the thing it is describing.
            insertSubview(mark, belowSubview: badge)
        }
    }

    /// Take the whole overlay down.
    ///
    /// `isHidden` AND `isUserInteractionEnabled`, said separately: a hidden view is out of the drawing
    /// pass and out of hit-testing, but the pair is what the leaf's own occlusion rule spells too, and
    /// stating both is what keeps a later "just fade it out" edit from silently leaving a full-pane tap
    /// swallower over live output. The badges go with it rather than lingering invisibly.
    private func retire() {
        guard armed || !marks.isEmpty else { return }
        armed = false
        isHidden = true
        isUserInteractionEnabled = false
        session = nil
        for mark in marks { mark.removeFromSuperview() }
        marks = []
    }

    // MARK: Placement

    override func layoutSubviews() {
        super.layoutSubviews()
        // See the file header: the metrics are a readback, so a resize reaches this overlay through
        // layout and through nothing else.
        refresh()
    }

    private func place() {
        dim.frame = bounds
        let badgeSize = badge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // TOP-trailing, in a top-left-origin space — the same arithmetic the Mac half spells inside its
        // `isFlipped`, unchanged.
        badge.frame = CGRect(
            x: bounds.maxX - badgeSize.width - Slate.Metric.space2, y: Slate.Metric.space2,
            width: badgeSize.width, height: badgeSize.height,
        )
        for mark in marks {
            mark.frame = CGRect(
                origin: mark.anchor,
                size: mark.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize),
            )
        }
    }

    // MARK: The second exit

    /// Belt-and-suspenders Escape cancel. The primary route is the renderer's own key handling →
    /// `cancelHintMode()` once the terminal is first responder; this is the net for an Esc that lands in
    /// the OVERLAY's chain instead.
    ///
    /// ⚠️ It fires ONLY while first responder status sits at or below this view, because that is what a
    /// `UIKeyCommand` published from `keyCommands` means — UIKit walks the chain UP from the responder,
    /// and this overlay is the terminal surface's SIBLING, not its ancestor. On a phone that costs
    /// nothing (there is no hardware Esc), and on an iPad it is the second exit exactly as the header
    /// says. Installing an event monitor to widen its reach would make this a second reader of a key the
    /// renderer already consumes, and is banned in this directory.
    override var keyCommands: [UIKeyCommand]? {
        [.slateCancel(action: #selector(cancelHint))]
    }

    @objc
    private func cancelHint() {
        model.cancelHintMode()
    }
}

// MARK: - The dim plate

/// The scrim under the labels, and the mode's largest cancel target.
///
/// It is the SAME token the modal overlays dim with. Two jobs, and the second is the one that is easy to
/// lose in a port: it BLOCKS taps to the terminal while hint mode is up, so a mis-aimed tap cancels the
/// mode instead of moving the cursor in whatever is running.
@MainActor
private final class HintDimPlateView: UIView {
    var onCancel: () -> Void = {}

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
        // A view's `backgroundColor` holds the dynamic `UIColor` itself, so the scrim follows the
        // appearance with no trait registration at all — the one rung in this file that needs none.
        backgroundColor = Slate.Native.State.shadow
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancel)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func cancel() { onCancel() }
}

// MARK: - One label badge

/// A single yellow 2-letter hint badge standing on its target's first cell.
///
/// The already-typed first letter is drawn faded so the user sees which key is next; a label the typed
/// prefix has ruled out is dimmed as a WHOLE PLATE rather than removed, because a badge that vanished
/// would let the eye read the target as gone and force the remaining field to be re-scanned after every
/// keystroke.
@MainActor
private final class HintLabelBadgeView: UIView {
    /// ⚠️ 0.2 is UNNAMED on the floor — the ruled-out badge's opacity, a rung BELOW ``Slate/Opacity/dim``
    /// (0.35) because this dims a whole PLATE rather than ink on one. Second spelling, same ⚠️ as the Mac
    /// half. Proposed `Slate.Opacity.dimmedPlate`.
    private static let ruledOut: CGFloat = 0.2

    let label: String
    /// The badge's top-left in the overlay's space — its target's first cell, straight out of
    /// ``TerminalCellMetrics/clampedRect(row:colStart:colEnd:)``. No conversion: the metrics' space and
    /// `UIView`'s are the same space.
    let anchor: CGPoint

    var onConfirm: () -> Void = {}

    private let text = UILabel()

    init(label: String, anchor: CGPoint) {
        self.label = label
        self.anchor = anchor
        super.init(frame: .zero)
        backgroundColor = HintPlate.fill
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline

        text.numberOfLines = 1
        text.lineBreakMode = .byClipping
        text.isAccessibilityElement = false
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate(DecorationHintBadge.constraints(in: self, text: text))

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = HintPresentation.labelAccessibility(label)
        // Tapping a badge resolves its target directly, through the SAME
        // ``TerminalViewModel/confirmHintTarget(_:)`` seam a two-key resolve fires. On the phone this is
        // not a convenience — it is the actuation path the soft keyboard makes awkward.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(confirm)))
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A badge is 14pt tall by design (see ``DecorationHintBadge/minHeight``) — far under a thumb — so
    /// its TOUCH target is grown past its plate rather than the plate being grown past the cell it
    /// stands on. A badge that
    /// covered its neighbours would be pointing at the wrong word, which is the failure this whole family
    /// refuses; overlapping hit rects only cost the topmost badge the tie, and the two-key path is always
    /// there when the tie goes the wrong way.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Slate.Metric.space1, dy: -Slate.Metric.space1).contains(point)
    }

    /// Re-ink for the current typed prefix. The plate does not move and the label does not change — only
    /// which letters are faded, and whether the whole badge is still in the running.
    ///
    /// The 2-letter run itself is ``DecorationHintBadge/letters(label:typed:font:ink:)`` — WHICH letters
    /// are faded, and that the label is uppercased at all, are ``HintPresentation``'s, and the drawing of
    /// that answer is now one implementation rather than one per shell.
    func apply(typed: String, dimmed: Bool) {
        text.attributedText = DecorationHintBadge.letters(
            label: label, typed: typed,
            font: .monospacedSystemFont(ofSize: Slate.Typeface.small, weight: .bold),
            ink: HintPlate.ink,
        )
        alpha = dimmed ? Self.ruledOut : 1
    }

    /// The plate is a pinned yellow and the hairline is a pinned black — neither is appearance-dynamic,
    /// so this runs once and there is no trait registration to make. That is the payoff of the pin, and
    /// it is worth saying: every other plate in this directory needs one.
    private func paint() {
        // A thin dark hairline so the yellow plate reads on a light background too.
        layer.borderColor = HintPlate.ink.withAlphaComponent(Slate.Opacity.dim).cgColor
    }

    @objc
    private func confirm() { onConfirm() }

    override func accessibilityActivate() -> Bool {
        onConfirm()
        return true
    }
}

// MARK: - The mode badge

/// The `HINTS` mode badge — the `hint-mode.png` titlebar chip, floated in the pane's top-trailing region
/// since slopdesk has no titlebar. Shows the active intent, the keys typed so far, and an `×` that leaves
/// the mode.
@MainActor
private final class HintModeBadgeView: UIView {
    private let onExit: () -> Void

    private let row = UIStackView()
    private let title = UILabel()
    private let intentLabel = UILabel()
    /// The typed prefix. Hidden rather than removed when nothing has been typed — an arranged subview
    /// that is hidden leaves the stack's layout, which is the UIKit spelling of the SwiftUI half's
    /// `if !typed.isEmpty`.
    private let typedLabel = UILabel()
    private let close: HintBadgeCloseView

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
        close = HintBadgeCloseView(onPress: onExit)
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        backgroundColor = HintPlate.fill
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.masksToBounds = false

        title.attributedText = NSAttributedString(
            string: HintPresentation.title,
            attributes: [
                .font: UIFont.systemFont(ofSize: Slate.Typeface.footnote, weight: .bold),
                .foregroundColor: HintPlate.ink,
                .kern: Slate.Typeface.pillTracking,
            ],
        )
        typedLabel.font = .monospacedSystemFont(ofSize: Slate.Typeface.footnote, weight: .bold)
        typedLabel.textColor = HintPlate.ink

        for text in [title, intentLabel, typedLabel] {
            text.numberOfLines = 1
            // The intent word and the typed keys are the two facts the badge exists to report; a chip
            // narrow enough to elide `REVEAL` would be naming the verb the user has to guess at.
            text.lineBreakMode = .byClipping
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.isAccessibilityElement = false
        }

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space1, leading: Slate.Metric.space2,
            bottom: Slate.Metric.space1, trailing: Slate.Metric.space2,
        )
        row.addArrangedSubview(title)
        row.addArrangedSubview(intentLabel)
        row.addArrangedSubview(typedLabel)
        row.addArrangedSubview(close)
        addSubview(row)
        NSLayoutConstraint.activate(row.slateEdges(of: self))

        // A semantic GROUP, for the reason the status chip gives: the copy is read once off the title and
        // the `×` stays a button VoiceOver can reach.
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        title.isAccessibilityElement = true
        title.accessibilityHint = HintPresentation.badgeAccessibilityHint
        // The cast is a layer colour and the appearance can move it; the plate and the ink cannot (both
        // are pinned).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (chip: Self, _: UITraitCollection) in
            chip.layer.slateShadow(.chip, in: chip.traitCollection)
        }
        layer.slateShadow(.chip, in: traitCollection)
    }

    func apply(intent: HintIntent, typed: String) {
        intentLabel.attributedText = NSAttributedString(
            string: intent.badgeLabel,
            attributes: [
                .font: UIFont.systemFont(ofSize: Slate.Typeface.small, weight: .semibold),
                .foregroundColor: HintPlate.ink.withAlphaComponent(Slate.Opacity.muted),
                .kern: Slate.Typeface.pillTracking,
            ],
        )
        typedLabel.text = HintPresentation.displayLabel(typed)
        typedLabel.isHidden = typed.isEmpty
        title.accessibilityLabel = HintPresentation.badgeAccessibilityLabel(intent)
        setNeedsLayout()
    }
}

// MARK: - The badge's × plate

/// The `×` that leaves hint mode — the same seam the dim-plate tap and Esc fire.
///
/// NOT ``PaneStatusPillCloseView``, and the difference is the plate it stands on. That `×` grows the
/// SELECTION wash under a press, which is a tint of the brand accent; here it would land on a PINNED
/// yellow plate the accent has no relationship to at all. So this one acknowledges the finger the way the
/// rest of the badge does — by going to full black from the muted rung — and the square it takes is still
/// ``Slate/Metric/glyphPlate``, because a mark that is a different size on this chip than on the one
/// above it reads as a different control.
@MainActor
private final class HintBadgeCloseView: UIControl {
    private let glyph = UIImageView()
    private let onPress: () -> Void

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            fade()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            fade()
        }
    }

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.contentMode = .center
        glyph.isAccessibilityElement = false
        glyph.isUserInteractionEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            // ``Slate/Metric/glyphPlate`` — the ONE square every `×` on a pane chip takes, and the hit
            // area as much as the drawing.
            widthAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            heightAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addTarget(self, action: #selector(fire), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button
        // The help IS the label: `exitHelp` already names the action and the key that does it.
        accessibilityLabel = HintPresentation.exitHelp
        slateHelp(HintPresentation.exitHelp)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A 16pt mark on a badge that floats over live output. Same bargain as the status chip's `×`: the
    /// plate stays the rung, the TOUCH target is grown past it, and every route out of hint mode that is
    /// not this tap (Esc, the dim plate, a two-key resolve) is still there.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Slate.Metric.space1, dy: -Slate.Metric.space1).contains(point)
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began,
             .changed: hovering = true
        default: hovering = false
        }
    }

    @objc
    private func fire() { onPress() }

    /// The glyph BRIGHTENS rather than snapping. ``Slate/Motion/smallFade`` names this exact use, and it
    /// is the rung every other acknowledgement in the UIKit chrome spends. A `UIImageView`'s `image` is
    /// not an animatable property, so the fade rides a `CATransition` on the glyph's layer rather than a
    /// `CATransaction` around a colour — the same result, and the honest spelling of it.
    private func fade() {
        let cross = CATransition()
        cross.type = .fade
        cross.duration = Slate.Motion.smallFade.duration
        cross.timingFunction = Slate.Motion.smallFade.timingFunction
        glyph.layer.add(cross, forKey: "ink")
        repaint()
    }

    private func repaint() {
        let lit = isHighlighted || hovering
        glyph.image = UIImage(
            systemName: SFSymbol.xmark.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .bold,
            ),
        )?.withTintColor(
            lit ? HintPlate.ink : HintPlate.ink.withAlphaComponent(Slate.Opacity.muted),
            renderingMode: .alwaysOriginal,
        )
    }
}
#endif
