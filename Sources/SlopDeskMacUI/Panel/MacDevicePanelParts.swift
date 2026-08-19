// MacDevicePanelParts — the shells BOTH device panels draw with, in AppKit (docs/56 stage D,
// increment 53).
//
// This file is the merge increment 52b promised and deliberately declined at the time. Both AppKit
// halves grew a `Mac*Parts.swift`, and `MacAndroidParts`' own header named the eleven shells below as
// "the honest candidates for one `MacDevicePanelParts.swift` once both halves have landed and their
// shapes have stopped moving. Merging them across two in-flight increments would have been merging two
// moving targets." They have landed; this is that file.
//
// THE LINE, and it is the same one increment 52b drew. Nothing may be factored into a shared DEVICE
// abstraction: the two panels share not one byte of protocol — `scrcpy` over `adb` against
// `baguette`'s websocket, Annex-B against AVC, packed control messages against JSON envelopes — and a
// common device vocabulary would be an abstraction over a coincidence. That rule is about DEVICE
// TYPES. Every shell here takes `String`, `NSView`, `SFSymbol` or nothing at all, and none of them can
// name a `SimulatorDevice`, an `AndroidFact` or an `AndroidInk`. **A shell with no device type in its
// signature is not a device abstraction** — it is chrome, and chrome drawn twice is the duplicate the
// one-implementation rule bans.
//
// What stayed behind is exactly what the line predicts: each half keeps its own ink resolver, its own
// family mark, its own fact line and its own fact view, because each of those four names a device type
// in its signature.
//
// THE ONE RECONCILIATION. `MacSimulatorRowShell` carried an `active` state and `MacAndroidRowShell` did
// not, and the Android file argued the omission was deliberate. It was — but it is an argument about
// its CALLER, not about the shell: `DESIGN.md`'s `list-row-active` specifies a `Surface.raised` wash
// plus a `Line.card` hairline, the simulator's shell is exactly that, and the Android list simply never
// sets it. The merged shell carries `active`; `MacAndroidDeviceRow` still never sets it, so with
// `active == false` the border resolves `.clear` and the Android list draws pixel-for-pixel what it drew
// before. The argument itself moved to `MacAndroidDeviceRow`, where it is about the thing it is about.
//
// WHAT IS NOT HERE. The words are ``SimulatorPresentation``'s and ``AndroidPresentation``'s, one target
// down and shared with the phone. The two idioms this target already owns are reused rather than
// re-minted: ``MacPlateIconButton`` is the chrome's latching plate, and ``MacPanelPlateButton`` is the
// stage's one TEXT button.

import AppKit
import SFSafeSymbols
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - `.task(id:)`, written out

