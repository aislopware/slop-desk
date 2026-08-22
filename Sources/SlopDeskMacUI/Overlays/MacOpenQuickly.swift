// MacOpenQuickly — the ⌘⇧O / ⌘J picker, in AppKit.
//
// The seventh surface off the shared SwiftUI floor (docs/56 stage D) and the LAST modal one. When
// this card moved, `OverlayHostView`'s `draws` ledger emptied and the shared host stopped being
// mounted on macOS at all.
//
// It is the palette's shape with three things added, and each of them is a decision this file has to
// answer for in `NSView` terms:
//
//   1. A PILL RING between the query and the list. The pills are a filter, not a mode: the query
//      survives a pill change, so switching from ALL to FOLDERS narrows what you are already
//      searching rather than starting again.
//   2. A TWO-LEVEL LIST under the ALL pill — a caps header per non-empty source over its rows —
//      flattened into one column, because the headers are headings rather than containers and a
//      folded-away source then costs exactly the rows it hides.
//   3. A ⌘K ACTION SHEET on the selected row: a second searchable list, anchored at the row it is
//      about, that owns the keyboard while it is up.
//
// That last one is where AppKit and SwiftUI genuinely part. The phone draws it as a `.popover`; this
// half draws it as a plate INSIDE the card, and not for taste — a popover is its own window, the
// filter field inside it has to be first responder to be typed into, and a popover hung off a
// `.nonactivatingPanel` does not reliably take key. An inline plate is in a window that is already
// key, so its field focuses, its Esc is ours to route, and the anchor is a constraint rather than a
// beak.
//
// What it does not own is anything the picker IS. ``OpenQuicklyModel`` builds and ranks every source,
// ``OpenQuicklyPresentation`` measures the card, flattens the list, words the zero state and the
// footer, and ``OpenQuicklyActions`` is the whole verb table — the one ↩ runs and the one ⌘K opens.
// ``HoverSelectionGate`` arbitrates hover against keyboard nav; ``FuzzyMatcher/runs(of:ranges:)``
// cuts the fzf mark. Every one of them is in `SlopDeskClientCore` and read by both halves.

import AppKit
import SlopDeskClientCore
import SlopDeskProtocol // MetadataClient — the Agents source's host RPC
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The card

@MainActor
final class MacOpenQuicklyView: NSView, NSTextFieldDelegate {
    private let store: WorkspaceStore
    private let coordinator: OverlayCoordinator
    private let folders: FolderFrecencyStore?

    private let magnifier = NSImageView()
    private let field = NSTextField()
    private let topRule = MacCardRuleView()
    private let pillTray = NSStackView()
    private var pills: [OpenQuicklyFilter: MacOpenQuicklyPillView] = [:]
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let bottomRule = MacCardRuleView()
    private let footer = NSStackView()
    private let runHint = MacFooterHintView(label: "", glyph: "↩")
    private let sheet: MacOpenQuicklyActionsView

    /// The query. Mirrored off the field rather than read from it on every access, so the honest
    /// zero-state line and the ranking see the same string within one keystroke.
    private var query = ""
    /// The keyboard-selected row, indexed into the SELECTABLE rows (headers excluded).
    private var selection = 0
    /// Hover→selection arbiter: a hover-driven selection must not auto-scroll, and a list scrolling
    /// under a PARKED pointer must not steal the selection. One per presentation, shared by the rows.
    private let hoverGate = HoverSelectionGate()
    /// The focused pane's Jump-To rows, snapshotted ONCE on the way in — running the link detector
    /// over a whole scrollback is not per-keystroke work.
    private var currentJumpItems: [JumpToItem] = []
    /// The Agents rows, loaded async off the focused pane's host metadata RPC.
    private var agentItems: [OpenQuicklyItem] = []
    private var agentsLoading = false
    /// The in-flight Agents fetch, cancelled and replaced when what it depends on moves — so a stale
    /// list can never land late over a current one.
    private var agentLoad: Task<Void, Never>?
    private var agentLoadKey: AgentLoadKey?

    /// The rows currently in the column, in draw order.
    private var rows: [MacOpenQuicklyRowView] = []
    /// The height the results took at the last render, so the panel is only re-sized when it moved.
    private var resultsHeight: Double = 0
    private var scrollHeight: NSLayoutConstraint?
    /// The sheet's distance from the card's top edge, driven by the row it is about.
    private var sheetTop: NSLayoutConstraint?
    private var sheetHeight: NSLayoutConstraint?

    /// Told the card's wanted size whenever the results change height.
    var onResize: (NSSize) -> Void = { _ in }

