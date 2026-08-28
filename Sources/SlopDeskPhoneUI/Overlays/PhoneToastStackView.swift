// PhoneToastStackView — the phone's transient notification corner, in UIKit (docs/62 stage F).
//
// The UIKit half of the deleted `ToastStackView`: the live ``OverlayCoordinator/toasts`` stack drawn as a
// bottom-trailing column, newest LAST and flush to the corner. It is the in-app surface for the background
// events that ALSO fire a system notification (a long command finished, an agent needs input, a pane
// event), so a user watching the workspace sees them without leaving the window.
//
// The Mac's half is an `NSPanel` sized to the column (``SlopDeskMacUI/MacToastStack``) and the two meet
// BELOW the view layer at ``ToastPresentation`` — the headline, the spine budget, the mark and the dwell.
// Nothing here re-decides any of those. What is here is the phone's LAYOUT and the UIKit view of the ink
// ladder.
//
// A notification is A PANE SPEAKING FROM OFF-SCREEN. Every push site is gated on the source pane NOT being
// focused, so a card always names a place the user is not looking at — which is what the design answers:
//
//   * The card is a member of the FLOATING FAMILY (``SlatePaperCardSurface``): the same paper, the same
//     neutral system ink, sentence-case in one voice, hierarchy by size and weight. The earlier design
//     spoke the instrument register — a coloured caps-mono eyebrow over a mono subject — and was rejected
//     wholesale: four hues of engraving stacked in a corner read as an instrument panel, not as an app
//     speaking. The words the eyebrow carried became the HEADLINE.
//   * The LEADING MARK speaks the system's enclosed-status idiom: the `*.circle.fill` two-layer form in
//     one hue, drawn as its TWO symbol layers rather than the fused symbol so the glyph is CENTRED on the
//     disc (the fused `info.circle.fill` sets its serif "i" visibly off-centre at this size).
//   * The CARD IS A DOOR. Tapping it jumps to the pane it names (``Toast/paneKey``), which is why the card
//     is a ``SlateRowButton`` rather than a plain view — a control cannot be outranked by a background it
//     does not have, so the whole body is the target without an invisible barrier behind it.
//   * The SPINE. Only the newest ``ToastPresentation/expandedCount`` cards carry a detail line, so four
//     simultaneous notifications cost a third of the corner instead of blanketing the prompt.
//
// ⚠️ THERE IS NO HOVER ON THIS PLATFORM, and that is a real behavioural difference rather than an omission.
// The Mac freezes a card's dwell under the pointer and reveals a collapsed card's body on hover; a touch
// device has neither event, so ``ToastPresentation/showsBody(_:expanded:hovering:)`` and
// ``ToastPresentation/showsClose(_:hovering:)`` are asked with `hovering: false` here — permanently. That
// is exactly why a sticky card's ✕ is UNCONDITIONAL: on the Mac hover reveals it, and on the phone nothing
// would.
//
// ⚠️ THE HOST IS ALWAYS MOUNTED AND MUST BE DEAF WHEN EMPTY. It is a full-bleed child of
// ``PhoneOverlayLayerView``, so its own `hitTest` has to pass a touch through the corner's empty space AND
// through the gaps between cards — a `UIStackView` answers with ITSELF for a point in a gap, which would
// silently eat a touch meant for the terminal. Both are refused below; only a card takes a touch.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import UIKit

// MARK: - The corner

@MainActor
final class PhoneToastStackView: UIView {
    /// Jump to the pane a card names (its ``Toast/paneKey``) — injected by the layer, which owns the
    /// store. `nil` leaves cards as inert notices, so this view never needs a `WorkspaceStore`.
    var onJump: ((String) -> Void)?

    private let overlay: OverlayCoordinator
    private let column = UIStackView()
    /// The live cards, keyed by toast id so a re-sync REUSES a card rather than rebuilding it — which is
    /// what lets a running dwell keep running while a second toast arrives beside it. Rebuilding here
    /// would restart a countdown the epoch says should be left alone.
    private var cards: [String: PhoneToastCardView] = [:]
    private var generation = 0

