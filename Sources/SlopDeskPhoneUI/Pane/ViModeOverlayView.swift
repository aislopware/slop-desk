// ViModeOverlayView — the vi / copy-mode chrome, in UIKit (docs/62, the pane-leaf cluster).
//
// The UIKit halves of the persistent mode badge (with a live repeat-count and an `×` exit) and the `⌘/`
// reference card. Both are DRAWINGS over ``ViKeyHintPresentation`` (`SlopDeskClientCore`), which holds
// the three hint tables, the headings, the pill's wording and the reflow ladder — so the two renderers
// cannot disagree about which keys the card advertises, or about which arrangement a given width affords.
//
// THE PILL RIDES THE EXISTING PURE ENGINE. It reads the OBSERVABLE mirrors
// (``TerminalViewModel/viVisualMode`` / ``viPendingCount``), never the `@ObservationIgnored` `isCopyMode`
// flag the renderer's key path reads — that separation is what keeps the mode chrome off the key
// intercept's hazard, and it survives the port because `withObservationTracking` registers on exactly the
// properties its closure touches. One read, one callback, re-armed after every apply.
//
// THE CARD'S REFLOW IS ARITHMETIC, AND HERE THAT IS THE ONLY REASON IT WORKS AT ALL. The SwiftUI half was
// a `Layout` HANDED a `ProposedViewSize`; UIKit hands a view its own bounds, which is the size it has
// ALREADY taken — so a card that asked its own `bounds.width` which rung it could afford would measure
// the answer it had just given and hug its content forever. The proposal arrives instead as
// ``ViKeyHintBarView/availableWidth``, set by the leaf that mounts the card, which is the same direction
// `sizeThatFits(proposal:)` got it from. Everything below that is
// ``ViKeyHintPresentation/layout(forWidth:gap:columnWidth:)``'s answer and ``ViKeyHintPresentation/groups(for:)``'s
// placement; this file supplies only the MEASUREMENT — how wide one column actually draws. `ViewThatFits`
// has no UIKit equivalent whatsoever, and neither does `Layout`, which is precisely why that ladder was
// pushed to the floor before either renderer needed it.
//
// `Slate.*` tokens only, in their native (`UIColor`/`UIFont`) spelling. No libghostty / Metal /
// VideoToolbox is touched: these are plain layer-backed chips driven by the pane model's observables.
//
// HONESTY (the "nothing is a dead key" rule) lives with the tables, not here: ``ViKeyHintPresentation``
// lists ONLY the keys ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires, and its own test pins it
// there. A card that hand-wrote a row would be advertising a key nothing dispatches.

#if os(iOS)
import SFSafeSymbols // the mode glyph's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // ViKeyHintPresentation — the tables, the wording and the width ladder
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

/// The vi-mode pill — the persistent badge shown in the pane's top-trailing overlay while the pane is in
/// vi / copy-mode: the current MODE label (`VI` for plain scrollback navigation, `VISUAL` / `VISUAL LINE`
/// / `VISUAL BLOCK` in a selection), the LIVE pending repeat-count digits, and an `×` that leaves the
/// mode.
///
/// `onExit` is the SINGLE exit seam — the leaf wires it to ``TerminalViewModel/exitCopyMode()``, which
/// also resets the count, the visual mode and the hint bar, so the `×`, the `Esc`/`q` keys and a
/// programmatic dismiss all converge on one state rather than on three nearly-identical teardowns.
@MainActor
final class ViModePillView: UIView {
    private let model: TerminalViewModel
    private let onExit: () -> Void

    private let row = UIStackView()
    private let glyph = UIImageView()
    private let label = UILabel()
    /// The live repeat-count. Hidden rather than removed when no count is pending — an arranged subview
    /// that is hidden leaves the stack's layout, which is the UIKit spelling of the SwiftUI half's
    /// `if let count`.
    private let count = UILabel()
    /// THE SAME `×` the status chips carry (``PaneStatusPillCloseView``), not a second one: it is the
    /// identical control — ``Slate/Metric/glyphPlate`` square, the selection wash under a press,
    /// ``Slate/Typeface/small`` at `.medium` in the secondary tone — on a chip that floats in the same
    /// corner. A private copy here would be the third spelling of a mark whose whole job is to look like
    /// itself wherever a pane chip shows one.
    private let close: PaneStatusPillCloseView

