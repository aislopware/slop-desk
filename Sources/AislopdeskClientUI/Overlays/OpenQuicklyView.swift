// OpenQuicklyView — the floating Open-Quickly picker (E11 / WI-6), an Xcode-style `⌘⇧O` multi-source
// quick switcher (`open-quickly.png`). It FOLDS in the E10 Jump-To panel: ONE centered, SCRIMMED card with a
// pre-focused search field, a row of filter pills (All / Opened / Recent / Folders / Agents / Current /
// Recipes — SSH is absent by product decision), a sectioned + fuzzy-ranked result list, a per-row `⌘K` Actions
// popover, and a context-sensitive footer hint bar. `⌘⇧O` opens it on **All**; `⌘J` opens it on **Current**
// (the Jump-To scope).
//
// SEAM discipline: every source is assembled by the PURE `OpenQuicklyModel` (headlessly tested) — Opened from
// the live `WorkspaceStore.tree`, Recent from `recentlyClosedTabs`, Folders from the injected
// `FolderFrecencyStore`, Current from the focused pane's `JumpToModel` snapshot, Agents from the focused
// pane's host metadata RPC (`MetadataClient.listAgentSessions`, Claude-only) loaded ASYNC, and Recipes from
// `store.savedRecipeFiles()` snapshotted on appear. Ranking runs the vendored `FuzzyMatcher`. Every row's
// default action + its `⌘K` action table actuate through the shared `LinkActionActuator` (the same thin
// platform dispatch the renderer + Jump-To use), so link/cd/host routing has ONE home. The active pill lives
// on the `OverlayCoordinator` (`openQuicklyFilter`); the search query + keyboard selection are local view state.
//
// Picker-LOCAL keys (handled here, NEVER globally registered): `Tab`/`⇧Tab` cycle pills, `⌘1–9` quick-pick a
// visible row, `⌘K` toggles the Actions popover, `⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J/⌘E` jump straight to a pill, `↑`/`↓`
// move, `↩` runs the selected row, `Esc` closes. Presented as a NATIVE `.sheet` by `OverlayHostView` (the
// system provides the window chrome); OpenQuicklyView carries only its content. `Slate.*` tokens ONLY for
// that content (raw font/colour/radius literals fail check-ds-leaks).

