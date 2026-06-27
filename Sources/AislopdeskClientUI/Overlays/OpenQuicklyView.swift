// OpenQuicklyView — the floating Open-Quickly picker (E11 / WI-6), the otty Xcode-style `⌘⇧O` multi-source
// quick switcher (`open-quickly.png`). It FOLDS in the E10 Jump-To panel: ONE centered, SCRIMMED card with a
// pre-focused search field, a row of filter pills (All / Opened / Recent / Folders / Agents / Current — SSH +
// Recipes are a deliberate product cut), a sectioned + fuzzy-ranked result list, a per-row `⌘K` Actions
// popover, and a context-sensitive footer hint bar. `⌘⇧O` opens it on **All**; `⌘J` opens it on **Current**
// (the Jump-To scope).
//
// SEAM discipline: every source is assembled by the PURE `OpenQuicklyModel` (headlessly tested) — Opened from
// the live `WorkspaceStore.tree`, Recent from `recentlyClosedTabs`, Folders from the injected
// `FolderFrecencyStore`, Current from the focused pane's `JumpToModel` snapshot, and Agents from the focused
// pane's host metadata RPC (`MetadataClient.listAgentSessions`, Claude-only) loaded ASYNC. Ranking runs the
// vendored `FuzzyMatcher`. Every row's default action + its `⌘K` action table actuate through the shared
// `LinkActionActuator` (the same thin platform dispatch the renderer + Jump-To use), so link/cd/host routing
// has ONE home. The active pill lives on the `OverlayCoordinator` (`openQuicklyFilter`); the search query +
// keyboard selection are local view state.
//
// Picker-LOCAL keys (handled here, NEVER globally registered): `Tab`/`⇧Tab` cycle pills, `⌘1–9` quick-pick a
// visible row, `⌘K` toggles the Actions popover, `⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J` jump straight to a pill, `↑`/`↓` move,
// `↩` runs the selected row, `Esc` closes. The scrim + centering + fade are added by `OverlayHostView`;
// OpenQuicklyView IS the panel. `Otty.*` tokens ONLY (raw font/colour/radius literals fail check-ds-leaks).

#if canImport(SwiftUI)
import AislopdeskProtocol
import AislopdeskWorkspaceCore
import Foundation
import SwiftUI

struct OpenQuicklyView: View {
    /// The live store — the source of Opened panes / Recent tabs, the focused-pane Current snapshot, the
    /// pane-focus + scrollback-jump + reopen ops, and the active terminal model the actuator writes to.
    let store: WorkspaceStore
    /// The single overlay reducer — owns the active pill (``OverlayCoordinator/openQuicklyFilter``) + closes
    /// the picker. `@Observable`, so reading `openQuicklyFilter` in `body` auto-tracks the pill highlight.
    let coordinator: OverlayCoordinator
    /// The app-owned, client-side Folders frecency store (the **Folders** pill source + "Forget This Folder").
    /// `nil` on iOS / tests / previews ⇒ the Folders source is simply empty there.
    let folders: FolderFrecencyStore?

    /// The query field text. Editing it re-filters (cheap) the in-memory sources + resets the selection.
    @State private var query = ""
    /// The keyboard-selected row index into ``selectableRows``.
    @State private var selection = 0
    /// Whether the ⌘K Actions popover is shown for the selected row.
    @State private var actionsVisible = false
    /// The focused pane's Jump-To rows, SNAPSHOTTED once on appear (running the detector over the whole
    /// scrollback is not per-keystroke work) — the **Current** source, kept verbatim so a Current row's ⌘K
    /// reuses the shared `LinkActionActuator.rowActions(for:JumpToItem,…)` table.
    @State private var currentJumpItems: [JumpToItem] = []
    /// The **Agents** rows (Claude-only), loaded ASYNC from the focused pane's host metadata RPC.
    @State private var agentItems: [OpenQuicklyItem] = []
    /// Whether an Agents fetch is in flight (drives the honest "Loading agents…" state).
    @State private var agentsLoading = false

    /// Pre-focuses the search field on appear so typing reaches it immediately (otty parity).
    @FocusState private var searchFocused: Bool

