// MacPalette — the ⌘⇧P command palette, in AppKit.
//
// The fourth surface off the shared SwiftUI floor (docs/56 stage D) and the first MODAL one: the
// three before it were a summoned reference card and two readouts, and none of them had a text field
// or a list you steer. This one is the palette-family's shape entire — a pre-focused query, a ranked
// list under it, and a keyboard that drives both — so what it settles it settles for Open Quickly,
// the global search and the peek reply behind it.
//
// It rides ``MacOverlayPanelController``, so the dismiss floor, Esc and the first-responder handback
// are the panel's (see that file's header). What is here is the three things a card of this kind has
// to answer for itself:
//
//   1. THE KEYBOARD BELONGS TO THE FIELD, and the list is steered THROUGH it. The field editor is
//      first responder for the card's whole life — it has to be, or typing would stop reaching the
//      query — so every navigation key arrives as an editing COMMAND (`moveUp:`, `pageDown:`,
//      `insertNewline:`) rather than as a key press, and `control(_:textView:doCommandBy:)` is where
//      the list reads them. ⌃P/⌃N cost nothing: the macOS text system already binds them to
//      `moveUp:`/`moveDown:`, which is exactly why those are the keys every terminal user's fingers
//      know. The two chords that are NOT editing commands — ⌘↑/⌘↓ to the ends and ⌘↩ to run without
//      closing — come through `performKeyEquivalent(with:)` instead, which is the door AppKit opens
//      for a command-modified key before the responder chain sees it.
//   2. IT REDRAWS OFF OBSERVATION, not off its own edits. Typing and stepping are this view's own
//      events, but ⌘↩ RUNS a verb and keeps the card up — so the ✓ gutter of the row just toggled has
//      to flip under the pointer, and the results have to re-rank against a store that moved.
//      `withObservationTracking` re-arms on every render, so the card follows whatever it read.
//   3. IT SIZES ITSELF TO ITS RESULTS. The card is fixed-width and variable-height: a query that
//      narrows to two rows gets a two-row card, and the panel is told the new size rather than the
//      list being padded out inside a fixed one.
//
// What it does NOT own is anything a palette IS. ``PaletteMetrics`` measures the card,
// ``PalettePresentation`` pairs the ranked rows with the keyboard's index and resolves the WORKING
// DIRECTORY badge, ``HoverSelectionGate`` arbitrates hover against keyboard nav, and
// ``OverlayCoordinator`` owns the query, the ranking, the selection and the running — every one of
// them in `SlopDeskClientCore`, and every one of them already there before this file existed.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate + the nerd-font splice — the ONE ladder, in its native view
import SlopDeskWorkspaceCore

// MARK: - The card

/// The palette card's content: a search line, the card's one internal rule, and the ranked list.
@MainActor
final class MacPaletteView: NSView, NSTextFieldDelegate {
    private let coordinator: OverlayCoordinator
    private let store: WorkspaceStore
    private let toggledState: @MainActor (PaletteItem) -> Bool

    private let field = NSTextField()
    private let magnifier = NSImageView()
    private let rule = MacCardRuleView()
    private let scroll = NSScrollView()
    private let column = NSStackView()
    /// The row views currently in the column, in draw order — kept so a selection step can move the
    /// plate without rebuilding a list that did not change.
    private var rows: [MacPaletteRowView] = []
    /// The height the results took at the last render, so the panel is only re-sized when it moved.
    private var resultsHeight: Double = 0

    /// Hover→selection arbiter: a hover-driven selection must not auto-scroll, and a list scrolling
    /// under a PARKED pointer must not steal the selection. One per presentation, shared by the rows.
    private let hoverGate = HoverSelectionGate()

    /// Told the card's wanted size whenever the results change height.
    var onResize: (NSSize) -> Void = { _ in }

