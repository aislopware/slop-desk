// MacViModeOverlay — the vi / copy-mode chrome, in AppKit (docs/56 wave R, batch R4).
//
// The AppKit halves of ``ViModePill`` (the persistent mode badge with a live repeat-count and an `×`
// exit) and ``ViKeyHintBar`` (the `⌘/` reference card). Both are DRAWINGS over
// ``ViKeyHintPresentation`` (`SlopDeskClientCore`), which holds the three hint tables, the headings,
// the pill's wording and the reflow ladder — so the two renderers cannot disagree about which keys
// the card advertises, or about which arrangement a given width affords.
//
// THE PILL RIDES THE EXISTING PURE ENGINE. It reads the OBSERVABLE mirrors
// (``TerminalViewModel/viVisualMode`` / ``viPendingCount``), never the `@ObservationIgnored`
// `isCopyMode` flag the renderer's `keyDown` path reads — that separation is what keeps the mode
// chrome off the keyDown intercept's AttributeGraph hazard, and it survives the port because
// ``ObservationFollow`` registers on exactly the properties its `read` block touches — so the
// separation is a dependency set, not a convention.
//
// THE CARD'S REFLOW IS ARITHMETIC, AND ON THIS SIDE THAT IS THE ONLY REASON IT WORKS AT ALL. The
// SwiftUI half is a `Layout` HANDED a `ProposedViewSize`; AppKit hands a view its own bounds, which
// is the size it has ALREADY taken — so a card that asked its own `bounds.width` which rung it could
// afford would measure the answer it had just given and hug its content forever. The proposal
// arrives instead as ``MacViKeyHintBar/availableWidth``, set by whatever mounts the card (batch R9),
// which is the same direction `sizeThatFits(proposal:)` gets it from. Everything below that is
// ``ViKeyHintPresentation/layout(forWidth:gap:columnWidth:)``'s answer and
// ``ViKeyHintPresentation/groups(for:)``'s placement; this file supplies only the MEASUREMENT — how
// wide one column actually draws — the way `PhonePanelSheet` supplies `named:` to
// `PanelTabs.labelling`. `ViewThatFits` has no AppKit equivalent whatsoever, which is precisely why
// that ladder was pushed to the floor before either renderer needed it.
//
// `Slate.*` tokens only, in their native (`NSColor`/`NSFont`) spelling. No libghostty / Metal /
// VideoToolbox is touched: these are plain layer-backed chips driven by the pane model's observables.
//
// HONESTY (the "nothing is a dead key" rule) lives with the tables, not here: ``ViKeyHintPresentation``
// lists ONLY the keys ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires, and its own test
// pins it there. A card that hand-wrote a row would be advertising a key nothing dispatches.

import AppKit
import SFSafeSymbols // the mode glyph's name, spelled once on the floor and checked by the compiler
import SlopDeskClientCore // ViKeyHintPresentation — the tables, the wording and the width ladder
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

/// The vi-mode pill — the persistent badge shown in the pane's top-trailing overlay while the pane is
/// in vi / copy-mode: the current MODE label (`VI` for plain scrollback navigation, `VISUAL` /
/// `VISUAL LINE` / `VISUAL BLOCK` in a selection), the LIVE pending repeat-count digits, and an `×`
/// that leaves the mode.
///
/// `onExit` is the SINGLE exit seam — the leaf wires it to ``TerminalViewModel/exitCopyMode()``, which
/// also resets the count, the visual mode and the hint bar, so the `×`, the `Esc`/`q` keys and a
/// programmatic dismiss all converge on one state rather than on three nearly-identical teardowns.
@MainActor
final class MacViModePill: NSView {
    private let model: TerminalViewModel
    private let onExit: () -> Void

    private let row = NSStackView()
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// The live repeat-count. Hidden rather than removed when no count is pending — an arranged
    /// subview that is hidden leaves the stack's layout, which is the AppKit spelling of the SwiftUI
    /// half's `if let count`.
    private let count = NSTextField(labelWithString: "")
    /// THE SAME `×` the status chips carry (``MacPaneStatusPillCloseView``, batch R2), not a second
    /// one: it is the identical control — ``Slate/Metric/glyphPlate`` square, the selection wash on
    /// hover, ``Slate/Typeface/small`` at `.medium` in the secondary tone — on a chip that floats in
    /// the same corner. A private copy here would be the third spelling of a mark whose whole job is
    /// to look like itself wherever a pane chip shows one.
    private let close: MacPaneStatusPillCloseView