    // The fixed panel width + results viewport cap (open-quickly.png: a centered card, wider than Jump-To so
    // the six pills + the trailing cwd/badge fit).
    private let panelWidth: CGFloat = 640
    private let resultsMaxHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            divider
            pillBar
            resultsList
            divider
            footerBar
        }
        .frame(width: panelWidth)
        .background(Otty.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard)
                .stroke(Otty.Line.card, lineWidth: Otty.Metric.hairline),
        )
        .shadow(color: Otty.State.shadow, radius: 30, x: 0, y: 12)
        .onAppear { snapshotCurrent() }
        .onChange(of: query) { _, _ in
            selection = 0
            actionsVisible = false
        }
        .onChange(of: coordinator.openQuicklyFilter) { _, _ in
            selection = 0
            actionsVisible = false
        }
        // Async-load the Agents source on appear + whenever the focused pane / its metadata façade changes or
        // the picker switches to a pill that surfaces Agents (.all / .agents). `.task(id:)` auto-cancels the
        // prior fetch, so a stale in-flight list can never clobber the current one.
        .task(id: agentLoadKey) { await loadAgents() }
        // Keyboard: while this picker is presented the app NSEvent monitor YIELDS the whole keyboard to this
        // focused overlay (its `isOverlayCapturingKeys` gate, keyed on `openQuicklyVisible`), so the global
        // chord table never fires behind it — the picker-local chords below (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J, ⌘1–9, ⌘K, Tab,
        // arrows) reach ``handleKey`` instead of switching the background tab / closing the focused pane. Plain
        // ↩ is the field's `.onSubmit` (TextField-native), so a single ↩ never double-fires.
        .onKeyPress(phases: .down) { press in handleKey(press) }
        #if os(macOS)
            .onExitCommand { close() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                close()
                return .handled
            }
        #endif
    }

    private var divider: some View {
        Rectangle()
            .fill(Otty.Line.divider)
            .frame(height: Otty.Metric.hairline)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            TextField("Search tabs, windows…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
                .focused($searchFocused)
                .onSubmit { actSelected() } // plain ↩ acts + closes
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / find-bar idiom).
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Filter pill bar

    // Recipes pill: added in E16 once the recipe store exists.
    /// The otty pill ring (open-quickly.png): the active pill is FILLED (`Otty.State.selected`) with primary
    /// text; inactive pills are OUTLINED (`Otty.Line.card`) with secondary text. SSH + Recipes are absent by
    /// product decision (see ``OpenQuicklyFilter``).
    private var pillBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            ForEach(OpenQuicklyFilter.pickerPills, id: \.self) { filter in
                pill(filter)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
    }

    private func pill(_ filter: OpenQuicklyFilter) -> some View {
        let active = filter == coordinator.openQuicklyFilter
        return Button {
            coordinator.setOpenQuicklyFilter(filter)
        } label: {
            Text(filter.label)
                .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                .foregroundStyle(active ? Otty.Text.primary : Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)
                .background(
                    Capsule().fill(active ? Otty.State.selected : Color.clear),
                )
                .overlay(
                    Capsule().stroke(active ? Color.clear : Otty.Line.card, lineWidth: Otty.Metric.hairline),
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if selectableRows.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayEntries) { entry in
                            displayRow(entry)
                        }
                    }
                }
                .padding(.vertical, Otty.Metric.space1)
            }
            .frame(maxHeight: resultsMaxHeight)
            .onChange(of: selection) { _, _ in
                guard let id = selectedRowID else { return }
                withAnimation(Otty.Anim.smallFade) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func displayRow(_ entry: DisplayEntry) -> some View {
        switch entry.kind {
        case let .header(filter):
            sectionHeader(filter)
        case let .row(item, selectableIndex):
            row(item, selectableIndex: selectableIndex)
        }
    }

    private func sectionHeader(_ filter: OpenQuicklyFilter) -> some View {
        Text(filter.sectionHeader)
            .font(.system(size: Otty.Typeface.small, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Otty.State.header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.top, Otty.Metric.space3)
            .padding(.bottom, Otty.Metric.space1)
            .id("header:\(filter.rawValue)")
    }

    private var emptyState: some View {
        Text(emptyMessage)
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Otty.Metric.space4)
    }

    private func row(_ item: OpenQuicklyItem, selectableIndex: Int) -> some View {
        let isSelected = selectableIndex == selection
        return HStack(spacing: Otty.Metric.space2) {
            Image(systemName: item.symbol)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
                .frame(width: 18, alignment: .center)
            highlightedTitle(item)
                .font(.system(size: Otty.Typeface.body))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: Otty.Metric.space2)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
            if let stamp = item.timestamp {
                Text(OutlinePresentation.relativeTime(from: stamp, now: Date()))
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
                    .monospacedDigit()
            }
            badge(item.badge)
            #if os(iOS)
            // iOS touch fallback for the ⌘K Actions popover (E11 iOS flag — the chord needs a hardware
            // keyboard, so every chord-only affordance gets a tap fallback): a trailing ellipsis selects
            // this row then opens its Actions popover (anchored on the now-selected row). macOS keeps the
            // ⌘K chord and shows no button (the affordance is hidden behind `#if os(iOS)`).
            Button {
                selection = selectableIndex
                actionsVisible = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(Otty.Text.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions")
            #endif
        }
        .padding(.horizontal, Otty.Metric.space3)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusItem)
                .fill(isSelected ? Otty.State.selected : Color.clear),
        )
        .padding(.horizontal, Otty.Metric.space2)
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { selection = selectableIndex } }
        .onTapGesture { act(item) }
        .id(item.id)
        // The Actions popover anchors on the SELECTED row (⌘K), reusing the per-kind action table.
        .popover(isPresented: Binding(
            get: { actionsVisible && isSelected },
            set: { if !$0 { actionsVisible = false } },
        )) {
            actionsPopover(for: item)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Otty.Typeface.small, weight: .medium))
            .foregroundStyle(Otty.Text.secondary)
            .padding(.horizontal, Otty.Metric.space1)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                    .fill(Otty.Surface.element),
            )
    }

    // MARK: - Title highlight (fzf ranges)

    /// The row title with the fzf-matched runs tinted the accent colour + semibold (the palette idiom). The
    /// fuzzy haystack is the item's ``OpenQuicklyItem/searchText`` (a folder matches on its full path) but the
    /// highlight is applied over the visible ``title`` — so a path-only match renders the title flat.
    private func highlightedTitle(_ item: OpenQuicklyItem) -> Text {
        let title = item.title
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ranges = FuzzyMatcher.score(trimmed, title)?.ranges, !ranges.isEmpty else {
            return Text(title).foregroundStyle(Otty.Text.primary)
        }
        var segments: [Text] = []
        var cursor = title.startIndex
        for range in ranges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                segments.append(Text(title[cursor..<range.lowerBound]).foregroundStyle(Otty.Text.primary))
            }
            segments.append(Text(title[range]).foregroundStyle(Otty.State.accent).fontWeight(.semibold))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            segments.append(Text(title[cursor...]).foregroundStyle(Otty.Text.primary))
        }
        return segments.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    // MARK: - Footer bar (Quick Select ⌘ · <default action> ↩ · Actions ⌘K)

    private var footerBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            footerHint("Quick Select", glyph: "⌘")
            Spacer(minLength: Otty.Metric.space2)
            footerHint(defaultActionLabel, glyph: "↩")
            footerHint("Actions", glyph: "⌘K")
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 34)
    }

    private func footerHint(_ label: String, glyph: String) -> some View {
        HStack(spacing: Otty.Metric.space1) {
            Text(label)
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Text.tertiary)
            Text(glyph)
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                        .fill(Otty.Surface.element),
                )
        }
    }

    /// The context-sensitive default-action verb for the footer's `↩` hint (otty shows "Switch to ↩" for a
    /// tab/pane, but the verb differs per source). Falls back to "Open" when nothing is selected.
    private var defaultActionLabel: String {
        switch selectedItem?.kind {
        case .pane: "Switch to"
        case .recentTab: "Reopen"
        case .folder: "Change Directory"
        case .agent: "Resume"
        case .command,
             .prompt: "Jump to"
        case .path,
             .url,
             .fileURL: "Open"
        case nil: "Open"
        }
    }

    // MARK: - Actions popover (⌘K — the per-row action set)

    private func actionsPopover(for item: OpenQuicklyItem) -> some View {
        let actions = rowActions(for: item)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button {
                    action.run()
                    close()
                } label: {
                    HStack(spacing: Otty.Metric.space2) {
                        Image(systemName: action.symbol)
                            .frame(width: 16)
                        Text(action.title)
                            .font(.system(size: Otty.Typeface.body))
                        Spacer(minLength: Otty.Metric.space3)
                    }
                    .foregroundStyle(Otty.Text.primary)
                    .padding(.horizontal, Otty.Metric.space3)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Otty.Metric.space1)
        .frame(minWidth: 220)
        .background(Otty.Surface.card)
    }

    /// The per-kind ⌘K action table. A **Current** row (a Jump-To detection) reuses the shared
    /// `LinkActionActuator.rowActions(for:JumpToItem,…)` table verbatim (reconstructing the carried
    /// `JumpToItem` — `rowActions` keys only on its act + title); the other kinds (Pane / Folder / Agent /
    /// Recent) get their otty action subset, with the SSH row dropped (no SSH source exists).
    private func rowActions(for item: OpenQuicklyItem) -> [LinkActionActuator.RowAction] {
        typealias RowAction = LinkActionActuator.RowAction
        switch item.act {
        case let .jumpTo(jumpAct):
            // A Current COMMAND row (otty: "Re-Run in Current Pane · Re-Run in New Tab · Copy Command", per
            // the spec Actions table + ES-E11-3) gets the verbatim-re-run action set, NOT the generic
            // Jump-to+Copy the shared Jump-To table returns. "Re-Run in New Tab" is a deliberate deferral
            // (no defer-bytes-into-a-fresh-PTY store hook exists; pinned in docs/DECISIONS.md) — omitted, not
            // shipped as a dead row. Prompt/path/url/file rows keep the shared Jump-To table below.
            if item.kind == .command {
                return [
                    RowAction(title: "Re-Run in Current Pane", symbol: "arrow.clockwise") {
                        store.reRunCommandInActivePane(item.title)
                    },
                    RowAction(title: "Copy Command", symbol: "doc.on.doc") {
                        LinkActionActuator.copyToPasteboard(item.title)
                    },
                ]
            }
            let jumpItem = JumpToItem(
                id: item.id,
                kind: jumpToKind(item.kind),
                title: item.title,
                timestamp: item.timestamp,
                act: jumpAct,
            )
            return LinkActionActuator.rowActions(for: jumpItem, store: store, model: activeModel)
        case let .focusPane(id):
            // otty Tab actions = "Close Tab · Move Tab to New Window · Reveal CWD in Finder · Copy CWD Path".
            // "Move Tab to New Window" is N/A in this single-window vertical-rail model (pinned N/A in
            // docs/DECISIONS.md — not a dead row); "Switch to Pane" is DROPPED (↩ already switches, so it was
            // a redundant duplicate of the default action). Close routes through the busy-shell/close-confirm
            // path so a dirty/busy pane still prompts.
            var actions = [RowAction(title: "Close Pane", symbol: "xmark") {
                store.requestClosePaneTree(id)
            }]
            if let cwd = item.subtitle {
                actions.append(RowAction(title: "Reveal CWD in Finder", symbol: "folder") {
                    LinkActionActuator.actuate(.revealHost(cwd), model: activeModel)
                })
                actions.append(RowAction(title: "Copy CWD Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(cwd)
                })
            }
            return actions
        case let .openFolder(path):
            var actions = [
                RowAction(title: "Change Directory Here", symbol: "arrow.turn.down.right") {
                    LinkActionActuator.actuate(.changeDirectoryPTY(path), model: activeModel)
                },
                RowAction(title: "Reveal in Finder", symbol: "folder") {
                    LinkActionActuator.actuate(.revealHost(path), model: activeModel)
                },
                RowAction(title: "Copy Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(path)
                },
            ]
            if folders != nil {
                actions.append(RowAction(title: "Forget This Folder", symbol: "trash") {
                    folders?.forget(path: path)
                })
            }
            return actions
        case let .resumeAgent(sessionID, cwd):
            var actions = [RowAction(title: "Resume Session", symbol: "play") {
                resumeAgent(sessionID: sessionID, cwd: cwd)
            }]
            if !cwd.isEmpty {
                actions.append(RowAction(title: "Copy Project Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(cwd)
                })
            }
            actions.append(RowAction(title: "Copy Session ID", symbol: "number") {
                LinkActionActuator.copyToPasteboard(sessionID)
            })
            return actions
        case let .reopenRecentTab(index):
            // Reopen EXACTLY this row's tab by its carried LIFO index (row N reopens tab N) — NOT always the
            // most-recently-closed one the old `reopenLastClosedPane()` popped regardless of which row fired.
            var actions = [RowAction(title: "Reopen Tab", symbol: "arrow.uturn.left") {
                store.reopenClosedTab(at: index)
            }]
            if let cwd = item.subtitle {
                actions.append(RowAction(title: "Copy CWD Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(cwd)
                })
            }
            return actions
        }
    }

    /// Map an Open-Quickly kind back onto its Jump-To kind for the reconstructed `JumpToItem` (cosmetic — the
    /// shared `rowActions` keys only on the act + title). A non-Current kind never reaches here.
    private func jumpToKind(_ kind: OpenQuicklyKind) -> JumpToItemKind {
        switch kind {
        case .url: .url
        case .fileURL: .fileURL
        case .command: .command
        case .prompt: .prompt
        default: .path
        }
    }

    // MARK: - Sources + sectioning

    /// The per-pill source rows, assembled from the live store / folders / async Agents / Current snapshot via
    /// the PURE `OpenQuicklyModel` builders — the view stays a thin renderer.
    private var sources: [OpenQuicklyFilter: [OpenQuicklyItem]] {
        [
            .opened: OpenQuicklyModel.openedItems(from: store.tree),
            .recent: OpenQuicklyModel.recentItems(from: store.recentlyClosedTabs),
            .folders: OpenQuicklyModel.folderItems(from: folders?.ranked() ?? []),
            .agents: agentItems,
            .current: OpenQuicklyModel.currentItems(from: currentJumpItems),
        ]
    }

    /// The ranked, sectioned result list for the active pill — `.all` merges every non-empty source under its
    /// ALL-CAPS header; a specific pill is one section. Ranks via the vendored `FuzzyMatcher` (integer scores).
    private var sections: [OpenQuicklySection] {
        OpenQuicklyModel.sectioned(
            sources: sources,
            filter: coordinator.openQuicklyFilter,
            query: query,
        ) { q, h in FuzzyMatcher.score(q, h)?.score }
    }

    /// The flattened, navigable rows (headers excluded) — the arrow-key / ⌘1–9 target.
    private var selectableRows: [OpenQuicklyItem] {
        OpenQuicklyModel.selectable(sections)
    }

    /// One rendered entry: a section header (only in `.all`) or a row paired with its selectable index.
    private struct DisplayEntry: Identifiable {
        enum Kind {
            case header(OpenQuicklyFilter)
            case row(OpenQuicklyItem, Int)
        }

        let kind: Kind
        var id: String {
            switch kind {
            case let .header(filter): "header:\(filter.rawValue)"
            case let .row(item, _): item.id
            }
        }
    }

    /// The display entries: in `.all`, one ALL-CAPS header per non-empty source then its rows; in a specific
    /// pill, just the rows (the pill itself is the label — no redundant header). The selectable index is the
    /// flat row position across every section, matching ``selectableRows``.
    private var displayEntries: [DisplayEntry] {
        let showHeaders = coordinator.openQuicklyFilter == .all
        var out: [DisplayEntry] = []
        var index = 0
        for section in sections {
            if showHeaders, !section.items.isEmpty {
                out.append(DisplayEntry(kind: .header(section.filter)))
            }
            for item in section.items {
                out.append(DisplayEntry(kind: .row(item, index)))
                index += 1
            }
        }
        return out
    }

    /// The honest empty-state line for the active pill: a typed-but-no-match query reads "No matches"; an
    /// in-flight Agents fetch reads "Loading agents…"; otherwise the source's own empty message.
    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches" }
        let filter = coordinator.openQuicklyFilter
        if filter == .agents, agentsLoading { return "Loading agents…" }
        return filter.emptyMessage
    }

    /// The keyboard-selected row (clamped), or `nil` when nothing is selectable.
    private var selectedItem: OpenQuicklyItem? {
        let rows = selectableRows
        guard selection >= 0, selection < rows.count else { return nil }
        return rows[selection]
    }

    /// The id of the keyboard-selected row (for `scrollTo`).
    private var selectedRowID: String? { selectedItem?.id }

    // MARK: - Focused-pane resolution

    /// The focused pane's terminal model (the actuator's write target), or `nil` when no live terminal pane is
    /// focused (headless / placeholder / preview).
    private var activeModel: TerminalViewModel? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.terminalModel
    }

    /// The focused pane's host metadata façade (the Agents source), or `nil` while disconnected — the same
    /// per-pane channel the Details panel reads.
    private var activeMetadataClient: MetadataClient? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient
    }

    /// The focused pane's last-known cwd (OSC 7), used as the Agents project scope + to resolve relative
    /// detected paths in the Current snapshot. Empty ⇒ nil.
    private var activeCwd: String? {
        guard let id = store.tree.activeSession?.activeTab?.activePane,
              let cwd = store.tree.activeSession?.specs[id]?.lastKnownCwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    // MARK: - Current snapshot + Agents async load

    /// Snapshot the focused pane into ``currentJumpItems`` ONCE on appear: run the link detector over its
    /// scrollback (only when link detection is enabled) + map its OSC-133 command index, assembled by the pure
    /// `JumpToModel` (identical to the old Jump-To panel's snapshot).
    private func snapshotCurrent() {
        guard let model = activeModel else {
            currentJumpItems = []
            return
        }
        let rows = model.searchScrollbackLines()
        let links: [DetectedLink] = SettingsKey.linkDetectionEnabled
            ? TerminalLinkDetector.detect(rows: rows, cwd: activeCwd, schemes: SettingsKey.linkSchemePolicy)
            : []
        let blocks = model.blocks.navigatorBlocks.map { block in
            BlockSummary(
                index: block.index,
                commandText: block.commandText,
                isPrompt: false,
                firstSeen: model.blocks.firstSeen(index: block.index),
            )
        }
        currentJumpItems = JumpToModel.items(links: links, blocks: blocks)
    }

    /// Identity of "what the Agents fetch depends on": whether a pill that surfaces Agents is active, the
    /// focused pane, and its (re)connected metadata façade. A change re-fires the `.task` (auto-cancelling the
    /// prior), so a stale list can't land late.
    private struct AgentLoadKey: Equatable {
        let showsAgents: Bool
        let pane: PaneID?
        let client: ObjectIdentifier?
    }

    private var agentLoadKey: AgentLoadKey {
        let filter = coordinator.openQuicklyFilter
        return AgentLoadKey(
            showsAgents: filter == .all || filter == .agents,
            pane: store.tree.activeSession?.activeTab?.activePane,
            client: activeMetadataClient.map { ObjectIdentifier($0) },
        )
    }

    /// Fetch the focused pane's Claude agent sessions (host-served metadata RPC). A no-op when no pill surfaces
    /// Agents; clears to empty when no live metadata façade backs the pane. Claude-only filtering is the pure
    /// `OpenQuicklyModel.agentItems`.
    private func loadAgents() async {
        guard agentLoadKey.showsAgents else { return }
        guard let client = activeMetadataClient else {
            agentItems = []
            agentsLoading = false
            return
        }
        agentsLoading = true
        let sessions = await client.listAgentSessions(project: activeCwd ?? "")
        agentItems = OpenQuicklyModel.agentItems(from: sessions)
        agentsLoading = false
    }

    // MARK: - Keyboard (picker-local)

    /// The single picker-local key router. `Tab`/`⇧Tab` cycle pills; `↑`/`↓` move; `⌘K` toggles the Actions
    /// popover; `⌘1–9` quick-pick a visible row; `⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J` jump straight to a pill. Everything else
    /// is `.ignored` (plain typing is already consumed by the focused field; `↩` is its `.onSubmit`).
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Match keys directly (NOT gated on an empty modifier set): AppKit decorates arrow keys with the
        // `.numericPad`/`.function` flags, so an `isEmpty` guard would silently drop them.
        if press.key == .upArrow {
            moveSelection(-1)
            return .handled
        }
        if press.key == .downArrow {
            moveSelection(1)
            return .handled
        }
        if press.key == .tab {
            let current = coordinator.openQuicklyFilter
            let next = press.modifiers.contains(.shift)
                ? OpenQuicklyModel.prevFilter(current)
                : OpenQuicklyModel.nextFilter(current)
            coordinator.setOpenQuicklyFilter(next)
            return .handled
        }
        guard press.modifiers.contains(.command) else { return .ignored }
        // ⌘K toggles the per-row Actions popover on the selected row.
        if press.key == "k" {
            if !selectableRows.isEmpty { actionsVisible.toggle() }
            return .handled
        }
        // ⌘1–9 directly opens the Nth VISIBLE row (1-based → 0-based via the pure model).
        if let digit = press.key.character.wholeNumberValue, (1...9).contains(digit) {
            if let index = OpenQuicklyModel.quickPickIndex(digit, in: selectableRows) {
                act(selectableRows[index])
            }
            return .handled
        }
        // ⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J jump straight to the matching pill (picker-local).
        let key = String(press.key.character).lowercased()
        if let pill = OpenQuicklyFilter.pickerPills.first(where: { $0.pickerChordKey == key }) {
            coordinator.setOpenQuicklyFilter(pill)
            return .handled
        }
        return .ignored
    }

    private func moveSelection(_ delta: Int) {
        let n = selectableRows.count
        guard n > 0 else {
            selection = 0
            return
        }
        selection = max(0, min(n - 1, selection + delta))
    }

    // MARK: - Act

    /// Act on the keyboard-selected row (↩), if any.
    private func actSelected() {
        guard let item = selectedItem else { return }
        act(item)
    }

    /// Run a row's DEFAULT action then close. Each `Act` routes through the shared `LinkActionActuator` (or a
    /// store op), so Open-Quickly and the old Jump-To panel actuate identically. ↩ on a Current LINK is an
    /// EXPLICIT open intent (config-INDEPENDENT — never the configurable ⌘click gesture), matching the E10 fix.
    private func act(_ item: OpenQuicklyItem) {
        switch item.act {
        case let .focusPane(id):
            store.focusPaneTree(id)
        case let .openFolder(path):
            // The folder default action is otty's "change directory here" — verbatim `cd` into the focused
            // pane (parent-if-file is handled by the policy, though a frecent entry is always a directory).
            LinkActionActuator.actuate(.changeDirectoryPTY(path), model: activeModel)
        case let .resumeAgent(sessionID, cwd):
            resumeAgent(sessionID: sessionID, cwd: cwd)
        case let .reopenRecentTab(index):
            // Reopen EXACTLY the picked Recent row's tab by its carried LIFO index (row N reopens tab N), not
            // always the most-recently-closed one — the index-addressed store hook.
            store.reopenClosedTab(at: index)
        case let .jumpTo(jumpAct):
            switch jumpAct {
            case let .block(index):
                store.jumpToNavigatorBlockInActivePane(index: index)
            case let .link(link):
                LinkActionActuator.actuate(LinkActionPolicy.explicitOpenAction(link: link), model: activeModel)
            }
        }
        close()
    }

    /// Resume a Claude agent session in the focused pane: `cd` into its project (verbatim, parent-if-file) then
    /// `claude --resume <id>` — the agents are Claude-only by construction, so the resume verb is fixed. A
    /// no-op when no live terminal backs the focused pane.
    private func resumeAgent(sessionID: String, cwd: String) {
        guard let model = activeModel else { return }
        if !cwd.isEmpty {
            model.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(cwd).utf8))
        }
        model.sendInput(Data("claude --resume \(sessionID)\n".utf8))
    }

    private func close() { coordinator.closeOpenQuickly() }
}
#endif