    init(
        coordinator: OverlayCoordinator,
        store: WorkspaceStore,
        toggledState: @escaping @MainActor (PaletteItem) -> Bool,
    ) {
        self.coordinator = coordinator
        self.store = store
        self.toggledState = toggledState
        super.init(frame: .zero)

        buildSearchLine()
        buildResults()
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            magnifier.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space2,
            ),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightInput),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: field.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func buildSearchLine() {
        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil,
        )
        magnifier.contentTintColor = Slate.Native.Overlay.secondary
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.body, weight: .regular,
        )
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        addSubview(magnifier)

        // A field with no bezel and no background: the CARD is the surface, and a second plate drawn
        // inside it would read as an input sunk into paper rather than as the card's own first line.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Overlay.primary
        field.placeholderString = "Search for commands…"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
    }

    private func buildResults() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        // The rows must not touch the card's own edge — a row clipped flush against the rim reads as
        // a rendering fault rather than as "there is more below" — and the horizontal inset is the
        // row's OUTER one, so the selection plate stops short of the card's sides.
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space2, left: Slate.Metric.space2,
            bottom: Slate.Metric.space2, right: Slate.Metric.space2,
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = column
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // Pinned to the CLIP view's width so the rows lay out at the card's width and the scrolling
        // is vertical only — a document view left free in both axes scrolls sideways instead.
        column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    // MARK: Presentation

    /// Gives the field the keyboard and draws the first list. Called once the panel is on screen —
    /// a field cannot become first responder in a window that is not yet key.
    func begin() {
        field.stringValue = coordinator.paletteQuery
        window?.makeFirstResponder(field)
        render()
    }

    /// Draws the current state, and re-arms itself on everything it read.
    ///
    /// The `onChange` handler fires BEFORE the value it announces is stored, so the next render is
    /// scheduled rather than run — reading inside the callback would answer with the old value.
    private func render() {
        withObservationTracking {
            drawRows()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.render() }
            }
        }
    }

    private func drawRows() {
        let display = PalettePresentation.displayRows(coordinator.rankedResults)
        let badge = PalettePresentation.workingDirectoryBadge(store: store)
        if rows.count != display.count {
            for row in rows {
                column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = display.map { _ in
                let row = MacPaletteRowView(gate: hoverGate)
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: column.widthAnchor, constant: -Slate.Metric.space2 * 2,
                ).isActive = true
                return row
            }
        }
        for (row, entry) in zip(rows, display) {
            row.show(
                entry,
                selection: coordinator.paletteSelection,
                badgeText: badge,
                toggled: entry.ranked.item.isSeparator ? false : toggledState(entry.ranked.item),
                onRun: { [coordinator] item in coordinator.run(item) },
                onHover: { [coordinator] index in coordinator.paletteSelection = index },
            )
        }
        fitToResults()
        revealSelection(display)
    }

    /// Tells the panel the height the results want, capped at the viewport's ceiling.
    private func fitToResults() {
        column.layoutSubtreeIfNeeded()
        let wanted = Swift.min(column.fittingSize.height, PaletteMetrics.resultsMaxHeight)
        guard wanted != resultsHeight else { return }
        resultsHeight = wanted
        onResize(NSSize(
            width: PaletteMetrics.panelWidth,
            height: Slate.Metric.heightInput + Slate.Metric.hairline + wanted,
        ))
    }

    /// Scrolls the selected row into view — for KEYBOARD navigation only.
    ///
    /// A hover-driven selection must not scroll, or the list follows the mouse: hover selects → the
    /// scroll slides a new row under the pointer → hover selects that one → forever.
    private func revealSelection(_ display: [PaletteDisplayRow]) {
        guard hoverGate.shouldAutoScrollOnSelectionChange() else { return }
        guard let index = display.firstIndex(where: { $0.selectableIndex == coordinator.paletteSelection }),
              rows.indices.contains(index)
        else { return }
        let row = rows[index]
        column.layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }

    // MARK: The keyboard

    /// The two chords that are not editing commands.
    ///
    /// A command-modified key never reaches the field editor's `doCommandBy:` — AppKit offers it to
    /// the responder chain as a key EQUIVALENT first — so ⌘↑/⌘↓ (to the ends, the `NSTableView`
    /// standard) and ⌘↩ (run and keep the card up) are read here instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.specialKey {
        case .upArrow:
            coordinator.moveSelectionToFirst()
        case .downArrow:
            coordinator.moveSelectionToLast()
        case .carriageReturn,
             .enter:
            coordinator.acceptSelectedKeepingOpen()
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_: Notification) {
        coordinator.paletteQuery = field.stringValue
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            coordinator.moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)):
            coordinator.moveSelection(1)
        // The text system routes ⇞/⇟ inside a field to its SCROLLING pair rather than the moving one,
        // and both spellings arrive depending on whether the field editor can scroll — so both are
        // taken, and both mean "one viewport of rows" here.
        case #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.scrollPageUp(_:)):
            coordinator.moveSelection(-pageStride)
        case #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.scrollPageDown(_:)):
            coordinator.moveSelection(pageStride)
        case #selector(NSResponder.insertNewline(_:)):
            coordinator.acceptSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            coordinator.closePalette()
        default:
            // Home/End are deliberately left alone: in a focused text field they belong to the query's
            // caret, and taking them would break editing the search text.
            return false
        }
        return true
    }

    /// One ⇞/⇟ stride, from the same two numbers that size the viewport.
    private var pageStride: Int {
        PaletteMetrics.pageStride(rowHeight: Slate.Metric.heightRowTall)
    }
}

// MARK: - One row