    /// The last applied reading. Kept so an observation callback that changes nothing repaints
    /// nothing — the mirrors are re-synced after EVERY copy-mode key, including the ones that move a
    /// cursor and leave both of these alone.
    private var mode: TerminalViewModel.VisualMode = .none
    private var pending: Int?
    /// Whether the first paint has happened. It gates BOTH the early-out (the resting reading is
    /// `.none` / `nil`, so an unpainted pill would compare equal to itself and never draw a word) and
    /// the animation (a pill fading its own arrival in reads as a lag, not as a transition).
    private var painted = false

    init(model: TerminalViewModel, onExit: @escaping () -> Void) {
        self.model = model
        self.onExit = onExit
        // `.chrome`, not a bare ink: the shared close plate derives the `×`'s own tone from the plate it
        // sits on (secondary on chrome, white on a vivid fill, where a secondary tone would vanish), and
        // the vi pill's plate is the chrome one. Passing the ink directly would have been the same
        // colour today and a silently wrong one the day this pill goes vivid — the SwiftUI half spends
        // `Slate.Text.secondary` unconditionally for exactly the chrome case.
        close = MacPaneStatusPillCloseView(help: ViKeyHintPresentation.exitHelp, fill: .chrome)
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        // The chip rung lifts the pill off busy terminal output. `masksToBounds` stays false or the
        // cast is clipped away by the very plate casting it.
        layer?.masksToBounds = false
        layer?.shadowRadius = Slate.Elevation.chip.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.chip.y)
        layer?.shadowOpacity = 1

        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        glyph.image = NSImage(
            systemSymbolName: SFSymbol.characterCursorIbeam.rawValue, accessibilityDescription: nil,
        )?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Slate.Typeface.small, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(
                        paletteColors: [Slate.Native.Text.primary],
                    )),
            )

        for text in [label, count] {
            text.isSelectable = false
            text.maximumNumberOfLines = 1
            // The mode word and the count are both short fixed strings; a pill narrow enough to
            // truncate `VISUAL BLOCK` would be reporting the mode in a form the user has to guess at.
            // They resist compression instead, so a cramped corner overflows visibly rather than
            // lying — the same bargain the status chips' word makes.
            text.lineBreakMode = .byClipping
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.setAccessibilityElement(false)
        }
        // Mono, not just tabular figures: the SwiftUI half asks for `design: .monospaced` AND
        // `.monospacedDigit()`, and a running count that changes width as it passes 9 is the thing
        // both of those exist to prevent.
        count.font = .monospacedSystemFont(ofSize: Slate.Typeface.footnote, weight: .semibold)
        count.textColor = Slate.Native.accent

        close.onPress = { [weak self] in self?.onExit() }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space2,
            bottom: Slate.Metric.space1, right: Slate.Metric.space2,
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

        // A GROUP rather than SwiftUI's combined element, for the reason the status chip gives:
        // `.combine` folds a child button's action into one element and AppKit has no equivalent that
        // keeps the dismiss operable, so the pill is a labelled container and the `×` stays a button
        // inside it. The label is re-set on every apply — it carries the live count.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityHelp(ViKeyHintPresentation.exitHelp)
    }

    // MARK: The live read

    /// Re-read the two observable mirrors and repaint.
    private func follow() {
        ObservationFollow.arm(self) { pill in
            (mode: pill.model.viVisualMode, pending: pill.model.viPendingCount)
        } apply: { pill, reading in
            pill.apply(mode: reading.mode, pending: reading.pending)
        }
    }

    /// The count appearing and the ring going loud are ONE transaction. Both are
    /// ``Slate/Motion/smallFade`` in the SwiftUI half (two `.animation` modifiers over the same
    /// curve), and running them apart would let a `5v` — a count typed and then a visual mode armed —
    /// read as two separate events when it was one keystroke pair.
    private func apply(mode: TerminalViewModel.VisualMode, pending: Int?) {
        guard !painted || mode != self.mode || pending != self.pending else { return }
        let first = !painted
        painted = true
        self.mode = mode
        self.pending = pending

        let paint = { [self] in
            label.attributedStringValue = NSAttributedString(
                string: mode.pillLabelOrDefault,
                attributes: [
                    .font: NSFont.systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold),
                    .foregroundColor: Slate.Native.Text.primary,
                    .kern: Slate.Typeface.pillTracking,
                ],
            )
            count.stringValue = pending.map { String($0) } ?? ""
            count.isHidden = pending == nil
            setAccessibilityLabel(
                ViKeyHintPresentation.accessibilityLabel(mode: mode, count: pending),
            )
            needsDisplay = true
            updateLayer()
        }
        guard !first else {
            paint()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            paint()
            layoutSubtreeIfNeeded()
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
            layer?.borderColor = ring().cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The pill's outline — this renderer's two-line ink ladder over
    /// ``TerminalViewModel/VisualMode/isVisual``. Plain navigation wears the same subtle hairline as
    /// the read-only chip; a visual selection swaps in the accent ring so the "I am selecting" state
    /// is unmistakable beside the count.
    ///
    /// The lit rung is ``Slate/Opacity/accentRing`` (stage F batch P6) — the SAME alpha the SwiftUI
    /// pill, the find bar's ON chip and `MacGlobalSearch`'s spend. All four were a raw `0.5` until the
    /// value went to the floor, and a fourth renderer re-spelling it is exactly the drift the descent
    /// was for: an alpha is frameworkless, so it can be compared across the framework boundary and a
    /// `Color` table cannot.
    private func ring() -> NSColor {
        mode.isVisual
            ? Slate.Native.accent.withAlphaComponent(Slate.Opacity.accentRing)
            : Slate.Native.Line.subtle
    }

    /// Belt-and-suspenders Escape dismiss. The primary exit is the renderer's `keyDown` →
    /// `exitCopyMode()` once the terminal is first responder (the routing nudges focus there on arm);
    /// this is the net for the case where Esc lands in the PILL's chain instead — a click on the `×`
    /// leaves focus here — and it leaves through the SAME `onExit` seam the `×` fires.
    ///
    /// `cancelOperation(_:)` is AppKit's spelling of what the phone spells ``View/slateCancelKey(perform:)``: AppKit routes Esc AND ⌘. up the responder chain, so this fires from
    /// anywhere at or below the pill without anyone tapping the event stream. Installing a local
    /// monitor here would be a second reader of the same key, and is banned in this directory.
    override func cancelOperation(_: Any?) {
        onExit()
    }
}

