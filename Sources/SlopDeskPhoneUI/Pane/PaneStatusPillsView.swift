// PaneStatusPillsView — the pane's status chips, in UIKit (docs/62, the pane-leaf cluster).
//
// ONE view over ``PaneStatusPill`` (`SlopDeskClientCore`), which says what each chip is CALLED, what
// VoiceOver reads, whether it carries an `×` and what kind of plate it stands on — `🔒 READ ONLY ×`,
// `🛡 SECURE INPUT`, `⚠ SYNC INPUT ×`.
//
// WHICH chips are up, and in what order, is ``PaneStatusPillPresentation/visible(_:)``'s — not this
// file's and not the leaf's. This view draws ONE chip; the top-trailing column that stacks them (with the
// vi-mode pill above and the find bar below) belongs to ``TerminalLeafView``, and the video leaf mounts a
// single `.readOnly` chip rather than a column at all, which is why there is no column type here.
//
// The design reference mock places these in a window TITLEBAR's top-right corner
// (`docs/ui-shell/screenshots/readonly-mode.png` and, later, `secure-input.png`). slopdesk has NO
// titlebar on either platform — on the phone there is not even a window to have one — so the EQUIVALENT
// placement is the pane's top-trailing overlay region (the same place the ⌘F find bar floats).
//
// ⚠️ THE SIX LADDERS ARE ONE VALUE NOW. Both halves this replaces resolved `pill.fill` six separate
// times — plate, hairline width, ink, close ink, glyph weight, label weight — each a two-case `switch`
// standing alone, which is six chances for a seventh chip's rung to be added to five of them. docs/62
// §2.1 names that as a cleanup the port should take, and ``Appearance`` is it: one `switch`, resolved
// once at init, and a new fill kind fails to compile until every rung answers for it.
//
// `Slate.*` tokens ONLY, in their native (`UIColor`/`UIFont`) spelling. The MARK is
// ``Slate/PaneStatusPillArt``'s rather than a table on this side of the framework boundary: a fourth pill
// added below has to reach BOTH renderers, and a table either renderer owns is one the other cannot see.
//
// NO TRACKING AREA, AND THAT IS THE WHOLE OF THE `×`'s PLATFORM DIFFERENCE. AppKit needs an
// `NSTrackingArea` to know the pointer is over the mark; UIKit has `UIHoverGestureRecognizer`, which is a
// gesture on the view and dies with it — so the Mac's ⚠️ about a stale hover firing under an alpha-0 tab
// (docs/56 risk 3) has no counterpart here. What the phone has instead is a FINGER, so the press rung
// (`isHighlighted`) is the one that actually fires on a touch device and the hover rung is the iPad's.

#if os(iOS)
import SFSafeSymbols // the mark's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // PaneStatusPill / PaneStatusPillFill / PaneStatusPillInk — decided below
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceModel
import UIKit

/// One pane status chip.
///
/// Faithful to `readonly-mode.png` and `secure-input.png`: the read-only chip is compact and SUBTLY
/// FILLED (it blends with the chrome rather than standing out) with a solid padlock and a primary-tone
/// label, then a LIGHTER `×`; the two mode chips are VIVID FILLED plates carrying a white glyph and a
/// white label, with no `×` on secure input.
///
/// `onDismiss` fires from the `×` and is ignored by a chip that has none. The leaf routes it: read-only
/// to ``TerminalViewModel/exitReadOnly()`` (whose `onReadOnlyChanged` hook converges the store's
/// `paneReadOnly` set, so the `×`, the palette term and the sidebar lock all land on one state) and sync
/// input to ``WorkspaceStore/disarmSyncInput(for:)`` (which disarms the WHOLE tab, so the chip leaves
/// every sibling at once).
@MainActor
final class PaneStatusPillView: UIView {
    /// The chip this view draws. `let`: a chip whose state changed is a different chip, and the column
    /// that mounts them keys on the pill — so nothing ever needs to mutate one in place.
    let pill: PaneStatusPill

    private let appearance: Appearance
    private let row = UIStackView()
    private let glyph = UIImageView()
    private let label = UILabel()
    /// Present exactly when ``PaneStatusPill/dismissHelp`` is — the pill answers whether the mode is one
    /// the user turns off from HERE, and secure input is deliberately not (see that property).
    private let close: PaneStatusPillCloseView?

