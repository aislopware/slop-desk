// MacTerminalFindBar — the in-pane ⌘F find overlay, in AppKit (docs/56 wave R, batch R5).
//
// The Mac half of ``TerminalFindBar``. It is a THIN renderer over two shared values, exactly as its
// SwiftUI twin is: the driver ``TerminalFindBarModel`` (`SlopDeskClientCore`), which owns every match
// / nav / toggle mutation, and ``FindBarPresentation`` / ``FindBarMetrics``, which own every word and
// every measurement. This file is the DRAWING and nothing else — the model already left for
// `SlopDeskClientCore` precisely so an AppKit find bar could READ the words and the numbers rather
// than agree with them, and this is the reader that argument was written for.
//
// The behaviour the model owns, in one line each, so this file can be read without opening it: the
// counter counts the `scrollbackTextLines()` snapshot taken on open while libghostty owns the live
// highlight (a documented divergence); regex / whole-word / case-sensitive modes are ROW-DRIVEN
// because libghostty's matcher is a literal, case-insensitive substring scan; literal mode arms
// `search:` and steps `navigate_search:`. The full argument is in the model's header.
//
// Anatomy matches `find.png` (top-trailing of the focused pane, floating card, `Slate.*` tokens ONLY):
//   [ query field ][ Aa case pill ][ ab whole-word pill ][ .* regex pill ][ N of M ][ ∧ prev ][ ∨ next ]
//   [ ▣ search-all-tabs ][ × close ]
// (`rectangle.stack` "search all tabs" escalates to cross-tab Global Search ⇧⌘F — see
// ``TerminalFindBarModel/searchAllTabs()``.)
//
// ## Two things this port did NOT respell
//
// THE MODE CHIPS ARE ``MacFindTogglePillView`` — the very view `MacGlobalSearch` already draws, reached
// across this module rather than copied into it. Its own header carries the lock ("the find bar's chips
// and these must read identically") and `check-supervisor.sh` pins `FindTogglePillAppearance` as a pair
// between the SwiftUI find bar and that file. A third AppKit spelling of the chip would have satisfied
// every gate in the repo and still been the drift the lock exists to forbid, because nothing compares a
// hover plate in one file with a hover plate in another. So there are two AppKit pill drawings in this
// app: zero. (It is `MacGlobalSearch.swift`'s only tenant that is not about global search — a candidate
// for a shared `Mac*Parts` file once both halves stand still, which is the increment-52/53 rule.)
//
// THE PLATES ARE ``MacPlateIconButton`` — the AppKit twin of `SlatePlateButton`, rung for rung: idle
// clear, hover `State.hover`, press `State.selected`, glyph `Text.icon` at `.medium`. It takes the icon
// and plate sizes as parameters, which is what lets the find bar hand it the POINTER rung below.
//
// ## The rung, and the arm that stayed behind
//
// The SwiftUI twin picks its rung through a `#if os(iOS)`. That gate decides ONE thing — which rung the
// platform's pointer earns — and this target has no such question: a Mac is driven by a MOUSE, so the
// rung is ``FindBarMetrics/pointer``, unconditionally. The touch rung and the iOS nav notes stay with
// `SlopDeskPhoneUI`; a `#if` here would be dead text reading as a live rule (docs/56 §3).
//
// ## Chrome
//
// `find.png`: the card is delineated by FILL + drop SHADOW only — NO hairline stroke around the CARD
// (verified by pixel-scanning: the pane→shadow gradient runs straight into the card fill, no border
// line). Only the mode chips keep their own hairline outlines, and the query line keeps its own inner
// one — see ``MacFindQueryWell``.
//
// Hang-safety: NO `GhosttySurface` / VideoToolbox / Metal is touched here — the bar only calls the model
// seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a headless surface.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - What a key in the query field MEANS

/// The four things a keystroke that reached the query field can be, as a value.
///
/// It is a VALUE and not four `if`s inside the delegate for one reason: ⇧↩ and ↩ arrive through the
/// same selector, and the SwiftUI twin needed a `.shift` guard so "next" and "previous" could never
/// double-fire off one press. That guard is the whole rule, it is invisible in a delegate that also
/// mutates a model, and it is the one thing here a headless test can pin.
///
/// It stays in this target rather than descending to `SlopDeskClientCore` because its input is a
/// `Selector` — AppKit's vocabulary, which the shared floor cannot name.
enum MacFindBarKey: Equatable {
    /// ↩ — step to the next match.
    case next
    /// ⇧↩ — step against the search direction.
    case previous
    /// ⎋ — close the bar, clear the highlights, hand the keyboard back.
    case close
    /// Anything else: the field editor's, untouched.
    case passThrough

