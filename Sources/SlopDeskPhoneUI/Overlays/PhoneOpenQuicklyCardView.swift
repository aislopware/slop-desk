// PhoneOpenQuicklyCardView — the phone's ⌘⇧O / ⌘J multi-source picker, in UIKit (docs/62 stage F).
//
// The UIKit half of the deleted `OpenQuicklyView`: a pre-focused query bar, the filter pill ring
// (All / Opened / Recent / Folders / Agents / Current — SSH absent by product decision), a sectioned and
// fuzzy-ranked result list, a per-row ⌘K action page, and a footer hint rail. ⌘⇧O opens on ALL; ⌘J opens
// on CURRENT, which is the Jump-To scope folded into the same picker.
//
// NOTHING HERE RE-DERIVES WHAT THE PICKER IS. The five sources are assembled by ``OpenQuicklySources``,
// ranked and sectioned by ``OpenQuicklyModel``, flattened into draw order — headers and the flat
// selectable index the keyboard counts by, paired — by ``OpenQuicklyPresentation/displayEntries(_:filter:)``,
// worded by the same enum's zero states and footer hints, and every verb, the default one included, is
// ``OpenQuicklyActions``'. `slopdesk-invariants` fails the build if either shell grows its own copy of the
// verb table, and it should: a table written twice does not fail loudly when it drifts, it just quietly
// offers one surface a verb the other has not got.
//
// ⚠️ THE ⌘K ACTIONS ARE A PAGE, NOT A POPOVER, and that is the shell's constraint rather than a taste.
// A `UIPopoverPresentationController` needs a presenting VIEW CONTROLLER, and this card is a plain view
// inside ``PhoneOverlayLayerView`` — the layer that exists precisely because UIKit DROPS a second
// `present(_:animated:)` silently while one is up, which is why the clipboard questions are an in-window
// layer too. So the action set takes the card over: same paper, same rim, its own filter field, and Esc
// comes back. It is also the better touch shape — a popover anchored to a row on a phone is a sheet
// wearing an arrow.
//
// ⚠️ NO HOVER-SELECT, where the deleted card had an arbiter for it (``HoverSelectionGate``). Its whole
// job was to stop a keyboard `scrollTo` sliding a row under a PARKED pointer and stealing the selection
// back to the mouse — a hazard that needs a pointer that rests, and the phone's does not exist while the
// finger is off the glass. ``PhonePaletteCardView`` dropped it first, for the same reason, and two
// surfaces in one cluster disagreeing about it would be worse than either answer.
//
// ⚠️ A HELD KEY STEPS ONCE. See ``PhonePaletteCardView/keyCommands`` — the repeat whitelist merges into
// `rust/slopdesk-workspace::key_repeat` (docs/62 §7 item 1) rather than being ported, and a private
// repeat clock here is exactly the parallel policy that merge exists to end.