    init(overlay: OverlayCoordinator) {
        self.overlay = overlay
        super.init(frame: .zero)
        backgroundColor = .clear
        column.axis = .vertical
        column.alignment = .trailing
        column.spacing = Slate.Metric.space2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            // Parked in the bottom-trailing corner, inset by the card margin: the stack grows UPWARD from
            // there, newest card flush to the bottom — the corner the eye already goes to. Against the
            // SAFE AREA, so the home indicator never crosses a card the Mac's panel never had to dodge.
            column.trailingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Slate.Metric.space4,
            ),
            column.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Slate.Metric.space4,
            ),
            // A stack of fixed-width cards cannot overflow the screen's top; the inequality is what keeps
            // a deep stack from growing off it on a small phone in landscape.
            column.topAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: Slate.Metric.space4,
            ),
        ])
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ THE CORNER IS DEAF EXCEPT WHERE A CARD IS. `self` answers for the empty screen this view covers
    /// and `column` answers for the gaps BETWEEN cards; both must fall through, or an always-mounted
    /// notification host takes touches away from the terminal it floats over. See the file header.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return (hit === self || hit === column) ? nil : hit
    }

    // MARK: The live read

    /// The one tracked read. ``withObservationTracking(_:onChange:)`` fires ONCE, so the re-arm below IS
    /// the subscription — and every tracked read has to happen INSIDE the closure, or that property
    /// silently stops being followed. `onChange` runs INSIDE the mutation, so the re-arm hops to the next
    /// main-queue turn; the generation counter supersedes an arm left over from an earlier pass.
    private func follow() {
        generation &+= 1
        let generation = generation

        var live: [Toast] = []
        withObservationTracking {
            live = overlay.toasts
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        sync(live)
    }

    /// Reconciles the column against the coordinator's list.
    ///
    /// The diff is BY ID, not by position: the coordinator replaces a same-id toast in place (a pane that
    /// speaks twice), and rebuilding the card there would restart a dwell the epoch says should keep
    /// running.
    private func sync(_ toasts: [Toast]) {
        let alive = Set(toasts.map(\.id))
        for (id, card) in cards where !alive.contains(id) {
            cards[id] = nil
            card.stopDwell()
            retire(card)
        }
        for (index, toast) in toasts.enumerated() {
            let expanded = ToastPresentation.isExpanded(index: index, count: toasts.count)
            if let card = cards[toast.id] {
                card.update(toast: toast, expanded: expanded)
            } else {
                let card = PhoneToastCardView(
                    toast: toast, expanded: expanded,
                    onDismiss: { [overlay] in overlay.dismissToast(toast.id) },
                    onJump: { [weak self] key in self?.onJump?(key) },
                )
                cards[toast.id] = card
                column.addArrangedSubview(card)
                arrive(card)
            }
        }
        // The stack's order is the coordinator's — newest LAST. `insertArrangedSubview` on an
        // already-arranged view MOVES it, so a card that changed rank (the one below it expired) travels
        // rather than being rebuilt, and keeps its dwell.
        for (index, toast) in toasts.enumerated() {
            guard let card = cards[toast.id] else { continue }
            column.insertArrangedSubview(card, at: index)
        }
    }

    // MARK: Arrival and departure

    /// A card enters THROUGH THE TRAILING EDGE — the corner the stack hugs — and fades in with the move.
    private func arrive(_ card: PhoneToastCardView) {
        guard window != nil else { return }
        card.alpha = 0
        card.transform = CGAffineTransform(translationX: Slate.Metric.toastWidth, y: 0)
        let animator = OverlayMotion.animator(Slate.Motion.fadeSlideIn)
        animator.addAnimations {
            card.alpha = 1
            card.transform = .identity
        }
        animator.startAnimation()
    }

    /// And leaves the same way it came. The old SwiftUI removal was opacity-only, so a card in the MIDDLE
    /// of the stack vanished in place and every card above it snapped down; sliding out through the
    /// trailing edge keeps the column coherent while the survivors close the gap.
    ///
    /// The stack's own reflow is animated in the SAME beat, because removing an arranged subview is a
    /// layout change to every sibling — animating only the leaver would let the rest jump around it.
    private func retire(_ card: PhoneToastCardView) {
        guard window != nil else {
            card.removeFromSuperview()
            return
        }
        let animator = OverlayMotion.animator(Slate.Motion.stackReflow)
        animator.addAnimations { [column] in
            card.alpha = 0
            card.transform = CGAffineTransform(translationX: Slate.Metric.toastWidth, y: 0)
            // `isHidden` is what a `UIStackView` reflows on, and it is animatable inside the same
            // transaction — so the survivors travel while the leaver slides out, instead of snapping the
            // instant it is removed from the arranged list.
            card.isHidden = true
            column.layoutIfNeeded()
        }
        animator.addCompletion { _ in
            MainActor.assumeIsolated { card.removeFromSuperview() }
        }
        animator.startAnimation()
    }
}

