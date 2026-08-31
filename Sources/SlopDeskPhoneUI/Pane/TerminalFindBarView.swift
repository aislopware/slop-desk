// TerminalFindBarView — the in-pane ⌘F find overlay, in UIKit (docs/62, the pane-leaf cluster).
//
// A THIN renderer over two shared values: the driver ``TerminalFindBarModel`` (`SlopDeskClientCore`),
// which owns every match / nav / toggle mutation, and ``FindBarPresentation`` / ``FindBarMetrics``, which
// own every word and every measurement. This file is the DRAWING and nothing else — the model left for
// `SlopDeskClientCore` precisely so a hand-written find bar could READ the words and the numbers rather
// than agree with them.
//
// The behaviour the model owns, in one line each, so this file can be read without opening it: the
// counter counts the `scrollbackLines()` snapshot taken on open while the surface owns the live
// highlight (a documented divergence); regex / whole-word / case-sensitive modes are ROW-DRIVEN because
// the surface's matcher is a literal, case-insensitive substring scan; literal mode arms `search:` and
// steps `navigate_search:`. The full argument is in the model's header.
//
// Anatomy matches `find.png` (top-trailing of the focused pane, floating card, `Slate.*` tokens ONLY):
//   [ query field ][ Aa case pill ][ ab whole-word pill ][ .* regex pill ][ N of M ][ ∧ prev ][ ∨ next ]
//   [ ▣ search-all-tabs ][ × close ]
// (`rectangle.stack` "search all tabs" escalates to cross-tab Global Search ⇧⌘F.)
//
// ## The rung, and why it is asked for by name
//
// A FINGER drives this bar, so the rung is ``FindBarMetrics/touch``, unconditionally. The Mac's half asks
// for ``FindBarMetrics/pointer`` in the same one line. What these are is a TOUCH TARGET rather than "the
// iOS size" — the distinction docs/56 §3 asks for — and both rungs sit side by side on the floor,
// reviewable against each other instead of one per renderer.
//
// ↩ / ⇧↩ and ⌘G / ⇧⌘G need a hardware keyboard; the in-bar ∧ / ∨ chevrons are the touch path to the SAME
// two verbs, which is why no extra affordance is owed for the chords.
//
// ## Two things this port did NOT respell, and one that dissolved
//
// THE MODE CHIPS ARE ``FindTogglePill``, and the name is load-bearing: the global-search surface mounts
// the EXACT same control, and `slopdesk-invariants` pins ``FindTogglePillAppearance`` as a pair between
// the two bars. A second chip drawing would satisfy every gate in the repo and still be the drift the
// lock exists to forbid, because nothing compares one file's hover plate with another's.
//
// THE PLATES ARE ``SlatePlateVerbButton`` — the design system's own hover/press plate, handed this bar's
// rung rather than defaulted, because its defaults are the chrome ladder's numbers and not this bar's
// reading of them.
//
// AND THE KEY VALUE DISSOLVED. The Mac half carries a ``MacFindBarKey`` enum whose whole reason for
// existing is that AppKit delivers ↩ and ⇧↩ through the SAME `doCommandBySelector:` door, so a `.shift`
// guard is the only thing stopping "next" and "previous" double-firing off one press. UIKit routes them
// through two DIFFERENT doors — ↩ is `textFieldShouldReturn`, ⇧↩ is a published `UIKeyCommand` — so the
// guard is structural here and a value that re-stated it would be a value with nothing to decide.
//
// Hang-safety: NO `TerminalSurface` / VideoToolbox / Metal is touched here — the bar only calls the model
// seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a headless surface.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

/// The find bar strip. Owns only its widgets and the focus it asserts — every match / nav / toggle
/// mutation routes through ``TerminalFindBarModel`` so this half and the Mac's stay byte-for-byte.
@MainActor
final class TerminalFindBarView: UIView, UITextFieldDelegate {
    private let model: TerminalFindBarModel

    /// A FINGER drives this bar. See the file header — the rung is asked for by name, never by `#if`.
    private let rung: FindBarRung