    init(store: WorkspaceStore, coordinator: OverlayCoordinator, folders: FolderFrecencyStore?) {
        self.store = store
        self.coordinator = coordinator
        self.folders = folders
        sheet = MacOpenQuicklyActionsView()
        super.init(frame: .zero)

        buildSearchLine()
        buildPills()
        buildResults()
        buildFooter()
        buildSheet()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func buildSearchLine() {
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = Slate.Native.Overlay.secondary
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.body, weight: .regular,
        )

        // No bezel and no background: the CARD is the surface, and a plate drawn inside it would read
        // as an input sunk into paper rather than as the card's own first line.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Overlay.primary
        field.placeholderString = OpenQuicklyPresentation.searchPrompt
        field.delegate = self

        for view in [magnifier, field, topRule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            magnifier.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space2,
            ),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.heightAnchor.constraint(equalToConstant: Slate.Metric.heightInput),

            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: field.bottomAnchor),
            topRule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),
        ])
    }

    private func buildPills() {
        pillTray.orientation = .horizontal
        pillTray.spacing = Slate.Metric.space2
        pillTray.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space2, left: Slate.Metric.space3,
            bottom: Slate.Metric.space2, right: Slate.Metric.space3,
        )
        pillTray.translatesAutoresizingMaskIntoConstraints = false
        for filter in OpenQuicklyFilter.pickerPills {
            let pill = MacOpenQuicklyPillView(filter)
            pill.onPick = { [weak self] in self?.pick(filter) }
            pills[filter] = pill
            // Leading gravity for all six: the ring reads left-to-right and the empty space to its
            // right is what a trailing `Spacer` was.
            pillTray.addView(pill, in: .leading)
        }
        addSubview(pillTray)
        NSLayoutConstraint.activate([
            pillTray.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillTray.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillTray.topAnchor.constraint(equalTo: topRule.bottomAnchor),
        ])
    }

    private func buildResults() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        // The rows must not touch the card's rim — a row clipped flush against it reads as a
        // rendering fault rather than as "there is more below".
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space2,
            bottom: Slate.Metric.space1, right: Slate.Metric.space2,
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = column
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // Pinned to the CLIP view's width so the rows lay out at the card's width and the scrolling
        // is vertical only — a document view free in both axes scrolls sideways instead.
        column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight = height
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pillTray.bottomAnchor),
            height,
        ])
    }

    private func buildFooter() {
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Slate.Metric.space2
        footer.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space4, bottom: 0, right: Slate.Metric.space4,
        )
        footer.translatesAutoresizingMaskIntoConstraints = false
        // Quick Select on the left, the ↩ verb and ⌘K on the right — the two gravities are what the
        // `Spacer` between them was.
        footer.addView(
            MacFooterHintView(
                label: OpenQuicklyPresentation.quickSelectHint,
                glyph: OpenQuicklyPresentation.quickSelectGlyph,
            ),
            in: .leading,
        )
        footer.addView(runHint, in: .trailing)
        footer.addView(
            MacFooterHintView(
                label: OpenQuicklyPresentation.actionsHint,
                glyph: OpenQuicklyPresentation.actionsGlyph,
            ),
            in: .trailing,
        )

        bottomRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomRule)
        addSubview(footer)
        NSLayoutConstraint.activate([
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottomRule.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func buildSheet() {
        sheet.isHidden = true
        sheet.translatesAutoresizingMaskIntoConstraints = false
        sheet.onClose = { [weak self] in self?.setActions(visible: false) }
        sheet.onRun = { [weak self] action in
            action.run()
            self?.coordinator.closeOpenQuickly()
        }
        sheet.onRefilter = { [weak self] in self?.refillSheet() }
        addSubview(sheet)
        let top = sheet.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        let height = sheet.heightAnchor.constraint(equalToConstant: 0)
        sheetTop = top
        sheetHeight = height
        NSLayoutConstraint.activate([
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            sheet.widthAnchor.constraint(equalToConstant: OpenQuicklyMetrics.actionsWidth),
            top,
            height,
        ])
    }

    // MARK: Presentation

    /// Snapshots the focused pane, gives the field the keyboard and draws the first list. Called once
    /// the panel is on screen — a field cannot become first responder in a window that is not key.
    func begin() {
        snapshotCurrent()
        window?.makeFirstResponder(field)
        render()
    }

    /// Draws the current state, and re-arms itself on everything it read.
    ///
    /// The `onChange` handler fires BEFORE the value it announces is stored, so the next render is
    /// scheduled rather than run — reading inside the callback would answer with the old value.
    private func render() {
        withObservationTracking {
            draw()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.render() }
            }
        }
    }

    private func draw() {
        let filter = coordinator.openQuicklyFilter
        for (pilled, pill) in pills { pill.setActive(pilled == filter) }
        refreshAgents(filter: filter)
        let built = sections(filter: filter)
        selectableRows = OpenQuicklyModel.selectable(built)
        let entries = OpenQuicklyPresentation.displayEntries(built, filter: filter)
        drawRows(entries, selectable: selectableRows)
        runHint.relabel(
            OpenQuicklyPresentation.defaultActionLabel(for: selectedItem(in: selectableRows)?.kind),
        )
        fitToResults()
        revealSelection(entries)
    }

    private func drawRows(_ entries: [OpenQuicklyDisplayEntry], selectable: [OpenQuicklyItem]) {
        var lines: [MacOpenQuicklyRowView.Line] = entries.map { entry in
            switch entry.kind {
            case let .header(filter): .header(filter)
            case let .row(item, index): .row(item, selectableIndex: index)
            }
        }
        if selectable.isEmpty {
            lines = [.empty(OpenQuicklyPresentation.emptyMessage(
                query: query, filter: coordinator.openQuicklyFilter, agentsLoading: agentsLoading,
            ))]
        }
        if rows.count != lines.count {
            for row in rows {
                column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = lines.map { _ in
                let row = MacOpenQuicklyRowView(gate: hoverGate)
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: column.widthAnchor, constant: -Slate.Metric.space2 * 2,
                ).isActive = true
                return row
            }
        }
        for (row, line) in zip(rows, lines) {
            row.show(
                line,
                query: query,
                selection: selection,
                onRun: { [weak self] item in self?.act(item) },
                onHover: { [weak self] index in self?.select(index) },
            )
        }
    }

    /// Tells the panel the height the results want, capped at the viewport's ceiling.
    private func fitToResults() {
        column.layoutSubtreeIfNeeded()
        let wanted = Swift.min(column.fittingSize.height, OpenQuicklyMetrics.resultsMaxHeight)
        guard wanted != resultsHeight else { return }
        resultsHeight = wanted
        scrollHeight?.constant = wanted
        pillTray.layoutSubtreeIfNeeded()
        onResize(NSSize(
            width: OpenQuicklyMetrics.panelWidth,
            height: Slate.Metric.heightInput + Slate.Metric.hairline * 2
                + pillTray.fittingSize.height + wanted + Slate.Metric.heightRow,
        ))
    }

    /// Scrolls the selected row into view — for KEYBOARD navigation only.
    ///
    /// A hover-driven selection must not scroll, or the list follows the mouse: hover selects → the
    /// scroll slides a new row under the pointer → hover selects that one → forever.
    private func revealSelection(_ entries: [OpenQuicklyDisplayEntry]) {
        guard hoverGate.shouldAutoScrollOnSelectionChange() else { return }
        guard let index = entries.firstIndex(where: {
            if case let .row(_, selectableIndex) = $0.kind { return selectableIndex == selection }
            return false
        }), rows.indices.contains(index) else { return }
        let row = rows[index]
        column.layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }

    // MARK: The sources

    /// The picker's corpora, ranked and sectioned for the active pill. Both the per-pane fact read and
    /// the five-source assembly are ``OpenQuicklySources``', below either shell — this half only says
    /// which pill and which query, and holds what came back.
    private func sections(filter: OpenQuicklyFilter) -> [OpenQuicklySection] {
        OpenQuicklySources.sections(
            store: store, folders: folders, agents: agentItems, current: currentJumpItems,
            filter: filter, query: query,
        )
    }

    /// The rows the keyboard can land on, as the LAST ``draw()`` built them.
    ///
    /// ⚠️ HELD, not re-derived, and the correctness argument is the stronger half of the reason.
    /// ``sections(filter:)`` walks every session, tab and pane (one ``TreeWorkspace/spec(for:)`` per
    /// pane, which is itself a tree walk), re-ranks the whole folder frecency history and runs five
    /// fuzzy passes — and ``draw()`` used to run it TWICE, once for the entries and once through a
    /// `selectableRows(filter:)` that threw the sections away. `move`, `moveToEnd`, `setActions`,
    /// `actSelected` and the ⌘-digit quick pick each ran a THIRD, so one arrow key cost three full
    /// rebuilds of the corpus.
    ///
    /// A held list is also the only one that can be right: a clamp or a quick pick resolved against a
    /// freshly-derived corpus is answering about rows the user is not looking at, because the drawn
    /// list is whatever the last `draw()` produced. Every re-derivation site now reads what was drawn.
    private var selectableRows: [OpenQuicklyItem] = []

    private func selectedItem(in rows: [OpenQuicklyItem]) -> OpenQuicklyItem? {
        guard selection >= 0, selection < rows.count else { return nil }
        return rows[selection]
    }

    // MARK: Focused-pane resolution

    private var activePane: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    /// The focused pane's terminal model — the actuator's write target — or `nil` when no live
    /// terminal pane is focused.
    private var activeModel: TerminalViewModel? {
        guard let id = activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.terminalModel
    }

    /// The focused pane's host metadata façade (the Agents source), or `nil` while disconnected —
    /// the same per-pane channel the Details panel reads.
    private var activeMetadataClient: MetadataClient? {
        guard let id = activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient
    }

    /// The focused pane's working directory — the Agents project scope, and how a relative detected
    /// path in the Current snapshot resolves. Empty reads as none.
    private var activeCwd: String? {
        guard let id = activePane, let cwd = store.paneCwd(for: id), !cwd.isEmpty else { return nil }
        return cwd
    }

    // MARK: Current snapshot + the Agents fetch

    /// Snapshot the focused pane into ``currentJumpItems`` ONCE on the way in. The snapshot itself is
    /// ``OpenQuicklySources/currentItems(model:cwd:)``'s, below both halves — it was these same
    /// eighteen lines here and in the phone's picker, detector gate and `BlockSummary` mapping
    /// included, and the cross-target clone rule is what found it rather than a reader.
    private func snapshotCurrent() {
        currentJumpItems = OpenQuicklySources.currentItems(model: activeModel, cwd: activeCwd)
    }

    /// What the Agents fetch depends on: whether a pill surfaces Agents at all, the focused pane, and
    /// its (re)connected metadata façade.
    private struct AgentLoadKey: Equatable {
        let showsAgents: Bool
        let pane: PaneID?
        let client: ObjectIdentifier?
    }

    /// Re-fires the fetch when its key moves, and only then.
    ///
    /// The old task is CANCELLED first, which is the whole point of keying it: without that, a pane
    /// switch mid-flight lets the previous pane's agent list land over the current pane's.
    private func refreshAgents(filter: OpenQuicklyFilter) {
        let key = AgentLoadKey(
            showsAgents: filter == .all || filter == .agents,
            pane: activePane,
            client: activeMetadataClient.map { ObjectIdentifier($0) },
        )
        guard key != agentLoadKey else { return }
        agentLoadKey = key
        agentLoad?.cancel()
        guard key.showsAgents else { return }
        guard let client = activeMetadataClient else {
            agentItems = []
            agentsLoading = false
            return
        }
        agentsLoading = true
        let project = activeCwd ?? ""
        agentLoad = Task { [weak self] in
            let sessions = await client.listAgentSessions(project: project)
            guard !Task.isCancelled, let self else { return }
            agentItems = OpenQuicklyModel.agentItems(from: sessions)
            agentsLoading = false
            draw()
        }
    }

    // MARK: The keyboard

    func controlTextDidChange(_ note: Notification) {
        // The action sheet's own field is a second `NSTextField` with this view as its delegate's
        // neighbour — but it delegates to the sheet, so anything arriving here is the query's.
        guard (note.object as? NSTextField) === field else { return }
        query = field.stringValue
        // A new query re-ranks the list, so the old selection means nothing — and an action sheet
        // about a row that may not survive the keystroke has to go with it.
        selection = 0
        setActions(visible: false)
        draw()
    }

    /// Navigation reaches a FOCUSED FIELD as an editing command rather than as a key press — the
    /// field editor is first responder for the card's whole life, because it has to be or typing
    /// would stop reaching the query.
    ///
    /// ⌃P/⌃N cost nothing: the text system already binds them to `moveUp:`/`moveDown:`, which is why
    /// those are the keys a terminal user's fingers know.
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        // ⇞/⇟ inside a field routes to the SCROLLING pair rather than the moving one, and which of
        // the two arrives depends on whether the field editor itself can scroll — so both spellings
        // are taken, and both mean "one viewport of rows".
        case #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.scrollPageUp(_:)):
            move(-pageStride)
        case #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.scrollPageDown(_:)):
            move(pageStride)
        // Home/End. The DOCUMENT pair, not the LINE pair: ⌘←/⌘→ send `moveToBeginningOfLine:` and
        // belong to the query's caret, which is why the palette leaves them alone — but Home/End in
        // a one-line field have nowhere of their own to go, so the list takes them.
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)),
             #selector(NSResponder.moveToBeginningOfDocument(_:)):
            moveToEnd(first: true)
        case #selector(NSResponder.scrollToEndOfDocument(_:)),
             #selector(NSResponder.moveToEndOfDocument(_:)):
            moveToEnd(first: false)
        case #selector(NSResponder.insertTab(_:)):
            pick(OpenQuicklyModel.nextFilter(coordinator.openQuicklyFilter))
        case #selector(NSResponder.insertBacktab(_:)):
            pick(OpenQuicklyModel.prevFilter(coordinator.openQuicklyFilter))
        case #selector(NSResponder.insertNewline(_:)):
            actSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            coordinator.closeOpenQuickly()
        default:
            return false
        }
        return true
    }

    /// The ⌘ table. A command-modified key never reaches the field editor's `doCommandBy:` — AppKit
    /// offers it to the responder chain as a key EQUIVALENT first — so this is where ⌘1–9, ⌘K and the
    /// pill chords are read.
    ///
    /// While the action sheet is up it owns the keyboard, and the picker's ⌘ chords are its business
    /// rather than the sheet's, so they are refused rather than fired behind it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), sheet.isHidden else { return false }
        guard let character = event.charactersIgnoringModifiers?.first,
              let chord = OpenQuicklyPresentation.commandChord(character)
        else { return false }
        switch chord {
        case let .quickPick(digit):
            let rows = selectableRows
            if let index = OpenQuicklyModel.quickPickIndex(digit, in: rows) { act(rows[index]) }
        case .toggleActions:
            setActions(visible: sheet.isHidden)
        case let .selectPill(filter):
            pick(filter)
        }
        return true
    }

    /// One ⇞/⇟ stride, from the same two numbers that size the viewport.
    private var pageStride: Int {
        OpenQuicklyMetrics.pageStride(rowHeight: Slate.Metric.heightRowTall)
    }

    private func move(_ delta: Int) {
        select(ListNavigation.clampedSelection(
            current: selection, delta: delta, count: selectableRows.count,
        ))
    }

    private func moveToEnd(first: Bool) {
        let count = selectableRows.count
        select(ListNavigation.clampedSelection(
            current: 0, delta: first ? 0 : count - 1, count: count,
        ))
    }

    private func select(_ index: Int) {
        guard index != selection else { return }
        selection = index
        // The sheet is about the row that WAS selected; moving off it closes it rather than leaving
        // a menu pointing at a row the keyboard has left.
        setActions(visible: false)
        draw()
    }

    private func pick(_ filter: OpenQuicklyFilter) {
        coordinator.setOpenQuicklyFilter(filter)
        selection = 0
        setActions(visible: false)
        draw()
    }

    // MARK: The action sheet

    private func setActions(visible: Bool) {
        guard visible else {
            // Idempotent: closing an already-closed sheet must not steal the keyboard back from
            // whatever has it, because every selection change calls this on the way past.
            guard !sheet.isHidden else { return }
            sheet.isHidden = true
            window?.makeFirstResponder(field)
            return
        }
        guard let item = selectedItem(in: selectableRows) else { return }
        sheet.isHidden = false
        sheet.begin(
            OpenQuicklyActions.rowActions(
                for: item, store: store, model: activeModel, folders: folders,
            ),
        )
        anchorSheet()
        window?.makeFirstResponder(sheet.filterField)
    }

    /// Re-cuts the sheet's list after its filter narrowed, and re-fits its height to what is left.
    private func refillSheet() {
        anchorSheet()
    }

    /// Pins the sheet's top edge to the row it is about, clamped inside the card.
    ///
    /// The anchor is what makes it a MENU rather than a second list: a plate that opened in the
    /// card's middle would say nothing about which row it belonged to.
    private func anchorSheet() {
        layoutSubtreeIfNeeded()
        let wanted = Swift.min(sheet.fittingSize.height, OpenQuicklyMetrics.resultsMaxHeight)
        sheetHeight?.constant = wanted
        let rowTop: Double
        if let index = rows.firstIndex(where: \.isSelectedRow) {
            let frame = rows[index].convert(rows[index].bounds, to: self)
            rowTop = bounds.height - frame.maxY
        } else {
            rowTop = Slate.Metric.heightInput
        }
        let ceiling = Swift.max(
            Slate.Metric.space2, bounds.height - wanted - Slate.Metric.heightRow,
        )
        sheetTop?.constant = Swift.min(Swift.max(rowTop, Slate.Metric.space2), ceiling)
    }

    /// A click on the card's own body — the gap beside a row, the pill bar's air — closes an open
    /// sheet, which is the gesture a popover's own light dismissal would have been.
    override func mouseDown(with _: NSEvent) {
        setActions(visible: false)
    }

    // MARK: Acting

    private func actSelected() {
        guard let item = selectedItem(in: selectableRows) else { return }
        act(item)
    }

    private func act(_ item: OpenQuicklyItem) {
        OpenQuicklyActions.runDefault(item, store: store, model: activeModel)
        coordinator.closeOpenQuickly()
    }
}