// MARK: - The key-hint card

/// The vi key-hint card — the on-demand reference toggled by `⌘/` while in vi mode (off by default;
/// ``TerminalViewModel/showViKeyHints`` drives its visibility, flipped by
/// ``TerminalViewModel/toggleViKeyHints()``). Floats along the pane BOTTOM and lists, in compact
/// columns, the keys slopdesk's copy-mode ACTUALLY wires.
///
/// Pure presentation: no model reads, no state beyond the rung it last settled on — every row comes
/// from ``ViKeyHintPresentation``, and every column is built once in `init` because the tables are
/// constants. That is also what makes the measurement cheap: the three widths are taken once, which
/// is what `Layout.makeCache` does on the other side.
@MainActor
final class MacViKeyHintBar: NSView {
    /// THE PROPOSAL. The width the mounter can spare for the card, INCLUDING this view's own
    /// horizontal padding — the AppKit stand-in for the `ProposedViewSize` a `Layout` is handed.
    ///
    /// It defaults to infinity for the same reason `sizeThatFits` reads an UNSPECIFIED width as
    /// infinite: an un-proposed card reports its widest arrangement, which is what makes a parent
    /// that has room give it room. A mounter that never sets this gets the three-column card, which
    /// is the right answer for every pane wide enough to hold it and a visibly-too-wide one
    /// otherwise — never a silently clipped card.
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