/// One line of the list — a section header or an action row, because the two alternate down a single
/// column and a view that could only be one of them would be rebuilt every time a section began.
///
/// A header carries the WORKING DIRECTORY pill when it is the header that owns it; an action row
/// carries the ✓ gutter, the fzf-marked title, its place line and the keycap for the chord that runs
/// it without opening the palette at all.
@MainActor
final class MacPaletteRowView: NSView {
    /// The ✓ glyph, cut once: a row re-cuts on every keystroke, and asking the symbol catalogue for
    /// the same mark each time would be the one allocation on that path that is not a string.
    private static let tick = NSImage(
        systemSymbolName: "checkmark", accessibilityDescription: nil,
    )

    private let gate: HoverSelectionGate
    private let check = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = MacPaletteBadgeView()
    private let cap = MacKeycapView(label: "")

    private var item: PaletteItem?
    private var selectableIndex: Int?
    private var selected = false
    private var onRun: (PaletteItem) -> Void = { _ in }
    private var onHover: (Int) -> Void = { _ in }

    /// The row's one line of content. A STACK rather than pinned constraints, and for one reason: a
    /// row's accessories come and go — a verb has no place line, only one header carries the pill,
    /// and a chordless row has no cap — and a stack view drops a hidden arranged view out of the
    /// layout entirely, where a constraint to a hidden view keeps pulling on the row it left.
    private let content = NSStackView()
    private var heightConstraint: NSLayoutConstraint?

    init(gate: HoverSelectionGate) {
        self.gate = gate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth

        check.imageScaling = .scaleNone
        check.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .semibold,
        )
        check.contentTintColor = Slate.Native.Overlay.primary

        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.isSelectable = false
        // Head-truncated: a squeezed place line keeps its LEAF, which is the part that says which of
        // two identically-titled panes this row is.
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.maximumNumberOfLines = 1
        subtitle.isSelectable = false
        subtitle.font = .systemFont(ofSize: Slate.Typeface.small)
        subtitle.textColor = Slate.Native.Overlay.secondary

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space2
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space3, bottom: 0, right: Slate.Metric.space3,
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        // The trailing gravity is what a `Spacer` was: the cap and the pill sit on the row's right
        // edge, and the leading run takes whatever is left.
        for view in [check, title, subtitle] as [NSView] { content.addView(view, in: .leading) }
        for view in [badge, cap] as [NSView] { content.addView(view, in: .trailing) }
        addSubview(content)

        // The title yields before the place line and the cap: a shortcut with its key truncated off
        // is not a shortcut, and a truncated title is still the row you recognise.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        let height = heightAnchor.constraint(equalToConstant: Slate.Metric.heightRowTall)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The 20pt gutter is the row's leading column, and a header's caps label starts where a
            // row's title does — so headers and labels share one left margin, with the ✓ to their
            // left. A header carries no glyph, so on that row the gutter is width and nothing else.
            check.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-cuts this line for `entry`.
    func show(
        _ entry: PaletteDisplayRow,
        selection: Int,
        badgeText: String?,
        toggled: Bool,
        onRun: @escaping (PaletteItem) -> Void,
        onHover: @escaping (Int) -> Void,
    ) {
        item = entry.ranked.item
        selectableIndex = entry.selectableIndex
        self.onRun = onRun
        self.onHover = onHover
        selected = entry.selectableIndex == selection
        if entry.ranked.item.isSeparator {
            showHeader(entry.ranked.item, badgeText: badgeText)
        } else {
            showAction(entry, toggled: toggled)
        }
        needsDisplay = true
    }