// MARK: - One filter pill

/// A capsule in the filter ring: FILLED with the reading ink when it is the active one, OUTLINED in
/// the supporting ink when it is not.
///
/// The active pill is a plate rather than an accent, for the house reason — a list marks importance
/// with light and weight, and one blue capsule on a monochrome card is the rule's counter-example.
@MainActor
final class MacOpenQuicklyPillView: NSView {
    var onPick: () -> Void = {}

    private let label: NSTextField
    private var active = false

    override var wantsUpdateLayer: Bool { true }

    init(_ filter: OpenQuicklyFilter) {
        label = NSTextField(labelWithString: filter.label)
        label.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        label.isSelectable = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        toolTip = filter.emptyMessage
        setAccessibilityLabel(filter.label)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        needsDisplay = true
    }

    /// A capsule is a rectangle whose radius is half its height, and the height is a constraint — so
    /// the radius is set where the height is KNOWN rather than where it was asked for.
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = active
                ? Slate.Native.Overlay.plate.cgColor : NSColor.clear.cgColor
            layer?.borderColor = active
                ? NSColor.clear.cgColor : Slate.Native.Overlay.hairline.cgColor
            label.textColor = active
                ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) { onPick() }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - One footer hint

/// What a key does, then the key as a CAP. The glyph used to be a bare tinted plate with no edge —
/// which is what a badge looks like, not what a key looks like.
@MainActor
final class MacFooterHintView: NSView {
    private let text: NSTextField
    private let cap: MacKeycapView