    private let field: UITextField
    private let well: FindQueryWellView
    private let pills: [FindModePill: FindTogglePill]
    private let counter = UILabel()
    /// The counter's own horizontal air, as a container. Padding the LABEL would survive it being hidden
    /// and leave a widened gap where the counter used to be, which is the one state the bar spends most
    /// of its life in (an empty query prints no counter at all).
    private let counterBox = UIStackView()
    private let row = UIStackView()

    private let previous: SlatePlateVerbButton
    /// ⚠️ `nextMatch`, NOT `next`: `UIResponder` vends a `next` of its own, so a stored property under
    /// that name is an attempted override and does not compile. The Mac half keeps the short name —
    /// `NSResponder` spells its chain `nextResponder` — which is a genuine framework divergence rather
    /// than a style choice.
    private let nextMatch: SlatePlateVerbButton
    private let allTabs: SlatePlateVerbButton
    private let dismiss: SlatePlateVerbButton

    /// The last ``TerminalFindBarModel/focusToken`` this bar acted on. Re-asserting first responder on
    /// every observation pass would tear down and rebuild the field's editing session on each keystroke,
    /// which drops the selection and any in-flight IME composition — so the token is compared, never just
    /// read.
    private var focusToken: Int

    /// The live following. Stored for ``teardown()`` alone — the bar can leave the chip column and stay
    /// retained for a beat, which is the one case ``ObservationFollow/stop()`` exists for.
    private var barFollow: ObservationFollow?

    init(model: TerminalFindBarModel) {
        // Everything below is built from LOCALS and only then stored: a class initialiser may not read its
        // own `self` before `super.init`, so the well cannot be handed the field off a property.
        let rung = FindBarMetrics.touch
        let field = UITextField()
        self.model = model
        self.rung = rung
        self.field = field
        well = FindQueryWellView(field: field)
        pills = Dictionary(
            uniqueKeysWithValues: FindModePill.inPaneFindBar
                .map { ($0, FindTogglePill($0, plate: CGFloat(rung.plate))) },
        )
        // The four trailing plates stand on this bar's rung, handed over rather than defaulted —
        // ``SlatePlateVerbButton``'s own defaults are the chrome ladder's, which agree with the POINTER
        // rung and are not the same decision.
        previous = Self.plate(.chevronUp, help: FindBarPresentation.previousMatchHelp, rung: rung)
        nextMatch = Self.plate(.chevronDown, help: FindBarPresentation.nextMatchHelp, rung: rung)
        allTabs = Self.plate(.rectangleStack, help: FindBarPresentation.searchAllTabsHelp, rung: rung)
        dismiss = Self.plate(.xmark, help: FindBarPresentation.closeHelp, rung: rung)
        focusToken = model.focusToken
        super.init(frame: .zero)
        buildField(field)
        buildRow()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// End the following, so a wake already in flight cannot re-arm against a model this bar has
    /// finished with. Called by the leaf when the bar leaves the chip column.
    func teardown() {
        barFollow?.stop()
        barFollow = nil
    }

    // MARK: Building

    private func buildField(_ field: UITextField) {
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Text.primary
        field.attributedPlaceholder = NSAttributedString(
            string: FindBarPresentation.placeholder,
            attributes: [.foregroundColor: Slate.Native.Text.tertiary],
        )
        // The active caret is the accent colour. On the Mac this has to be set on the shared field editor
        // once the field is focused; here it is a plain property of the field, which is one of the two
        // focus hops docs/62 §3.5 says delete.
        field.tintColor = Slate.Native.accent
        // A query is a needle, not prose: no autocapitalisation, no autocorrection, no smart quotes — a
        // "helpfully" curled apostrophe would search for a character the buffer does not contain.
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .search
        // A fixed-width field (see ``FindBarRung/fieldWidth``) scrolls a longer query rather than clipping
        // it — `UITextField` does that by itself, where the Mac has to ask its cell for it.
        field.delegate = self
        field.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        well.addSubview(field)
        NSLayoutConstraint.activate(DecorationFindWell.constraints(
            in: well, field: field, width: CGFloat(rung.fieldWidth),
        ))
    }

    private func buildRow() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        // `find.png`: the card is delineated by FILL + drop SHADOW only — NO hairline stroke around the
        // CARD (verified by pixel-scanning: the pane→shadow gradient runs straight into the card fill).
        // Only the mode chips keep their own hairline outlines, and the query line keeps its own inner
        // one. `masksToBounds` stays false or the cast is clipped away by the plate casting it.
        layer.masksToBounds = false

        counter.font = .monospacedDigitSystemFont(
            ofSize: Slate.Typeface.footnote, weight: .regular,
        )
        counter.textColor = Slate.Native.Text.secondary
        counter.numberOfLines = 1
        // Never truncated and never wrapped: `N of M` is the one label in the bar whose whole content is
        // the information, and a `1 of 1…` reads as a different number.
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        counterBox.axis = .horizontal
        counterBox.isLayoutMarginsRelativeArrangement = true
        counterBox.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Slate.Metric.space1, bottom: 0, trailing: Slate.Metric.space1,
        )
        counterBox.addArrangedSubview(counter)