/// ONE keyed task: start it when the key appears, leave it strictly alone while the key holds, cancel
/// it when the key changes or goes `nil`.
///
/// This is ``MacCodePanelSurfaces``' `keyed(_:on:run:)` rule with its dictionary taken off, because
/// every surface here owns exactly one loop. AppKit has no `.task(id:)` at all, so the rule has to be
/// written somewhere; written once and shared is the difference between surfaces that agree and
/// surfaces that each got the identity check slightly wrong.
///
/// ⚠️ THE IDENTITY CHECK IS THE WHOLE THING. A holder that restarted on every observation callback
/// would re-open the thumbnail socket several times a second for a card that never changed, or re-arm
/// the stage's veil delay and turn a 600 ms grace into a veil that never appears — both failure modes a
/// poll cannot report about itself.
@MainActor
final class MacDevicePanelLoop {
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
func macDevicePanelCapsLabel(
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
func macDevicePanelLabel(
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

/// A group's heading: the caps title, its shared platform version as the heading's own CAPTION, and the
/// far edge left for the group's CONTROL.
///
/// The caption sits beside the word it qualifies rather than at the panel's far edge, which at this
/// surface's width is most of a screen away from it; the far edge is where a control belongs, and that
/// distinction is the whole reason the header takes two trailing slots rather than one.
@MainActor
final class MacDevicePanelSectionHeader: NSStackView {
    init(_ title: String, caption: String?, accessory: NSView?) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false

        let heading = macDevicePanelCapsLabel(title)
        addArrangedSubview(heading)
        if let caption {
            // NOT run through the caps helper: a version is already `iOS 26.5` or `Android 15`, and
            // upper-casing it would print `IOS 26.5`. It keeps the engraved FACE (it is still taxonomy,
            // sitting beside a heading) and drops the caps and the tracking, which belong to caps alone.
            let qualifier = macDevicePanelLabel(
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

// MARK: - The tray

/// Several plate controls on one tray — a single fill, a single corner, no gaps between members.
///
/// The tray is a SHAPE, and that is why it beats hairline separators: plates inside one share a fill
/// and a corner, so a rail of ten becomes three objects and the count stops mattering. Members butt
/// against each other on purpose — a gap between two members inside a tray argues against the grouping
/// while costing the width that made it necessary.
///
/// The SwiftUI tray also RELIGHTS its members (a plate's own hover fill is the tray's fill, so inside
/// one it would vanish), carried by an environment flag. AppKit has no environment, and
/// ``MacPlateIconButton`` reads none — so its hover rung is left alone and the tray takes the fill one
/// step BELOW a member's hover instead of the same one. That is the same signal from the other side,
/// and it is the only difference between the two trays.
@MainActor
final class MacDevicePanelPlateTray: NSStackView {
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
/// rings down the trailing edge, which is texture rather than twelve verbs (user-directed 2026-08-04).
@MainActor
final class MacDevicePanelGlyphButton: NSView {
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
final class MacDevicePanelSpinner: NSView {
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
final class MacDevicePanelSearchPlate: NSView, NSTextFieldDelegate {
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
        glyph.contentTintColor = Slate.Native.Text.icon
        glyph.translatesAutoresizingMaskIntoConstraints = false

        clear.image = NSImage(
            systemSymbolName: SFSymbol.xmarkCircleFill.rawValue,
            accessibilityDescription: nil,
        )
        clear.isBordered = false
        clear.contentTintColor = Slate.Native.Text.icon
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
final class MacDevicePanelVeil: NSView {
    init(caption: String, spinner: Bool, action: NSView?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        var stacked: [NSView] = []
        if spinner { stacked.append(MacDevicePanelSpinner()) }
        stacked.append(macDevicePanelLabel(
            caption, size: Slate.Typeface.footnote, color: Slate.Native.Text.secondary,
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
/// depth is the surface ladder, never a cast shadow — `DESIGN.md`'s `list-row-active`).
///
/// It is a base class rather than a container taking child views because its callers need the live
/// hover flag to re-tint something inside them — the device row's verb steps up an ink under the
/// pointer, and a card's stop button does the same. SwiftUI hands that down as a builder argument;
/// here it is ``hoverChanged(_:)``.
///
/// NOT EVERY LIST USES ``active``, and a shell that offers it is not a list that must set it — see
/// ``MacAndroidDeviceRow``, which never does and is drawn correctly by the `.clear` border that falls
/// out.
@MainActor
class MacDevicePanelRowShell: NSView {
    /// The content line. Subclasses fill it; the shell owns its inset, its height and its fills.
    let content = NSStackView()

    var onTap: (() -> Void)?

    var active = false {
        didSet {
            guard active != oldValue else { return }
            fade()
        }
    }

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
        layer?.borderWidth = Slate.Metric.cardBorderWidth

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

    private func repaint() {
        let fill: NSColor =
            if active {
                Slate.Native.Surface.raised
            } else if hovering {
                Slate.Native.State.hover
            } else {
                .clear
            }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = (active ? Slate.Native.Line.card : NSColor.clear).cgColor
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

/// The device grids: fixed-width CARDS for what is running, width-sharing ROWS for what is not.
///
/// AppKit has no `LazyVGrid`, and the panel's whole width argument depends on one — a right panel is
/// ~700pt and a device name is ~180 of it, so one row per line put a play triangle five hundred points
/// from the name it belonged to. This is that layout: column count follows the width, so a wider panel
/// shows more devices rather than longer rows.
///
/// The two modes differ in what a column's width IS, which is the same distinction SwiftUI's
/// `.adaptive(minimum:maximum:)` draws. A CARD's content is a picture at a resolution the server
/// already chose, so its column is fixed — stretching it to the DEVICE's own aspect would make the
/// proportions the card exists to show a lie. A ROW's content is a name, and a name is happy to have
/// more room, so its columns share whatever is left over.
@MainActor
final class MacDevicePanelGrid: NSView {
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