#if os(iOS)
import Foundation
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class PhoneOpenQuicklyCardView: UIView {
    private let store: WorkspaceStore
    private let overlay: OverlayCoordinator

    private let search = SlateSearchBarView(prompt: OpenQuicklyPresentation.searchPrompt)
    private let pills: [OpenQuicklyFilter: PhoneOpenQuicklyPillButton]
    private let table = UITableView(frame: .zero, style: .plain)
    private let footer = PhoneOpenQuicklyFooterView()
    /// The viewport's height, re-solved from the row ladder on every draw — see ``resize()``. `lazy`
    /// rather than an implicitly-unwrapped optional, for the reason ``PhonePaletteCardView``'s twin
    /// states: minted from a stored view, but never absent.
    private lazy var tableHeight = table.heightAnchor.constraint(equalToConstant: .zero)
    /// The ⌘K page while it is up. Its presence is also what silences this card's own chords.
    private var actions: PhoneOpenQuicklyActionsView?

    /// The query text. A MIRROR of the field, because every derivation below needs it and reading it
    /// back off the responder mid-layout is how a field and its list disagree.
    private var query = ""
    /// The keyboard cursor, an index into ``rows``.
    private var selection = 0
    /// The flattened list in draw order, and the selectable rows the keyboard counts by. Both fall out
    /// of ONE `sections` build — see ``refresh()`` on why that matters more here than it reads.
    private var lines: [Line] = []
    private var rows: [OpenQuicklyItem] = []
    /// The focused pane's Jump-To rows, snapshotted ONCE on the way in: detecting over a whole scrollback
    /// is not per-keystroke work.
    private var current: [JumpToItem] = []
    /// The Agents rows (Claude-only), fetched from the host's metadata RPC.
    private var agents: [OpenQuicklyItem] = []
    private var agentsLoading = false
    /// The one in-flight Agents fetch. A LATCH rather than a stored `Task` — see ``reloadAgents()``.
    private let agentsLatch = DeadlineLatch()
    /// What the last Agents fetch was made FOR. A key that has not moved does not re-fetch.
    private var agentsKey: AgentLoadKey?
    /// The pill the last apply drew, so a store change does not reset the cursor the way a pill change
    /// must.
    private var drawnFilter: OpenQuicklyFilter?
    private var hasBegun = false

    /// One line of the list. Headers and rows are interleaved and the keyboard counts only the rows,
    /// which is exactly the pairing ``OpenQuicklyDisplayEntry`` carries — this enum is that value with
    /// the id dropped, because a table addresses by index.
    enum Line {
        case header(OpenQuicklyFilter)
        case row(OpenQuicklyItem, index: Int)
        case empty(String)
    }

    init(store: WorkspaceStore, overlay: OverlayCoordinator) {
        self.store = store
        self.overlay = overlay
        // Minted from a LOCAL: a class initialiser may not read `self` before `super.init`, and the tray
        // below needs the pills already made.
        var made: [OpenQuicklyFilter: PhoneOpenQuicklyPillButton] = [:]
        for filter in OpenQuicklyFilter.pickerPills {
            made[filter] = PhoneOpenQuicklyPillButton(filter)
        }
        pills = made
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        SlatePaperCardSurface.layoutShadow(of: self)
    }

    // MARK: - Building

    private func build() {
        SlatePaperCardSurface.apply(to: self)
        // A summoned card is modal to a reader too: everything under it is behind, and the paper itself
        // is not an element in front of its own content.
        accessibilityViewIsModal = true

        search.onTextChange = { [weak self] text in
            guard let self else { return }
            query = text
            // A new query is a new list: the cursor goes to the top and a ⌘K page opened against a row
            // that may not survive the keystroke closes with it.
            selection = 0
            closeActions()
            refresh()
        }
        // ↩ runs the cursor's row — the field's own submit, so a single Return can never double-fire
        // against a `UIKeyCommand` for the same key.
        search.onSubmit = { [weak self] in self?.act(self?.selectedItem) }

        let tray = UIStackView()
        tray.axis = .horizontal
        tray.spacing = Slate.Metric.space2
        tray.alignment = .center
        for filter in OpenQuicklyFilter.pickerPills {
            guard let pill = pills[filter] else { continue }
            pill.onTap = { [weak self] in self?.select(filter) }
            tray.addArrangedSubview(pill)
        }
        // A trailing spacer, so the ring stays LEFT of a wide card rather than spreading across it.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tray.addArrangedSubview(spacer)
        tray.isLayoutMarginsRelativeArrangement = true
        tray.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Slate.Metric.space2, leading: Slate.Metric.space3,
            bottom: Slate.Metric.space2, trailing: Slate.Metric.space3,
        )
        // The ring scrolls when six pills will not fit the width — an iPhone in portrait is narrower
        // than the six labels, and a pill the user cannot reach is a filter that does not exist.
        let ring = UIScrollView()
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.showsHorizontalScrollIndicator = false
        ring.addSubview(tray)
        tray.translatesAutoresizingMaskIntoConstraints = false

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        // No chrome inside the card — the family's rule. The two rules this card DOES draw are earned:
        // the list scrolls under the query bar and over the footer rail.
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        // ⚠️ THE KEYBOARD MUST NOT GO AWAY ON A SCROLL: the query field is this surface's whole input,
        // and a keyboard dismissed by a flick would have to be summoned again by tapping the field.
        table.keyboardDismissMode = .none
        table.register(
            PhoneOpenQuicklyRowCell.self, forCellReuseIdentifier: PhoneOpenQuicklyRowCell.reuseID,
        )
        table.register(
            PhoneOpenQuicklyNoticeCell.self,
            forCellReuseIdentifier: PhoneOpenQuicklyNoticeCell.reuseID,
        )
        table.contentInset = UIEdgeInsets(
            top: Slate.Metric.space1, left: 0, bottom: Slate.Metric.space1, right: 0,
        )

        let column = UIStackView(arrangedSubviews: [
            search, SlateCardSeparatorView(frame: .zero), ring, table,
            SlateCardSeparatorView(frame: .zero), footer,
        ])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // The viewport stops at ``OpenQuicklyMetrics/resultsMaxHeight``; past that the LIST scrolls
        // instead of the card growing to the height of the window. Below it the card hugs its rows, so a
        // two-result query is a small card rather than a tall one with empty paper under it.
        tableHeight.isActive = true

        NSLayoutConstraint.activate(column.slateEdges(of: self))
        NSLayoutConstraint.activate(tray.slateEdges(of: ring))
        NSLayoutConstraint.activate([
            // The ring takes its height from the pills and never stretches — a scroll view has no
            // intrinsic size of its own, so this is what stops it eating the list's space.
            tray.heightAnchor.constraint(equalTo: ring.heightAnchor),
        ])
    }

    // MARK: - Coming up, and going away

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            // A card taken off screen with a fetch in flight would land its answer on a dead list. The
            // cancel lives here rather than in `deinit`, where main-actor state is not ours to touch —
            // which is the same reason ``DeadlineLatch`` itself has no `deinit` cancel.
            agentsLatch.cancel()
            return
        }
        guard !hasBegun else { return }
        hasBegun = true
        current = OpenQuicklySources.currentItems(model: activeModel, cwd: activeCwd)
        follow()
        reloadAgents()
    }

    /// The one tracked read, and it is deliberately TWO properties: the pill, which the reducer owns, and
    /// the pane tree, because a pane closed behind this card must not stay in the Opened section. The
    /// sources are NOT assembled inside the block — `read` returns values and does no work, and
    /// assembling here would both rank on the observation turn and register a dependency on every
    /// property five corpora happen to touch.
    private func follow() {
        ObservationFollow.arm(
            self,
            read: { ($0.overlay.openQuicklyFilter, $0.store.tree) },
            apply: { card, _ in card.applyLive() },
        )
    }

    private func applyLive() {
        // A PILL change is a new list and resets the cursor; a store change under a standing list is not
        // the user moving, so the cursor stays where their eye is. The clamp in `refresh()` catches the
        // case where the list shrank under it.
        if drawnFilter != overlay.openQuicklyFilter {
            drawnFilter = overlay.openQuicklyFilter
            selection = 0
            closeActions()
        }
        for (filter, pill) in pills { pill.isActive = filter == overlay.openQuicklyFilter }
        reloadAgents()
        refresh()
    }

    // MARK: - The list

    /// Re-derive and re-draw.
    ///
    /// ⚠️ `sections` IS BUILT ONCE AND BOTH READINGS HANG OFF THAT ONE BUILD. It reads like a field and is
    /// a whole re-derivation: the five corpora are reassembled off the live store and then RANKED. The
    /// declarative half measured it at ~145 µs a pass and paid it TWICE per keystroke, because the
    /// selectable rows and the display entries each reached through to it independently.
    private func refresh() {
        let built = OpenQuicklySources.sections(
            store: store, folders: overlay.folders, agents: agents, current: current,
            filter: overlay.openQuicklyFilter, query: query,
        )
        rows = OpenQuicklyModel.selectable(built)
        if rows.isEmpty {
            // The honest line for the case: a typed-but-unmatched query, an Agents fetch still in
            // flight, or the source's own "nothing here yet" — WHICH of the three, in which order, is
            // the far side's.
            lines = [.empty(OpenQuicklyPresentation.emptyMessage(
                query: query, filter: overlay.openQuicklyFilter, agentsLoading: agentsLoading,
            ))]
        } else {
            lines = OpenQuicklyPresentation.displayEntries(
                built, filter: overlay.openQuicklyFilter,
            ).map { entry -> Line in
                switch entry.kind {
                case let .header(filter): Line.header(filter)
                case let .row(item, index): Line.row(item, index: index)
                }
            }
        }
        selection = ListNavigation.clampedSelection(current: selection, delta: 0, count: rows.count)
        table.reloadData()
        resize()
        // The ↩ hint is the ROW's verb, not the picker's — "Open Folder" over a folder, "Focus Pane"
        // over a pane — so it is re-read on every draw rather than set once.
        footer.defaultAction = OpenQuicklyPresentation.defaultActionLabel(for: selectedItem?.kind)
        scrollToSelection()
    }

    /// The card hugs its rows up to the viewport cap. Measured from the row LADDER rather than from
    /// `contentSize`, which is not yet valid in the same turn a reload is applied.
    private func resize() {
        let content = lines.reduce(0.0) { total, line in
            switch line {
            case .header: total + Slate.Metric.heightRow
            default: total + Slate.Metric.heightRowTall
            }
        }
        let padded = content + table.contentInset.top + table.contentInset.bottom
        tableHeight.constant = Swift.min(padded, CGFloat(OpenQuicklyMetrics.resultsMaxHeight))
    }

    /// Keeps the cursor's row on screen. A selection past the end — the query narrowed the list under it
    /// — scrolls nowhere rather than to the top.
    private func scrollToSelection() {
        guard let row = lines.firstIndex(where: { line in
            guard case let .row(_, index) = line else { return false }
            return index == selection
        }) else { return }
        table.scrollToRow(at: IndexPath(row: row, section: 0), at: .none, animated: false)
    }

    private var selectedItem: OpenQuicklyItem? { rows[safe: selection] }

    // MARK: - The pills

    private func select(_ filter: OpenQuicklyFilter) {
        // Through the REDUCER, never onto a local: ``OverlayCoordinator/openQuicklyFilter`` is what ⌘J
        // sets to open this card on CURRENT, and a card holding its own copy would show the pill the
        // chord did not pick.
        overlay.setOpenQuicklyFilter(filter)
    }

    // MARK: - Agents

    /// Identity of what an Agents fetch depends on: whether a pill surfaces them at all, the focused
    /// pane, and its (re)connected metadata façade.
    private struct AgentLoadKey: Equatable {
        let showsAgents: Bool
        let pane: PaneID?
        let client: ObjectIdentifier?
    }

    private var agentsLoadKey: AgentLoadKey {
        let filter = overlay.openQuicklyFilter
        return AgentLoadKey(
            showsAgents: filter == .all || filter == .agents,
            pane: store.tree.activeSession?.activeTab?.activePane,
            client: activeMetadataClient.map { ObjectIdentifier($0) },
        )
    }

    /// Fetch the focused pane's Claude agent sessions, but only when the key MOVED. The declarative half
    /// got that from `.task(id:)` — which cancelled the prior fetch as a side effect of the id changing —
    /// so the identity comparison is by hand here and the cancellation is the latch's.
    ///
    /// ⚠️ THE CANCEL-AND-RE-ARM IS ``DeadlineLatch``', NOT A `Task` HELD IN A PROPERTY, and that is a
    /// rule (`one-deadline-latch`) rather than a preference: the cancel-comes-first, the
    /// `Task.isCancelled` check on the far side of the wait, and the weak capture are the three details
    /// that read as noise until the one time one of them is missing. Armed at `.zero` because this is not
    /// a deadline — nothing here waits — and the latch is simply where "replace whatever was in flight"
    /// lives. The second `isCancelled` check below is mine and is NOT one of the three: it covers the
    /// suspension the RPC itself adds, which the latch cannot see.
    private func reloadAgents() {
        let key = agentsLoadKey
        guard key != agentsKey else { return }
        agentsKey = key
        agents = []
        guard key.showsAgents, let client = activeMetadataClient else {
            agentsLatch.cancel()
            agentsLoading = false
            return
        }
        agentsLoading = true
        let project = activeCwd ?? ""
        agentsLatch.arm(after: .zero) { [weak self] in
            let sessions = await client.listAgentSessions(project: project)
            guard !Task.isCancelled, let self else { return }
            // Claude-only filtering and the row minting are the model's; what is left here is landing
            // the answer.
            agents = OpenQuicklyModel.agentItems(from: sessions)
            agentsLoading = false
            refresh()
        }
    }

    // MARK: - The focused pane

    /// The focused pane's terminal model — the actuator's write target — or `nil` over a non-terminal
    /// pane, which is what a picker opened over a desktop stream should offer.
    private var activeModel: TerminalViewModel? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.terminalModel
    }

    /// The focused pane's host metadata façade (the Agents source), or `nil` while disconnected.
    private var activeMetadataClient: MetadataClient? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient
    }

    /// The focused pane's working directory — the Agents project scope, and what resolves a relative
    /// detected path in the Current snapshot.
    private var activeCwd: String? {
        guard let id = store.tree.activeSession?.activeTab?.activePane,
              let cwd = store.paneCwd(for: id), !cwd.isEmpty
        else { return nil }
        return cwd
    }

    // MARK: - Acting

    /// Run a row's DEFAULT verb, then close. WHICH verb is ``OpenQuicklyActions``' — every one routes
    /// through the shared ``LinkActionActuator`` or a store op, so a target opened from the picker and
    /// the same target opened from a renderer link take exactly the same path.
    private func act(_ item: OpenQuicklyItem?) {
        guard let item else { return }
        OpenQuicklyActions.runDefault(item, store: store, model: activeModel)
        close()
    }

    /// The ⌘K page for a row: the same table the Mac's picker opens, filtered by its own field.
    private func openActions(for item: OpenQuicklyItem) {
        guard actions == nil else { return }
        let page = PhoneOpenQuicklyActionsView(
            actions: OpenQuicklyActions.rowActions(
                for: item, store: store, model: activeModel, folders: overlay.folders,
            ),
            onRun: { [weak self] action in
                action.run()
                self?.close()
            },
            onCancel: { [weak self] in self?.closeActions() },
        )
        actions = page
        addSubview(page)
        NSLayoutConstraint.activate(page.slateEdges(of: self))
    }

    private func closeActions() {
        guard let page = actions else { return }
        actions = nil
        page.removeFromSuperview()
        // The keyboard comes back to the query field — the page took the responder with its own field,
        // and a card left with none would send the next keystroke to the workspace behind it.
        search.isTakingInput = true
    }

    private func close() { overlay.closeOpenQuickly() }

    // MARK: - The keyboard

    /// The picker-local vocabulary. ↑/↓ step, ⇞/⇟ stride a viewport, Home/End snap to the ends, Tab and
    /// ⇧Tab cycle the pills, and every ⌘-modified key the far side claims routes through ``chord(_:)``.
    ///
    /// ⚠️ EMPTY WHILE THE ⌘K PAGE IS UP. `keyCommands` are collected from the FIRST RESPONDER upwards,
    /// and the page's own field is that responder while it is open — but this card is still its ancestor,
    /// so a ⌘K or a Tab declared here would fire straight through the page at the list behind it.
    ///
    /// ⚠️ HOME AND END ARE TAKEN HERE AND NOT ON THE PALETTE, which is a real disagreement between two
    /// cards in one cluster rather than an oversight. The palette leaves them to the caret because its
    /// field is the whole surface; this picker's spec (`open-quickly.png`, "Jump through list |
    /// PageUp / PageDown, Home / End") puts them on the LIST, and the deleted card took them.
    override var keyCommands: [UIKeyCommand]? {
        guard actions == nil else { return [] }
        return [
            command(UIKeyCommand.inputUpArrow, #selector(stepUp)),
            command(UIKeyCommand.inputDownArrow, #selector(stepDown)),
            command(UIKeyCommand.inputPageUp, #selector(pageUp)),
            command(UIKeyCommand.inputPageDown, #selector(pageDown)),
            command(UIKeyCommand.inputHome, #selector(jumpToFirst)),
            command(UIKeyCommand.inputEnd, #selector(jumpToLast)),
            command("\t", #selector(nextPill)),
            command("\t", #selector(previousPill), .shift),
            .slateCancel(action: #selector(cancel)),
        ] + Self.chordInputs.map { command($0, #selector(chord), .command) }
    }

    /// ⚠️ `wantsPriorityOverSystemBehavior` IS THE WHOLE POINT. The query field is the first responder,
    /// and UIKit spends an arrow on its caret — and a Tab on its own focus move — before a command on an
    /// ancestor ever sees it.
    private func command(
        _ input: String, _ action: Selector, _ modifiers: UIKeyModifierFlags = [],
    ) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// WHICH ⌘-keys the picker claims is not a list kept here: the alphabet is OFFERED to
    /// ``OpenQuicklyPresentation/commandChord(_:)`` once, and what comes back non-`nil` is what gets a
    /// command. A verb added to the far side's table appears here without this file being told, and one
    /// removed stops being registered — which is the same guarantee the shared table buys everywhere
    /// else, spent on the registration rather than only on the dispatch.
    private static let chordInputs: [String] = "0123456789abcdefghijklmnopqrstuvwxyz"
        .filter { OpenQuicklyPresentation.commandChord($0) != nil }
        .map(String.init)

    @objc
    private func chord(_ sender: UIKeyCommand) {
        guard let character = sender.input?.first,
              let chord = OpenQuicklyPresentation.commandChord(character)
        else { return }
        switch chord {
        case let .quickPick(digit):
            if let index = OpenQuicklyModel.quickPickIndex(digit, in: rows) { act(rows[index]) }
        case .toggleActions:
            if let item = selectedItem, actions == nil { openActions(for: item) } else { closeActions() }
        case let .selectPill(pill):
            select(pill)
        }
    }

    @objc
    private func stepUp() { move(-1) }
    @objc
    private func stepDown() { move(1) }
    @objc
    private func pageUp() { move(-pageStride) }
    @objc
    private func pageDown() { move(pageStride) }
    @objc
    private func jumpToFirst() { moveTo(0) }
    @objc
    private func jumpToLast() { moveTo(rows.count - 1) }
    @objc
    private func nextPill() { select(OpenQuicklyModel.nextFilter(overlay.openQuicklyFilter)) }
    @objc
    private func previousPill() { select(OpenQuicklyModel.prevFilter(overlay.openQuicklyFilter)) }

    @objc
    private func cancel() { close() }

    /// One ⇞/⇟ stride: the rows one full viewport shows, derived on the far side from the SAME number
    /// that sizes the viewport — so re-tuning the card re-tunes the page rather than leaving a stride
    /// that no longer matches what the eye just skipped.
    private var pageStride: Int {
        OpenQuicklyMetrics.pageStride(rowHeight: Double(Slate.Metric.heightRowTall))
    }

    private func move(_ delta: Int) {
        selection = ListNavigation.clampedSelection(
            current: selection, delta: delta, count: rows.count,
        )
        redrawSelection()
    }

    private func moveTo(_ index: Int) {
        selection = ListNavigation.clampedSelection(current: 0, delta: index, count: rows.count)
        redrawSelection()
    }

    /// A cursor move touches the plate on two rows and the footer's verb — never the list, which has not
    /// changed. Re-running ``refresh()`` here would re-rank five corpora to move a highlight.
    private func redrawSelection() {
        for path in table.indexPathsForVisibleRows ?? [] {
            guard case let .row(_, index) = lines[safe: path.row],
                  let cell = table.cellForRow(at: path) as? PhoneOpenQuicklyRowCell
            else { continue }
            cell.setSelected(index == selection)
        }
        footer.defaultAction = OpenQuicklyPresentation.defaultActionLabel(for: selectedItem?.kind)
        scrollToSelection()
    }
}

// MARK: - The table

extension PhoneOpenQuicklyCardView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { lines.count }

    func tableView(_ table: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        switch lines[safe: path.row] {
        case let .row(item, index):
            let cell = table.dequeueReusableCell(
                withIdentifier: PhoneOpenQuicklyRowCell.reuseID, for: path,
            )
            if let row = cell as? PhoneOpenQuicklyRowCell {
                row.show(item, query: query, selected: index == selection)
                row.onActions = { [weak self] in
                    guard let self else { return }
                    selection = index
                    redrawSelection()
                    openActions(for: item)
                }
            }
            return cell
        case let .header(filter):
            return notice(table, path, text: filter.sectionHeader, header: true)
        case let .empty(message):
            return notice(table, path, text: message, header: false)
        case .none:
            return UITableViewCell()
        }
    }

    private func notice(
        _ table: UITableView, _ path: IndexPath, text: String, header: Bool,
    ) -> UITableViewCell {
        let cell = table.dequeueReusableCell(
            withIdentifier: PhoneOpenQuicklyNoticeCell.reuseID, for: path,
        )
        (cell as? PhoneOpenQuicklyNoticeCell)?.show(text, header: header)
        return cell
    }

    func tableView(_: UITableView, heightForRowAt path: IndexPath) -> CGFloat {
        switch lines[safe: path.row] {
        case .header: Slate.Metric.heightRow
        default: Slate.Metric.heightRowTall
        }
    }

    /// A section header and the zero-state sentence are not controls and must not light under a finger.
    func tableView(_: UITableView, shouldHighlightRowAt path: IndexPath) -> Bool {
        guard case .row = lines[safe: path.row] else { return false }
        return true
    }

    func tableView(_ table: UITableView, didSelectRowAt path: IndexPath) {
        table.deselectRow(at: path, animated: false)
        guard case let .row(item, _) = lines[safe: path.row] else { return }
        act(item)
    }
}

/// Indexing a live list from a table-view callback: the delegate can be asked about a path from the frame
/// BEFORE the reload that shrank the list, and a bare subscript would trap there rather than draw nothing.
/// File-private for the reason ``PhoneGlobalSearchCardView``'s copy states.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - A filter pill

/// One filter pill: FILLED on the neutral plate with primary text when it is the active scope, OUTLINED
/// with secondary text when it is not (`open-quickly.png`).
///
/// A `UIControl` rather than a `UIButton` with a configuration, for the reason ``SlatePlateIconButton``
/// records: the two states are a fill and an ink, and a configuration handler would be a second place
/// they are decided.
@MainActor
final class PhoneOpenQuicklyPillButton: UIControl {
    var onTap: () -> Void = {}

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            reink()
        }
    }

    private let caption = UILabel()

    init(_ filter: OpenQuicklyFilter) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.borderWidth = Slate.Metric.hairline
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.text = filter.label
        caption.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        caption.isUserInteractionEnabled = false
        addSubview(caption)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        // ⚠️ A `CGColor` on a layer is RESOLVED, not dynamic — it was fixed at the appearance current
        // when it was assigned. The registration names the ONE trait this control depends on.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: Self, _: UITraitCollection) in
            pill.reink()
        }
        reink()
        isAccessibilityElement = true
        accessibilityLabel = filter.label
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A TRUE capsule — the corner follows the height rather than naming a radius, which is why this
        // control names no radius token. `.circular`, not `.continuous`: a squircle at half the height is
        // no longer a capsule.
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .circular
    }

    private func reink() {
        let traits = traitCollection
        backgroundColor = isActive ? Slate.Native.Overlay.plate : .clear
        // The active pill is a FILL and drops its edge; the resting ones are edges with no fill. Two
        // channels for one state, so the ring reads on either theme.
        layer.borderColor = isActive
            ? UIColor.clear.cgColor
            : Slate.Native.Overlay.hairline.resolvedColor(with: traits).cgColor
        caption.textColor = isActive ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary
    }

    @objc
    private func fire() { onTap() }
}

// MARK: - The footer rail

/// The closing rail: Quick Select ⌘ · <the row's own verb> ↩ · Actions ⌘K.
///
/// Every label and every glyph is ``OpenQuicklyPresentation``'s. The one that MOVES is the middle one —
/// the ↩ verb is the selected ROW's, not the picker's — which is why it is a property here rather than an
/// init parameter.
@MainActor
final class PhoneOpenQuicklyFooterView: UIView {
    var defaultAction: String = "" {
        didSet {
            guard defaultAction != oldValue else { return }
            action.text = defaultAction
        }
    }

    private let action = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(arrangedSubviews: [
            Self.hint(
                UILabel.hintLabel(OpenQuicklyPresentation.quickSelectHint),
                glyph: OpenQuicklyPresentation.quickSelectGlyph,
            ),
            Self.spacer(),
            Self.hint(action, glyph: "↩"),
            Self.hint(
                UILabel.hintLabel(OpenQuicklyPresentation.actionsHint),
                glyph: OpenQuicklyPresentation.actionsGlyph,
            ),
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        UILabel.dressHint(action)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// What the key does, then the key as a CAP. The glyph was once a bare tinted plate with no edge —
    /// which is what a badge looks like, not what a key looks like.
    private static func hint(_ label: UILabel, glyph: String) -> UIStackView {
        let pair = UIStackView(arrangedSubviews: [label, SlateKeycapView(label: glyph)])
        pair.axis = .horizontal
        pair.alignment = .center
        pair.spacing = Slate.Metric.space1
        return pair
    }

    private static func spacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
}

private extension UILabel {
    static func hintLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        dressHint(label)
        return label
    }

    static func dressHint(_ label: UILabel) {
        label.font = .systemFont(ofSize: Slate.Typeface.small)
        label.textColor = Slate.Native.Overlay.tertiary
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

// MARK: - A result row

/// One picker row: a leading kind glyph, the fuzzy-marked title, then the trailing metadata — subtitle,
/// relative stamp, type badge — and the ⋯ that opens the same action page ⌘K does.
@MainActor
final class PhoneOpenQuicklyRowCell: UITableViewCell {
    static let reuseID = "PhoneOpenQuicklyRow"

    /// The touch fallback for ⌘K. Every chord-only affordance on this phone gets one: the chord needs a
    /// hardware keyboard, and most of these screens have none.
    var onActions: () -> Void = {}

    private let plate = UIView()
    private let glyph = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let stamp = UILabel()
    private let badge = UILabel()
    private let more = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        plate.translatesAutoresizingMaskIntoConstraints = false
        SlateSelectionPlateSurface.install(on: plate)
        contentView.addSubview(plate)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.tintColor = Slate.Native.Overlay.secondary
        glyph.isAccessibilityElement = false

        title.numberOfLines = 1
        // MIDDLE truncation, because a title that ran long is usually a path and its TAIL is what names
        // the thing — a tail-truncated path is a list of identical prefixes.
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        subtitle.numberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.textAlignment = .right
        subtitle.font = .systemFont(ofSize: Slate.Typeface.footnote)
        subtitle.textColor = Slate.Native.Overlay.tertiary
        // The metadata gives way first: it is context, and the title is the answer.
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stamp.font = .monospacedDigitSystemFont(ofSize: Slate.Typeface.small, weight: .regular)
        stamp.textColor = Slate.Native.Overlay.tertiary
        stamp.setContentHuggingPriority(.required, for: .horizontal)

        badge.font = .systemFont(ofSize: Slate.Typeface.small, weight: .medium)
        badge.textColor = Slate.Native.Overlay.secondary
        badge.textAlignment = .center
        badge.backgroundColor = Slate.Native.Overlay.plate
        badge.layer.cornerRadius = Slate.Metric.radiusSmall
        badge.layer.cornerCurve = .continuous
        badge.layer.masksToBounds = true
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        more.translatesAutoresizingMaskIntoConstraints = false
        more.setImage(
            UIImage(
                systemSymbol: .ellipsisCircle,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.body),
            ),
            for: .normal,
        )
        more.tintColor = Slate.Native.Overlay.secondary
        more.accessibilityLabel = OpenQuicklyPresentation.actionsHint
        more.addTarget(self, action: #selector(fireActions), for: .touchUpInside)
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [glyph, title, subtitle, stamp, badge, more])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(row)

        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space2,
            ),
            plate.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(
                equalTo: plate.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            row.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            // A FIXED glyph slot, so titles line up down the list whatever each row's symbol measures.
            glyph.widthAnchor.constraint(equalToConstant: Slate.Metric.iconSize),
            subtitle.widthAnchor.constraint(
                lessThanOrEqualToConstant: CGFloat(OpenQuicklyMetrics.subtitleMaxWidth),
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActions = {}
    }

    func show(_ item: OpenQuicklyItem, query: String, selected: Bool) {
        glyph.image = UIImage(
            systemName: item.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )
        title.attributedText = Self.marked(item, query: query, selected: selected)
        subtitle.text = item.subtitle
        subtitle.isHidden = item.subtitle == nil
        // `nil` for a pane or a link — those carry no receive time, and an empty slot is honest where a
        // dash would be a value.
        stamp.text = item.timestamp.map { OutlinePresentation.relativeTime(from: $0, now: Date()) }
        stamp.isHidden = item.timestamp == nil
        badge.text = " \(item.badge) "
        setSelected(selected)
        isAccessibilityElement = true
        accessibilityLabel = [item.title, item.subtitle, item.badge]
            .compactMap(\.self)
            .joined(separator: ", ")
        accessibilityTraits = .button
    }

    func setSelected(_ selected: Bool) {
        SlateSelectionPlateSurface.apply(selected, to: plate)
    }

    /// The mark is CONTRAST, not colour: the matched run keeps the reading ink at semibold while the
    /// letters around it step back. WHERE the cuts fall is ``FuzzyMatcher/runs(of:ranges:)``', shared
    /// with the Mac's row and with both halves of the palette; the ink is this half's.
    ///
    /// The haystack the ranking scored may be WIDER than the title — a folder row matches on its full
    /// path — so the highlight is scored against the title alone and a path-only match draws flat. That
    /// is the deleted card's behaviour, kept: marking a run of a string the reader cannot see would put
    /// the highlight nowhere.
    private static func marked(
        _ item: OpenQuicklyItem, query: String, selected: Bool,
    ) -> NSAttributedString {
        let resting: UIFont = .systemFont(
            ofSize: Slate.Typeface.body, weight: selected ? .medium : .regular,
        )
        let lit: UIFont = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranges = trimmed.isEmpty ? [] : FuzzyMatcher.score(trimmed, item.title)?.ranges ?? []
        let runs = FuzzyMatcher.runs(of: item.title, ranges: ranges)
        guard runs.count > 1 else {
            return .slateNerdAware(item.title, font: resting, color: Slate.Native.Overlay.primary)
        }
        let spliced = NSMutableAttributedString()
        for run in runs {
            spliced.append(.slateNerdAware(
                run.text,
                font: run.matched ? lit : resting,
                color: run.matched ? Slate.Native.Overlay.primary : Slate.Native.Overlay.secondary,
            ))
        }
        return spliced
    }

    @objc
    private func fireActions() { onActions() }
}

// MARK: - A header, or the zero state

/// The two lines that are not rows: an ALL-CAPS section header, and the honest zero-state sentence.
///
/// ONE cell for both, where ``PhoneGlobalSearchRowCell`` folds all THREE of its kinds together. The split
/// falls differently here because the row above is heavy — a glyph slot, a marked title, three trailing
/// readouts and a button — and none of it is a caps label. What these two DO share is everything: one
/// line of text on a plain row, differing only in face and ink.
@MainActor
final class PhoneOpenQuicklyNoticeCell: UITableViewCell {
    static let reuseID = "PhoneOpenQuicklyNotice"

    private let caption = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.numberOfLines = 1
        contentView.addSubview(caption)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space4,
            ),
            caption.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space4,
            ),
            caption.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ text: String, header: Bool) {
        if header {
            // The caps micro-label every card's section header speaks — the instrument voice with the
            // tracking that only reaches a `UILabel` as a `.kern` attribute.
            caption.attributedText = NSAttributedString(
                string: text.uppercased(),
                attributes: [
                    .kern: Slate.Typeface.instrumentTracking,
                    .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .medium),
                    .foregroundColor: Slate.Native.Overlay.tertiary,
                ],
            )
            caption.textAlignment = .left
            accessibilityTraits = .header
        } else {
            caption.attributedText = nil
            caption.font = .systemFont(ofSize: Slate.Typeface.body)
            caption.textColor = Slate.Native.Overlay.tertiary
            caption.text = text
            caption.textAlignment = .center
            accessibilityTraits = .staticText
        }
        isAccessibilityElement = true
        accessibilityLabel = text
    }
}

// MARK: - The ⌘K page

/// The selected row's verb table, as a page over the card: a pre-focused filter field, a rule, and the
/// ranked actions under it.
///
/// The action set is itself searchable, through the SAME ranking the main list uses — which is why the
/// filter runs through ``OpenQuicklyModel/rankActions(_:query:title:)`` rather than a `contains`.
@MainActor
final class PhoneOpenQuicklyActionsView: UIView {
    private let all: [LinkActionActuator.RowAction]
    private let onRun: (LinkActionActuator.RowAction) -> Void
    private let onCancel: () -> Void

    private let search = SlateSearchBarView(prompt: OpenQuicklyPresentation.actionsPrompt)
    private let table = UITableView(frame: .zero, style: .plain)
    private var shown: [LinkActionActuator.RowAction] = []
    private var selection = 0

    init(
        actions: [LinkActionActuator.RowAction],
        onRun: @escaping (LinkActionActuator.RowAction) -> Void,
        onCancel: @escaping () -> Void,
    ) {
        all = actions
        self.onRun = onRun
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The page IS the card's paper again, not a translucent sheet over it: the rim and the cast
        // already ended the surface once, and a second one inside would read as two cards.
        SlatePaperCardSurface.apply(to: self)

        search.onTextChange = { [weak self] text in
            guard let self else { return }
            // A narrowed list invalidates the highlight — it goes back to the top rather than to
            // whatever row happens to be at the old index.
            selection = 0
            rank(text)
        }
        search.onSubmit = { [weak self] in self?.runHighlighted() }

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .none
        table.register(
            PhoneOpenQuicklyActionCell.self,
            forCellReuseIdentifier: PhoneOpenQuicklyActionCell.reuseID,
        )

        let column = UIStackView(arrangedSubviews: [
            search, SlateCardSeparatorView(frame: .zero), table,
        ])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        addSubview(column)
        NSLayoutConstraint.activate(column.slateEdges(of: self))
        rank("")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        SlatePaperCardSurface.layoutShadow(of: self)
    }

    private func rank(_ query: String) {
        shown = OpenQuicklyModel.rankActions(all, query: query, title: \.title)
        table.reloadData()
    }

    private func runHighlighted() {
        guard let action = shown[safe: selection] else { return }
        onRun(action)
    }

    /// ↑/↓ over the FILTERED list, Esc closes just this page. ↩ is the field's own submit, so a single
    /// Return never double-fires.
    override var keyCommands: [UIKeyCommand]? {
        [
            command(UIKeyCommand.inputUpArrow, #selector(stepUp)),
            command(UIKeyCommand.inputDownArrow, #selector(stepDown)),
            .slateCancel(action: #selector(cancel)),
        ]
    }

    private func command(_ input: String, _ action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc
    private func stepUp() { move(-1) }
    @objc
    private func stepDown() { move(1) }

    @objc
    private func cancel() { onCancel() }

    private func move(_ delta: Int) {
        selection = ListNavigation.clampedSelection(
            current: selection, delta: delta, count: shown.count,
        )
        for path in table.indexPathsForVisibleRows ?? [] {
            (table.cellForRow(at: path) as? PhoneOpenQuicklyActionCell)?
                .setHighlighted(path.row == selection)
        }
        guard shown.indices.contains(selection) else { return }
        table.scrollToRow(at: IndexPath(row: selection, section: 0), at: .none, animated: false)
    }
}

extension PhoneOpenQuicklyActionsView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        // ONE row when there is nothing to run — the far side's "no actions" line, standing where the
        // list would be. A page with an empty body reads as a page that failed to load.
        Swift.max(shown.count, 1)
    }

    func tableView(_ table: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = table.dequeueReusableCell(
            withIdentifier: PhoneOpenQuicklyActionCell.reuseID, for: path,
        )
        if let row = cell as? PhoneOpenQuicklyActionCell {
            if let action = shown[safe: path.row] {
                row.show(action, highlighted: path.row == selection)
            } else {
                row.showEmpty(OpenQuicklyPresentation.noActionsMessage)
            }
        }
        return cell
    }

    func tableView(_: UITableView, heightForRowAt _: IndexPath) -> CGFloat { Slate.Metric.heightRow }

    func tableView(_: UITableView, shouldHighlightRowAt path: IndexPath) -> Bool {
        shown.indices.contains(path.row)
    }

    func tableView(_ table: UITableView, didSelectRowAt path: IndexPath) {
        table.deselectRow(at: path, animated: false)
        guard let action = shown[safe: path.row] else { return }
        onRun(action)
    }
}

/// One verb: its glyph, its title, and the plate the highlight lifts it onto.
@MainActor
final class PhoneOpenQuicklyActionCell: UITableViewCell {
    static let reuseID = "PhoneOpenQuicklyAction"

    private let plate = UIView()
    private let glyph = UIImageView()
    private let caption = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        plate.translatesAutoresizingMaskIntoConstraints = false
        SlateSelectionPlateSurface.install(on: plate)
        contentView.addSubview(plate)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.tintColor = Slate.Native.Overlay.secondary
        glyph.isAccessibilityElement = false
        caption.numberOfLines = 1
        caption.font = .systemFont(ofSize: Slate.Typeface.body)
        caption.textColor = Slate.Native.Overlay.primary

        let row = UIStackView(arrangedSubviews: [glyph, caption])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(row)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space2,
            ),
            plate.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(
                lessThanOrEqualTo: plate.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            row.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Slate.Metric.iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func show(_ action: LinkActionActuator.RowAction, highlighted: Bool) {
        glyph.isHidden = false
        glyph.image = UIImage(
            systemName: action.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )
        caption.text = action.title
        caption.textColor = Slate.Native.Overlay.primary
        caption.textAlignment = .left
        setHighlighted(highlighted)
        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityTraits = .button
    }

    func showEmpty(_ message: String) {
        glyph.isHidden = true
        glyph.image = nil
        caption.text = message
        caption.textColor = Slate.Native.Overlay.tertiary
        caption.textAlignment = .left
        setHighlighted(false)
        isAccessibilityElement = true
        accessibilityLabel = message
        accessibilityTraits = .staticText
    }

    func setHighlighted(_ highlighted: Bool) {
        SlateSelectionPlateSurface.apply(highlighted, to: plate)
    }
}

#endif