    init(label: String, glyph: String) {
        text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: Slate.Typeface.small)
        text.textColor = Slate.Native.Overlay.tertiary
        text.isSelectable = false
        cap = MacKeycapView(label: glyph)
        super.init(frame: .zero)

        for view in [text, cap] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            cap.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: Slate.Metric.space1),
            cap.trailingAnchor.constraint(equalTo: trailingAnchor),
            cap.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        cap.relabel(glyph, lit: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The ↩ hint's verb is the SELECTED ROW's, so it re-cuts as the keyboard walks the list.
    func relabel(_ label: String) {
        guard text.stringValue != label else { return }
        text.stringValue = label
    }
}

// MARK: - One row

/// A section header, a result row, or the zero state — three shapes down one column, so the view
/// that draws them is one rather than three that would each be rebuilt as the list changed kind.
@MainActor
final class MacOpenQuicklyRowView: NSView {
    enum Line {
        case header(OpenQuicklyFilter)
        case row(OpenQuicklyItem, selectableIndex: Int)
        case empty(String)
    }

    private let gate: HoverSelectionGate
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let stamp = NSTextField(labelWithString: "")
    private let badge = MacRowBadgeView()

    private let content = NSStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var item: OpenQuicklyItem?
    private var selectableIndex: Int?
    private var selected = false
    private var onRun: (OpenQuicklyItem) -> Void = { _ in }
    private var onHover: (Int) -> Void = { _ in }