    init(pill: PaneStatusPill, onDismiss: @escaping () -> Void = {}) {
        // Everything below is built from LOCALS and only then stored: a class initialiser may not read
        // its own `self` before `super.init`, so the `×` cannot be handed its ink off the property.
        let appearance = Appearance(fill: pill.fill)
        self.pill = pill
        self.appearance = appearance
        close = pill.dismissHelp.map { help in
            PaneStatusPillCloseView(help: help, fill: pill.fill, onPress: onDismiss)
        }
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        // A small shadow lifts the chip off busy terminal output for legibility. `masksToBounds` stays
        // false or the cast is clipped away by the very plate casting it.
        layer.masksToBounds = false
        layer.borderWidth = appearance.hairlineWidth

        glyph.contentMode = .center
        label.numberOfLines = 1
        // The word is a fixed caps constant, never elided: a chip that truncated to `SECURE INP…` would
        // be reporting a security state in a form the user has to guess at. It resists compression
        // instead, so a column too narrow for it overflows visibly rather than lying.
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The chip reads as ONE element carrying the shared copy, and the WORD is the element that
        // carries it — the glyph and the word are two spellings of the same fact, and VoiceOver reading
        // both would say it twice.
        glyph.isAccessibilityElement = false
        label.isAccessibilityElement = true
        label.accessibilityLabel = pill.accessibilityLabel
        label.accessibilityHint = pill.accessibilityHint

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space1, leading: Slate.Metric.space2,
            bottom: Slate.Metric.space1, trailing: Slate.Metric.space2,
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isUserInteractionEnabled = true
        row.addArrangedSubview(glyph)
        row.addArrangedSubview(label)
        if let close { row.addArrangedSubview(close) }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A semantic GROUP, not a combined element, and the difference is the `×`. SwiftUI's `.combine`
        // folded a child button's action into one element; UIKit has no equivalent that keeps the dismiss
        // operable, so the chip is a group whose word carries the copy and whose `×` stays a button — the
        // copy is read once, and the one thing on the chip you can DO is still reachable by VoiceOver.
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup

        // ⚠️ Two rungs are `CGColor`s on a layer, which are RESOLVED and not dynamic — they were frozen
        // at the appearance current when they were assigned. The registration names the ONE trait they
        // depend on rather than waking on every trait change; `traitCollectionDidChange` is deprecated at
        // this deployment target and is banned in this target.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (chip: Self, _: UITraitCollection) in
            chip.paint()
        }
        paint()
    }

    private func paint() {
        // The FILL and the LABEL ink stay `UIColor`s on views, which follow the appearance themselves;
        // only the border and the cast are layer colours and have to be re-resolved.
        backgroundColor = appearance.plate
        layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
        layer.slateShadow(.chip, in: traitCollection)

        glyph.image = UIImage(
            systemName: pill.symbol.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: appearance.glyphWeight,
            ),
        )?.withTintColor(
            appearance.ink.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal,
        )
        label.attributedText = NSAttributedString(
            string: pill.label,
            attributes: [
                // The SYSTEM face, not the instrument one: this is a status word in the chrome's own
                // voice, not a readout of anything the terminal printed.
                .font: UIFont.systemFont(ofSize: Slate.Typeface.footnote, weight: appearance.labelWeight),
                .foregroundColor: appearance.ink,
                // The pill/badge rung of the caps tracking ladder — measured off the system secure-input
                // pill's own small-caps spacing, and applied ONLY to an all-caps label.
                .kern: Slate.Typeface.pillTracking,
            ],
        )
    }

}

// MARK: - This renderer's ink ladder, as ONE value

/// Everything the chip's plate kind decides, resolved once.
///
/// The two vivid tones are ``Slate/Native/paneStatusPillFill(_:)``'s — theme-INDEPENDENT on purpose
/// (the shipped themes have `info == accent`, so a palette-derived security badge would be invisible
/// against the accent — `secure-input.png` is the green-accent Paper theme yet the pill is the same
/// royal blue), and only a NAME can say that, which is why ``PaneStatusPillFill`` is a kind rather
/// than a colour in the first place.
private struct Appearance {
    /// The chip's plate.
    let plate: UIColor
    /// A chrome plate is DELINEATED by a hairline (it is only a shade off the chrome behind it); a
    /// vivid plate is not (the fill already is the boundary, and a border would only muddy it). A
    /// WIDTH of zero rather than a clear border colour, because `borderWidth` is the property that
    /// actually decides whether anything is drawn.
    let hairlineWidth: CGFloat
    /// Label and glyph ink: the theme's primary tone on the chrome plate, white on a vivid one.
    ///
    /// White is reached as `SlateNativeColor.white` and not through a token, which is deliberate:
    /// ``Slate/Native`` leaves `Text/onAccent` out on purpose — it is pinned white in every
    /// appearance, so it is not a colour the platform has an opinion about.
    let ink: UIColor
    /// The `×` glyph's own ink: LIGHTER than the label on the chrome plate (per the screenshot), but
    /// full white on a vivid one, where a secondary tone would vanish.
    let closeInk: UIColor
    /// A vivid chip carries more weight than a chrome one — it is louder on purpose.
    let glyphWeight: UIFont.Weight
    let labelWeight: UIFont.Weight