    private let slots = NSStackView()
    private let columns: [ViKeyHintColumn: MacViKeyHintColumnView]
    /// Each column's INTRINSIC width, measured once. The tables are constants, so this cannot go
    /// stale — and re-measuring inside `layout()` would ask a column that is currently sitting in a
    /// stretched slot how wide it wants to be, which is a different question.
    private let columnWidths: [ViKeyHintColumn: CGFloat]
    private var rung: ViKeyHintLayout?

    /// Every key chip the card advertises — the honesty surface, forwarded so a test and the snapshot
    /// rig keep ONE address for it across both renderers.
    static var advertisedKeys: [String] { ViKeyHintPresentation.advertisedKeys }

    override init(frame frameRect: NSRect) {
        var built: [ViKeyHintColumn: MacViKeyHintColumnView] = [:]
        var widths: [ViKeyHintColumn: CGFloat] = [:]
        for column in ViKeyHintColumn.allCases {
            let view = MacViKeyHintColumnView(column: column)
            built[column] = view
            // `fittingSize` is the minimum size the column's own constraints admit — the widest row,
            // its chips, its gaps and its label together. That is exactly what
            // `sizeThatFits(.unspecified)` returns on the other side, and what the ladder's
            // `columnWidth` closure is defined to mean.
            widths[column] = view.fittingSize.width
        }
        columns = built
        columnWidths = widths
        super.init(frame: frameRect)
        build()
        applyLadder()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        layer?.masksToBounds = false
        // The PANEL rung, not the chip's: this is a floating reference card, the same depth the find
        // bar sits at, and it covers terminal output rather than perching on it.
        layer?.shadowRadius = Slate.Elevation.panel.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.panel.y)
        layer?.shadowOpacity = 1