    private func showHeader(_ item: PaletteItem, badgeText: String?) {
        // The gutter STAYS on a header — emptied, not hidden. It is what lands the caps label at the
        // exact x of a row title; hiding it would drop the header 20pt to the left of the rows it
        // names, and a stack view hides by removing from the layout.
        check.image = nil
        subtitle.isHidden = true
        cap.isHidden = true
        heightConstraint?.constant = Slate.Metric.heightRow
        // The caps micro-label in the instrument voice — the card NAMING a region, which a shouted
        // row in the system face at semibold did not read as.
        title.attributedStringValue = NSAttributedString(
            string: item.title.uppercased(),
            attributes: [
                .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .medium),
                .foregroundColor: Slate.Native.Overlay.tertiary,
                .kern: Slate.Typeface.instrumentTracking,
            ],
        )
        let owns = PalettePresentation.headerOwnsWorkingDirectoryBadge(item.title)
        badge.isHidden = !(owns && badgeText != nil)
        if let badgeText, owns { badge.show(badgeText) }
    }

    private func showAction(_ entry: PaletteDisplayRow, toggled: Bool) {
        let item = entry.ranked.item
        badge.isHidden = true
        heightConstraint?.constant = Slate.Metric.heightRowTall
        // The ✓ is set in the READING ink, not an accent: a checkmark already means one thing, and
        // colouring it says nothing more. Emptied rather than hidden for the reason above — an
        // untoggled row keeps its gutter, or its title would not line up with the toggled row above.
        check.image = toggled ? Self.tick : nil
        title.attributedStringValue = MacPaletteTitle.marked(entry.ranked, selected: selected)
        let place = item.subtitle ?? ""
        subtitle.isHidden = place.isEmpty
        if !place.isEmpty {
            subtitle.attributedStringValue = .slateNerdAware(
                place,
                font: .systemFont(ofSize: Slate.Typeface.small),
                color: Slate.Native.Overlay.secondary,
            )
        }
        let shortcut = item.shortcut ?? ""
        cap.isHidden = shortcut.isEmpty
        // The cap brightens WITH its row, so the eye tracks one object down the list.
        if !shortcut.isEmpty { cap.relabel(shortcut, lit: selected) }
    }

    // MARK: The plate

    override var wantsUpdateLayer: Bool { true }

    /// The selection is a lifted PLATE and a heavier title — never a colour. The house rule is that a
    /// list marks importance with light and weight, and the one accent-blue row on an otherwise
    /// monochrome card was what the rule was written against.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected
                ? Slate.Native.Overlay.plate.cgColor : NSColor.clear.cgColor
            layer?.borderColor = selected
                ? Slate.Native.Overlay.hairline.cgColor : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    /// Hover moves the keyboard's selection onto this row — but only on genuine pointer MOVEMENT.
    ///
    /// A keyboard scroll slides a new row under a parked pointer and AppKit re-fires the entry for
    /// it; admitting that would yank the selection straight back to wherever the mouse was left.
    override func mouseEntered(with _: NSEvent) {
        guard let selectableIndex, gate.admitHover(at: NSEvent.mouseLocation) else { return }
        guard !selected else { return }
        gate.noteHoverDrivenSelection()
        onHover(selectableIndex)
    }

    /// The row IS the click target — a target laid OVER a row is topmost for the pointer and eats the
    /// hover underneath it.
    override func mouseDown(with _: NSEvent) {
        guard let item, !item.isSeparator else { return }
        onRun(item)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - The working-directory pill

/// The contextual cwd pill on the header that owns it: a folder glyph and a home-abbreviated path on
/// a faint plate, head-truncated so the leaf survives a squeeze.
@MainActor
final class MacPaletteBadgeView: NSView {
    private let glyph = NSImageView()
    private let path = NSTextField(labelWithString: "")

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusControl
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.small, weight: .regular,
        )
        glyph.contentTintColor = Slate.Native.Overlay.secondary
        path.font = .systemFont(ofSize: Slate.Typeface.small)
        path.textColor = Slate.Native.Overlay.secondary
        path.lineBreakMode = .byTruncatingHead
        path.maximumNumberOfLines = 1
        path.isSelectable = false

        for view in [glyph, path] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor, constant: Slate.Metric.space1,
            ),
            path.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            path.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            path.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ text: String) { path.stringValue = text }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.plate.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The title, with what the query hit marked

/// The fzf mark, and it is CONTRAST rather than colour: the run the query matched keeps the reading
/// ink at semibold while the letters around it step back to `secondary`, so a hit reads as LIT.
///
/// It was the system accent, which put the one blue thing on an otherwise monochrome card — and the
/// one PINK thing on a machine whose accent is pink.
@MainActor
enum MacPaletteTitle {
    static func marked(_ ranked: RankedRow, selected: Bool) -> NSAttributedString {
        let title = ranked.item.title
        // The selected row's title goes one weight heavier as a whole; a matched run is heavier
        // still, so the two marks stack rather than cancelling.
        let base = NSFont.systemFont(
            ofSize: Slate.Typeface.body, weight: selected ? .medium : .regular,
        )
        let hit = NSFont.systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        guard !ranked.titleRanges.isEmpty else {
            return .slateNerdAware(title, font: base, color: Slate.Native.Overlay.primary)
        }
        let spliced = NSMutableAttributedString()
        var cursor = title.startIndex
        for range in ranked.titleRanges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                spliced.append(.slateNerdAware(
                    title[cursor..<range.lowerBound], font: base,
                    color: Slate.Native.Overlay.secondary,
                ))
            }
            spliced.append(.slateNerdAware(
                title[range], font: hit, color: Slate.Native.Overlay.primary,
            ))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            spliced.append(.slateNerdAware(
                title[cursor...], font: base, color: Slate.Native.Overlay.secondary,
            ))
        }
        return spliced
    }
}