        // A TRANSPARENT tray: the chips delineate themselves, so the container only spaces them. The same
        // shape the global-search bar builds around the same pills — which is the locked invariant, not a
        // coincidence.
        let tray = UIStackView()
        tray.axis = .horizontal
        tray.spacing = Slate.Metric.space1
        for mode in FindModePill.inPaneFindBar {
            guard let pill = pills[mode] else { continue }
            pill.onToggle = { [weak self] in
                guard let self else { return }
                DecorationFindBarRead.toggle(mode, in: model)
            }
            tray.addArrangedSubview(pill)
        }

        previous.addAction(UIAction { [weak self] _ in self?.model.previous() }, for: .primaryActionTriggered)
        nextMatch.addAction(UIAction { [weak self] _ in self?.model.next() }, for: .primaryActionTriggered)
        // Escalates the in-pane find to cross-tab Global Search (⇧⌘F), seeded with the current query.
        // Wired through ``TerminalFindBarModel/searchAllTabs()`` → ``OverlayCoordinator/openGlobalSearch``.
        allTabs.addAction(UIAction { [weak self] _ in self?.model.searchAllTabs() }, for: .primaryActionTriggered)
        dismiss.addAction(UIAction { [weak self] _ in self?.model.close() }, for: .primaryActionTriggered)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space1, leading: Slate.Metric.space2,
            bottom: Slate.Metric.space1, trailing: Slate.Metric.space2,
        )
        for part in [well, tray, counterBox, previous, nextMatch, allTabs, dismiss] as [UIView] {
            row.addArrangedSubview(part)
        }
        addSubview(row)
        NSLayoutConstraint.activate(row.slateEdges(of: self))

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: Self, _: UITraitCollection) in
            bar.paintChrome()
        }
        paintChrome()
    }

    /// One trailing plate, standing on the bar's rung. The word it says is ``FindBarPresentation``'s in
    /// every case — a help string spelled here would be the third surface disagreeing about what `∧` does
    /// — and ``SlatePlateVerbButton/help`` is the tooltip AND the accessible name, so one assignment
    /// covers both.
    private static func plate(
        _ symbol: SFSymbol, help: String, rung: FindBarRung,
    ) -> SlatePlateVerbButton {
        SlatePlateVerbButton(
            symbol: symbol, help: help, size: CGFloat(rung.iconSize), plate: CGFloat(rung.plate),
        )
    }

    // MARK: Chrome

    private func paintChrome() {
        backgroundColor = Slate.Native.Surface.raised
        layer.slateShadow(.panel, in: traitCollection)
    }

    /// The card is SOLID TO TOUCH. It floats over live terminal output, and a tap that fell through its
    /// padding would move the terminal's selection out from under a search the user is reading. A
    /// `UIView` with a background is already opaque to hit-testing; this states the rule so a later
    /// `isUserInteractionEnabled = false` on an ancestor reads as the regression it would be.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        bounds.contains(point)
    }

    // MARK: Focus

    /// Pre-focuses the query field so typing lands immediately.
    ///
    /// ⚠️ NO RUNLOOP HOP, and its absence is the point. The Mac defers one hop because a field cannot take
    /// first responder before its WINDOW has it, and `viewDidMoveToWindow` runs while the bar is still
    /// being put in place; the SwiftUI half deferred because a `@FocusState` set in the same tick the view
    /// appears is dropped before its backing responder exists. Neither holds here — by
    /// `didMoveToWindow` the field is in a window and is a real responder — so the hop would only be a
    /// frame of latency on the one control the user opened the bar to type into. docs/62 §3.5 counts this
    /// as one of the eight hops that delete.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        focusQuery()
    }

    private func focusQuery() {
        guard !field.isFirstResponder else { return }
        field.becomeFirstResponder()
    }

    // MARK: The live read

    /// One tracked read of everything the bar draws — ``DecorationFindBarRead/reading(_:)``, on the floor
    /// because the DEPENDENCY SET is what must not drift between the two bars.
    private func follow() {
        barFollow = ObservationFollow.arm(self) { bar in
            DecorationFindBarRead.reading(bar.model)
        } apply: { bar, reading in
            bar.apply(reading)
        }
    }

    private func apply(_ reading: DecorationFindBarReading) {
        // Written back only when it actually DIFFERS. Assigning `text` on a field being edited resets the
        // insertion point to the end and discards any marked (IME) text — and every keystroke round-trips
        // through here, so an unguarded write would make the bar unusable in any language composed rather
        // than typed. The guard is false exactly when something OTHER than this field moved the query: a
        // close-and-reopen, or a future seed.
        if field.text != reading.query { field.text = reading.query }
        for (mode, pill) in pills { pill.setOn(reading.lit[mode] ?? false) }
        showCounter(reading.label)
        if reading.token != focusToken {
            focusToken = reading.token
            focusQuery()
        }
    }

    /// The `N of M` line, or nothing at all under an empty field — the three-way rule is
    /// ``FindBarPresentation/counterText(position:query:)``'s, never re-derived here.
    ///
    /// Each keystroke / ⌘G CROSS-FADES the label to its new value. The SwiftUI half rolled the digits
    /// (`contentTransition(.numericText())`) so the eye tracks WHICH number moved; UIKit has no equivalent
    /// that is not a reimplementation of it, so this half spends the fade alone — the same bargain the Mac
    /// made, and for the same reason (the roll is the flourish, the fade is what says the number is new).
    private func showCounter(_ label: String?) {
        counterBox.isHidden = label == nil
        guard let label, counter.text != label else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Slate.Motion.smallFade.duration
        fade.timingFunction = Slate.Motion.smallFade.timingFunction
        counter.layer.add(fade, forKey: "counter")
        counter.text = label
    }

    // MARK: The keyboard

    @objc
    private func queryChanged() {
        // Live query edit — the model recomputes the counter and re-arms `libghostty-vt`'s highlight.
        model.setQuery(field.text ?? "")
    }

    /// Plain ↩ → the next match. The field stays first responder: a search you step through is a search
    /// you are still typing into.
    func textFieldShouldReturn(_: UITextField) -> Bool {
        model.next()
        return false
    }

    /// ⇧↩ steps against the search direction, and ⎋ closes.
    ///
    /// ⇧↩ takes priority over the system: a single-line field would otherwise swallow the return as an
    /// end-of-editing and the bar would step forward on both directions of one key. Esc deliberately does
    /// NOT — see ``UIKeyCommand/slateCancel(action:)``, which loses that race on purpose so a cancel
    /// cannot close the bar out from under a half-typed IME composition.
    override var keyCommands: [UIKeyCommand]? {
        let back = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(stepBack))
        back.wantsPriorityOverSystemBehavior = true
        return [back, .slateCancel(action: #selector(close))]
    }

    @objc
    private func stepBack() {
        model.previous()
    }

    @objc
    private func close() {
        // The keyboard hand-back to the terminal surface is `close()`'s, not this view's — closing tears
        // down the focused field while the pane's workspace focus never changed, so none of the surface's
        // own reclaim paths fire. See ``TerminalFindBarModel/close()``.
        model.close()
    }
}