#if canImport(SwiftUI)
import AislopdeskProtocol
import AislopdeskWorkspaceCore
import Foundation
import SFSafeSymbols
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
    /// The ⌘K Actions popover's fuzzy filter query (the action set is itself searchable).
    @State private var actionsQuery = ""
    /// The keyboard-highlighted action index within the popover's FILTERED action list.
    @State private var actionsSelection = 0
    /// The focused pane's Jump-To rows, SNAPSHOTTED once on appear (running the detector over the whole
    /// scrollback is not per-keystroke work) — the **Current** source, kept verbatim so a Current row's ⌘K
    /// reuses the shared `LinkActionActuator.rowActions(for:JumpToItem,…)` table.
    @State private var currentJumpItems: [JumpToItem] = []
    /// The **Agents** rows (Claude-only), loaded ASYNC from the focused pane's host metadata RPC.
    @State private var agentItems: [OpenQuicklyItem] = []
    /// Whether an Agents fetch is in flight (drives the honest "Loading agents…" state).
    @State private var agentsLoading = false
    /// The **Recipes** rows — the saved `.aislopdeskrecipe` library, snapshotted on appear (the library is
    /// on-disk; a rescan on every keystroke would be wasteful). Rebuilt when the picker closes+reopens.
    @State private var recipeItems: [OpenQuicklyItem] = []

    /// Pre-focuses the search field on appear so typing reaches it immediately.
    @FocusState private var searchFocused: Bool
    /// Pre-focuses the ⌘K Actions popover's filter field when it opens (so typing filters actions at once).
    @FocusState private var actionsFocused: Bool

    // The fixed panel width + results viewport cap (open-quickly.png: a centered card, wider than Jump-To so
    // the six pills + the trailing cwd/badge fit).
    private let panelWidth: CGFloat = 640
    private let resultsMaxHeight: CGFloat = 360
    /// The rendered row height (`row(_:)` frame) — the divisor for one PageUp/PageDown "page" of rows.
    private let rowHeight: CGFloat = 38

    /// One PageUp/PageDown "page" measured in rows: the visible viewport height divided by the row height,
    /// floored to at least one row (so a page always advances). Integer math — no float on the wire/selection.
    private var pageStep: Int { max(1, Int(resultsMaxHeight / rowHeight)) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            divider
            pillBar
            resultsList
            divider
            footerBar
        }
        // Presented as a native `.sheet` by `OverlayHostView` — the system provides the window chrome (bg /
        // rounded corners / shadow), so this view carries only its content + a fixed macOS dialog width.
        #if os(macOS)
        .frame(width: panelWidth)
        #endif
        .onAppear {
            snapshotCurrent()
            recipeItems = OpenQuicklyModel.recipeItems(from: store.savedRecipeFiles())
        }
        .onChange(of: query) { _, _ in
            selection = 0
            actionsVisible = false
        }
        .onChange(of: coordinator.openQuicklyFilter) { _, _ in
            selection = 0
            actionsVisible = false
        }
        // Opening the ⌘K Actions popover starts with a blank filter + the first action highlighted; closing it
        // returns the keyboard to the main search field. Retyping the filter resets the highlight to the top.
        .onChange(of: actionsVisible) { _, visible in
            actionsQuery = ""
            actionsSelection = 0
            if !visible { searchFocused = true }
        }
        .onChange(of: actionsQuery) { _, _ in actionsSelection = 0 }
        // Async-load the Agents source on appear + whenever the focused pane / its metadata façade changes or
        // the picker switches to a pill that surfaces Agents (.all / .agents). `.task(id:)` auto-cancels the
        // prior fetch, so a stale in-flight list can never clobber the current one.
        .task(id: agentLoadKey) { await loadAgents() }
        // Keyboard: while this picker is presented the app NSEvent monitor YIELDS the whole keyboard to this
        // focused overlay (its `isOverlayCapturingKeys` gate, keyed on `openQuicklyVisible`), so the global
        // chord table never fires behind it — the picker-local chords below (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J/⌘E, ⌘1–9, ⌘K,
        // Tab, arrows) reach ``handleKey`` instead of switching the background tab / closing the focused pane. Plain
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

    private var divider: some View { Divider() }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
            TextField("Search tabs, windows…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent) // the active caret is the accent colour
                .focused($searchFocused)
                .onSubmit { actSelected() } // plain ↩ acts + closes
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: 48)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / find-bar idiom).
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Filter pill bar

    /// The filter pill ring (open-quickly.png): the active pill is FILLED (`Slate.State.selected`) with primary
    /// text; inactive pills are OUTLINED (`Slate.Line.card`) with secondary text. SSH is absent by
    /// product decision (see ``OpenQuicklyFilter``). Recipes is now wired (E16 complete).
    private var pillBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            ForEach(OpenQuicklyFilter.pickerPills, id: \.self) { filter in
                pill(filter)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, Slate.Metric.space2)
    }

    private func pill(_ filter: OpenQuicklyFilter) -> some View {
        let active = filter == coordinator.openQuicklyFilter
        return Button {
            coordinator.setOpenQuicklyFilter(filter)
        } label: {
            Text(filter.label)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(active ? Slate.Text.primary : Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .background(
                    Capsule().fill(active ? Slate.State.selected : Color.clear),
                )
                .overlay(
                    Capsule().stroke(active ? Color.clear : Slate.Line.card, lineWidth: Slate.Metric.hairline),
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
                .padding(.vertical, Slate.Metric.space1)
            }
            .frame(maxHeight: resultsMaxHeight)
            .onChange(of: selection) { _, _ in
                guard let id = selectedRowID else { return }
                withAnimation(Slate.Anim.smallFade) { proxy.scrollTo(id, anchor: .center) }
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
            .font(.system(size: Slate.Typeface.small, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Slate.State.header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.top, Slate.Metric.space3)
            .padding(.bottom, Slate.Metric.space1)
            .id("header:\(filter.rawValue)")
    }

    private var emptyState: some View {
        Text(emptyMessage)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Slate.Metric.space4)
    }

    private func row(_ item: OpenQuicklyItem, selectableIndex: Int) -> some View {
        let isSelected = selectableIndex == selection
        return HStack(spacing: Slate.Metric.space2) {
            Image(systemName: item.symbol)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .frame(width: 18, alignment: .center)
            highlightedTitle(item)
                .font(.system(size: Slate.Typeface.body))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: Slate.Metric.space2)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
            if let stamp = item.timestamp {
                Text(OutlinePresentation.relativeTime(from: stamp, now: Date()))
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
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
                Image(systemSymbol: .ellipsisCircle)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.Text.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions")
            #endif
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusItem)
                .fill(isSelected ? Slate.State.selected : Color.clear),
        )
        .padding(.horizontal, Slate.Metric.space2)
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
            .font(.system(size: Slate.Typeface.small, weight: .medium))
            .foregroundStyle(Slate.Text.secondary)
            .padding(.horizontal, Slate.Metric.space1)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .fill(Slate.Surface.element),
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
            return Text(title).foregroundStyle(Slate.Text.primary)
        }
        var segments: [Text] = []
        var cursor = title.startIndex
        for range in ranges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                segments.append(Text(title[cursor..<range.lowerBound]).foregroundStyle(Slate.Text.primary))
            }
            segments.append(Text(title[range]).foregroundStyle(Slate.State.accent).fontWeight(.semibold))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            segments.append(Text(title[cursor...]).foregroundStyle(Slate.Text.primary))
        }
        return segments.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    // MARK: - Footer bar (Quick Select ⌘ · <default action> ↩ · Actions ⌘K)

    private var footerBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            footerHint("Quick Select", glyph: "⌘")
            Spacer(minLength: Slate.Metric.space2)
            footerHint(defaultActionLabel, glyph: "↩")
            footerHint("Actions", glyph: "⌘K")
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: 34)
    }

    private func footerHint(_ label: String, glyph: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(label)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.tertiary)
            Text(glyph)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                        .fill(Slate.Surface.element),
                )
        }
    }

    /// The context-sensitive default-action verb for the footer's `↩` hint ("Switch to ↩" for a
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
        case .recipe: "Open Recipe"
        case nil: "Open"
        }
    }

    // MARK: - Actions popover (⌘K — the per-row action set)

    private func actionsPopover(for item: OpenQuicklyItem) -> some View {
        let actions = filteredActions(for: item)
        return VStack(alignment: .leading, spacing: 0) {
            // A pre-focused fuzzy filter field (spec line 39 — the ⌘K Actions popover is itself
            // fuzzy-searchable). Typing narrows `actions` through the SAME `FuzzyMatcher.score` the main list
            // uses; ↑/↓ move the highlight; ↩ runs the highlighted action.
            actionsSearchField
            divider
            if actions.isEmpty {
                Text("No actions")
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Slate.Metric.space2)
            } else {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    actionRow(action, index: index, isHighlighted: index == actionsSelection)
                }
            }
        }
        .padding(.vertical, Slate.Metric.space1)
        .frame(minWidth: 240)
        .background(Slate.Surface.card)
        // The popover owns the keyboard while open (its field is focused): ↑/↓ move the highlight over the
        // FILTERED list; ↩ is the field's `.onSubmit`; Esc closes just the popover (not the whole picker).
        .onKeyPress(phases: .down) { press in handleActionsKey(press, count: actions.count) }
    }

    private var actionsSearchField: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
            TextField("Filter actions…", text: $actionsQuery)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent)
                .focused($actionsFocused)
                .onSubmit { runHighlightedAction() }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: 34)
        .onAppear {
            // Same one-runloop-hop focus idiom as the main search field (a `@FocusState` set in the appear
            // tick, before the backing responder exists, is dropped).
            DispatchQueue.main.async { actionsFocused = true }
        }
    }

    private func actionRow(_ action: LinkActionActuator.RowAction, index: Int, isHighlighted: Bool) -> some View {
        Button {
            action.run()
            close()
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Image(systemName: action.symbol)
                    .frame(width: 16)
                Text(action.title)
                    .font(.system(size: Slate.Typeface.body))
                Spacer(minLength: Slate.Metric.space3)
            }
            .foregroundStyle(Slate.Text.primary)
            .padding(.horizontal, Slate.Metric.space3)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusItem)
                    .fill(isHighlighted ? Slate.State.selected : Color.clear),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { actionsSelection = index } }
    }

    /// The selected row's ⌘K action table, fuzzy-filtered + ranked by ``actionsQuery`` through the SAME
    /// `FuzzyMatcher` scorer the main result list uses (an empty query returns every action in table order).
    private func filteredActions(for item: OpenQuicklyItem) -> [LinkActionActuator.RowAction] {
        OpenQuicklyModel.rankActions(
            rowActions(for: item),
            query: actionsQuery,
            title: { $0.title },
        ) { q, h in FuzzyMatcher.score(q, h)?.score }
    }

    /// ↑/↓ move the highlight over the filtered actions (clamped); Esc closes just the popover. ↩ is handled
    /// by the field's `.onSubmit` (so a single ↩ never double-fires). Everything else falls through.
    private func handleActionsKey(_ press: KeyPress, count: Int) -> KeyPress.Result {
        if press.key == .upArrow {
            actionsSelection = OpenQuicklyModel.clampedSelection(current: actionsSelection, delta: -1, count: count)
            return .handled
        }
        if press.key == .downArrow {
            actionsSelection = OpenQuicklyModel.clampedSelection(current: actionsSelection, delta: 1, count: count)
            return .handled
        }
        if press.key == .escape {
            actionsVisible = false
            return .handled
        }
        return .ignored
    }

    /// Run the highlighted (↩) filtered action on the selected row, then close. A no-op when the highlight is
    /// out of range (e.g. the filter narrowed the list past the prior highlight).
    private func runHighlightedAction() {
        guard let item = selectedItem else { return }
        let actions = filteredActions(for: item)
        guard actionsSelection >= 0, actionsSelection < actions.count else { return }
        actions[actionsSelection].run()
        close()
    }

    /// The per-kind ⌘K action table. A **Current** row (a Jump-To detection) reuses the shared
    /// `LinkActionActuator.rowActions(for:JumpToItem,…)` table verbatim (reconstructing the carried
    /// `JumpToItem` — `rowActions` keys only on its act + title); the other kinds (Pane / Folder / Agent /
    /// Recent) get their own per-kind action subset, with the SSH row dropped (no SSH source exists).
    private func rowActions(for item: OpenQuicklyItem) -> [LinkActionActuator.RowAction] {
        typealias RowAction = LinkActionActuator.RowAction
        switch item.act {
        case let .jumpTo(jumpAct):
            // A Current COMMAND row ("Re-Run in Current Pane · Re-Run in New Tab · Copy Command", per
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
            // The Tab action set = "Close Tab · Move Tab to New Window · Reveal CWD in Finder · Copy CWD Path".
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
            return Self.folderRowActions(path: path, store: store, model: activeModel, folders: folders)
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
        case let .openRecipe(url):
            return [
                RowAction(title: "Open Recipe", symbol: "book") {
                    store.openRecipe(at: url, source: .savedLibrary)
                    close()
                },
                RowAction(title: "Copy Path", symbol: "doc.on.doc") {
                    LinkActionActuator.copyToPasteboard(url.path)
                },
            ]
        }
    }

    /// The Folder ⌘K action table (`open-quickly.png` Actions: "Open in New Window · Split Right / Down ·
    /// Change Directory Here · Reveal · Copy Path · Forget This Folder"). **Open in New Window** is N/A in the
    /// single-window vertical-rail model (pinned N/A in `docs/DECISIONS.md`, like "Move Tab to New Window") and
    /// is omitted rather than shipped as a dead row. **Split Right / Down** open a FRESH terminal split rooted
    /// at the folder (the same `openTerminalRooted` ingress the external folder-drop Split-zones reuse, now with
    /// an `axis` so Split-Down is a vertical split). `static` so the ⌘K action set is reachable headlessly
    /// (`OpenQuicklyFolderActionsTests`) without instantiating the SwiftUI view — `model`/`folders` accept the
    /// nil/no-store path.
    static func folderRowActions(
        path: String,
        store: WorkspaceStore,
        model: TerminalViewModel?,
        folders: FolderFrecencyStore?,
    ) -> [LinkActionActuator.RowAction] {
        typealias RowAction = LinkActionActuator.RowAction
        var actions = [
            RowAction(title: "Split Right", symbol: "rectangle.split.2x1") {
                store.openTerminalRooted(at: path, split: true, leading: false, axis: .horizontal)
            },
            RowAction(title: "Split Down", symbol: "rectangle.split.1x2") {
                store.openTerminalRooted(at: path, split: true, leading: false, axis: .vertical)
            },
            RowAction(title: "Change Directory Here", symbol: "arrow.turn.down.right") {
                LinkActionActuator.actuate(.changeDirectoryPTY(path), model: model)
            },
            RowAction(title: "Reveal in Finder", symbol: "folder") {
                LinkActionActuator.actuate(.revealHost(path), model: model)
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

    /// The per-pill source rows, assembled from the live store / folders / async Agents / Current snapshot /
    /// Recipes snapshot via the PURE `OpenQuicklyModel` builders — the view stays a thin renderer.
    private var sources: [OpenQuicklyFilter: [OpenQuicklyItem]] {
        [
            .opened: OpenQuicklyModel.openedItems(from: store.tree),
            .recent: OpenQuicklyModel.recentItems(from: store.recentlyClosedTabs),
            .folders: OpenQuicklyModel.folderItems(from: folders?.ranked() ?? []),
            .agents: agentItems,
            .current: OpenQuicklyModel.currentItems(from: currentJumpItems),
            .recipes: recipeItems,
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
    /// popover; `⌘1–9` quick-pick a visible row; `⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J/⌘E` jump straight to a pill. Everything
    /// else is `.ignored` (plain typing is already consumed by the focused field; `↩` is its `.onSubmit`).
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
        // PageUp/PageDown jump a full viewport of rows; Home/End snap to the first/last row (open-quickly.png
        // "Jump through list | PageUp / PageDown, Home / End"). All clamp through the shared `clampedSelection`.
        if press.key == .pageUp {
            moveSelection(-pageStep)
            return .handled
        }
        if press.key == .pageDown {
            moveSelection(pageStep)
            return .handled
        }
        if press.key == .home {
            selection = OpenQuicklyModel.clampedSelection(current: 0, delta: 0, count: selectableRows.count)
            return .handled
        }
        if press.key == .end {
            let n = selectableRows.count
            selection = OpenQuicklyModel.clampedSelection(current: 0, delta: n - 1, count: n)
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
        selection = OpenQuicklyModel.clampedSelection(current: selection, delta: delta, count: selectableRows.count)
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
            // The folder default action is "change directory here" — verbatim `cd` into the focused
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
        case let .openRecipe(url):
            store.openRecipe(at: url, source: .savedLibrary)
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