    /// Whether the keyboard is sitting on this row — read by the card to anchor the ⌘K sheet.
    var isSelectedRow: Bool { selected }

    override var wantsUpdateLayer: Bool { true }

    init(gate: HoverSelectionGate) {
        self.gate = gate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.cardBorderWidth

        symbol.imageScaling = .scaleNone
        symbol.contentTintColor = Slate.Native.Overlay.secondary
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .regular,
        )

        // Middle-truncated: a squeezed title keeps its head AND its leaf, which between two panes in
        // sibling directories is the only part that tells them apart.
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.isSelectable = false
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.maximumNumberOfLines = 1
        subtitle.isSelectable = false
        subtitle.font = .systemFont(ofSize: Slate.Typeface.footnote)
        subtitle.textColor = Slate.Native.Overlay.tertiary
        subtitle.alignment = .right
        stamp.font = .monospacedDigitSystemFont(ofSize: Slate.Typeface.small, weight: .regular)
        stamp.textColor = Slate.Native.Overlay.tertiary
        stamp.isSelectable = false

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space2
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space3, bottom: 0, right: Slate.Metric.space3,
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [symbol, title] as [NSView] { content.addView(view, in: .leading) }
        for view in [subtitle, stamp, badge] as [NSView] { content.addView(view, in: .trailing) }
        addSubview(content)