    /// The routing table. Three selectors mean "return" rather than one because which of them a
    /// ⇧↩ arrives as is decided by the user's key-binding tables, not by this app — the default
    /// bindings send `insertNewline:`, a customised `~/Library/KeyBindings/DefaultKeyBinding.dict`
    /// can send `insertLineBreak:` or `insertNewlineIgnoringFieldEditor:`, and a find bar whose
    /// ⇧↩ silently stopped stepping backwards on one machine is the worst shape a key bug takes.
    static func verb(for selector: Selector, shift: Bool) -> Self {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            shift ? .previous : .next
        case #selector(NSResponder.cancelOperation(_:)):
            .close
        default:
            .passThrough
        }
    }
}

// MARK: - The bar

/// The find bar strip, as an `NSView`. Owns only its widgets and the focus it asserts — every match /
/// nav / toggle mutation routes through ``TerminalFindBarModel`` so this half and the phone's stay
/// byte-for-byte.
@MainActor
final class MacTerminalFindBar: NSView, NSTextFieldDelegate {
    private let model: TerminalFindBarModel

    /// A MOUSE drives this bar. See the file header — the rung is asked for by name, never by `#if`.
    private let rung: FindBarRung

    private let field: NSTextField
    private let well: MacFindQueryWell
    private let pills: [FindModePill: MacFindTogglePillView]
    private let counter = NSTextField(labelWithString: "")
    /// The counter's own horizontal air. The SwiftUI twin pads the label INSIDE the row's gap, so a
    /// box is what reproduces it: `setCustomSpacing` would survive the label being hidden and leave a
    /// widened gap where the counter used to be, which is the one state the bar spends most of its
    /// life in (an empty query prints no counter at all).
    private let counterBox = NSStackView()
    private let row = NSStackView()

    private let previous: MacPlateIconButton
    private let next: MacPlateIconButton
    private let allTabs: MacPlateIconButton
    private let dismiss: MacPlateIconButton

    /// The last ``TerminalFindBarModel/focusToken`` this bar acted on. Re-asserting first responder on
    /// every observation pass would end and restart the field editor on each keystroke, which drops the
    /// selection and any in-flight IME composition — so the token is compared, never just read.
    private var focusToken: Int

    init(model: TerminalFindBarModel) {
        // Everything below is built from LOCALS and only then stored: a class initialiser may not read
        // its own `self` before `super.init`, so the well cannot be handed the field off a property.
        let rung = FindBarMetrics.pointer
        let field = NSTextField()
        self.model = model
        self.rung = rung
        self.field = field
        well = MacFindQueryWell(field: field)
        pills = Dictionary(
            uniqueKeysWithValues: FindModePill.inPaneFindBar.map { ($0, MacFindTogglePillView($0)) },
        )
        // The four trailing plates stand on the POINTER rung, handed over rather than defaulted —
        // `MacPlateIconButton`'s own defaults are the chrome ladder's, which agree with this rung today
        // and are not the same decision.
        previous = Self.plateButton("chevron.up", rung: rung)
        next = Self.plateButton("chevron.down", rung: rung)
        allTabs = Self.plateButton("rectangle.stack", rung: rung)
        dismiss = Self.plateButton("xmark", rung: rung)
        focusToken = model.focusToken
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        // No border: the card is fill + cast, and the cast has to escape the corner radius.
        layer?.masksToBounds = false
        layer?.shadowRadius = Slate.Elevation.panel.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.panel.y)
        layer?.shadowOpacity = 1