// MARK: - One card

/// One notification: the mark, the headline, the detail line it may be holding back, and the ✕.
///
/// A ``SlateRowButton`` because the card IS a door — its whole body jumps to the pane it names. A card
/// with nowhere to go is left disabled rather than built as a different type, so a toast that gained or
/// lost its `paneKey` under a same-id replace keeps its identity and its running dwell.
@MainActor
final class PhoneToastCardView: SlateRowButton {
    private var toast: Toast
    private var expanded: Bool
    private let onDismiss: () -> Void

    private let mark = PhoneToastMarkView()
    private let headline = UILabel()
    private let detail = UILabel()
    private let close = UIButton(type: .system)

    /// Dwell CONSUMED, in seconds. Nothing draws it: an earlier round put a depleting hairline along the
    /// bottom edge and it was cut for reading as ornament. It is sampled rather than slept because the
    /// Mac's half FREEZES it under the pointer, and the two halves must spend the same clock.
    private var spent: Double = 0
    private var dwell: Timer?

    init(
        toast: Toast, expanded: Bool,
        onDismiss: @escaping () -> Void,
        onJump: @escaping (String) -> Void,
    ) {
        self.toast = toast
        self.expanded = expanded
        self.onDismiss = onDismiss
        let key = toast.paneKey
        super.init(action: { if let key { onJump(key) } })
        isEnabled = key != nil
        build()
        apply(toast: toast, expanded: expanded)
        restartDwell()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    deinit { dwell?.invalidate() }

    /// ⚠️ THE WHOLE BODY IS THE DOOR, and a `UIControl` only tracks a touch it is itself the hit view for.
    /// Left alone, `super.hitTest` answers with whichever label or nested `UIStackView` the touch landed
    /// on — none of which handles a touch — and the jump would fire only on the card's own padding.
    /// Folding every inert descendant back into `self` is what makes the card behave as the single button
    /// it reads as; the ✕ is the ONE part that keeps its own answer, and it stops being one the moment it
    /// is hidden (see ``apply(toast:expanded:)``), so its reserved slot rejoins the door.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === close ? hit : self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The other half of ``SlatePaperCardSurface``'s contract — without it Core Animation re-reads the
        // whole layer tree's alpha every frame to work out the cast's shape.
        SlatePaperCardSurface.layoutShadow(of: self)
    }

    // MARK: Building