// MARK: - The query line's own inset

/// The plate the query line sits in.
///
/// `find.png`: the query text sits in its OWN delineated inset — a distinct FILLED rounded field INSIDE
/// the card (not flush). The card is `Surface.raised` (≈ white in light themes), so a flush `Surface.face`
/// field reads as near-invisible; instead the field wears `State.selected`, a translucent neutral wash.
/// CROSS-THEME caveat: `State.selected` is a BLACK wash in light (composites DARKER than the card →
/// recessed inset, matching find.png) but WHITE in dark (composites LIGHTER → reads RAISED, not recessed).
/// No single solid/wash token is reliably recessed-AND-visible on both themes, so rather than chase a
/// darker fill the line is DELINEATED by its own inner `Line.subtle` hairline — a hard boundary that reads
/// as a distinct inset whichever way the fill contrasts. INNER line only; the card's no-border
/// fill+shadow chrome is NOT re-stroked.
///
/// ⚠️ NOT the search bar the summoned cards use (``SlateSearchBarView``), which is the same shape in a
/// different ink family: that well wears `Overlay.*`, the neutral alphas over the platform label colour
/// that resolve against whichever polarity a floating card stands in. This one stands on the chrome's own
/// `Surface.raised` over live terminal output, so it takes the chrome ladder. Merging the two would mean
/// picking one family for both surfaces, which is a design change.
@MainActor
private final class FindQueryWellView: UIView {
    /// The line this plate is the affordance FOR — held so a tap anywhere on the plate puts the caret in
    /// it, which is what an inset field promises.
    private let field: UITextField

