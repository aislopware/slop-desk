// OpenQuicklyView — the PHONE's Open-Quickly picker, an Xcode-style `⌘⇧O` multi-source quick
// switcher (`open-quickly.png`) that folds in the Jump-To panel: pre-focused search field, filter pills
// (All / Opened / Recent / Folders / Agents / Current — SSH absent by product decision), a sectioned +
// fuzzy-ranked result list, per-row `⌘K` Actions popover, footer hint bar. `⌘⇧O` opens on **All**; `⌘J`
// opens on **Current** (the Jump-To scope).
//
// SEAM: every source is assembled by the PURE `OpenQuicklyModel` (headlessly tested) — Opened from
// `WorkspaceStore.tree`, Recent from `closedTabRecords`, Folders from the injected `FolderFrecencyStore`,
// Current from the focused pane's `JumpToModel` snapshot, Agents from its host metadata RPC
// (`MetadataClient.listAgentSessions`, Claude-only) loaded ASYNC. Ranking runs `FuzzyMatcher`.
// Each row's default + `⌘K` actions actuate through the shared `LinkActionActuator` (renderer + Jump-To use
// the same dispatch), so link/cd/host routing has ONE home. The active pill lives on the `OverlayCoordinator`
// (`openQuicklyFilter`); the search query + keyboard selection are local view state.
//
// Picker-LOCAL keys (handled here, NEVER globally registered): `Tab`/`⇧Tab` cycle pills, `⌘1–9` quick-pick a
// visible row, `⌘K` toggles Actions, `⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J` jump to a pill, `↑`/`↓` move, `↩` runs the row,
// `Esc` closes. Presented as a NATIVE `.sheet` by `OverlayHostView` (the system provides the window chrome);
// this view carries only its content. `Slate.*` tokens ONLY (raw font/colour/radius literals fail
// check-ds-leaks).
//
// ⚠️ THE PHONE's, since docs/56 stage D: the Mac draws this picker in AppKit
// (``SlopDeskMacUI/MacOpenQuicklyView``), it was the last CARD to move, and nothing on this floor is
// drawn on the Mac any more. Nothing here may re-derive what the picker IS:
// the card's measurements, the flattening of sections into draw order (and with it the selectable
// index the keyboard counts by), the honest zero-state line, the ↩ verb, the footer's hints, the ⌘
// chord table and — the largest piece — the per-row ⌘K ACTION TABLE and the default action ↩ runs
// are all ``OpenQuicklyPresentation``'s and ``OpenQuicklyActions``'s. A verb table written twice
// does not fail loudly when it drifts; it just quietly offers one surface a verb the other has not
// got. `check-supervisor.sh` fails the build if either half grows its own copy.