    private func build() {
        SlatePaperCardSurface.apply(to: self)

        // The HEADLINE speaks the event as a sentence-case phrase in the floating family's reading ink —
        // hierarchy by size and weight in ONE voice, like every card title. A subject is usually a command
        // line, whose informative ends are the program and its last argument, so a too-long one loses its
        // MIDDLE rather than its tail.
        headline.translatesAutoresizingMaskIntoConstraints = false
        headline.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        headline.textColor = Slate.Native.Overlay.primary
        headline.numberOfLines = 1
        headline.lineBreakMode = .byTruncatingMiddle
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: Slate.Typeface.base)
        detail.textColor = Slate.Native.Overlay.secondary
        detail.numberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A comfortable square target, sized off the 8pt grid rather than off the glyph so it stays a
        // FINGER target at the headline's type size.
        let target = Slate.Metric.space3 + Slate.Metric.space2
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Slate.Typeface.small, weight: .semibold,
                ),
            ),
            for: .normal,
        )
        close.tintColor = Slate.Native.Overlay.secondary
        close.accessibilityLabel = ToastPresentation.dismissLabel
        close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: target),
            close.heightAnchor.constraint(equalToConstant: target),
        ])

        let headlineRow = UIStackView(arrangedSubviews: [headline, close])
        headlineRow.axis = .horizontal
        headlineRow.alignment = .center
        headlineRow.spacing = Slate.Metric.space2

        let text = UIStackView(arrangedSubviews: [headlineRow, detail])
        text.axis = .vertical
        text.alignment = .fill
        text.spacing = Slate.Metric.space1

        let row = UIStackView(arrangedSubviews: [mark, text])
        row.axis = .horizontal
        // The mark hangs at the TOP of the text block, beside the headline — a disc has no baseline of
        // its own, and centring it against a two-line card would float it beside the detail instead.
        row.alignment = .top
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space3),
            // One UNIFORM column edge. Cards that hug their own content were tried and rendered as a
            // ragged staircase — see ``Slate/Metric/toastWidth``.
            widthAnchor.constraint(equalToConstant: Slate.Metric.toastWidth),
        ])
    }

    // MARK: Content

    /// Re-reads a replaced toast. What restarts the dwell is ``ToastPresentation/dwellKey(_:)``, the same
    /// value the Mac's card compares across its in-place update — keyed on the row's ID it would never
    /// fire (the id is unchanged), and keyed on the epoch ALONE it could not see a card whose
    /// `autoDismiss` changed under it: sticky → timed left the card immortal, timed → sticky dismissed it
    /// on the next tick.
    func update(toast new: Toast, expanded: Bool) {
        let restart = ToastPresentation.dwellKey(new) != ToastPresentation.dwellKey(toast)
        apply(toast: new, expanded: expanded)
        if restart { restartDwell() }
    }

    private func apply(toast: Toast, expanded: Bool) {
        self.toast = toast
        self.expanded = expanded
        headline.text = ToastPresentation.headline(for: toast)
        detail.text = toast.body ?? ""
        mark.show(ToastPresentation.mark(for: toast.flavor))
        // No hover on this platform, permanently — see the file header.
        detail.isHidden = !ToastPresentation.showsBody(toast, expanded: expanded, hovering: false)
        let showsClose = ToastPresentation.showsClose(toast, hovering: false)
        // The ✕ KEEPS ITS SLOT even while invisible: a card that changed width or reflowed its subject
        // when the button came and went would be worse than one that reserves the button's corner.
        // Hidden ⇒ not a target either, so a stray tap in that corner cannot silently kill a card the
        // user never saw a ✕ on.
        close.alpha = showsClose ? 1 : 0
        close.isUserInteractionEnabled = showsClose
        // Said as ONE thing: the card is a single element whose label is what it says and whose hint is
        // where it goes. A card with nowhere to go says nothing extra.
        isAccessibilityElement = true
        accessibilityLabel = headline.text
        accessibilityHint = isEnabled ? ToastPresentation.jumpHint : nil
        accessibilityTraits = isEnabled ? .button : .staticText
        // ⚠️ AN ACCESSIBILITY ELEMENT HIDES ITS OWN SUBTREE, so the ✕ inside this card is unreachable to
        // VoiceOver as a button — it comes back as a CUSTOM ACTION on the card instead. Without this a
        // sticky notification, whose ✕ is its only exit, could not be dismissed at all with the screen
        // reader on.
        accessibilityCustomActions = showsClose
            ? [UIAccessibilityCustomAction(name: ToastPresentation.dismissLabel) { [weak self] _ in
                self?.onDismiss()
                return true
            }]
            : nil
    }

    @objc
    private func dismissTapped() { onDismiss() }

    // MARK: The dwell

    /// Starts (or restarts) the countdown. A sticky card — `autoDismiss == nil` — gets no timer at all,
    /// which is also why its ✕ is unconditional.
    private func restartDwell() {
        stopDwell()
        spent = 0
        let total = ToastPresentation.dwellSeconds(toast)
        guard total > 0 else { return }
        // SAMPLED rather than one timer of `total`, because the sample is what the Mac's hover freezes —
        // and the two halves spend the same clock even though only one of them can pause it.
        dwell = Timer.scheduledTimer(
            withTimeInterval: ToastPresentation.dwellTick, repeats: true,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                spent = Swift.min(total, spent + ToastPresentation.dwellTick)
                guard spent >= total else { return }
                stopDwell()
                onDismiss()
            }
        }
    }

    /// Stops the countdown. Idempotent, and called on removal so no timer outlives its card.
    func stopDwell() {
        dwell?.invalidate()
        dwell = nil
    }
}