    init(field: UITextField) {
        self.field = field
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusField)))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (well: Self, _: UITraitCollection) in
            well.reink()
        }
        reink()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func reink() {
        backgroundColor = Slate.Native.State.selected
        layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
    }

    @objc
    private func focusField() {
        field.becomeFirstResponder()
    }
}

// MARK: - One mode chip

/// A compact `Aa` / `ab` / `.*` toggle pill (the find-bar mode buttons).
///
/// LOCKED MODE-PILL RENDERING — screenshot-matched, final; do NOT re-litigate. `find.png` AND
/// `global-search.png` (verified by zooming both) show the pills as INDIVIDUALLY-OUTLINED rounded chips —
/// each with its OWN resting plate + `Line.subtle` hairline, gapped, sitting DIRECTLY on the bar. There is
/// NO shared segmented backing tray. Bare glyphs, resting plates and a shared tray are all tempting
/// alternatives that don't match the screenshots; re-flagging either is not a new finding.
/// Non-negotiable invariants: (1) every idle chip is visually DELINEATED (own plate + hairline, never a
/// bare glyph); (2) the find bar and the global-search query bar render the pills IDENTICALLY — both
/// through ``FindModePill`` + ``FindTogglePillAppearance`` + THIS view.
///
/// ⚠️ THE NAME IS THE CONTRACT. `GlobalSearchView` mounts this exact type, and the tray it lays them out
/// in is a plain `UIStackView` with ``Slate/Metric/space1`` between chips — the transparent container the
/// SwiftUI `FindTogglePillTray` was, which is not worth a type once a stack view can say it in three
/// lines.
///
/// WHAT the chip says is a ``FindModePill``, not three parameters, and HOW it looks is a
/// ``FindTogglePillAppearance``, not an inline table: the glyph, the help and the underline travel
/// together, and so do the plate, the ring and the ink. Both values are read by the Mac's half as well,
/// which cannot see this call site at all — a pill spelled at a call site could only stay identical across
/// three surfaces by luck.
@MainActor
final class FindTogglePill: UIControl {
    var onToggle: () -> Void = {}