    /// The last applied reading. Kept so an observation callback that changes nothing repaints nothing —
    /// the mirrors are re-synced after EVERY copy-mode key, including the ones that move a cursor and
    /// leave both of these alone.
    private var mode: TerminalViewModel.VisualMode = .none
    private var pending: Int?
    /// Whether the first paint has happened. It gates BOTH the early-out (the resting reading is `.none` /
    /// `nil`, so an unpainted pill would compare equal to itself and never draw a word) and the animation
    /// (a pill fading its own arrival in reads as a lag, not as a transition).
    private var painted = false
    /// Guards the observation re-arm against a stale `onChange` firing after this pill is gone.
    private var generation = 0

    init(model: TerminalViewModel, onExit: @escaping () -> Void) {
        self.model = model
        self.onExit = onExit
        // `.chrome`, not a bare ink: the shared close plate derives the `×`'s own tone from the plate it
        // sits on (secondary on chrome, white on a vivid fill, where a secondary tone would vanish), and
        // the vi pill's plate is the chrome one. Passing the ink directly would have been the same colour
        // today and a silently wrong one the day this pill goes vivid.
        close = PaneStatusPillCloseView(
            help: ViKeyHintPresentation.exitHelp, fill: .chrome, onPress: onExit,
        )
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Bump the generation so an already-scheduled re-arm drops itself. Called by the leaf when the chip
    /// leaves the column or the pane is torn down.
    func teardown() {
        generation &+= 1
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        // The chip rung lifts the pill off busy terminal output. `masksToBounds` stays false or the cast
        // is clipped away by the very plate casting it.
        layer.masksToBounds = false

        glyph.contentMode = .center
        glyph.isAccessibilityElement = false

        for text in [label, count] {
            text.numberOfLines = 1
            // The mode word and the count are both short fixed strings; a pill narrow enough to truncate
            // `VISUAL BLOCK` would be reporting the mode in a form the user has to guess at. They resist
            // compression instead, so a cramped corner overflows visibly rather than lying — the same
            // bargain the status chips' word makes.
            text.lineBreakMode = .byClipping
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.isAccessibilityElement = false
        }
        // Mono, not just tabular figures: the SwiftUI half asked for `design: .monospaced` AND
        // `.monospacedDigit()`, and a running count that changes width as it passes 9 is the thing both of
        // those exist to prevent.
        count.font = .monospacedSystemFont(ofSize: Slate.Typeface.footnote, weight: .semibold)
        count.textColor = Slate.Native.accent

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space1, leading: Slate.Metric.space2,
            bottom: Slate.Metric.space1, trailing: Slate.Metric.space2,
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(glyph)
        row.addArrangedSubview(label)
        row.addArrangedSubview(count)
        row.addArrangedSubview(close)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A semantic GROUP, for the reason the status chip gives: the copy is read once off the mode word
        // and the `×` stays a button VoiceOver can reach. The label is re-set on every apply — it carries
        // the live count.
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        label.isAccessibilityElement = true
        label.accessibilityHint = ViKeyHintPresentation.exitHelp

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: Self, _: UITraitCollection) in
            pill.paintChrome()
        }
        paintChrome()
    }

    /// The two rungs that are `CGColor`s on a layer, plus the glyph's resolved tint. The FILL is a view
    /// `backgroundColor`, which follows the appearance by itself.
    private func paintChrome() {
        backgroundColor = Slate.Native.Surface.raised
        layer.borderColor = ring().resolvedColor(with: traitCollection).cgColor
        layer.slateShadow(.chip, in: traitCollection)
        glyph.image = UIImage(
            systemName: SFSymbol.characterCursorIbeam.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .semibold,
            ),
        )?.withTintColor(
            Slate.Native.Text.primary.resolvedColor(with: traitCollection),
            renderingMode: .alwaysOriginal,
        )
    }

    // MARK: The live read

    /// Re-read the two observable mirrors and repaint, re-arming for the next change.
    private func follow() {
        generation &+= 1
        let token = generation
        var mode: TerminalViewModel.VisualMode = .none
        var pending: Int?
        withObservationTracking {
            mode = model.viVisualMode
            pending = model.viPendingCount
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.follow()
                }
            }
        }
        apply(mode: mode, pending: pending)
    }

    /// The count appearing and the ring going loud are ONE transaction. Both were
    /// ``Slate/Motion/smallFade`` in the SwiftUI half (two `.animation` modifiers over the same curve),
    /// and running them apart would let a `5v` — a count typed and then a visual mode armed — read as two
    /// separate events when it was one keystroke pair.
    private func apply(mode: TerminalViewModel.VisualMode, pending: Int?) {
        guard !painted || mode != self.mode || pending != self.pending else { return }
        let first = !painted
        painted = true
        self.mode = mode
        self.pending = pending

        let paint = { [self] in
            label.attributedText = NSAttributedString(
                string: mode.pillLabelOrDefault,
                attributes: [
                    .font: UIFont.systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold),
                    .foregroundColor: Slate.Native.Text.primary,
                    .kern: Slate.Typeface.pillTracking,
                ],
            )
            count.text = pending.map { String($0) } ?? ""
            count.isHidden = pending == nil
            label.accessibilityLabel = ViKeyHintPresentation.accessibilityLabel(
                mode: mode, count: pending,
            )
            layer.borderColor = ring().resolvedColor(with: traitCollection).cgColor
            layoutIfNeeded()
        }
        guard !first else {
            paint()
            return
        }
        // `UIView.animate` over the shared curve, not a spring — the ring's colour is a layer property
        // and rides the implicit `CATransaction` this opens, which is the UIKit reading of the Mac's
        // `allowsImplicitAnimation`.
        UIView.animate(
            withDuration: Slate.Motion.smallFade.duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: paint,
        )
    }

    /// The pill's outline — this renderer's two-line ink ladder over
    /// ``TerminalViewModel/VisualMode/isVisual``. Plain navigation wears the same subtle hairline as the
    /// read-only chip; a visual selection swaps in the accent ring so the "I am selecting" state is
    /// unmistakable beside the count.
    ///
    /// The lit rung is ``Slate/Opacity/accentRing`` — the SAME alpha the find bar's ON chip and the Mac's
    /// two spend. All of them were a raw `0.5` until the value went to the floor, and a fourth renderer
    /// re-spelling it is exactly the drift the descent was for: an alpha is frameworkless, so it can be
    /// compared across the framework boundary and a colour table cannot.
    private func ring() -> UIColor {
        mode.isVisual
            ? Slate.Native.accent.slateScalingAlpha(Slate.Opacity.accentRing)
            : Slate.Native.Line.subtle
    }

    /// Belt-and-suspenders Escape dismiss, through the SAME `onExit` seam the `×` fires. Its reach is the
    /// responder chain's — see ``HintModeOverlayView/keyCommands``, which states the one limitation both
    /// pane chips share on this platform.
    override var keyCommands: [UIKeyCommand]? {
        [.slateCancel(action: #selector(cancel))]
    }

    @objc
    private func cancel() { onExit() }
}

// MARK: - The key-hint card

/// The vi key-hint card — the on-demand reference toggled by `⌘/` while in vi mode (off by default;
/// ``TerminalViewModel/showViKeyHints`` drives its visibility, flipped by
/// ``TerminalViewModel/toggleViKeyHints()``). Floats along the pane BOTTOM and lists, in compact columns,
/// the keys slopdesk's copy-mode ACTUALLY wires.
///
/// Pure presentation: no model reads, no state beyond the rung it last settled on — every row comes from
/// ``ViKeyHintPresentation``, and every column is built once in `init` because the tables are constants.
/// That is also what makes the measurement cheap: the three widths are taken once, which is what
/// `Layout.makeCache` did on the other side.
@MainActor
final class ViKeyHintBarView: UIView {
    /// THE PROPOSAL. The width the leaf can spare for the card, INCLUDING this view's own horizontal
    /// padding — the UIKit stand-in for the `ProposedViewSize` a `Layout` was handed.
    ///
    /// It defaults to infinity for the same reason `sizeThatFits` read an UNSPECIFIED width as infinite:
    /// an un-proposed card reports its widest arrangement, which is what makes a parent that has room give
    /// it room. A mounter that never sets this gets the three-column card, which is the right answer for
    /// every pane wide enough to hold it and a visibly-too-wide one otherwise — never a silently clipped
    /// card.
    var availableWidth: CGFloat = .infinity {
        didSet {
            guard availableWidth != oldValue else { return }
            applyLadder()
        }
    }

    /// Between two side-by-side column slots.
    private static let gap = Slate.Metric.space4
    /// Between two columns stacked into one slot.
    private static let stackSpacing = Slate.Metric.space3

    private let slots = UIStackView()
    private let columns: [ViKeyHintColumn: ViKeyHintColumnView]
    /// Each column's INTRINSIC width, measured once. The tables are constants, so this cannot go stale —
    /// and re-measuring inside `layoutSubviews` would ask a column that is currently sitting in a
    /// stretched slot how wide it wants to be, which is a different question.
    private let columnWidths: [ViKeyHintColumn: CGFloat]
    private var rung: ViKeyHintLayout?

    /// Every key chip the card advertises — the honesty surface, forwarded so a test and the snapshot rig
    /// keep ONE address for it across both renderers.
    static var advertisedKeys: [String] { ViKeyHintPresentation.advertisedKeys }

    init() {
        var built: [ViKeyHintColumn: ViKeyHintColumnView] = [:]
        var widths: [ViKeyHintColumn: CGFloat] = [:]
        for column in ViKeyHintColumn.allCases {
            let view = ViKeyHintColumnView(column: column)
            built[column] = view
            // The minimum size the column's own constraints admit — the widest row, its chips, its gaps
            // and its label together. That is exactly what `sizeThatFits(.unspecified)` returned on the
            // other side, and what the ladder's `columnWidth` closure is defined to mean.
            widths[column] = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }
        columns = built
        columnWidths = widths
        super.init(frame: .zero)
        build()
        applyLadder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        layer.masksToBounds = false

        slots.axis = .horizontal
        // TOP, not centre: the rung that stacks SELECT over SEARCH beside MOTION only reads as two columns
        // of one card if all three headings share a baseline.
        slots.alignment = .top
        slots.spacing = Self.gap
        slots.isLayoutMarginsRelativeArrangement = true
        slots.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space2, leading: Slate.Metric.space3,
            bottom: Slate.Metric.space2, trailing: Slate.Metric.space3,
        )
        slots.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slots)
        NSLayoutConstraint.activate([
            slots.leadingAnchor.constraint(equalTo: leadingAnchor),
            slots.trailingAnchor.constraint(equalTo: trailingAnchor),
            slots.topAnchor.constraint(equalTo: topAnchor),
            slots.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = ViKeyHintPresentation.barAccessibilityLabel

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: Self, _: UITraitCollection) in
            card.paintChrome()
        }
        paintChrome()
    }

    private func paintChrome() {
        backgroundColor = Slate.Native.Surface.raised
        layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
        // The PANEL rung, not the chip's: this is a floating reference card, the same depth the find bar
        // sits at, and it covers terminal output rather than perching on it.
        layer.slateShadow(.panel, in: traitCollection)
    }

    // MARK: The width ladder

    /// Ask the ladder what the proposal affords and re-hang the columns if the answer changed.
    ///
    /// ⚠️ Measured against the width left INSIDE the card's own padding, not the proposal itself. The
    /// padding is a fixed cost at both ends, and a ladder that spent the whole proposal would keep three
    /// columns at a width that fits three columns and nothing else — which is a card whose last column is
    /// cut off by its own edge inset.
    private func applyLadder() {
        let inner = Double(availableWidth) - Double(Slate.Metric.space3) * 2
        apply(ViKeyHintPresentation.layout(
            forWidth: inner, gap: Double(Self.gap),
            columnWidth: { [columnWidths] column in Double(columnWidths[column] ?? 0) },
        ))
    }

    /// Hang the three columns in the slots the rung names.
    ///
    /// The COLUMN VIEWS are never rebuilt — only re-parented. A rung change is a re-flow, not a content
    /// change, and rebuilding would throw away the measured widths this whole ladder runs on.
    private func apply(_ next: ViKeyHintLayout) {
        guard next != rung else { return }
        rung = next
        for slot in slots.arrangedSubviews {
            slots.removeArrangedSubview(slot)
            slot.removeFromSuperview()
        }
        for group in ViKeyHintPresentation.groups(for: next) {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = Self.stackSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false
            for column in group {
                guard let view = columns[column] else { continue }
                stack.addArrangedSubview(view)
            }
            slots.addArrangedSubview(stack)
        }
    }
}