#if canImport(SwiftUI)
import Foundation
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct OpenQuicklyView: View {
    /// The live store — source of Opened panes / Recent tabs / Current snapshot, the focus + jump + reopen
    /// ops, and the active terminal model the actuator writes to.
    let store: WorkspaceStore
    /// The overlay reducer — owns the active pill (``OverlayCoordinator/openQuicklyFilter``) + closes the
    /// picker. `@Observable`, so reading `openQuicklyFilter` in `body` auto-tracks the pill highlight.
    let coordinator: OverlayCoordinator
    /// The client-side Folders frecency store (the **Folders** pill source + "Forget This Folder").
    /// `nil` on iOS / tests / previews ⇒ Folders source is empty there.
    let folders: FolderFrecencyStore?

    /// The query field text. Editing it re-filters (cheap) the in-memory sources + resets the selection.
    @State private var query = ""
    /// The keyboard-selected row index into ``selectableRows``.
    @State private var selection = 0
    /// Hover→selection arbiter (see ``HoverSelectionGate``): hover-driven selection must not auto-scroll,
    /// and a list scrolling under a PARKED pointer must not steal the selection. One per presentation.
    @State private var hoverGate = HoverSelectionGate()
    /// Whether the ⌘K Actions popover is shown for the selected row.
    @State private var actionsVisible = false
    /// The ⌘K Actions popover's fuzzy filter query (the action set is itself searchable).
    @State private var actionsQuery = ""
    /// The keyboard-highlighted action index within the popover's FILTERED action list.
    @State private var actionsSelection = 0
    /// The focused pane's Jump-To rows, SNAPSHOTTED once on appear (detecting over the whole scrollback isn't
    /// per-keystroke work) — the **Current** source, kept verbatim so a Current row's ⌘K reuses the shared
    /// `LinkActionActuator.rowActions(for:JumpToItem,…)` table.
    @State private var currentJumpItems: [JumpToItem] = []
    /// The **Agents** rows (Claude-only), loaded ASYNC from the focused pane's host metadata RPC.
    @State private var agentItems: [OpenQuicklyItem] = []
    /// Whether an Agents fetch is in flight (drives the honest "Loading agents…" state).
    @State private var agentsLoading = false

    /// Pre-focuses the search field on appear so typing reaches it immediately.
    @FocusState private var searchFocused: Bool
    /// Pre-focuses the ⌘K Actions popover's filter field when it opens (so typing filters actions at once).
    @FocusState private var actionsFocused: Bool

    /// One PageUp/PageDown "page" in rows, from ``OpenQuicklyMetrics`` — the viewport's own height over
    /// the height a row ACTUALLY draws at, so re-tuning the card re-tunes the page rather than leaving a
    /// stride that no longer matches what the eye just skipped.
    private var pageStep: Int {
        OpenQuicklyMetrics.pageStride(rowHeight: Slate.Metric.heightRowTall)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            divider
            pillBar
            resultsList
            divider
            footerBar
        }
        // The paper card is applied by `OverlayHostView`; this view carries only its content, and takes
        // the width the phone's card gives it.
        .onAppear {
            snapshotCurrent()
        }
        .onChange(of: query) { _, _ in
            selection = 0
            actionsVisible = false
        }
        .onChange(of: coordinator.openQuicklyFilter) { _, _ in
            selection = 0
            actionsVisible = false
        }
        // Opening ⌘K Actions starts with a blank filter + first action highlighted; closing returns the
        // keyboard to the main search field. Retyping the filter resets the highlight to the top.
        .onChange(of: actionsVisible) { _, visible in
            actionsQuery = ""
            actionsSelection = 0
            if !visible { searchFocused = true }
        }
        .onChange(of: actionsQuery) { _, _ in actionsSelection = 0 }
        // Async-load Agents on appear + whenever the focused pane / its metadata façade changes or the picker
        // switches to a pill surfacing Agents (.all / .agents). `.task(id:)` auto-cancels the prior fetch, so
        // a stale in-flight list can never clobber the current one.
        .task(id: agentLoadKey) { await loadAgents() }
        // Keyboard: while presented, the app NSEvent monitor YIELDS the whole keyboard to this focused overlay
        // (its `isOverlayCapturingKeys` gate, keyed on `openQuicklyVisible`), so the global chord table never
        // fires behind it — the picker-local chords (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J/⌘E, ⌘1–9, ⌘K, Tab, arrows) reach
        // ``handleKey`` instead of switching the background tab / closing the focused pane. Plain ↩ is the
        // field's `.onSubmit` (TextField-native), so a single ↩ never double-fires.
        // `.repeat` is admitted so a HELD arrow walks the list, but the picker routes its whole keyboard
        // through this one handler — so the repeats of everything else (⌘1–9, ⌘K, Tab, the pill chords) are
        // swallowed rather than re-fired. `.handled`, not `.ignored`: an ignored press walks on to the
        // responder chain and beeps.
        .onKeyPress(phases: OverlayKeyRepeat.phases) { press in
            guard OverlayKeyRepeat.admits(press) else { return .handled }
            return handleKey(press)
        }
        // Esc for the iPad's hardware keyboard. `.onExitCommand` is macOS-only and this card is the
        // phone's, so the key press IS the handler.
        .onKeyPress(.escape, phases: .down) { _ in
            close()
            return .handled
        }
    }

    /// The card's internal hairline — earned where content MOVES past content (the results scroll
    /// under the query bar, and the footer is a fixed rail the list runs beneath). Theme ink, not the
    /// system `Divider`, whose grey lands far too heavy on glass.
    private var divider: some View { SlateCardSeparator() }

    // MARK: - Search bar

    private var searchBar: some View {
        // The shared card-top search bar (focus-grab deferral included); plain ↩ acts + closes.
        SlateSearchBar(
            prompt: OpenQuicklyPresentation.searchPrompt,
            text: $query,
            focus: $searchFocused,
            onSubmit: { actSelected() },
        )
    }

    // MARK: - Filter pill bar

    /// The filter pill ring (open-quickly.png): the active pill is FILLED (the neutral plate) with primary
    /// text; inactive pills are OUTLINED with secondary text. SSH is absent by
    /// product decision (see ``OpenQuicklyFilter``).
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
                .foregroundStyle(active ? SlateOverlayInk.primary : SlateOverlayInk.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .background(
                    Capsule().fill(active ? SlateOverlayInk.plate : Color.clear),
                )
                .overlay(
                    Capsule().stroke(active ? Color.clear : SlateOverlayInk.hairline, lineWidth: Slate.Metric.hairline),
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
            .frame(maxHeight: OpenQuicklyMetrics.resultsMaxHeight)
            .onChange(of: selection) { _, _ in
                // Keyboard nav / query-reset only — a HOVER-driven change must not scroll, or the list
                // "follows the mouse" (hover selects → scrollTo slides a new row under the pointer → …).
                guard hoverGate.shouldAutoScrollOnSelectionChange() else { return }
                guard let id = selectedRowID else { return }
                withAnimation(Slate.Anim.smallFade) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func displayRow(_ entry: OpenQuicklyDisplayEntry) -> some View {
        switch entry.kind {
        case let .header(filter):
            sectionHeader(filter)
        case let .row(item, selectableIndex):
            row(item, selectableIndex: selectableIndex)
        }
    }

    private func sectionHeader(_ filter: OpenQuicklyFilter) -> some View {
        // The shared caps micro-label every card's section header speaks — the system face at semibold
        // competed with the row titles it was meant to be labelling.
        SlateCapsLabel(filter.sectionHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.top, Slate.Metric.space3)
            .padding(.bottom, Slate.Metric.space1)
            .id("header:\(filter.rawValue)")
    }

    private var emptyState: some View {
        SlateNoResultsLine(message: emptyMessage, ink: SlateOverlayInk.tertiary)
    }

    private func row(_ item: OpenQuicklyItem, selectableIndex: Int) -> some View {
        let isSelected = selectableIndex == selection
        return HStack(spacing: Slate.Metric.space2) {
            Image(systemName: item.symbol)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(SlateOverlayInk.secondary)
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
                    .foregroundStyle(SlateOverlayInk.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: OpenQuicklyMetrics.subtitleMaxWidth, alignment: .trailing)
            }
            if let stamp = item.timestamp {
                Text(OutlinePresentation.relativeTime(from: stamp, now: Date()))
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(SlateOverlayInk.tertiary)
                    .monospacedDigit()
            }
            badge(item.badge)
            // The touch fallback for ⌘K — the chord needs a hardware keyboard, so every chord-only
            // affordance gets a tap fallback: a trailing ellipsis selects this row then opens its Actions
            // popover, anchored on the now-selected row.
            Button {
                selection = selectableIndex
                actionsVisible = true
            } label: {
                Image(systemSymbol: .ellipsisCircle)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(SlateOverlayInk.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions")
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRowTall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateSelectionPlate(isSelected)
        .padding(.horizontal, Slate.Metric.space2)
        .contentShape(Rectangle())
        // The click is the row itself (WRAPPED, not overlaid — an overlaid target eats the hover below it).
        .slateRowButton { act(item) }
        // Hover-select on genuine pointer MOVEMENT only — a keyboard scrollTo sliding this row under a
        // parked pointer re-fires hover too, and admitting that would yank the selection back to the mouse.
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard case let .active(location) = phase, hoverGate.admitHover(at: location) else { return }
            guard selection != selectableIndex else { return }
            hoverGate.noteHoverDrivenSelection()
            selection = selectableIndex
        }
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
            .foregroundStyle(SlateOverlayInk.secondary)
            .padding(.horizontal, Slate.Metric.space1)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .fill(SlateOverlayInk.plate),
            )
    }

    // MARK: - Title highlight (fzf ranges)

    /// The row title with fzf-matched runs tinted accent + semibold (the palette idiom). The fuzzy haystack is
    /// ``OpenQuicklyItem/searchText`` (a folder matches on its full path) but the highlight applies over the
    /// visible ``title`` — so a path-only match renders the title flat.
    private func highlightedTitle(_ item: OpenQuicklyItem) -> Text {
        let title = item.title
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranges = trimmed.isEmpty ? [] : FuzzyMatcher.score(trimmed, title)?.ranges ?? []
        let runs = FuzzyMatcher.runs(of: title, ranges: ranges)
        guard runs.count > 1 else {
            return Text.nerdAware(title, size: Slate.Typeface.body).foregroundStyle(SlateOverlayInk.primary)
        }
        // WHERE the cuts fall is ``FuzzyMatcher/runs(of:ranges:)``'s, shared with the Mac's own row and
        // with both halves of the palette. What is left here is the INK, and the mark is CONTRAST rather
        // than colour: the hit run keeps the reading ink at semibold while the letters around it step
        // back. Every run goes through `nerdAware` so a program title's private-use glyph draws from the
        // bundled symbols face inside the highlight too.
        return .spliced(runs.map { run in
            Text.nerdAware(run.text, size: Slate.Typeface.body)
                .foregroundStyle(run.matched ? SlateOverlayInk.primary : SlateOverlayInk.secondary)
                .fontWeight(run.matched ? .semibold : .regular)
        })
    }

    // MARK: - Footer bar (Quick Select ⌘ · <default action> ↩ · Actions ⌘K)

    private var footerBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            footerHint(OpenQuicklyPresentation.quickSelectHint, glyph: "⌘")
            Spacer(minLength: Slate.Metric.space2)
            footerHint(defaultActionLabel, glyph: "↩")
            footerHint(OpenQuicklyPresentation.actionsHint, glyph: "⌘K")
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: Slate.Metric.heightRow)
    }

    /// A footer hint: what the key does, then the key as a CAP. The glyph used to be a bare tinted plate
    /// with no edge — which is what a badge looks like, not what a key looks like.
    private func footerHint(_ label: String, glyph: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(label)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(SlateOverlayInk.tertiary)
            SlateKeycap(label: glyph)
        }
    }

    /// The context-sensitive default-action verb for the footer's `↩` hint — the ROW's, not the picker's.
    private var defaultActionLabel: String {
        OpenQuicklyPresentation.defaultActionLabel(for: selectedItem?.kind)
    }

    // MARK: - Actions popover (⌘K — the per-row action set)

    private func actionsPopover(for item: OpenQuicklyItem) -> some View {
        let actions = filteredActions(for: item)
        return VStack(alignment: .leading, spacing: 0) {
            // A pre-focused fuzzy filter field (the ⌘K Actions popover is itself searchable). Typing narrows
            // `actions` through the SAME ranking the main list uses; ↑/↓ move the highlight; ↩
            // runs the highlighted action.
            actionsSearchField
            divider
            if actions.isEmpty {
                SlateNoResultsLine(
                    message: OpenQuicklyPresentation.noActionsMessage, ink: SlateOverlayInk.tertiary,
                    inset: Slate.Metric.space2,
                )
            } else {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    actionRow(action, index: index, isHighlighted: index == actionsSelection)
                }
            }
        }
        .padding(.vertical, Slate.Metric.space1)
        .frame(minWidth: OpenQuicklyMetrics.actionsWidth)
        .background(SlateOverlayInk.well)
        // The popover owns the keyboard while open (its field is focused): ↑/↓ move the highlight over the
        // FILTERED list; ↩ is the field's `.onSubmit`; Esc closes just the popover (not the whole picker).
        .onKeyPress(phases: OverlayKeyRepeat.phases) { press in
            guard OverlayKeyRepeat.admits(press) else { return .handled }
            return handleActionsKey(press, count: actions.count)
        }
    }

    private var actionsSearchField: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(SlateOverlayInk.secondary)
            TextField(OpenQuicklyPresentation.actionsPrompt, text: $actionsQuery)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(SlateOverlayInk.primary)
                .tint(SlateOverlayInk.primary)
                .focused($actionsFocused)
                .onSubmit { runHighlightedAction() }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRow)
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
            .foregroundStyle(SlateOverlayInk.primary)
            .padding(.horizontal, Slate.Metric.space3)
            .frame(height: Slate.Metric.heightRow)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusItem)
                    .fill(isHighlighted ? SlateOverlayInk.plate : Color.clear),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { actionsSelection = index } }
    }

    /// The selected row's ⌘K action table, fuzzy-filtered + ranked by ``actionsQuery`` through the SAME
    /// ranking the main result list uses (an empty query returns every action in table order).
    private func filteredActions(for item: OpenQuicklyItem) -> [LinkActionActuator.RowAction] {
        OpenQuicklyModel.rankActions(rowActions(for: item), query: actionsQuery, title: { $0.title })
    }

    /// ↑/↓ move the highlight over the filtered actions (clamped); Esc closes just the popover. ↩ is handled
    /// by the field's `.onSubmit` (so a single ↩ never double-fires). Everything else falls through.
    private func handleActionsKey(_ press: KeyPress, count: Int) -> KeyPress.Result {
        if press.key == .upArrow {
            actionsSelection = ListNavigation.clampedSelection(current: actionsSelection, delta: -1, count: count)
            return .handled
        }
        if press.key == .downArrow {
            actionsSelection = ListNavigation.clampedSelection(current: actionsSelection, delta: 1, count: count)
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

    /// The selected row's ⌘K verbs. WHICH verbs is ``OpenQuicklyActions``'s — the same table the
    /// Mac's own picker opens, so a verb added there appears here without either half being told.
    private func rowActions(for item: OpenQuicklyItem) -> [LinkActionActuator.RowAction] {
        OpenQuicklyActions.rowActions(for: item, store: store, model: activeModel, folders: folders)
    }

    // MARK: - Sources + sectioning

    /// The two per-pane facts the pure builders need and the tree does not carry — read here, from the
    /// workspace mirror, so ``OpenQuicklyModel`` stays a pure value function.
    private var paneFacts: (PaneID) -> (title: String?, cwd: String?) {
        { (store.liveProgramTitle(for: $0), store.paneCwd(for: $0)) }
    }

    /// The per-pill source rows, assembled from the live store / folders / async Agents / Current snapshot
    /// via the PURE `OpenQuicklyModel` builders — the view stays a thin renderer.
    private var sources: [OpenQuicklyFilter: [OpenQuicklyItem]] {
        [
            .opened: OpenQuicklyModel.openedItems(from: store.tree, facts: paneFacts),
            .recent: OpenQuicklyModel.recentItems(from: store.closedTabRecords, facts: paneFacts),
            .folders: OpenQuicklyModel.folderItems(from: folders?.ranked() ?? []),
            .agents: agentItems,
            .current: OpenQuicklyModel.currentItems(from: currentJumpItems),
        ]
    }

    /// The ranked, sectioned result list for the active pill — `.all` merges every non-empty source under its
    /// ALL-CAPS header; a specific pill is one section.
    private var sections: [OpenQuicklySection] {
        OpenQuicklyModel.sectioned(sources: sources, filter: coordinator.openQuicklyFilter, query: query)
    }

    /// The flattened, navigable rows (headers excluded) — the arrow-key / ⌘1–9 target.
    private var selectableRows: [OpenQuicklyItem] {
        OpenQuicklyModel.selectable(sections)
    }

    /// The display entries — a header per non-empty source under the ALL pill, then its rows, with the
    /// flat selectable index the keyboard counts by. ``OpenQuicklyPresentation``'s, because a half that
    /// paired them itself would be one off the moment a header appeared mid-list.
    private var displayEntries: [OpenQuicklyDisplayEntry] {
        OpenQuicklyPresentation.displayEntries(sections, filter: coordinator.openQuicklyFilter)
    }

    /// The honest empty-state line for the active pill: a typed-but-unmatched query, an in-flight Agents
    /// fetch, or the source's own message — ``OpenQuicklyPresentation``'s ordering of the three.
    private var emptyMessage: String {
        OpenQuicklyPresentation.emptyMessage(
            query: query, filter: coordinator.openQuicklyFilter, agentsLoading: agentsLoading,
        )
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

    /// The focused pane's working directory (`pane/cwd`), used as the Agents project scope + to resolve
    /// relative detected paths in the Current snapshot. Empty ⇒ nil.
    private var activeCwd: String? {
        guard let id = store.tree.activeSession?.activeTab?.activePane,
              let cwd = store.paneCwd(for: id), !cwd.isEmpty else { return nil }
        return cwd
    }

    // MARK: - Current snapshot + Agents async load

    /// Snapshot the focused pane into ``currentJumpItems`` ONCE on appear: run the link detector over its
    /// scrollback (only when link detection is enabled) + map its OSC-133 command index, assembled by the pure
    /// `JumpToModel`.
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
        // "Jump through list | PageUp / PageDown, Home / End"). All clamp through the one
        // `ListNavigation.clampedSelection` the palette and the command navigator also read.
        if press.key == .pageUp {
            moveSelection(-pageStep)
            return .handled
        }
        if press.key == .pageDown {
            moveSelection(pageStep)
            return .handled
        }
        if press.key == .home {
            selection = ListNavigation.clampedSelection(current: 0, delta: 0, count: selectableRows.count)
            return .handled
        }
        if press.key == .end {
            let n = selectableRows.count
            selection = ListNavigation.clampedSelection(current: 0, delta: n - 1, count: n)
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
        // WHAT a ⌘-modified key means here is ``OpenQuicklyPresentation``'s, so the Mac's picker reads
        // the same table off an `NSEvent`. The arrows, ⇞/⇟, Home/End and Tab above are NOT shared, and
        // deliberately: they arrive as a `KeyPress` here and as a field editor's editing command there.
        guard let chord = OpenQuicklyPresentation.commandChord(press.key.character) else {
            return .ignored
        }
        switch chord {
        case let .quickPick(digit):
            if let index = OpenQuicklyModel.quickPickIndex(digit, in: selectableRows) {
                act(selectableRows[index])
            }
        case .toggleActions:
            if !selectableRows.isEmpty { actionsVisible.toggle() }
        case let .selectPill(pill):
            coordinator.setOpenQuicklyFilter(pill)
        }
        return .handled
    }

    private func moveSelection(_ delta: Int) {
        selection = ListNavigation.clampedSelection(current: selection, delta: delta, count: selectableRows.count)
    }

    // MARK: - Act

    /// Act on the keyboard-selected row (↩), if any.
    private func actSelected() {
        guard let item = selectedItem else { return }
        act(item)
    }

    /// Run a row's DEFAULT action then close. WHICH action is ``OpenQuicklyActions``'s — every one of
    /// them routes through the shared ``LinkActionActuator`` or a store op, so a row opened from the
    /// picker and the same target opened from a renderer link take exactly the same path.
    private func act(_ item: OpenQuicklyItem) {
        OpenQuicklyActions.runDefault(item, store: store, model: activeModel)
        close()
    }

    private func close() { coordinator.closeOpenQuickly() }
}
#endif
