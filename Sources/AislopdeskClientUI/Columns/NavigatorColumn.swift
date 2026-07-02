// NavigatorColumn — the left sidebar navigator. macOS renders a flat "TABS" panel: a warm
// `Slate.Surface.sidebar` background (NOT the native `.sidebar` vibrancy/inset-grouped selection — the host
// split item is a PLAIN item now), a "TABS" header with the sort hamburger, a flat search field, and the
// active session's tabs rendered as `SlateTabRow`s — grouped into `SlateSectionHeader` sections when the
// hamburger's Group-By is set (E6 WI-5). The top 40pt is reserved for the traffic lights under the hidden
// titlebar.
//
// E6 WI-5 wires the panel to the STORE as the single source of row order:
//   • a flat search field filters via the pure ``RailRowsBuilder/filtered(_:query:)`` (reused, not rebuilt);
//   • the rendered SECTIONS are ``WorkspaceStore/orderedTabGroups(now:)`` (a pure derivation of the store's
//     ``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` / recency), so the hamburger's choice — and
//     a manual drag — mutate the STORE, never local `@State` (the E6-carryover binding constraint);
//   • each row carries the new ``RailRow`` chrome (subtitle / fused badge / process label);
//   • dragging a row reorders the session's tabs via ``WorkspaceStore/moveTabRendered(from:to:)`` — a WYSIWYG
//     move by RENDERED position (so only the dragged row moves, even under `.updated`), which flips Sort to
//     Manual; the leaf set is unchanged, so reconcile is a registry no-op (no surface teardown). Manual order
//     is a flat-list affordance, so the drag source/target are OFF whenever a grouping is active.
//
// iOS: a `List(selection:)` so NavigationSplitView pushes to the content column on a compact iPhone (a custom
// button list does not drive column navigation). Themed to match the macOS chrome but keeps the system list's
// navigation wiring; it gains the same search field, grouped `Section`s, badge, and drag reorder
// under `#if os(iOS)`.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol // AgentPreferences — the `preventSleep` flag the tab context menu toggles (B4)
import AislopdeskWorkspaceCore
import Defaults
import SFSafeSymbols
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The live ``PreferencesStore`` — threaded in so the tab context menu can surface the host-LOCAL
    /// **Prevent Sleep While Processing** flag (Batch 4 catalog-completeness;
    /// `docs/ui-shell/screenshots/open-code-agent-history.png` shows it on the tab menu). The macOS sidebar
    /// is hosted in a SEPARATE `NSHostingController` that does not
    /// inherit the WindowGroup environment, so the split-view host passes it explicitly (`nil` on a preview /
    /// pre-injection ⇒ the Prevent-Sleep row is simply hidden, never a dead control). On iOS the column inherits
    /// the value via the `NavigationSplitView`, but it is still passed explicitly for parity.
    var preferences: PreferencesStore?

    /// The app-global connection — drives the compact host + connection-status header pinned at the TOP of the
    /// sidebar, ABOVE the session switcher and the TABS section. This is the ONE place the host / connection
    /// state lives now: it is common to every pane, so it was lifted OUT of the per-pane footer (the terminal
    /// footer is gone entirely) into this shared header. Optional so the column stays standalone-mountable in
    /// previews / snapshot tests (a `nil` connection simply hides the header).
    var connection: AppConnection?
    /// Tapping the connection header opens the Connect-to-Host editor (``OverlayCoordinator/openConnect()``).
    /// No-op default keeps the column standalone-mountable.
    var onConnect: () -> Void = {}

    /// The transient sidebar search query — narrows the rows via the pure ``RailRowsBuilder/filtered`` (E6
    /// WI-5). View-local `@State`: it is a presentational filter, NOT row order (which lives on the store).
    @State private var query = ""

    /// The active tab's active pane — drives which row reads as selected.
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The active pane's live session — resolves the per-pane connection telemetry the Connection section
    /// shows: ping (per-pane channel RTT) and, for a GUI/video pane, the host stream cadence (fps).
    private var activeLive: LivePaneSession? {
        guard let id = selectedPane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The RTT (ms) to show in the Connection card. Prefers the ACTIVE pane's per-channel `latencyMS`, but
    /// falls back to ANY live pane's RTT when the active pane has none — a `.remoteGUI` window pane has no
    /// terminal-channel ping (`connection == nil`), so without this the ping would VANISH the moment you focus
    /// a window. Every pane pings the SAME host, so a sibling terminal's RTT is representative; `.min()` keeps
    /// it deterministic across the unordered registry.
    private var activePingMS: Double? {
        if let active = activeLive?.connection?.latencyMS { return active }
        return store.allSessions
            .compactMap { ($0 as? LivePaneSession)?.connection?.latencyMS }
            .min()
    }

    /// The active VIDEO pane's host-announced stream cadence (fps); `nil` for a terminal pane / until the
    /// host's FPS governor announces a value.
    private var activeFps: Int? { activeLive?.remoteWindow?.streamFps }

    var body: some View {
        #if os(macOS)
        macSidebar
        #else
        iosSidebar
        #endif
    }

    // MARK: - Sections (store-derived order × pane rows × search filter)

    /// One rendered sidebar section: an optional `header` (the group title, `nil` ⇒ the ungrouped flat list)
    /// and the rows in render order. A pure presentational value — identity is the group's stable key so the
    /// `ForEach` does not churn when a sibling section's contents change.
    private struct RowSection: Identifiable {
        let id: String
        let header: String?
        let rows: [RailRow]
    }

    /// Map the store's ordered tab groups (``WorkspaceStore/orderedTabGroups(now:)``) onto the FILTERED rail
    /// rows via the pure ``RailRowsBuilder/sectioned(_:groups:query:)`` (search × grouping composition, unit-
    /// pinned), then attach a stable `ForEach` identity to each surviving section.
    private func buildSections(_ rows: [RailRow], query: String) -> [RowSection] {
        RailRowsBuilder.sectioned(rows, groups: store.orderedTabGroups(), query: query)
            .enumerated()
            .map { index, group in
                RowSection(id: "\(index)|\(group.header ?? "")", header: group.header, rows: group.rows)
            }
    }

    /// Whether the manual drag-reorder affordance is live: ONLY a flat, UNFILTERED list — `tabGrouping ==`
    /// ``TabGrouping/none`` AND an empty search `query`. You cannot hand-order across derived buckets
    /// (By-Project / By-Date), so the rows are neither draggable nor drop targets while grouping is on —
    /// pretending to would silently discard a cross-group drop (it would snap back to its own bucket). And a
    /// search FILTER hides rows while ``renderedTabOrder`` / ``renderedPosition(of:)`` are computed against
    /// the FULL ordered groups, so a drag between two visible rows would move in full-order coordinates
    /// relative to tabs the user can't see — not WYSIWYG against the filtered list. Same flat-list-only
    /// rationale as the grouping gate, so a filtered list is off too.
    private var dragReorderEnabled: Bool { store.tabGrouping == .none && query.isEmpty }

    /// The active session's tab ids in RENDERED order — the flat sidebar order
    /// (``WorkspaceStore/orderedTabGroups(now:)`` flattened). The basis for a WYSIWYG drag: the dragged tab's
    /// IDENTITY (its payload) and the drop target are resolved into RENDERED positions into THIS list at drop
    /// time, not raw `session.tabs` indices (which differ from the rendered order under ``TabSort/updated``).
    /// Consulted only while `dragReorderEnabled`.
    private var renderedTabOrder: [TabID] {
        store.orderedTabGroups().flatMap(\.tabIDs)
    }

    /// The rendered position of `row`'s tab in the flat sidebar order, or `nil` if it isn't shown (e.g. the
    /// row filtered out) — in which case the row carries no drag payload / drop target.
    private func renderedPosition(of row: RailRow) -> Int? {
        renderedTabOrder.firstIndex(of: row.tabID)
    }

    /// Apply a manual drag-reorder. The drag payload is the dragged row's tab IDENTITY (FIX 2), resolved at
    /// DROP time to its CURRENT rendered position via ``TabDragPayload/resolveMove(payload:onto:in:)`` — so a
    /// mid-drag reorder (an `.updated` completion re-derives ``renderedTabOrder`` while the drag is in flight)
    /// still moves the DRAGGED tab, not whatever tab now sits at a stale index. Both resolved positions are
    /// into ``renderedTabOrder``, so the move is WYSIWYG. Routes through
    /// ``WorkspaceStore/moveTabRendered(from:to:)``, which materializes the rendered order into the tabs
    /// array then moves only the dragged tab (flipping Sort → Manual, no surface teardown). An unparseable /
    /// foreign payload, a self / OOB drop, or any drop while grouping is on is a no-op (validate-then-drop).
    private func handleTabDrop(_ items: [String], onto target: RailRow) -> Bool {
        guard dragReorderEnabled, let raw = items.first,
              let move = TabDragPayload.resolveMove(payload: raw, onto: target.tabID, in: renderedTabOrder)
        else { return false }
        store.moveTabRendered(from: move.from, to: move.to)
        return true
    }

    /// Conditionally attach the drag SOURCE + drop TARGET to a row's content: only while `dragReorderEnabled`
    /// and the row has a rendered position (it is shown). The drag payload is the row's tab IDENTITY (FIX 2),
    /// so the drop resolves the dragged tab by id against the live rendered order — never a stale array index.
    /// Off (grouping on / filtered / no position) ⇒ the bare content, so the rows aren't draggable across
    /// buckets or against hidden rows. While enabled the row is wrapped in a ``ReorderableRow`` so it can own
    /// the per-row `isTargeted` hover flag (a `@ViewBuilder` helper can't hold `@State`) and paint the E18
    /// WI-7 insertion-line indicator. The drop handler / payload / gate are UNCHANGED — passed straight in.
    @ViewBuilder
    private func reorderable(_ content: some View, row: RailRow) -> some View {
        if dragReorderEnabled, renderedPosition(of: row) != nil {
            ReorderableRow(
                payload: TabDragPayload.encode(row.tabID),
                tabID: row.tabID,
                reorderEnabled: dragReorderEnabled,
                renderedOrder: renderedTabOrder,
                onDrop: { handleTabDrop($0, onto: row) },
            ) { content }
        } else {
            content
        }
    }

    #if os(macOS)
    /// The flat macOS search field: a filled, hairline-bordered plate with a leading magnifier and a
    /// trailing clear `×` (only when non-empty). Binds the view-local `query`. (iOS uses the system
    /// `.searchable` instead, so this custom field is macOS-only.)
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
            TextField("Search tabs", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent) // the active caret is the accent colour
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemSymbol: .xmarkCircleFill)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.icon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Slate.Surface.card, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
    }

    /// macOS: the flat "TABS" panel — name rows + white-card active, hamburger sort, search field, grouped
    /// sections. Paints its own warm background (the host `NSSplitViewItem` is a plain item, so there is no
    /// native vibrancy/rounding).
    private var macSidebar: some View {
        let allRows = RailRowsBuilder.rows(for: store)
        let sections = buildSections(allRows, query: query)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40) // reserve the titlebar / traffic-light strip
            // E19 WI-5 / A32: the multi-session switcher sits ABOVE the "TABS" header (below the traffic-light
            // strip). It is additive — the tab list below still renders the ACTIVE session's tabs unchanged.
            SessionSwitcherView(store: store)
            HStack(spacing: 0) {
                Text("TABS")
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Slate.State.header)
                Spacer(minLength: 0)
                SlateSortMenuButton(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // The 8pt inset matches the tab list's `LazyVStack` inset below, so the search plate and the
            // row cards share LEFT/RIGHT edges (they were 12 vs 8 — visibly misaligned).
            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if allRows.isEmpty {
                        emptyLabel("No tabs open")
                    } else if sections.isEmpty {
                        emptyLabel("No matches")
                    } else {
                        ForEach(sections) { section in
                            if let header = section.header {
                                SlateSectionHeader(header)
                            }
                            ForEach(section.rows) { row in
                                macRow(row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden) // scrollbars stay invisible for the flat sidebar look
            .frame(maxHeight: .infinity) // the tab list fills the slack so the connection card pins to the bottom

            // Connection STATUS LINE: a borderless, FULL-BLEED whisper status bar pinned at the bottom of the
            // sidebar (window chrome, not a card). Common to EVERY pane — the single home for the host/status
            // cues. One line: dot + host + right-flushed metrics (ping = the active pane's RTT, or any live
            // pane's, so a window pane keeps it; fps for a live video pane only). It carries its own top
            // hairline + internal padding, so it spans the full width with no call-site insets.
            if let connection {
                ConnectionInfoSection(
                    connection: connection,
                    pingMS: activePingMS,
                    fps: activeFps,
                    onConnect: onConnect,
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Slate.Surface.sidebar)
    }

    /// One macOS tab row: the full chrome (badge / subtitle / process label) plus the
    /// drag-reorder source + drop target. The drop routes `reorderable` → `handleTabDrop` →
    /// ``WorkspaceStore/moveTabRendered(from:to:)`` (the WYSIWYG, rendered-position entry the row uses); the
    /// non-rendered ``WorkspaceStore/moveTab(from:to:)`` is only exercised by tests now.
    private func macRow(_ row: RailRow) -> some View {
        reorderable(
            SlateTabRow(
                title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
                active: row.id == selectedPane,
                subtitle: row.subtitle,
                processLabel: row.processLabel,
                badge: row.badge,
                readOnly: row.readOnly,
                onSelect: { select(row.id) },
                onClose: { store.requestClosePaneTree(row.id) },
            ),
            row: row,
        )
        .contextMenu { rowContextMenu(row) }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }
    #else
    /// iOS: a system `List(selection:)` so NavigationSplitView pushes to content on compact; themed to match. Gains
    /// the system `.searchable` field (keeps the `List` as the column root so the navigation push is unchanged),
    /// grouped `Section`s, badge, and drag reorder (E6 WI-5).
    private var iosSidebar: some View {
        let allRows = RailRowsBuilder.rows(for: store)
        let sections = buildSections(allRows, query: query)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            // E19 WI-5 / A32: the multi-session switcher as a leading Section so it composes into the column's
            // system List (the root must stay a List for NavigationSplitView's push). Additive — the tab
            // sections below still render the ACTIVE session's tabs unchanged.
            SessionSwitcherView(store: store)
            if allRows.isEmpty {
                Label("No tabs open", systemSymbol: .squareSplit2x1)
                    .foregroundStyle(Slate.Text.secondary)
            } else if sections.isEmpty {
                Label("No matches", systemSymbol: .magnifyingglass)
                    .foregroundStyle(Slate.Text.secondary)
            } else {
                ForEach(sections) { section in
                    Section(section.header ?? "Tabs") {
                        ForEach(section.rows) { row in
                            iosRow(row)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Slate.Surface.sidebar)
        .tint(Slate.State.accent)
        .searchable(text: $query, prompt: "Search tabs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.openChooserPane(.newTab) } label: { Image(systemSymbol: .plus) }
            }
        }
    }

    /// One iOS list row: the system `Label` (navigation wiring via `.tag`) plus the trailing fused badge,
    /// and the same drag-reorder source/target as macOS.
    private func iosRow(_ row: RailRow) -> some View {
        reorderable(
            HStack(spacing: 8) {
                Label {
                    Text(row.title.isEmpty ? defaultTitle(for: row.kind) : row.title)
                        .lineLimit(1)
                } icon: {
                    Image(systemSymbol: Self.symbol(for: row.kind))
                }
                Spacer(minLength: 6)
                if row.readOnly {
                    Image(systemSymbol: .lockFill)
                        .font(.system(size: Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Text.secondary)
                        .accessibilityLabel("Read only")
                }
                if let badge = row.badge {
                    TabBadgeView(kind: badge)
                }
            }
            .tag(row.id),
            row: row,
        )
        .contextMenu { rowContextMenu(row) }
    }
    #endif

    // MARK: - Tab context menu (E13 WI-3 — Clear Badge + per-pane badge overrides + notify toggles)

    /// The right-click / long-press menu for a sidebar row (`docs/ui-shell/screenshots/open-code-agent-history.png`):
    /// the Agent-Behaviour toggles surfaced on the tab. "Clear Badge" acknowledges the pane's completion/attention;
    /// the three BADGE items are PER-PANE override toggles (seeded from the pane's CURRENT effective gates, so
    /// the first flip preserves the other two — an absent override follows the global Settings → Agents
    /// default); the two NOTIFY items toggle the GLOBAL fire-time keys (notify preferences are global, not
    /// per-pane). Claude-only.
    /// **Prevent Sleep While Processing** (Batch 4) is a host-LOCAL `AgentPreferences` flag living in
    /// `PreferencesStore` (it rides the sidecar → applies on reconnect; default-OFF). It is surfaced here only
    /// when the store is threaded in (the split-view host now does), bound to the SAME global `agent.preventSleep`
    /// Settings → Agent Behaviour edits — the tab menu lists it too (see
    /// `docs/ui-shell/screenshots/open-code-agent-history.png`). A `nil` store
    /// (preview / pre-injection) simply hides the row.
    @ViewBuilder
    private func rowContextMenu(_ row: RailRow) -> some View {
        Button("Clear Badge") { store.clearAgentBadge(row.id) }
        Divider()
        Toggle("Badge While Processing", isOn: Binding(
            get: { store.agentBadgeGates(for: row.id).badgeWhileProcessing },
            set: { _ in store.toggleAgentBadgeGate(.whileProcessing, for: row.id) },
        ))
        Toggle("Badge When Task Completes", isOn: Binding(
            get: { store.agentBadgeGates(for: row.id).badgeWhenComplete },
            set: { _ in store.toggleAgentBadgeGate(.whenComplete, for: row.id) },
        ))
        Toggle("Badge When Awaiting Input", isOn: Binding(
            get: { store.agentBadgeGates(for: row.id).badgeWhenAwaitingInput },
            set: { _ in store.toggleAgentBadgeGate(.whenAwaitingInput, for: row.id) },
        ))
        Toggle("Notify When Task Completes", isOn: Binding(
            get: { Defaults[.agentNotifyTaskComplete] },
            set: { Defaults[.agentNotifyTaskComplete] = $0 },
        ))
        Toggle("Notify When Awaiting Input", isOn: Binding(
            get: { Defaults[.agentNotifyAwaitInput] },
            set: { Defaults[.agentNotifyAwaitInput] = $0 },
        ))
        // Prevent Sleep While Processing (E13 ES-E13-3) — the host-LOCAL system-sleep assertion
        // gate. Bound to the GLOBAL `agent.preventSleep` flag (the SAME Settings → Agent Behaviour edits), shown
        // only when the live store is threaded in. `?? false` mirrors the daemon default-OFF (`nil` ⇒ unset).
        if let preferences {
            Divider()
            Toggle("Prevent Sleep While Processing", isOn: Binding(
                get: { preferences.agent.preventSleep ?? false },
                set: { preferences.agent.preventSleep = $0 },
            ))
        }
    }

    /// Make the row's tab active (if it isn't) then focus its pane. Both go through the store.
    private func select(_ paneID: PaneID) {
        Self.selectRow(paneID, in: store)
    }

    /// The full tab-row SELECT path, exposed as a static testable helper (mirrors ``owningTabIndex(of:in:)``):
    /// switch to the owning tab (float-aware, stamps recency), focus the pane, then AUTO-CLEAR every agent
    /// badge on the newly-focused tab (badge auto-clears on tab focus). All three steps go through
    /// the store. Static so ``NavigatorColumnSelectTests`` exercises this logic headlessly without a live view.
    @MainActor
    static func selectRow(_ paneID: PaneID, in store: WorkspaceStore) {
        if let session = store.tree.activeSession,
           let index = owningTabIndex(of: paneID, in: session),
           index != session.activeTabIndex
        {
            store.selectTab(index)
        }
        store.focusPaneTree(paneID)
        // Auto-clear the agent badge for every pane in the now-focused tab (badge auto-clears on
        // tab focus). Runs AFTER focusPaneTree so the active tab is already the focused one.
        if let tab = store.tree.activeSession?.activeTab {
            for id in tab.allPaneIDs() {
                store.clearAgentBadge(id)
            }
        }
    }

    /// The index of the tab that OWNS `paneID` in `session`, FLOAT-AWARE: `Session.tabIndex(containing:)`
    /// delegates to `Tab.contains` = split tree + floating layer. A FLOATED pane in a BACKGROUND tab still gets
    /// a rail row (`RailRowsBuilder` enumerates `tab.allPaneIDs()` = tree + floats), so clicking its row must
    /// resolve the owning tab and `selectTab` it — the ONLY path that stamps tab recency (E6 WI-3, floats the
    /// tab in the `.updated` sidebar sort) — exactly as a tiled-pane row does. The pre-fix hand-rolled
    /// `tab.root.allPaneIDs()` scan saw the tree ONLY, so it never matched a float and silently dropped the
    /// recency stamp (E21 F1 class). Static + pure so the float-aware resolution is unit-tested without a live
    /// view (see `NavigatorColumnSelectTests`).
    static func owningTabIndex(of paneID: PaneID, in session: Session) -> Int? {
        session.tabIndex(containing: paneID)
    }

    private func defaultTitle(for kind: PaneKind) -> String {
        PaneChooserRegistry.option(for: kind).title
    }

    /// Type-safe SF Symbol for a pane kind (iOS rows only; macOS rows are name-only). Reads the
    /// symbol *name* from the shared ``PaneChooserRegistry`` and wraps it in a type-safe `SFSymbol`.
    private static func symbol(for kind: PaneKind) -> SFSymbol {
        SFSymbol(rawValue: PaneChooserRegistry.option(for: kind).symbol)
    }
}

/// A rail row wrapped with the manual drag-reorder source + drop target AND the E18 WI-7 insertion-line
/// indicator. It owns the per-row `isTargeted` hover flag — a `@ViewBuilder` helper can't hold `@State`, so
/// the targeting highlight lives here — and paints a thin insertion-line indicator for the landing
/// position between tabs as a 2pt accent rule on the row's TOP edge while a tab-reorder drag hovers it. The
/// drag payload, drop handler and reorder gate are passed in UNCHANGED from ``NavigatorColumn`` (the by-uuid
/// payload, ``NavigatorColumn``'s `handleTabDrop`, and the grouping/search gate are untouched) — this view
/// only adds the targeting highlight via the pure ``TabReorderInsertionLine`` placement model.
private struct ReorderableRow<Content: View>: View {
    /// The drag payload string (the row's tab IDENTITY — ``TabDragPayload/encode(_:)``).
    let payload: String
    /// This row's tab id — the anchor the insertion line resolves against while it is the drop target.
    let tabID: TabID
    /// The navigator's manual-reorder gate (off under grouping / a search filter) — suppresses the line too.
    let reorderEnabled: Bool
    /// The LIVE flat sidebar order, so the line is suppressed against a stale / unshown target.
    let renderedOrder: [TabID]
    /// The drop handler — ``NavigatorColumn``'s `handleTabDrop`, passed straight through (unchanged).
    let onDrop: ([String]) -> Bool
    @ViewBuilder let content: () -> Content

    /// SwiftUI's per-row drop-hover flag. Drives the insertion line via ``TabReorderInsertionLine``.
    @State private var isTargeted = false

    /// Whether the 2pt accent rule is drawn — resolved by the pure placement model (suppressed when no row is
    /// targeted, reorder is gated off, or the targeted row isn't shown in the live order).
    private var showsInsertionLine: Bool {
        TabReorderInsertionLine.anchorIndex(
            hovering: isTargeted ? tabID : nil, reorderEnabled: reorderEnabled, in: renderedOrder,
        ) != nil
    }

    var body: some View {
        content()
            .draggable(payload)
            .dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { isTargeted = $0 }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Slate.State.accent)
                    .frame(height: TabReorderInsertionLine.thickness)
                    .opacity(showsInsertionLine ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: showsInsertionLine)
                    .accessibilityHidden(true)
            }
    }
}
#endif