// MARK: - One labelled column

/// One labelled column of hints: the caps heading, then its rows.
///
/// Built once from ``ViKeyHintColumn`` and never mutated — which is what lets ``ViKeyHintBarView`` measure
/// it a single time and re-hang it across rungs without re-deriving anything.
@MainActor
private final class ViKeyHintColumnView: UIView {
    init(column: ViKeyHintColumn) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space1
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The heading rides the PILL family — the system face at ``Slate/Typeface/pillTracking``, the same
        // tracking the mode badge above it wears — because the card floats inside the pane beside it and
        // not on a paper surface. The instrument voice at ``Slate/Typeface/instrumentTracking`` is what a
        // SUMMONED card names a region in, and this card is not summoned; it is toggled in place.
        let heading = UILabel()
        heading.attributedText = NSAttributedString(
            string: column.heading,
            attributes: [
                .font: UIFont.systemFont(ofSize: Slate.Typeface.small, weight: .semibold),
                .foregroundColor: Slate.Native.Text.tertiary,
                .kern: Slate.Typeface.pillTracking,
            ],
        )
        heading.isAccessibilityElement = false
        stack.addArrangedSubview(heading)
        // The stack's own row rhythm PLUS the heading's bottom pad — `space1` twice, added, which is what
        // the SwiftUI half spelled as a `VStack(spacing: space1)` with a `.padding(.bottom, space1)` on the
        // heading. Deliberately not written as `space2`: it is two rungs summed, not one rung chosen, and
        // it must follow `space1` if that ever moves.
        stack.setCustomSpacing(Slate.Metric.space1 * 2, after: heading)

