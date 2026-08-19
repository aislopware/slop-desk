// MacAndroidParts — the small pieces every Android surface below draws with, in AppKit
// (docs/56 stage D, increment 52b).
//
// The SwiftUI half reaches for `SlateListRow`, `SlateSectionHeader`, `SlateFactLine`,
// `SlatePlateGroup`, `SlateSearchField` and `WorkingSpinner` — shell types in
// `SlopDeskClientUI/DesignSystem`. None of them can cross: they are `View`s, and the whole point of
// the split is that a DRAWING has two implementations. What can be shared is the ladder they read,
// and it is: every number and every ink below is `Slate`'s, in its native (`NSColor`/`NSFont`)
// spelling, so the two halves cannot drift on a rung.
//
// ⚠️ THIS FILE IS A KNOWING TWIN OF `MacSimulatorParts.swift`, and the duplication is REPORTED rather
// than hidden. Increment 52b's rule is that nothing may be factored into a shared device abstraction
// with the Simulator half, because the two panels share not one byte of protocol — `scrcpy` over `adb`
// against `baguette`'s websocket, Annex-B against AVC, packed control messages against JSON envelopes
// — and a common device vocabulary would be an abstraction over a coincidence. That rule is about the
// DEVICE types. Several shells below touch no device type at all (the keyed loop, the spinner, the
// search plate, the flow grid, the plate tray, the glyph button, the two label helpers, the veil), and
// those are chrome rather than protocol: they are the honest candidates for one
// `MacDevicePanelParts.swift` once both halves have landed and their shapes have stopped moving.
// Merging them across two in-flight increments would have been merging two moving targets.
//
// WHAT IS NOT HERE. The words and the folds are ``AndroidPresentation``'s, one target down and shared
// with the phone. The two idioms this target already owns are reused rather than re-minted:
// ``MacPlateIconButton`` is the toolbar's latching plate, and ``MacPanelPlateButton`` is the stage's
// one TEXT button — its own header already names the "Try Again" this panel's stage draws with it.

import AppKit
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - The ink roles, resolved

/// One role from ``AndroidInk`` as a colour.
///
/// The half that resolves, and the reason ``AndroidInk`` exists at all: `SlopDeskSlate` DEPENDS on
/// `SlopDeskClientCore`, which sits beside `SlopDeskDevicePanels` and above nothing that could name a
/// token back — so a hue cannot descend without becoming a cycle. Five lines here, five lines on the
/// phone, and the DECISION about which run is loud is neither's.
@MainActor
enum MacAndroidInk {
    static func color(_ ink: AndroidInk) -> NSColor {
        switch ink {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        case .icon: Slate.Native.Text.icon
        // `StatusInk`, not `Status`: this rung is spent on TEXT, and the two ladders part exactly
        // there — a dot may be `systemRed` because it is a shape, a word may not.
        case .err: Slate.Native.StatusInk.err
        }
    }
}

// MARK: - `.task(id:)`, written out

/// ONE keyed task: start it when the key appears, leave it strictly alone while the key holds, cancel
/// it when the key changes or goes `nil`.
///
/// This is ``MacCodePanelSurfaces``' `keyed(_:on:run:)` rule with its dictionary taken off, because
/// every surface here owns at most one loop. AppKit has no `.task(id:)` at all, so the rule has to be
/// written somewhere; written once and shared is the difference between surfaces that agree and
/// surfaces that each got the identity check slightly wrong.
///
/// ⚠️ THE IDENTITY CHECK IS THE WHOLE THING. A holder that restarted on every observation callback
/// would re-arm the stage's veil delay several times a second against a selection that never changed,
/// which turns a 600 ms grace into a veil that never appears.
@MainActor
final class MacAndroidLoop {
    private var running: (key: String, task: Task<Void, Never>)?

    deinit { running?.task.cancel() }

    func keyed(on key: String?, run: @escaping () async -> Void) {
        guard let key else {
            cancel()
            return
        }
        if let running, running.key == key { return }
        cancel()
        running = (key, Task { await run() })
    }

    func cancel() {
        running?.task.cancel()
        running = nil
    }
}

// MARK: - Labels