    private let mode: FindModePill
    private let plate: CGFloat
    private let text = UILabel()
    private var isOn = false

    /// The pointer is over the chip. iPadOS with a trackpad has hover exactly as the Mac does; a
    /// touch-only device never sets it, and the chip then reads press-only.
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            repaint(animated: true)
        }
    }

    init(_ mode: FindModePill, plate: CGFloat = Slate.Metric.plate) {
        self.mode = mode
        self.plate = plate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline

        text.textAlignment = .center
        text.isAccessibilityElement = false
        text.isUserInteractionEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: plate),
            heightAnchor.constraint(greaterThanOrEqualToConstant: plate),
            widthAnchor.constraint(
                greaterThanOrEqualTo: text.widthAnchor, constant: Slate.Metric.space1 * 2,
            ),
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = mode.help
        slateHelp(mode.help)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: Self, _: UITraitCollection) in
            pill.repaint(animated: false)
        }
        repaint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            repaint(animated: true)
        }
    }

    /// Set the lit state from the controller's flag. The chip never flips itself: it draws what it is
    /// told, and the tap only asks.
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        accessibilityTraits = on ? [.button, .selected] : .button
        repaint(animated: true)
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
    private func fire() { onToggle() }

    /// The three-case ladder, and its only decision is which TOKEN each case maps to — the verdict itself
    /// is ``FindTogglePillAppearance/resolve(isOn:hovering:)``'s, shared with the Mac.
    ///
    /// A PRESS reads as a hover here rather than growing a fourth rung: the appearance value has three
    /// cases and is pinned as a pair across the framework boundary, so inventing a press case on one side
    /// only is the drift the pin exists to catch. What the finger gets instead is the hover plate, which
    /// is the same acknowledgement the pointer gets for the same reason.
    private func repaint(animated: Bool) {
        let appearance = FindTogglePillAppearance.resolve(
            isOn: isOn, hovering: hovering || isHighlighted,
        )
        // Each chip carries its OWN resting plate (find.png / global-search.png): idle = a subtle
        // `Surface.face` plate, hover = a `State.hover` plate, on = the accent wash. No shared tray.
        let fill: UIColor =
            switch appearance {
            case .idle: Slate.Native.Surface.face
            case .hovering: Slate.Native.State.hover
            case .on: Slate.Native.State.accentMuted
            }
        // Every chip is individually outlined: idle/hover wear a `Line.subtle` hairline so the chip is
        // delineated (never a bare glyph); the ON chip swaps in the accent ring. ``Slate/Opacity/accentRing``
        // — the SAME alpha the vi pill and both Mac halves spend, all four having been a raw `0.5` until
        // the value went to the floor.
        let ring: UIColor =
            switch appearance {
            case .idle,
                 .hovering: Slate.Native.Line.subtle
            case .on: Slate.Native.accent.slateScalingAlpha(Slate.Opacity.accentRing)
            }
        let ink: UIColor =
            switch appearance {
            case .idle,
                 .hovering: Slate.Native.Text.secondary
            case .on: Slate.Native.accent
            }

        // The caption is REBUILT rather than re-tinted: `textColor` does not reliably reach a string that
        // already carries its own attributes, and this one carries the underline that IS the whole-word
        // chip's mark.
        text.attributedText = Self.caption(mode, ink: ink)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
        layer.borderColor = ring.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    /// The chip's word, underlined for the one mode whose mark IS an underline (`ab` for whole-word). The
    /// mono face is what keeps `Aa`, `ab` and `.*` the same three widths in every appearance.
    private static func caption(_ mode: FindModePill, ink: UIColor) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(
                ofSize: Slate.Typeface.footnote, weight: .semibold,
            ),
            .foregroundColor: ink,
        ]
        if mode.underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: mode.label, attributes: attributes)
    }
}
#endif
