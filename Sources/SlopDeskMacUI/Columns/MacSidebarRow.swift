// MacSidebarRow — one navigator row, in AppKit.
//
// otty-bare: a title on one 32pt line and ONE trailing slot. The richness lives in the tooltip and
// the context menu, both of which are values from below (``SidebarRowReading/tooltip`` and
// ``SidebarRowMenu/entries(for:store:preventSleep:)``) rather than decisions taken here.
//
// WHAT THIS VIEW OWNS is the four things a framework has to answer for itself:
//
//   1. THE LIVE READ. The row re-resolves its own ``SidebarRowReading`` under `withObservationTracking`,
//      so a pane's status tick repaints this leaf and never the list. That is the same leaf-scope
//      contract the SwiftUI rows kept — and the reason SELECTION is read here rather than passed in:
//      a parameter-carried `active` strands the previously selected row lit.
//   2. THE HOVER SWAP. A tracking area lights the plate and swaps the trailing slot for the close ×
//      inside a fixed reserve, so the fade never reflows the title.
//   3. THE INK'S POLARITY. The selected row is stamped out of the terminal island's material, so it
//      carries the ISLAND's appearance rather than the chrome's: every semantic ink inside it then
//      resolves against the plate it actually stands on, exactly as the SwiftUI half's
//      `\\.colorScheme` override did — one line here instead of a dozen hand-flipped inks.
//   4. THE RENAME FIELD, with the resolved-once rule the Finder idiom needs: Return commits, Escape
//      cancels, a click-away commits — but the teardown's own focus loss must not re-commit what
//      Escape just cancelled.
//
// The SELECTED plate is deliberately NOT here: it belongs to the island (``MacSidebarIslandView``),
// because it TRAVELS between the rows of one project and ignites when it arrives from another.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate, StatusDot geometry, the nerd-font splice — the ONE ladder, natively
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

@MainActor
final class MacSidebarRowView: NSView, NSTextFieldDelegate {
    /// The row's STRUCTURAL identity. Everything volatile is re-read in ``refresh()``.
    private(set) var row: RailRow
    private let store: WorkspaceStore
    private let paneDrag: PaneDragCoordinator?
    /// Reads and writes the host-local prevent-sleep flag for the context menu. `nil` ⇒ the row is
    /// absent, never a dead control.
    private let preventSleep: (get: () -> Bool, set: (Bool) -> Void)?
    /// The kind's generic title, for a row whose whole title chain comes up empty.
    private let fallbackTitle: String

    private let title = NSTextField(labelWithString: "")
    private let renameField = NSTextField()
    private let slot = NSTextField(labelWithString: "")
    private let slotImage = NSImageView()
    private let mark = MacStatusMarkView()
    private let lock = NSImageView()
    private let sync = NSImageView()
    private let shortcut = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let trailing = NSStackView()

    private var hovering = false
    private var tracking: NSTrackingArea?
    private var reading: SidebarRowReading
    /// Whether the open rename was already RESOLVED by Return or Escape — so the focus-loss handler
    /// that fires when the field is torn down does not re-commit the draft (which would make Escape
    /// rename to the draft, and Return commit twice). A genuine click-away leaves it `false`.
    private var renameResolved = false

    /// Whether this row is the live pane drag's resolved destination — the accent ring.
    private var isDropTarget = false

    var onSelect: () -> Void = {}

    init(
        row: RailRow, store: WorkspaceStore, paneDrag: PaneDragCoordinator?,
        preventSleep: (get: () -> Bool, set: (Bool) -> Void)?, fallbackTitle: String,
    ) {
        self.row = row
        self.store = store
        self.paneDrag = paneDrag
        self.preventSleep = preventSleep
        self.fallbackTitle = fallbackTitle
        reading = SidebarRowPresentation.reading(
            for: row, store: store, fallbackTitle: fallbackTitle,
        )
        super.init(frame: .zero)
        build()
        apply(reading)
        track()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.islandRadiusCompact
        layer?.cornerCurve = .continuous

        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.usesSingleLineMode = true
        renameField.delegate = self
        renameField.isHidden = true
        renameField.font = .systemFont(ofSize: Slate.Typeface.base)
        renameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renameField)

        slot.lineBreakMode = .byTruncatingTail
        slot.maximumNumberOfLines = 1
        slot.setContentCompressionResistancePriority(.required, for: .horizontal)
        slotImage.imageScaling = .scaleNone
        for indicator in [lock, sync] { indicator.imageScaling = .scaleNone }