        slots.orientation = .horizontal
        // TOP, not centre: the rung that stacks SELECT over SEARCH beside MOTION only reads as two
        // columns of one card if all three headings share a baseline.
        slots.alignment = .top
        slots.spacing = Self.gap
        slots.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space2, left: Slate.Metric.space3,
            bottom: Slate.Metric.space2, right: Slate.Metric.space3,
        )
        slots.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slots)
        NSLayoutConstraint.activate([
            slots.leadingAnchor.constraint(equalTo: leadingAnchor),
            slots.trailingAnchor.constraint(equalTo: trailingAnchor),
            slots.topAnchor.constraint(equalTo: topAnchor),
            slots.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ViKeyHintPresentation.barAccessibilityLabel)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.raised.cgColor
            layer?.borderColor = Slate.Native.Line.subtle.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The width ladder

    /// Ask the ladder what the proposal affords and re-hang the columns if the answer changed.
    ///
    /// ⚠️ Measured against the width left INSIDE the card's own padding, not the proposal itself. The
    /// padding is a fixed cost at both ends, and a ladder that spent the whole proposal would keep
    /// three columns at a width that fits three columns and nothing else — which is a card whose
    /// last column is cut off by its own edge inset.
    private func applyLadder() {
        let inner = Double(availableWidth) - Double(Slate.Metric.space3) * 2
        apply(ViKeyHintPresentation.layout(
            forWidth: inner, gap: Double(Self.gap),
            columnWidth: { [columnWidths] column in Double(columnWidths[column] ?? 0) },
        ))
    }

    /// Hang the three columns in the slots the rung names.
    ///
    /// The COLUMN VIEWS are never rebuilt — only re-parented. A rung change is a re-flow, not a
    /// content change, and rebuilding would throw away the measured widths this whole ladder runs on.
    private func apply(_ next: ViKeyHintLayout) {
        guard next != rung else { return }
        rung = next
        for slot in slots.arrangedSubviews {
            slots.removeArrangedSubview(slot)
            slot.removeFromSuperview()
        }
        for group in ViKeyHintPresentation.groups(for: next) {
            let stack = NSStackView()
            stack.orientation = .vertical
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
/// Built once from ``ViKeyHintColumn`` and never mutated — which is what lets ``MacViKeyHintBar``
/// measure it a single time and re-hang it across rungs without re-deriving anything.
@MainActor
private final class MacViKeyHintColumnView: NSView {
    init(column: ViKeyHintColumn) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space1
        stack.translatesAutoresizingMaskIntoConstraints = false

        // NOT ``macCapsString(_:color:weight:)``: that recipe is the INSTRUMENT face at
        // ``Slate/Typeface/instrumentTracking``, the voice a summoned card names a region in. This
        // heading rides the PILL family — the system face at ``Slate/Typeface/pillTracking``, the
        // same tracking the mode badges above it wear — because the card floats inside the pane
        // beside them and not on a paper surface.
        let heading = NSTextField(labelWithAttributedString: NSAttributedString(
            string: column.heading,
            attributes: [
                .font: NSFont.systemFont(ofSize: Slate.Typeface.small, weight: .semibold),
                .foregroundColor: Slate.Native.Text.tertiary,
                .kern: Slate.Typeface.pillTracking,
            ],
        ))
        heading.isSelectable = false
        heading.setAccessibilityElement(false)
        stack.addArrangedSubview(heading)
        // The stack's own row rhythm PLUS the heading's bottom pad — `space1` twice, added, which is
        // what the SwiftUI half spells as a `VStack(spacing: space1)` with a `.padding(.bottom,
        // space1)` on the heading. Deliberately not written as `space2`: it is two rungs summed, not
        // one rung chosen, and it must follow `space1` if that ever moves.
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
    private static func row(_ hint: ViKeyHint) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        for key in hint.keys { stack.addArrangedSubview(keycap(key)) }

        let label = NSTextField(labelWithString: hint.label)
        label.font = .systemFont(ofSize: Slate.Typeface.small)
        label.textColor = Slate.Native.Text.secondary
        label.isSelectable = false
        label.maximumNumberOfLines = 1
        // The SwiftUI half's `.fixedSize()`, which is what makes the measured column width HONEST:
        // a row that could compress would report a narrower intrinsic width than it draws at, and
        // the ladder would then pick a rung the card does not actually fit in.
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(label)
        return stack
    }

    /// A single key chip. The RANGE token (``ViKeyHintPresentation/separator``) renders as bare text
    /// with no plate, so `1 … 9` reads as a range rather than as three keys — the one row where a
    /// member of a `keys` array is not a key.
    private static func keycap(_ key: String) -> NSView {
        guard key == ViKeyHintPresentation.separator else { return MacViKeycapView(key: key) }
        let text = NSTextField(labelWithString: key)
        text.font = .systemFont(ofSize: Slate.Typeface.small, weight: .medium)
        text.textColor = Slate.Native.Text.tertiary
        text.isSelectable = false
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        return text
    }
}

// MARK: - One key chip

/// A single key chip — the keyboard cheat sheet's `keycapChip`, so the two reference surfaces read
/// identically to anyone who has both open.
@MainActor
private final class MacViKeycapView: NSView {
    /// ⚠️ 18 is UNNAMED on the floor — the keycap's minimum square, one rung under the control plate
    /// (``Slate/Metric/plate`` is 24) and one above the glyph plate (16). It is the SECOND spelling:
    /// the SwiftUI half carries the same literal with the same ⚠️. Proposed `Slate.Metric.keycap`.
    private static let side: CGFloat = 18

    init(key: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline

        // The SYSTEM mono face, not ``Slate/Typeface/instrumentNative(_:weight:)``: the SwiftUI half
        // asks for `design: .monospaced`, and the instrument voice is the terminal's own JetBrains
        // face. A keycap is chrome standing beside a description in the system face — printing it in
        // the pane's own family would make the card read as terminal OUTPUT rather than as a legend.
        let text = NSTextField(labelWithString: key)
        text.font = .monospacedSystemFont(ofSize: Slate.Typeface.small, weight: .medium)
        text.textColor = Slate.Native.Text.secondary
        text.isSelectable = false
        text.setAccessibilityElement(false)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        // A MINIMUM square with the label centred in it, not a fixed one: `⌃d` and `↩` are wider than
        // `h`, and a chip clipped to 18pt would drop half of the two-character keys the card exists
        // to advertise. The chip hugs whichever of the two is larger.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.side),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.side),
            widthAnchor.constraint(
                greaterThanOrEqualTo: text.widthAnchor, constant: Slate.Metric.space1 * 2,
            ),
            heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor),
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.face.cgColor
            layer?.borderColor = Slate.Native.Line.subtle.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