        // The title yields first: a truncated title is still the row you recognise, while a cwd
        // truncated to nothing tells you which of two identically-named panes this is not.
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
            symbol.widthAnchor.constraint(equalToConstant: 18),
            subtitle.widthAnchor.constraint(
                lessThanOrEqualToConstant: OpenQuicklyMetrics.subtitleMaxWidth,
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(
        _ line: Line,
        query: String,
        selection: Int,
        onRun: @escaping (OpenQuicklyItem) -> Void,
        onHover: @escaping (Int) -> Void,
    ) {
        self.onRun = onRun
        self.onHover = onHover
        switch line {
        case let .header(filter): showHeader(filter)
        case let .row(item, index): showRow(item, index: index, query: query, selection: selection)
        case let .empty(message): showEmpty(message)
        }
        needsDisplay = true
    }

    private func showHeader(_ filter: OpenQuicklyFilter) {
        item = nil
        selectableIndex = nil
        selected = false
        // The gutter STAYS, emptied rather than hidden: it is what lands the caps label at the exact
        // x of a row title, and a stack view hides by removing from the layout.
        symbol.image = nil
        for view in [subtitle, stamp, badge] as [NSView] { view.isHidden = true }
        heightConstraint?.constant = Slate.Metric.heightRow
        title.attributedStringValue = macCapsString(
            filter.sectionHeader, color: Slate.Native.Overlay.tertiary,
        )
        setAccessibilityLabel(filter.sectionHeader)
    }

    private func showRow(
        _ item: OpenQuicklyItem, index: Int, query: String, selection: Int,
    ) {
        self.item = item
        selectableIndex = index
        selected = index == selection
        symbol.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        heightConstraint?.constant = Slate.Metric.heightRowTall
        title.attributedStringValue = Self.marked(item.title, query: query, selected: selected)

        let place = item.subtitle ?? ""
        subtitle.isHidden = place.isEmpty
        if !place.isEmpty { subtitle.stringValue = place }
        // The relative stamp is re-read on every draw rather than stored: "2m ago" is only true for
        // a minute, and the list re-cuts on every keystroke anyway.
        if let timestamp = item.timestamp {
            stamp.isHidden = false
            stamp.stringValue = OutlinePresentation.relativeTime(from: timestamp, now: Date())
        } else {
            stamp.isHidden = true
        }
        badge.isHidden = false
        badge.show(item.badge)
        setAccessibilityLabel(item.title)
    }

    private func showEmpty(_ message: String) {
        item = nil
        selectableIndex = nil
        selected = false
        symbol.image = nil
        for view in [subtitle, stamp, badge] as [NSView] { view.isHidden = true }
        heightConstraint?.constant = Slate.Metric.heightRowTall
        title.attributedStringValue = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: Slate.Typeface.body),
                .foregroundColor: Slate.Native.Overlay.tertiary,
            ],
        )
        setAccessibilityLabel(message)
    }

    /// The fzf mark, as CONTRAST rather than colour: the run the query hit keeps the reading ink a
    /// weight up while the letters around it step back, so a hit reads as LIT.
    ///
    /// The cut itself is ``FuzzyMatcher/runs(of:ranges:)`` — four surfaces mark an fzf hit and all
    /// four want the same cut and their own ink. Every run goes through the nerd-aware splice so a
    /// program title's private-use glyph draws from the bundled symbols face inside the hit too.
    ///
    /// The haystack the ranking searched is the item's `searchText` (a folder matches on its whole
    /// path) while the mark is applied over the visible `title` — so a path-only match draws flat,
    /// which is honest: nothing the user can see was hit.
    private static func marked(
        _ title: String, query: String, selected: Bool,
    ) -> NSAttributedString {
        let base = NSFont.systemFont(
            ofSize: Slate.Typeface.body, weight: selected ? .medium : .regular,
        )
        let hit = NSFont.systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranges = trimmed.isEmpty ? [] : FuzzyMatcher.score(trimmed, title)?.ranges ?? []
        let runs = FuzzyMatcher.runs(of: title, ranges: ranges)
        guard runs.count > 1 else {
            return .slateNerdAware(title, font: base, color: Slate.Native.Overlay.primary)
        }
        let spliced = NSMutableAttributedString()
        for run in runs {
            spliced.append(.slateNerdAware(
                run.text,
                font: run.matched ? hit : base,
                color: run.matched ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary,
            ))
        }
        return spliced
    }

    // MARK: The plate

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

    /// Hover moves the keyboard's selection onto this row — but only on genuine pointer MOVEMENT. A
    /// keyboard scroll slides a new row under a parked pointer and AppKit re-fires the entry for it;
    /// admitting that would yank the selection straight back to wherever the mouse was left.
    override func mouseEntered(with _: NSEvent) {
        guard let selectableIndex, gate.admitHover(at: NSEvent.mouseLocation) else { return }
        guard !selected else { return }
        gate.noteHoverDrivenSelection()
        onHover(selectableIndex)
    }

    /// The row IS the click target — a target laid OVER a row is topmost for the pointer and eats
    /// the hover underneath it.
    override func mouseDown(with _: NSEvent) {
        guard let item else { return }
        onRun(item)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - The row's kind badge

/// The little `TAB` / `FOLDER` / `AGENT` plate on a row's trailing edge — what KIND of thing this row
/// is, in one word, so a merged ALL list stays readable without six icons to learn.
@MainActor
final class MacRowBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous

        label.font = .systemFont(ofSize: Slate.Typeface.small, weight: .medium)
        label.textColor = Slate.Native.Overlay.secondary
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space1),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ text: String) { label.stringValue = text }

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