        shortcut.alignment = .right
        shortcut.font = Slate.Typeface.instrumentNative(Slate.Typeface.base, weight: .semibold)
        shortcut.setAccessibilityElement(false)

        close.isBordered = false
        close.bezelStyle = .inline
        close.imagePosition = .imageOnly
        close.title = ""
        close.target = self
        close.action = #selector(closeRow)
        close.alphaValue = 0
        close.toolTip = "Close"
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .semibold,
            ))
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 6
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailing)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightTabRow),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.islandRail),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            renameField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            renameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            renameField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.islandRail,
            ),
            trailing.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.islandRail,
            ),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            // The close × stands on the MARK's own centre line rather than flush right: a bare glyph
            // is only as wide as itself, and at 18 it hung two points left of every ring and check,
            // so the swap read as the row shifting rather than as one column changing what it holds.
            close.centerXAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.islandRail - StatusDot.footprint / 2,
            ),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: StatusDot.closeTargetSide),
            close.heightAnchor.constraint(equalToConstant: StatusDot.closeTargetSide),
        ])
    }

    // MARK: The live read

    /// Re-resolve this row against the store and repaint, re-arming the tracking for the next change.
    func refresh() {
        var next: SidebarRowReading?
        var target = false
        withObservationTracking {
            next = SidebarRowPresentation.reading(
                for: row, store: store, fallbackTitle: fallbackTitle,
            )
            target = paneDrag?.drag?.destination == .sidebarRow(row.id)
        } onChange: { [weak self] in
            // ⚠️ `onChange` fires BEFORE the store's write lands, so the next read is SCHEDULED
            // rather than run inline — a read inside the callback sees the OLD value and paints one
            // frame stale. One hop per arming: the tracking is one-shot, so this cannot pile up.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        if let next, next != reading || target != isDropTarget {
            reading = next
            isDropTarget = target
            apply(next)
        }
    }

    /// Paint one reading.
    private func apply(_ reading: SidebarRowReading) {
        // The chip is stamped out of the terminal island's material, so what stands ON it reads
        // against the ISLAND's polarity: under a dark profile the selected row's label flips light
        // instead of drawing near-black on a dark plate. One appearance, and every semantic ink
        // inside resolves itself.
        appearance = reading.active
            ? NSAppearance(named: Slate.glassColorScheme == .dark ? .darkAqua : .aqua)
            : nil
        toolTip = reading.tooltip

        title.isHidden = reading.isEditing
        trailing.isHidden = reading.isEditing
        renameField.isHidden = !reading.isEditing
        if reading.isEditing, renameField.window?.firstResponder !== renameField.currentEditor() {
            renameResolved = false
            renameField.stringValue = reading.title
            renameField.textColor = Slate.Native.Text.primary
            window?.makeFirstResponder(renameField)
        }

        title.attributedStringValue = .slateNerdAware(
            reading.agentMarker ? RailRowsBuilder.agentMarkedTitle(reading.title) : reading.title,
            font: .systemFont(ofSize: Slate.Typeface.base, weight: weight(reading.titleWeight)),
            color: ink(reading.titleInk),
        )
        title.setAccessibilityValue(reading.spokenState ?? "")
        setAccessibilityLabel(reading.title)

        rebuildTrailing(reading)
        needsDisplay = true
        updateLayer()
    }

    /// The row's INK for a title rung — the palette side of ``SidebarRowReading/titleInk``.
    private func ink(_ rung: RowTitleInk) -> NSColor {
        switch rung {
        case let .urgent(role): Slate.Native.attentionInk(role)
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        }
    }

    private func weight(_ rung: RowTitleWeight) -> NSFont.Weight {
        switch rung {
        case .resting: .regular
        case .active: .medium
        case .attention: .semibold
        }
    }

    /// The trailing cluster: the rare MODE glyphs (lock / sync) ride outside the swap slot so a mode
    /// never vanishes under hover; the slot itself holds badge-or-receipt-or-shell-label plus the
    /// status mark at rest, and the close × takes its place under the pointer.
    ///
    /// A held ⌘ replaces the WHOLE cluster with one right-aligned digit: while the hold is up the
    /// question is "what do I press", so the number stands in for every indicator rather than
    /// crowding a new column beside them. Everything returns on ⌘-up.
    private func rebuildTrailing(_ reading: SidebarRowReading) {
        for view in trailing.arrangedSubviews {
            trailing.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let hint = reading.shortcutHint {
            shortcut.stringValue = "\(hint)"
            shortcut.textColor = Slate.Native.Text.secondary
            trailing.addArrangedSubview(shortcut)
            close.alphaValue = 0
            return
        }
        if reading.readOnly {
            configure(lock, symbol: "lock.fill", ink: Slate.Native.Text.secondary)
            lock.toolTip = "Read only"
            lock.setAccessibilityLabel("Read only")
            trailing.addArrangedSubview(lock)
        }
        if reading.syncInput {
            // The FIXED sync amber, not the lock's muted tone: sync input is a fan-out mode, and its
            // rail indicator has to be as unmissable as the pane's own pill.
            configure(sync, symbol: "rectangle.3.group", ink: Slate.Native.Status.syncInput)
            sync.toolTip = "Sync input — keystrokes mirror to every pane in this tab"
            sync.setAccessibilityLabel("Sync input")
            trailing.addArrangedSubview(sync)
        }
        if let filled = slotContent(reading) {
            trailing.addArrangedSubview(filled)
        }
        trailing.addArrangedSubview(mark)
        mark.style = StatusPresentation.statusDot(
            working: reading.workingLabel != nil, badge: reading.badge,
            agentIdle: reading.agentIdle, agentFinish: reading.agentFinish,
        )
        trailing.alphaValue = hovering ? 0 : 1
        close.alphaValue = hovering ? 1 : 0
    }

    /// The slot's one occupant, in rank order: a PRIVILEGE marker (the only badge that takes the slot
    /// as art), else a finished command's RECEIPT, else the resting process label.
    private func slotContent(_ reading: SidebarRowReading) -> NSView? {
        if let badge = reading.badge, let style = StatusPresentation.tabBadge(badge) {
            return badgeView(style)
        }
        if let receipt = reading.receipt {
            // ONE answer, never two: the bare tick for a clean exit, the command's NAME in red for a
            // failure — both in the outcome's own ink, so the shorter slot is not a fainter one.
            if let symbol = StatusPresentation.outcomeSymbol(receipt.outcome) {
                configure(
                    slotImage, symbol: symbol.rawValue,
                    ink: NSColor(StatusPresentation.outcomeInk(receipt.outcome)),
                    size: StatusDot.receiptCheckSize, weight: .semibold,
                )
                slotImage.setAccessibilityElement(false)
                return slotImage
            }
            slot.stringValue = receipt.name
            slot.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .bold)
            slot.textColor = NSColor(StatusPresentation.outcomeInk(receipt.outcome))
            return slot
        }
        guard let label = reading.processLabel else { return nil }
        // A process name is DATA — the instrument mono at the caption size, on the tertiary ink at
        // rest and in the bold primary once that name is a COMMAND, which is the register it keeps
        // through its own exit.
        let isCommand = RailRowsBuilder.slotLabelIsCommand(label)
        slot.stringValue = label
        slot.font = Slate.Typeface.instrumentNative(
            Slate.Typeface.small, weight: isCommand ? .bold : .regular,
        )
        slot.textColor = NSColor(StatusPresentation.slotNameInk(isCommand: isCommand))
        return slot
    }

    /// The privilege marker — `#` or `∞`, drawn as the same artwork the SwiftUI slot mounts.
    private func badgeView(_ style: TabBadgeStyle) -> NSView {
        switch style.art {
        case let .symbol(symbol):
            configure(
                slotImage, symbol: symbol.rawValue, ink: NSColor(style.tint),
                size: StatusDot.badgeSymbolSize,
            )
            return slotImage
        case let .vector(icon):
            return MacVectorIconView(icon: icon, side: StatusDot.footprint, ink: NSColor(style.tint))
        }
    }

    private func configure(
        _ view: NSImageView, symbol: String, ink: NSColor,
        size: CGFloat = Slate.Typeface.small, weight: NSFont.Weight = .semibold,
    ) {
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink])),
            )
    }

    // MARK: Hover

    private func track() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        track()
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value, !reading.isEditing else { return }
        hovering = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            trailing.animator().alphaValue = value ? 0 : 1
            close.animator().alphaValue = value ? 1 : 0
        }
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    /// A `CALayer` holds a FLAT `CGColor`, so a dynamic ink has to be re-resolved whenever the
    /// effective appearance changes — the plate under an unselected row's hover, and the drop ring.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering && !reading.active
                ? Slate.Native.State.hover.cgColor
                : NSColor.clear.cgColor
            layer?.borderWidth = isDropTarget ? 2 : 0
            layer?.borderColor = isDropTarget ? Slate.Native.accent.cgColor : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The mouse

    override func mouseDown(with event: NSEvent) {
        guard !reading.isEditing else {
            super.mouseDown(with: event)
            return
        }
        // Selection fires on the FIRST click (never waiting out a double-click window); the second
        // click then opens the rename field on the already-selected row — the Finder idiom.
        if event.clickCount == 2 {
            store.requestRenameTab(row.tabID)
        } else {
            onSelect()
        }
    }

    @objc
    private func closeRow() { store.requestClosePaneTree(row.id) }

    // MARK: The context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for entry in SidebarRowMenu.entries(
            for: row.id, store: store, preventSleep: preventSleep?.get(),
        ) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .action(verb):
                let item = NSMenuItem(title: verb.title, action: #selector(runVerb(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = verb
                menu.addItem(item)
            case let .toggle(flag, isOn):
                let item = NSMenuItem(
                    title: flag.title, action: #selector(flipSwitch(_:)), keyEquivalent: "",
                )
                item.target = self
                item.representedObject = flag
                item.state = isOn ? .on : .off
                menu.addItem(item)
            }
        }
        _ = event
        return menu
    }

    @objc
    private func runVerb(_ sender: NSMenuItem) {
        guard let verb = sender.representedObject as? SidebarRowVerb else { return }
        SidebarRowMenu.run(verb, row: row, store: store)
    }

    @objc
    private func flipSwitch(_ sender: NSMenuItem) {
        guard let flag = sender.representedObject as? SidebarRowSwitch else { return }
        SidebarRowMenu.flip(flag, paneID: row.id, store: store) { [preventSleep] in
            guard let preventSleep else { return }
            preventSleep.set(!preventSleep.get())
        }
    }

    // MARK: The rename field

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            renameResolved = true
            commitRename(renameField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            renameResolved = true
            store.clearTabRenameRequest()
            return true
        default:
            return false
        }
    }

    /// Focus loss commits the draft — the Finder rename field's own behaviour — UNLESS Return or
    /// Escape already resolved it (the field's teardown drops focus, and re-firing here would make
    /// Escape rename to the draft and Return commit twice).
    func controlTextDidEndEditing(_: Notification) {
        guard !renameResolved else { return }
        commitRename(renameField.stringValue)
    }

    /// An UNTOUCHED draft resolves as a CANCEL: the seed is the row's LIVE title (intent / running
    /// command / generic fallback), and committing it verbatim would freeze that snapshot as a
    /// sticky `userRenamed` identity. Only an edit expresses a rename.
    private func commitRename(_ text: String) {
        if text == reading.title {
            store.clearTabRenameRequest()
        } else {
            SidebarSelection.commitRename(row.id, to: text, in: store)
        }
    }

    // MARK: The drag's drop target

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let paneDrag else { return }
        if window == nil {
            paneDrag.unregister(.sidebarRow(row.id))
        } else {
            paneDrag.register(.sidebarRow(row.id)) { [weak self] in
                guard let self, let window else { return nil }
                return window.convertToScreen(convert(bounds, to: nil))
            }
        }
    }
}

// MARK: - A vector icon, natively

/// One ``VectorIcon`` drawn at a given side in one ink — the AppKit twin of ``VectorIconView``, over
/// the SAME path data and the same parser. Only the caffeinate `∞` mug reaches it from the rail.
@MainActor
final class MacVectorIconView: NSView {
    private let icon: VectorIcon
    private let ink: NSColor

    init(icon: VectorIcon, side: CGFloat, ink: NSColor) {
        self.icon = icon
        self.ink = ink
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = CGFloat.minimum(bounds.width, bounds.height) / icon.viewBox
        for layer in icon.fills {
            context.setFillColor(ink.withAlphaComponent(layer.opacity).cgColor)
            context.addPath(SVGPath.path(layer.data, viewBox: icon.viewBox, in: bounds).cgPath)
            // ⚠️ EVEN-ODD, not the default winding: a Material duotone punches its holes with a
            // second subpath wound the SAME way as the outer one, which non-zero would fill solid.
            context.fillPath(using: .evenOdd)
        }
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(icon.strokeWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for outline in icon.outlines {
            context.addPath(SVGPath.path(outline, viewBox: icon.viewBox, in: bounds).cgPath)
            context.strokePath()
        }
    }
}