        buildField()
        buildRow()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func buildField() {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none // the well is the affordance; no system halo
        field.usesSingleLineMode = true
        // The field is FIXED-width (see ``FindBarRung/fieldWidth``), so a query longer than it has to
        // scroll rather than clip — otherwise the tail of what was typed is simply not there.
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Text.primary
        field.placeholderString = FindBarPresentation.placeholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(field)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: CGFloat(rung.fieldWidth)),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Slate.Metric.space2),
            field.topAnchor.constraint(equalTo: well.topAnchor, constant: Slate.Metric.space1),
            field.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    private func buildRow() {
        counter.font = .monospacedDigitSystemFont(
            ofSize: Slate.Typeface.footnote, weight: .regular,
        )
        counter.textColor = Slate.Native.Text.secondary
        counter.isSelectable = false
        counter.maximumNumberOfLines = 1
        // Never truncated and never wrapped: `N of M` is the one label in the bar whose whole content
        // is the information, and a `1 of 1…` reads as a different number.
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        counter.wantsLayer = true // the roll below is a layer transition
        counterBox.orientation = .horizontal
        counterBox.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space1, bottom: 0, right: Slate.Metric.space1,
        )
        counterBox.addArrangedSubview(counter)

        // A TRANSPARENT tray: the chips delineate themselves, so the container only spaces them. The
        // same shape `MacGlobalSearch` builds around the same pills — which is the locked invariant,
        // not a coincidence.
        let tray = NSStackView()
        tray.orientation = .horizontal
        tray.spacing = Slate.Metric.space1
        for mode in FindModePill.inPaneFindBar {
            guard let pill = pills[mode] else { continue }
            pill.onToggle = { [weak self] in self?.toggle(mode) }
            tray.addArrangedSubview(pill)
        }

        wire(previous, help: FindBarPresentation.previousMatchHelp) { [weak self] in
            self?.model.previous()
        }
        wire(next, help: FindBarPresentation.nextMatchHelp) { [weak self] in self?.model.next() }
        // Escalates the in-pane find to cross-tab Global Search (⇧⌘F), seeded with the current query.
        // Wired through ``TerminalFindBarModel/searchAllTabs()`` → ``OverlayCoordinator/openGlobalSearch``.
        wire(allTabs, help: FindBarPresentation.searchAllTabsHelp) { [weak self] in
            self?.model.searchAllTabs()
        }
        wire(dismiss, help: FindBarPresentation.closeHelp) { [weak self] in self?.model.close() }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space2,
            bottom: Slate.Metric.space1, right: Slate.Metric.space2,
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        for part in [well, tray, counterBox, previous, next, allTabs, dismiss] as [NSView] {
            row.addArrangedSubview(part)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// One trailing plate, standing on the bar's rung. Static so the initialiser can build the four
    /// before `super.init` — the alternative is `MacPlateIconButton`'s own defaults, which are the
    /// chrome ladder's numbers and not this bar's reading of them.
    private static func plateButton(_ symbolName: String, rung: FindBarRung) -> MacPlateIconButton {
        MacPlateIconButton(
            symbolName: symbolName, iconSize: CGFloat(rung.iconSize), plate: CGFloat(rung.plate),
        )
    }

    /// The word a plate says and the verb it runs. The word is ``FindBarPresentation``'s in every
    /// case — a tooltip spelled here would be the fourth surface disagreeing about what `∧` does.
    private func wire(_ button: MacPlateIconButton, help: String, action: @escaping () -> Void) {
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.onClick = action
    }

    // MARK: Chrome

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // `effectiveAppearance` has to be the CURRENT one while a dynamic colour resolves, or every
        // rung answers for whatever appearance happened to be drawing last.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
            layer?.shadowColor = Slate.Native.State.shadow.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The card is SOLID TO CLICKS. It floats over live terminal output, and a click that fell through
    /// its padding would move the terminal's selection out from under a search the user is reading.
    override func mouseDown(with _: NSEvent) {}

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // MARK: Focus

    /// Pre-focuses the query field so typing lands immediately.
    ///
    /// Deferred one runloop hop, for the reason the SwiftUI twin defers its `@FocusState`: a field
    /// cannot take first responder before its window has it, and `viewDidMoveToWindow` runs while the
    /// bar is still being put in place. The hop is the palette / cheat-sheet idiom.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focusQuery() }
        }
    }

    private func focusQuery() {
        guard let window, window.firstResponder !== field.currentEditor() else { return }
        window.makeFirstResponder(field)
        tintCaret()
    }

    /// The active caret is the accent colour (the SwiftUI twin's `.tint`). It has to be set on the
    /// FIELD EDITOR — the window's shared `NSTextView` — which only exists once the field is focused,
    /// so this is a step of focusing rather than a property of the field.
    private func tintCaret() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = Slate.Native.accent
    }

    // MARK: The live read

    /// One tracked read of everything the bar draws. The model is `@Observable`, and every mutation it
    /// makes — a keystroke's recount, a toggle, a ⌘G step, the re-open bump — lands in one of these.
    private func follow() {
        var query = ""
        var label: String?
        var lit: [FindModePill: Bool] = [:]
        var token = 0
        withObservationTracking {
            let controller = model.controller
            query = controller.query
            label = FindBarPresentation.counterText(
                position: controller.positionLabel, query: controller.query,
            )
            lit = Dictionary(
                uniqueKeysWithValues: FindModePill.inPaneFindBar.map { ($0, isOn($0)) },
            )
            token = model.focusToken
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        apply(query: query, label: label, lit: lit, token: token)
    }

    private func apply(query: String, label: String?, lit: [FindModePill: Bool], token: Int) {
        // Written back only when it actually DIFFERS. `stringValue` on a field being edited rebuilds
        // the field editor's contents, which drops the insertion point to the end and discards any
        // marked (IME) text — and every keystroke round-trips through here, so an unguarded write
        // would make the bar unusable in any language composed rather than typed. The guard is false
        // exactly when something OTHER than this field moved the query: a close-and-reopen, or a
        // future seed.
        if field.stringValue != query { field.stringValue = query }
        for (mode, pill) in pills { pill.setOn(lit[mode] ?? false) }
        showCounter(label)
        if token != focusToken {
            focusToken = token
            focusQuery()
        }
    }

    /// The `N of M` line, or nothing at all under an empty field — the three-way rule is
    /// ``FindBarPresentation/counterText(position:query:)``'s, never re-derived here.
    ///
    /// Each keystroke / ⌘G CROSS-FADES the label to its new value. The SwiftUI twin rolls the digits
    /// (`contentTransition(.numericText())`) so the eye tracks WHICH number moved; AppKit has no
    /// equivalent that is not a reimplementation of it, so this half spends the fade alone — the same
    /// bargain ``MacPlateIconButton`` made with the symbol bounce, and for the same reason (the roll
    /// is the flourish, the fade is what says the number is new).
    private func showCounter(_ label: String?) {
        counterBox.isHidden = label == nil
        guard let label, counter.stringValue != label else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Slate.Motion.smallFade.duration
        fade.timingFunction = Slate.Motion.smallFade.timingFunction
        counter.layer?.add(fade, forKey: "counter")
        counter.stringValue = label
    }

    // MARK: The mode chips

    /// Whether `mode`'s chip is lit — the controller's own flag, never a mirror.
    private func isOn(_ mode: FindModePill) -> Bool {
        switch mode {
        case .caseSensitive: model.controller.caseSensitive
        case .wholeWord: model.controller.wholeWord
        case .regex: model.controller.isRegex
        }
    }

    /// Flip `mode` through the model, which refreshes the mirror and re-arms the highlight.
    private func toggle(_ mode: FindModePill) {
        switch mode {
        case .caseSensitive: model.toggleCaseSensitive()
        case .wholeWord: model.toggleWholeWord()
        case .regex: model.toggleRegex()
        }
        // The pill's own lit state is redrawn by `follow()`, off the controller — a chip that painted
        // itself on the click would be a mirror of the flag rather than a reading of it.
    }

    // MARK: The keyboard

    /// Live query edit — the model recomputes the counter and re-arms libghostty's highlight.
    func controlTextDidChange(_: Notification) {
        model.setQuery(field.stringValue)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        let shift = NSApplication.shared.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask).contains(.shift) ?? false
        switch MacFindBarKey.verb(for: selector, shift: shift) {
        case .next:
            model.next()
        case .previous:
            model.previous()
        case .close:
            // The keyboard hand-back to the terminal surface is `close()`'s, not this view's — closing
            // tears down the focused field editor while the pane's workspace focus never changed, so
            // none of the surface's own reclaim paths fire. See ``TerminalFindBarModel/close()``.
            model.close()
        case .passThrough:
            return false
        }
        return true
    }
}