// MARK: - The ⌘K action sheet

/// The selected row's verbs, as a searchable plate anchored at the row.
///
/// It owns the keyboard while it is up — its filter field is first responder — and its Esc closes
/// only ITSELF, never the picker behind it: a menu that dismissed the whole card would make ⌘K a
/// gamble.
@MainActor
final class MacOpenQuicklyActionsView: NSView, NSTextFieldDelegate {
    /// The filter field, handed out so the card can give it the keyboard on the way in.
    let filterField = NSTextField()

    var onRun: (LinkActionActuator.RowAction) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Fired after the filter narrowed the list, so the card can re-fit and re-anchor the plate.
    var onRefilter: () -> Void = {}

    private let magnifier = NSImageView()
    private let rule = MacCardRuleView()
    private let column = NSStackView()
    private var rows: [MacOpenQuicklyActionRowView] = []

    /// The full table for the current row, and the highlight into its FILTERED view.
    private var table: [LinkActionActuator.RowAction] = []
    private var filtered: [LinkActionActuator.RowAction] = []
    private var highlight = 0

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusCard
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        layer?.masksToBounds = false
        // A plate INSIDE a card still has to lift off it, and the only thing that separates two
        // cream surfaces at the same radius is the shadow.
        layer?.shadowRadius = Slate.Elevation.palette.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.palette.y)
        layer?.shadowOpacity = 1

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = Slate.Native.Overlay.secondary
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .regular,
        )
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.font = .systemFont(ofSize: Slate.Typeface.body)
        filterField.textColor = Slate.Native.Overlay.primary
        filterField.placeholderString = OpenQuicklyPresentation.actionsPrompt
        filterField.delegate = self

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space1, left: Slate.Metric.space1,
            bottom: Slate.Metric.space1, right: Slate.Metric.space1,
        )

        for view in [magnifier, filterField, rule, column] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            magnifier.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            filterField.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: Slate.Metric.space2,
            ),
            filterField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space3,
            ),
            filterField.topAnchor.constraint(equalTo: topAnchor),
            filterField.heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: filterField.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),

            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: rule.bottomAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Opens the sheet on `actions` with a blank filter and the first verb highlighted.
    func begin(_ actions: [LinkActionActuator.RowAction]) {
        table = actions
        filterField.stringValue = ""
        highlight = 0
        refilter()
    }

    private func refilter() {
        filtered = OpenQuicklyModel.rankActions(
            table, query: filterField.stringValue, title: { $0.title },
        )
        if rows.count != Swift.max(filtered.count, 1) {
            for row in rows {
                column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = (0..<Swift.max(filtered.count, 1)).map { _ in
                let row = MacOpenQuicklyActionRowView()
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: column.widthAnchor, constant: -Slate.Metric.space1 * 2,
                ).isActive = true
                return row
            }
        }
        if filtered.isEmpty {
            rows[0].showEmpty(OpenQuicklyPresentation.noActionsMessage)
        } else {
            for (index, row) in rows.enumerated() {
                row.show(
                    filtered[index],
                    highlighted: index == highlight,
                    onRun: { [weak self] action in self?.onRun(action) },
                    onHover: { [weak self] in self?.setHighlight(index) },
                )
            }
        }
        onRefilter()
    }

    private func setHighlight(_ index: Int) {
        guard index != highlight else { return }
        highlight = index
        for (position, row) in rows.enumerated() { row.setHighlighted(position == index) }
    }

    func controlTextDidChange(_: Notification) {
        // A narrowed list has no memory of where the highlight was — the verb it sat on may be gone.
        highlight = 0
        refilter()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            setHighlight(ListNavigation.clampedSelection(
                current: highlight, delta: -1, count: filtered.count,
            ))
        case #selector(NSResponder.moveDown(_:)):
            setHighlight(ListNavigation.clampedSelection(
                current: highlight, delta: 1, count: filtered.count,
            ))
        case #selector(NSResponder.insertNewline(_:)):
            // Out of range is a NO-OP rather than a clamp: the filter may have narrowed past where
            // the highlight was, and running "whatever is nearest" is not what ↩ was asked for.
            guard highlight >= 0, highlight < filtered.count else { return true }
            onRun(filtered[highlight])
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
        default:
            return false
        }
        return true
    }

    /// The plate swallows its own clicks, or a click on the gap between two verbs would fall through
    /// to the card behind and close the sheet the user was reaching into.
    override func mouseDown(with _: NSEvent) {}

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.well.cgColor
            layer?.borderColor = Slate.Native.Overlay.hairline.cgColor
            layer?.shadowColor = Slate.Native.State.overlayShadow.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - One verb