// MARK: - The mark

/// The card's one point of colour: the system's enclosed-status idiom — a `*.circle.fill` in hierarchical
/// rendering — drawn as its TWO LAYERS, a `circle.fill` disc under the bare glyph, instead of the fused
/// symbol.
///
/// Composed for CENTRING: the fused `info.circle.fill` sets its serif "i" measurably off the disc's centre,
/// which a 20pt mark makes visible; stacked, each glyph centres on its own bounding box. The flat
/// hand-tinted wash disc this replaces was photographed and read as a sticker laid ON the surface — a
/// symbol-drawn disc participates in the material, and the gradient gives it the dimension the fused
/// symbol had (HIG: symbols, not images, on glass).
@MainActor
final class PhoneToastMarkView: UIView {
    /// The disc — sized off the grid, a shade taller than the headline's cap height.
    private static let discSize = Slate.Metric.space4 + Slate.Metric.space1

    private let disc = UIImageView()
    private let glyph = UIImageView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The enclosure. It is a TEMPLATE image tinted below, not a filled one, so both layers follow the
        // appearance the way every other ink in the family does.
        disc.image = UIImage(
            systemName: "circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.discSize),
        )
        // `footnote`/medium puts the glyph at ~0.55 of the disc — the proportion the fused symbol draws
        // its inner layer at — where a bolder, smaller glyph floated lost.
        for layer in [disc, glyph] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            layer.contentMode = .center
            addSubview(layer)
            NSLayoutConstraint.activate([
                layer.centerXAnchor.constraint(equalTo: centerXAnchor),
                layer.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.discSize),
            heightAnchor.constraint(equalToConstant: Self.discSize),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Draws `mark` — the flavour's bare glyph, in the flavour's rung. The rung → ink map is
    /// ``Slate/Native/toastMarkInk(for:)``'s: the RUNG is decided once, in ``ToastPresentation/mark(for:)``,
    /// and the colour lookup is the one line every renderer calls rather than a table kept twice.
    func show(_ mark: ToastMark) {
        glyph.image = UIImage(
            systemName: mark.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.footnote, weight: .medium,
            ),
        )
        let ink = Slate.Native.toastMarkInk(for: mark.rung)
        glyph.tintColor = ink
        // The disc carries the enclosure layer's share of the hue — matched to what HIERARCHICAL rendering
        // gives the enclosure of the system's own `*.circle.fill`, so a composed mark is
        // indistinguishable from the native idiom. A TINT rather than a fill: a tinted template image
        // re-resolves with the appearance, where a `CGColor` on a layer would not.
        disc.tintColor = ink.slateScalingAlpha(ToastPresentation.discLayerOpacity)
    }
}

// MARK: - Motion

/// One rung of the motion ladder, as the property animator UIKit spends it through.
///
/// `UIView.animate` can carry a rung's DURATION but not its bezier, and the four control points are the
/// whole point of ``SlateCurve`` — so an overlay that animates a view property (a transform, an alpha, a
/// stack reflow) goes through here rather than re-typing the curve or settling for `.curveEaseInOut`.
/// ``PaneFade`` is the LAYER-property twin of this, and the two are not interchangeable: a `CATransaction`
/// reaches implicit layer animations, and a property animator reaches `layoutIfNeeded` and the stack
/// reflows that ride on it.
@MainActor
enum OverlayMotion {
    static func animator(_ curve: SlateCurve) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(
            duration: curve.duration,
            controlPoint1: CGPoint(x: curve.x1, y: curve.y1),
            controlPoint2: CGPoint(x: curve.x2, y: curve.y2),
        )
    }
}
#endif