    init(fill: PaneStatusPillFill) {
        switch fill {
        case .chrome:
            plate = Slate.Native.Surface.raised
            hairlineWidth = Slate.Metric.hairline
            ink = Slate.Native.Text.primary
            closeInk = Slate.Native.Text.secondary
            glyphWeight = .semibold
            labelWeight = .medium
        case let .fixed(tone):
            plate = Slate.Native.paneStatusPillFill(tone)
            hairlineWidth = 0
            ink = SlateNativeColor.white
            closeInk = SlateNativeColor.white
            glyphWeight = .bold
            labelWeight = .semibold
        }
    }
}

// MARK: - The × plate

/// The `×` close glyph, with the tab row's subtle plate under a pointer or a finger.
///
/// A `UIControl` rather than a `UIButton`: a button's image machinery dims its content on highlight,
/// which would fight the plate fill that IS this control's press feedback — two answers to one press, one
/// of them the framework's default rather than this app's. That is ``SlatePlateVerbButton``'s ⚠️, and it
/// applies to a control this small more sharply, not less.
///
/// It is NOT ``SlatePlateVerbButton`` itself, and the reason is the ink: that control's tint is a chrome
/// rung, where this glyph's is decided by the PLATE it stands on and is white on a vivid one. Handing it
/// a tint would work today and would silently stop tracking the day a fourth pill kind lands, because the
/// rule that picks the tint would then live at the call site instead of beside the plate it is about.
@MainActor
final class PaneStatusPillCloseView: UIControl {
    /// The glyph's ink, decided by the plate this `×` stands on and fixed for the chip's life. The
    /// `UIColor` is dynamic; only which ROLE was chosen is frozen here.
    private let ink: UIColor
    private let glyph = UIImageView()
    private let onPress: () -> Void

    /// The pointer is over the plate. iPadOS with a trackpad has hover exactly as the Mac does; a
    /// touch-only device never sets it, and the plate then reads press-only.
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

    /// Takes the FILL rather than a colour: the rule below is about the plate this glyph stands on, and
    /// ``Appearance`` is where every rung that plate decides already lives. Passing the ink directly
    /// would be the same colour today and a silently wrong one the day a chip goes vivid.
    init(help: String, fill: PaneStatusPillFill, onPress: @escaping () -> Void) {
        ink = Appearance(fill: fill).closeInk
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous

        glyph.contentMode = .center
        glyph.isAccessibilityElement = false
        glyph.isUserInteractionEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            // The plate is a RUNG (``Slate/Metric/glyphPlate``), not a literal — it was one while three
            // chips in this directory each spelled it.
            widthAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            heightAnchor.constraint(equalToConstant: Slate.Metric.glyphPlate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        // `.touchUpInside`, so the verb fires on the RELEASE and only inside the plate — a press dragged
        // off it is a cancelled tap, which is the contract every control on this platform keeps. It
        // matters more here than on a toolbar plate: what this one cancels is a MODE (a lock, a whole
        // tab's mirrored input), and an accidental dismiss is not something the chip can offer to undo.
        addTarget(self, action: #selector(fire), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button
        // The help IS the label: `dismissHelp` is already a verb phrase naming what the tap does
        // ("Disable read-only"), which is what a button element is supposed to announce.
        accessibilityLabel = help
        slateHelp(help)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (mark: Self, _: UITraitCollection) in
            mark.repaint(animated: false)
        }
        repaint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The `×`'s hit area is ``Slate/Metric/glyphPlate`` — 16pt, which is UNDER the 44pt the HIG asks of
    /// a touch target and is deliberate: a chip is a READOUT that happens to be dismissible, and growing
    /// its mark to a thumb would make the mark bigger than the word beside it. What compensates is that
    /// every mode this chip reports has a second exit that is not a tap at all (Esc, the palette, the
    /// pane menu) — so a missed tap costs a retry, never the only way out.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Slate.Metric.space1, dy: -Slate.Metric.space1).contains(point)
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began, .changed: hovering = true
        default: hovering = false
        }
    }

    @objc
    private func fire() { onPress() }

    /// The plate FADES in rather than snapping. ``Slate/Motion/smallFade`` names this exact use ("the
    /// hover plate"), and it is the rung every other plate in the UIKit chrome spends
    /// (``SlatePlateVerbButton``) — a `×` that popped would be the one control on screen that does.
    private func fade() { repaint(animated: true) }

    private func repaint(animated: Bool) {
        // The SELECTION wash, not the hover fill, for a press: this is the same plate the tab row's own
        // `×` grows, and the two are compared by anyone who closes a tab and then dismisses a chip.
        let fill: UIColor = if isHighlighted {
            Slate.Native.State.selected
        } else if hovering {
            Slate.Native.State.hover
        } else {
            .clear
        }
        let resolved = fill.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = resolved
        CATransaction.commit()

        glyph.image = UIImage(
            systemName: SFSymbol.xmark.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .medium,
            ),
        )?.withTintColor(ink.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
    }
}
#endif