@MainActor
final class MacOpenQuicklyActionRowView: NSView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let content = NSStackView()

    private var action: LinkActionActuator.RowAction?
    private var highlighted = false
    private var onRun: (LinkActionActuator.RowAction) -> Void = { _ in }
    private var onHover: () -> Void = {}

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous

        symbol.imageScaling = .scaleNone
        symbol.contentTintColor = Slate.Native.Overlay.primary
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Slate.Typeface.footnote, weight: .regular,
        )
        title.font = .systemFont(ofSize: Slate.Typeface.body)
        title.textColor = Slate.Native.Overlay.primary
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.isSelectable = false

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Slate.Metric.space2
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: Slate.Metric.space2, bottom: 0, right: Slate.Metric.space2,
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [symbol, title] as [NSView] { content.addView(view, in: .leading) }
        addSubview(content)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(
        _ action: LinkActionActuator.RowAction,
        highlighted: Bool,
        onRun: @escaping (LinkActionActuator.RowAction) -> Void,
        onHover: @escaping () -> Void,
    ) {
        self.action = action
        self.onRun = onRun
        self.onHover = onHover
        self.highlighted = highlighted
        symbol.isHidden = false
        symbol.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        title.stringValue = action.title
        title.textColor = Slate.Native.Overlay.primary
        setAccessibilityLabel(action.title)
        needsDisplay = true
    }

    func showEmpty(_ message: String) {
        action = nil
        highlighted = false
        symbol.isHidden = true
        title.stringValue = message
        title.textColor = Slate.Native.Overlay.tertiary
        setAccessibilityLabel(message)
        needsDisplay = true
    }

    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = highlighted
                ? Slate.Native.Overlay.plate.cgColor : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        guard action != nil else { return }
        onHover()
    }

    override func mouseDown(with _: NSEvent) {
        guard let action else { return }
        onRun(action)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