        for hint in column.hints { stack.addArrangedSubview(Self.row(hint)) }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// One hint row — the key chip(s) followed by the description.
    private static func row(_ hint: ViKeyHint) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Slate.Metric.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        for key in hint.keys { stack.addArrangedSubview(keycap(key)) }

        let label = UILabel()
        label.text = hint.label
        label.font = .systemFont(ofSize: Slate.Typeface.small)
        label.textColor = Slate.Native.Text.secondary
        label.numberOfLines = 1
        // The SwiftUI half's `.fixedSize()`, which is what makes the measured column width HONEST: a row
        // that could compress would report a narrower intrinsic width than it draws at, and the ladder
        // would then pick a rung the card does not actually fit in.
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(label)
        return stack
    }

    /// A single key chip. The RANGE token (``ViKeyHintPresentation/separator``) renders as bare text with
    /// no plate, so `1 … 9` reads as a range rather than as three keys — the one row where a member of a
    /// `keys` array is not a key.
    private static func keycap(_ key: String) -> UIView {
        guard key == ViKeyHintPresentation.separator else { return ViKeycapView(key: key) }
        let text = UILabel()
        text.text = key
        text.font = .systemFont(ofSize: Slate.Typeface.small, weight: .medium)
        text.textColor = Slate.Native.Text.tertiary
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        return text
    }
}