// MARK: - The query line's own inset

/// The plate the query line sits in.
///
/// `find.png`: the query text sits in its OWN delineated inset — a distinct FILLED rounded field INSIDE
/// the card (not flush). The card is `Surface.raised` (≈ white in light themes), so a flush
/// `Surface.face` field reads as near-invisible; instead the field wears `State.selected`, a translucent
/// neutral wash. CROSS-THEME caveat: `State.selected` is a BLACK wash in light (composites DARKER than
/// the card → recessed inset, matching find.png) but WHITE in dark (composites LIGHTER → reads RAISED,
/// not recessed). No single solid/wash token is reliably recessed-AND-visible on both themes (the only
/// darker-than-card token in dark, `Surface.face` / the backdrop, is near-invisible in light). So rather
/// than chase a darker fill the line is DELINEATED by its own inner `Line.subtle` hairline — a hard
/// boundary that reads as a distinct inset whichever way the fill contrasts. INNER line only; the card's
/// no-border fill+shadow chrome is NOT re-stroked.
///
/// ⚠️ NOT ``MacGlobalSearchWellView``, which is the same shape in a different ink family: that well is a
/// SUMMONED CARD's input and wears `Overlay.well` / `Overlay.hairline`, the neutral alphas over the
/// platform label colour that resolve against whichever polarity a floating card stands in. This one
/// stands on the chrome's own `Surface.raised` over live terminal output, so it takes the chrome ladder.
/// Merging the two would mean picking one family for both surfaces, which is a design change.
@MainActor
private final class MacFindQueryWell: NSView {
    /// The line this plate is the affordance FOR — held so a click anywhere on the plate puts the caret
    /// in it, which is what an inset field promises and what the SwiftUI twin got from its text field
    /// filling the padded shape.
    private let field: NSTextField

    override var wantsUpdateLayer: Bool { true }

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.State.selected.cgColor
            layer?.borderColor = Slate.Native.Line.subtle.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