/// The ENGRAVED caps micro-label (MERIDIAN L2): the section headings, the console drawer's own name.
/// Mono, semibold, widely tracked — the "engraved on the tool" register that marks taxonomy against
/// the prose rows under it.
@MainActor
func macAndroidCapsLabel(
    _ words: String, color: NSColor = Slate.Native.State.header,
    weight: NSFont.Weight = .semibold,
) -> NSTextField {
    let label = NSTextField(labelWithAttributedString: NSAttributedString(
        string: words.uppercased(),
        attributes: [
            .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: weight),
            .foregroundColor: color,
            // Wide enough to read as engraving, applied ONLY to an all-caps label.
            .kern: Slate.Typeface.instrumentTracking,
        ],
    ))
    label.isSelectable = false
    return label
}

/// A plain one-line label on a rung of the ladder.
@MainActor
func macAndroidLabel(
    _ words: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
    mono: Bool = false,
) -> NSTextField {
    let label = NSTextField(labelWithString: words)
    label.font = mono
        ? Slate.Typeface.instrumentNative(size, weight: weight)
        : .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

// MARK: - The section heading

/// A group's heading: the caps title, its shared platform version as the heading's own CAPTION, and
/// the far edge left for the group's CONTROL.
///
/// The caption sits beside the word it qualifies rather than at the panel's far edge, which at this
/// surface's width is most of a screen away from it; the far edge is where a control belongs, and that
/// distinction is the whole reason the header takes two trailing slots rather than one.
@MainActor
final class MacAndroidSectionHeader: NSStackView {
    init(_ title: String, caption: String?, accessory: NSView?) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false

        let heading = macAndroidCapsLabel(title)
        addArrangedSubview(heading)
        if let caption {
            // NOT run through the caps helper: a platform version is already `Android 15`, and
            // upper-casing it would print `ANDROID 15`. It keeps the engraved FACE — it is still
            // taxonomy, sitting beside a heading — and drops the caps and the tracking, which belong
            // to caps alone.
            let qualifier = macAndroidLabel(
                caption, size: Slate.Typeface.small, color: Slate.Native.Text.tertiary, mono: true,
            )
            setCustomSpacing(Slate.Metric.space2, after: heading)
            addArrangedSubview(qualifier)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addArrangedSubview(spacer)
        if let accessory { addArrangedSubview(accessory) }

        edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space2, left: Slate.Metric.space2,
            bottom: Slate.Metric.space1, right: Slate.Metric.space2,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

// MARK: - The device-family mark

/// The device family as a SHAPE, so the kind of machine is answered without reading a word.
///
/// One glyph per family and no finer — see ``AndroidDeviceKind/symbol`` for which silhouette each
/// family gets. Drawn in the ICON ink rather than the primary one: every row carries this, so at full
/// contrast a column of them is a rule down the leading edge competing with the names they exist to
/// help find.
///
/// LEADING, not centred: inside a family group every row carries the SAME silhouette, so what centring
/// would buy is nothing, while what it costs is the heading — a 13pt phone centred in a 24pt column
/// starts five points right of the caps label above it.
@MainActor
func macAndroidFamilyMark(_ device: AndroidDevice) -> NSView {
    let glyph = NSImageView(
        image: NSImage(
            systemSymbolName: AndroidDeviceKind.infer(device).symbol.rawValue,
            accessibilityDescription: nil,
        ) ?? NSImage(),
    )
    glyph.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Slate.Typeface.body, weight: .medium,
    )
    glyph.contentTintColor = MacAndroidInk.color(.icon)
    glyph.imageAlignment = .alignLeft
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.widthAnchor.constraint(equalToConstant: Slate.Metric.deviceMarkWidth).isActive = true
    return glyph
}

// MARK: - The fact line

/// The header's measured facts, middle-dot separated, each with its own tooltip and its own Copy.
///
/// The four rules the line keeps are `SlateFactLine`'s and are not restated: figures speak the
/// instrument voice, every fact is copyable on its own, the separator belongs to the LINE rather than
/// to a fact (so a fact appearing or leaving cannot strand a dangling `·`), and the label is drawn
/// rather than only hovered.
@MainActor
final class MacAndroidFactLine: NSStackView {
    init(_ facts: [AndroidFact], size: CGFloat = Slate.Typeface.footnote) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false

        for (index, fact) in facts.enumerated() {
            if index > 0 {
                addArrangedSubview(macAndroidLabel(
                    "·", size: size, color: Slate.Native.Text.tertiary,
                ))
            }
            addArrangedSubview(MacAndroidFactView(fact, size: size))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addArrangedSubview(spacer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

/// One fact: its grey label and its value, as ONE hit target — the tooltip, the Copy menu and the
/// truncation all belong to the pair, not to the word in front of it.
@MainActor
private final class MacAndroidFactView: NSStackView {
    private let copies: String
    private let title: String

    init(_ fact: AndroidFact, size: CGFloat) {
        copies = fact.copies
        title = AndroidPresentation.copyTitle(fact)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false

        if fact.showsLabel {
            let name = macAndroidLabel(
                fact.label, size: size, color: Slate.Native.Text.tertiary,
            )
            // The LABEL is what yields first when the band narrows: a truncated grey word is still a
            // hint, and a truncated figure is a wrong number.
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addArrangedSubview(name)
        }
        addArrangedSubview(macAndroidLabel(
            fact.text, size: size, color: MacAndroidInk.color(fact.ink), mono: fact.isMeasured,
        ))
        toolTip = fact.label
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The context menu is built per click rather than stored: it is one item, and an `NSMenu` held by
    /// every fact of every header is a retained object per figure on screen.
    override func menu(for _: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: #selector(copyValue), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Through the ONE funnel, never a second `NSPasteboard.general` pair — the clear-then-write is
    /// load-bearing on AppKit and ``ClientPasteboard/write(_:)`` already owns it.
    @objc
    private func copyValue() { ClientPasteboard.write(copies) }
}

// MARK: - The tray

/// Several plate controls on one tray — a single fill, a single corner, no gaps between members.
///
/// The tray is a SHAPE, and that is why it beats hairline separators: plates inside one share a fill
/// and a corner, so the stage's eight-verb rail becomes three objects and the count stops mattering.
/// Members butt against each other on purpose — a gap between two members inside a tray argues against
/// the grouping while costing the width that made it necessary.
///
/// The SwiftUI tray also RELIGHTS its members (a plate's own hover fill is the tray's fill, so inside
/// one it would vanish), carried by an environment flag. AppKit has no environment, and
/// ``MacPlateIconButton`` reads none — so its hover rung is left alone and the tray takes the fill one
/// step BELOW a member's hover instead of the same one. That is the same signal from the other side,
/// and it is the only difference between the two trays.
@MainActor
final class MacAndroidPlateTray: NSStackView {
    init(_ plates: [NSView]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Slate.Native.Overlay.well.cgColor
        for plate in plates { addArrangedSubview(plate) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.well.cgColor
        }
    }
}

// MARK: - The small glyph button

/// The list's own verb: a small solid glyph in a control-sized box, whose INK is the caller's.
///
/// Distinct from ``MacPlateIconButton``, which is the chrome's latching plate. This one never latches
/// and never grows a plate — what the pointer changes is the glyph's WEIGHT of ink, decided by the row
/// under it, because drawn at full strength on every row a dozen of these became a column of identical
/// triangles down the trailing edge, which is texture rather than twelve verbs (user-directed
/// 2026-08-04).
@MainActor
final class MacAndroidGlyphButton: NSView {
    private let glyph = NSImageView()
    private let action: () -> Void
    private let symbolName: String
    private let size: CGFloat

    var tint: NSColor { didSet { repaint() } }

    init(
        symbol: SFSymbol, help: String, size: CGFloat = Slate.Typeface.footnote,
        tint: NSColor, action: @escaping () -> Void,
    ) {
        symbolName = symbol.rawValue
        self.size = size
        self.tint = tint
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = help
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(help)
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    private func repaint() {
        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tint])),
            )
    }

    /// Fires on the UP and only inside, which is every other button on this platform's contract.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: - The spinner

/// The platform's indeterminate indicator, at the size the panel's control rung uses.
///
/// ⚠️ It animates only while it is IN A WINDOW. An AppKit spinner left running under an unmounted
/// surface is a timer nobody looks at, and these mount and unmount on every poll round.
@MainActor
final class MacAndroidSpinner: NSView {
    private let wheel = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wheel.style = .spinning
        wheel.controlSize = .small
        wheel.isIndeterminate = true
        wheel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wheel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            wheel.centerXAnchor.constraint(equalTo: centerXAnchor),
            wheel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { wheel.stopAnimation(nil) } else { wheel.startAnimation(nil) }
    }
}

// MARK: - The search plate

/// The chrome's filter input: a magnifier, the jump-free field, and a clear affordance that appears on
/// the first keystroke.
///
/// The FIELD is ``SlateNativeSearchField``'s configuration verbatim, and that is the load-bearing part
/// — at `Typeface.footnote` a stretched or bezelled field renders its text 1pt lower unfocused than
/// focused, so click-to-focus visibly bumps the line. It must never be stretched vertically; the plate
/// centres it instead.
@MainActor
final class MacAndroidSearchPlate: NSView, NSTextFieldDelegate {
    private let field: NSTextField
    private let clear = NSButton()
    private let onChange: (String) -> Void

    var query: String { field.stringValue }

    init(placeholder: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        field = SlateNativeSearchField.makeConfiguredField(text: "", delegate: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        applyPlate()

        field.placeholderString = placeholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(
            image: NSImage(
                systemSymbolName: SFSymbol.magnifyingglass.rawValue,
                accessibilityDescription: nil,
            ) ?? NSImage(),
        )
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .regular,
        )
        glyph.contentTintColor = MacAndroidInk.color(.icon)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        clear.image = NSImage(
            systemSymbolName: SFSymbol.xmarkCircleFill.rawValue,
            accessibilityDescription: nil,
        )
        clear.isBordered = false
        clear.contentTintColor = MacAndroidInk.color(.icon)
        clear.target = self
        clear.action = #selector(clearQuery)
        clear.title = ""
        clear.translatesAutoresizingMaskIntoConstraints = false
        // It appears on the FIRST keystroke and vanishes on the last, which at a field's trailing edge
        // is a glyph blinking beside the caret — so it is hidden rather than removed, and the field's
        // width never moves under the insertion point.
        clear.isHidden = true

        addSubview(glyph)
        addSubview(field)
        addSubview(clear)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor, constant: Slate.Metric.space1,
            ),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.leadingAnchor.constraint(
                equalTo: field.trailingAnchor, constant: Slate.Metric.space1,
            ),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            clear.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: Slate.Typeface.body),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Set from a menu verb rather than a keystroke — the console's "Filter by ActivityManager", which
    /// writes the field and must produce the same reading the user typing it would.
    func setQuery(_ text: String) {
        field.stringValue = text
        clear.isHidden = text.isEmpty
        onChange(text)
    }

    private func applyPlate() {
        layer?.backgroundColor = Slate.Native.State.hover.cgColor
        layer?.borderColor = Slate.Native.Line.field.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyPlate() }
    }

    @objc
    private func clearQuery() { setQuery("") }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === field else { return }
        clear.isHidden = field.stringValue.isEmpty
        onChange(field.stringValue)
    }
}

// MARK: - The empty stage

/// The stage with no picture on it: OPAQUE, on the stage's own tone rather than a dimming scrim.
///
/// A scrim says "something is on top of the picture"; there is no picture, and the truthful drawing is
/// the stage itself, empty. It stops at the header rather than covering it, which keeps the way out
/// reachable while it is up (user-directed 2026-08-04 — a load with no end and no exit was the
/// reported bug), and that is the caller's constraint rather than this view's.
@MainActor
final class MacAndroidVeil: NSView {
    init(caption: String, spinner: Bool, action: NSView?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        var stacked: [NSView] = []
        if spinner { stacked.append(MacAndroidSpinner()) }
        stacked.append(macAndroidLabel(
            caption, size: Slate.Typeface.footnote, color: MacAndroidInk.color(.secondary),
        ))
        if let action { stacked.append(action) }

        let stack = NSStackView(views: stacked)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Slate.Metric.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
    }
}

// MARK: - The row shell

/// THE list-row anatomy (MERIDIAN C2), in AppKit: an optional leading accessory, a title slot and a
/// trailing cluster, on a SINGLE fixed-height line.
///
/// One shell means one set of constants, so a row can never drift off the system — height is
/// `heightRow` always (a row never grows a second line, so the list's rhythm is a constant beat and a
/// state change swaps TEXT, not geometry), padding is horizontal `space3`, idle is transparent, hover
/// is the flat `State.hover` plate, and ACTIVE is a raised card with a hairline and no shadow (at-rest
/// depth is the surface ladder, never a cast shadow).
///
/// It is a base class rather than a container taking child views because its caller needs the live
/// hover flag to re-tint something inside it — the device row's verb steps up an ink under the
/// pointer. SwiftUI hands that down as a builder argument; here it is ``hoverChanged(_:)``.
@MainActor
class MacAndroidRowShell: NSView {
    /// The content line. Subclasses fill it; the shell owns its inset, its height and its fills.
    let content = NSStackView()

    var onTap: (() -> Void)?

    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            hoverChanged(hovering)
            fade()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusTab
        layer?.cornerCurve = .continuous

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space3,
            ),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        repaint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Overridden by a row that re-tints something under the pointer. The default does nothing, which
    /// is right for a row whose only hover signal is the shell's own fill.
    func hoverChanged(_: Bool) {}

    // NO ACTIVE STATE, and it is not an omission. The Android list has ONE depth of selection — a
    // selected device is not a lit row, it is the stage, drawn instead of the list — so a row that
    // could be `active` would be a state nothing here can ever set. The simulator's shell carries one
    // because its list keeps a selected row visible beside its stage.

    private func repaint() {
        layer?.backgroundColor = (hovering ? Slate.Native.State.hover : .clear).cgColor
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            repaint()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { repaint() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    /// Fires on the UP and only inside, which is the platform's contract for every other row on screen.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onTap?()
    }
}

// MARK: - The list's flow grid

/// The device grids: fixed-width CARDS for what is attached, width-sharing ROWS for what is not.
///
/// AppKit has no `LazyVGrid`, and the panel's whole width argument depends on one — a right panel is
/// ~700pt and a device name is ~180 of it, so one row per line put a play triangle five hundred points
/// from the name it belonged to. This is that layout: column count follows the width, so a wider panel
/// shows more devices rather than longer rows.
///
/// The two modes differ in what a column's width IS, which is the same distinction SwiftUI's
/// `.adaptive(minimum:maximum:)` draws. A CARD's content is a rectangle at the DEVICE's own aspect, so
/// its column is fixed — one attached device is one card, not a card stretched across the panel, which
/// would make the proportions the card exists to show a lie. A ROW's content is a name, and a name is
/// happy to have more room, so its columns share whatever is left over.
@MainActor
final class MacAndroidGrid: NSView {
    private let columnWidth: CGFloat
    private let isFixed: Bool
    private let spacing: CGFloat
    private let cells: [NSView]

    /// - Parameters:
    ///   - columnWidth: fixed width when `isFixed`, otherwise the MINIMUM a column may shrink to.
    init(cells: [NSView], columnWidth: CGFloat, isFixed: Bool, spacing: CGFloat) {
        self.cells = cells
        self.columnWidth = columnWidth
        self.isFixed = isFixed
        self.spacing = spacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for cell in cells {
            // ⚠️ The cells are laid out by FRAME here, so autoresizing translation goes back ON —
            // a grid child that kept `translatesAutoresizingMaskIntoConstraints = false` has its frame
            // overwritten by the constraint engine the moment anything else in the window changes.
            cell.translatesAutoresizingMaskIntoConstraints = true
            addSubview(cell)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Top-down, so the first row of cells is at the TOP of the grid rather than the bottom.
    override var isFlipped: Bool { true }

    private var columns: Int {
        guard bounds.width > 0 else { return 1 }
        return max(1, Int((bounds.width + spacing) / (columnWidth + spacing)))
    }

    /// The tallest cell in each grid line sets that line's height, so a card whose caption wrapped does
    /// not overlap the line under it.
    override func layout() {
        super.layout()
        let columns = columns
        let shared = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let width = isFixed ? columnWidth : max(columnWidth, shared)
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, cell) in cells.enumerated() {
            let column = index % columns
            if column == 0, index > 0 {
                y += lineHeight + spacing
                lineHeight = 0
            }
            let height = cell.fittingSize.height
            cell.frame = CGRect(
                x: CGFloat(column) * (width + spacing), y: y, width: width, height: height,
            )
            lineHeight = max(lineHeight, height)
        }
        gridHeight = y + lineHeight
        invalidateIntrinsicContentSize()
    }

    private var gridHeight: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: gridHeight)
    }
}