// MARK: - One key chip

/// A single key chip on the vi card.
///
/// ⚠️ NOT ``SlateKeycapView``, which is the same shape in a different INK FAMILY. That cap wears
/// `Overlay.plate` / `Overlay.hairline` — the neutral alphas over the platform label colour that resolve
/// against whichever polarity a SUMMONED card stands in (the cheat sheet, the palette). This one stands on
/// the chrome's own `Surface.raised` inside a pane, over live terminal output, so it takes the chrome
/// ladder — the same distinction the Mac's find bar draws between its query well and the global-search
/// one. Merging the two would mean picking one family for both surfaces, which is a design change and not
/// a refactor.
@MainActor
private final class ViKeycapView: UILabel {
    /// ⚠️ 18 is UNNAMED on the floor — the keycap's minimum square, one rung under the control plate
    /// (``Slate/Metric/plate`` is 24) and one above the glyph plate (16). It is the SECOND spelling: the
    /// Mac half carries the same literal with the same ⚠️. Proposed `Slate.Metric.keycap`.
    private static let side: CGFloat = 18

    init(key: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The SYSTEM mono face, not ``Slate/Typeface/instrumentNative(_:weight:)``: the instrument voice is
        // the terminal's own JetBrains face, and a keycap is chrome standing beside a description in the
        // system face — printing it in the pane's own family would make the card read as terminal OUTPUT
        // rather than as a legend.
        text = key
        font = .monospacedSystemFont(ofSize: Slate.Typeface.small, weight: .medium)
        textColor = Slate.Native.Text.secondary
        textAlignment = .center
        isAccessibilityElement = false
        backgroundColor = Slate.Native.Surface.face
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cap: Self, _: UITraitCollection) in
            cap.reink()
        }
        reink()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A MINIMUM square with the label centred in it, not a fixed one: `⌃d` and `↩` are wider than `h`,
    /// and a chip clipped to 18pt would drop half of the two-character keys the card exists to advertise.
    /// The chip hugs whichever of the two is larger — which is what an `intrinsicContentSize` maximum
    /// says, where the Mac spells the same rule as two `greaterThanOrEqualTo` constraints.
    override var intrinsicContentSize: CGSize {
        let text = super.intrinsicContentSize
        return CGSize(
            width: Swift.max(Self.side, text.width + Slate.Metric.space1 * 2),
            height: Swift.max(Self.side, text.height),
        )
    }

    private func reink() {
        layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
