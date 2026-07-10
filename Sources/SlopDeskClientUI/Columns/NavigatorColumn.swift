// NavigatorColumn — the left sidebar navigator. macOS renders a flat "TABS" panel on a warm
// `Slate.Surface.ground` background (NOT native `.sidebar` vibrancy/inset-grouped selection — the host split
// item is a PLAIN item), a "TABS" header + sort hamburger, a flat search field, and the active session's tabs
// as `SlateTabRow`s — grouped into `SlateSectionHeader` sections when the hamburger's Group-By is set
// (E6 WI-5). Top 40pt is reserved for the traffic lights under the hidden titlebar.
//
// E6 WI-5 wires the panel to the STORE as the single source of row order:
//   • the flat search field filters via the pure ``RailRowsBuilder/filtered(_:query:)`` (reused, not rebuilt);
//   • the rendered SECTIONS are ``WorkspaceStore/orderedTabGroups(now:)`` (a pure derivation of the store's
//     ``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` / recency), so the hamburger's choice — and
//     a manual drag — mutate the STORE, never local `@State` (the E6-carryover binding constraint);
//   • each row carries the ``RailRow`` chrome (subtitle / fused badge / process label);
//   • dragging a row reorders the session's tabs via ``WorkspaceStore/moveTabRendered(from:to:)`` — a WYSIWYG
//     move by RENDERED position (only the dragged row moves, even under `.updated`), which flips Sort to
//     Manual; the leaf set is unchanged, so reconcile is a registry no-op (no surface teardown). Manual order
//     is a flat-list affordance, so the drag source/target are OFF whenever grouping is active.
//
// iOS: a `List(selection:)` so NavigationSplitView pushes to the content column on a compact iPhone (a custom
// button list does not drive column navigation). Themed to match macOS but keeps the system list's navigation
// wiring; gains the same search field, grouped `Section`s, badge, and drag reorder under `#if os(iOS)`.

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskVideoProtocol // AgentPreferences — the `preventSleep` flag the tab context menu toggles (B4)
import SlopDeskWorkspaceCore
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The live ``PreferencesStore`` — threaded in so the tab context menu can surface the host-LOCAL
    /// **Prevent Sleep While Processing** flag (Batch 4; `docs/ui-shell/screenshots/open-code-agent-history.png`
    /// shows it on the tab menu). The macOS sidebar is hosted in a SEPARATE `NSHostingController` that does not
    /// inherit the WindowGroup environment, so the split-view host passes it explicitly (`nil` on a preview /
    /// pre-injection ⇒ the Prevent-Sleep row is hidden, never a dead control). iOS inherits it via the
    /// `NavigationSplitView` but still passes it explicitly for parity.
    var preferences: PreferencesStore?

    /// The shared chrome state — the macOS sidebar hosts its OWN collapse toggle at the top-trailing corner
    /// of the traffic-light strip (the button lives inside the panel it hides; the content titlebar keeps only
    /// the collapsed-state REOPEN button). Threaded in by the split-view host like `preferences` (the sidebar's
    /// `NSHostingController` inherits no environment). `nil` (previews / iOS, where `NavigationSplitView`
    /// provides its own toggle) omits the button.
    var chrome: WorkspaceChromeState?

    /// The app-global connection — resting home is the SIDEBAR FOOTER (full-width, leading monogram + host
    /// + trailing metrics — room to breathe; never jammed into the traffic-light strip). While the sidebar
    /// is COLLAPSED the titlebar hosts the trailing fallback (`SlateTitlebar`). Threaded in like
    /// `preferences`; `nil` (previews / iOS) omits the cluster.
    var connection: AppConnection?
    /// Tapping the cluster opens the Connect-to-Host editor (``OverlayCoordinator/openConnect()``).
    var onConnect: () -> Void = {}

    /// The transient sidebar search query — narrows the rows via the pure ``RailRowsBuilder/filtered`` (E6
    /// WI-5). View-local `@State`: it is a presentational filter, NOT row order (which lives on the store).
    @State private var query = ""

    /// The memoized row model (perf audit): the sidebar body reads its rows from HERE so a settled body
    /// registers NO Observation dependency on the store's volatile per-pane dicts — a status/git/progress
    /// tick then re-renders only the cheap ``SidebarLiveRow`` leaves (which read their own pane's chrome
    /// live), never the whole rows + `disambiguated()` + sectioning + list-diff pass. Plain class in
    /// `@State` (NOT `@Observable`): its mutation during a body eval must not re-invalidate anything.
    @State private var rowsMemo = RailRowsMemo()

    /// The rows the sidebar renders this eval. With an ACTIVE search query the memo is BYPASSED: `filtered`
    /// matches the volatile subtitle (git line) + process label, so serving those from the stale cache could
    /// filter against yesterday's git line — while searching, the body accepts today's per-tick rebuild
    /// (exactly the pre-memo behavior; search is a transient mode and typing re-derives everything anyway).
    private var renderedRows: [RailRow] {
        query.isEmpty ? rowsMemo.rows(for: store) : RailRowsBuilder.rows(for: store)
    }

    /// The active tab's active pane — drives which row reads as selected.
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    // MARK: - WINDOWS section (MERIDIAN C4)

    /// The remote-GUI pane rows, rendered as the sidebar's SECOND section (TABS · WINDOWS — same row anatomy,
    /// spec §3.6): the only difference is the leading identity monogram. Narrowed by the same search query as
    /// the tab rows.
    private func windowRows(from allRows: [RailRow]) -> [RailRow] {
        RailRowsBuilder.filtered(allRows.filter { $0.kind == .remoteGUI }, query: query)
    }

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

    /// Map the store's grouping onto the FILTERED rail rows, then attach a stable `ForEach` identity to each
    /// surviving section. ``TabGrouping/byProject`` renders via the PER-PANE sectioning
    /// (``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``) so a split tab's panes bucket into their
    /// OWN projects and the section header can't flicker with focus; ``TabGrouping/none`` /
    /// ``TabGrouping/byDate`` (tab-centric — a flat list / per-tab recency) keep the tab-level
    /// ``RailRowsBuilder/sectioned(_:groups:query:)``.
    private func buildSections(_ rows: [RailRow], query: String) -> [RowSection] {
        let groups: [RailRowGroup] = store.tabGrouping == .byProject
            ? RailRowsBuilder.sectionedByProject(rows, tabOrder: store.flatOrderedTabIDs(), query: query)
            : RailRowsBuilder.sectioned(rows, groups: store.orderedTabGroups(), query: query)
        return groups
            .enumerated()
            .map { index, group in
                RowSection(id: "\(index)|\(group.header ?? "")", header: group.header, rows: group.rows)
            }
    }

    /// Whether the manual drag-reorder affordance is live: ONLY a flat, UNFILTERED list — `tabGrouping ==`
    /// ``TabGrouping/none`` AND an empty search `query`. You cannot hand-order across derived buckets
    /// (By-Project / By-Date), so rows are neither draggable nor drop targets while grouping is on —
    /// pretending to would silently discard a cross-group drop (it snaps back to its own bucket). A search
    /// FILTER is off for the same reason: ``renderedTabOrder`` / ``renderedPosition(of:)`` are computed against
    /// the FULL ordered groups, so a drag between two visible rows would move in full-order coordinates
    /// relative to tabs the user can't see — not WYSIWYG against the filtered list.
    private var dragReorderEnabled: Bool { store.tabGrouping == .none && query.isEmpty }

    /// The active session's tab ids in RENDERED order — the flat sidebar order
    /// (``WorkspaceStore/orderedTabGroups(now:)`` flattened). The basis for a WYSIWYG drag: the dragged tab's
    /// IDENTITY (its payload) and the drop target resolve into RENDERED positions in THIS list at drop time,
    /// not raw `session.tabs` indices (which differ from the rendered order under ``TabSort/updated``).
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
    /// mid-drag reorder (an `.updated` completion re-derives ``renderedTabOrder`` in flight) still moves the
    /// DRAGGED tab, not whatever tab now sits at a stale index. Both positions are into ``renderedTabOrder``,
    /// so the move is WYSIWYG. Routes through ``WorkspaceStore/moveTabRendered(from:to:)``, which materializes
    /// the rendered order into the tabs array then moves only the dragged tab (flipping Sort → Manual, no
    /// surface teardown). An unparseable / foreign payload, a self / OOB drop, or any drop while grouping is on
    /// is a no-op (validate-then-drop).
    private func handleTabDrop(_ items: [String], onto target: RailRow) -> Bool {
        guard dragReorderEnabled, let raw = items.first,
              let move = TabDragPayload.resolveMove(payload: raw, onto: target.tabID, in: renderedTabOrder)
        else { return false }
        store.moveTabRendered(from: move.from, to: move.to)
        return true
    }

    /// Conditionally attach the drag SOURCE + drop TARGET to a row's content: only while `dragReorderEnabled`
    /// and the row has a rendered position (it is shown). The payload is the row's tab IDENTITY (FIX 2), so the
    /// drop resolves the dragged tab by id against the live rendered order — never a stale array index. Off
    /// (grouping on / filtered / no position) ⇒ the bare content, so rows aren't draggable across buckets or
    /// against hidden rows. While enabled the row is wrapped in a ``ReorderableRow`` so it can own the per-row
    /// `isTargeted` hover flag (a `@ViewBuilder` helper can't hold `@State`) and paint the E18 WI-7
    /// insertion-line indicator. The drop handler / payload / gate pass through UNCHANGED.
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
        .background(Slate.Surface.face, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
    }

    /// macOS: the flat "TABS" panel — name rows + white-card active, hamburger sort, search field, grouped
    /// sections. Paints its own warm background (the host `NSSplitViewItem` is a plain item, so there is no
    /// native vibrancy/rounding).
    private var macSidebar: some View {
        let allRows = renderedRows
        // TABS · WINDOWS (MERIDIAN C4): remote-GUI pane rows leave the tab list for their own section
        // below — same anatomy, the leading identity monogram is the only difference (spec §3.6).
        let tabRows = allRows.filter { $0.kind != .remoteGUI }
        let windows = windowRows(from: allRows)
        let sections = buildSections(tabRows, query: query)
        return VStack(alignment: .leading, spacing: 0) {
            // Traffic-light strip: ONLY the sidebar-collapse toggle (top-trailing). Connection lives in the
            // footer below — the lights strip is too narrow for host + metrics and always looked jammed.
            // Top 3 centres the 24pt plate on the traffic-light row (y≈15).
            //
            // The toggle is anchored to the sidebar's TRAILING edge, which RIDES the collapse/expand slide —
            // visible mid-slide it glides with the moving edge and reads as a flash. So it shows only in the
            // SETTLED expanded state: hides INSTANTLY when the collapse flag flips (before the slide starts)
            // and, on expand, fades back only after the slide settles (0.25 clears the ~0.25s NSSplitView
            // collapse animation; 0.15 still caught the tail).
            ZStack(alignment: .topTrailing) {
                Color.clear
                if let chrome {
                    PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                        .opacity(chrome.sidebarCollapsed ? 0 : 1)
                        .allowsHitTesting(!chrome.sidebarCollapsed)
                        .animation(
                            chrome.sidebarCollapsed ? nil : Slate.Anim.standard.delay(0.25),
                            value: chrome.sidebarCollapsed,
                        )
                        .padding(.top, 3)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: Slate.Metric.titlebarHeight)
            HStack(spacing: 0) {
                // MERIDIAN L2: the panel label speaks the INSTRUMENT voice (mono + wide tracking) — same
                // register as `SlateSectionHeader`, one size up for the panel-level label.
                Text("TABS")
                    .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .semibold))
                    .tracking(Slate.Typeface.instrumentTracking)
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
                    } else if sections.isEmpty, windows.isEmpty {
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
                        // The WINDOWS section (MERIDIAN C4): open remote-window panes, same row anatomy
                        // with the identity monogram. Not drag-reorderable — manual order is a TABS
                        // affordance; a window row's home is this derived section.
                        if !windows.isEmpty {
                            SlateSectionHeader("Windows")
                            ForEach(windows) { row in
                                windowRow(row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden) // scrollbars stay invisible for the flat sidebar look
            .frame(maxHeight: .infinity)

            // Connection footer — full-width status row under the tab list (ScrollView maxHeight: .infinity
            // pins this to the bottom). Hairline separates list from chrome; fillWidth so hover/hit read as
            // one sidebar item. Leading-aligned fixed column keeps ticking telemetry from shifting the host.
            if let connection {
                Rectangle()
                    .fill(Slate.Line.subtle)
                    .frame(maxWidth: .infinity)
                    .frame(height: Slate.Metric.hairline)
                // The telemetry (ping / fps / kbps, ~1 Hz) is read inside `SidebarConnectionFooter` (perf
                // audit) so its per-second ticks re-render that leaf, never this sidebar body.
                SidebarConnectionFooter(store: store, connection: connection, onConnect: onConnect)
                    .padding(.horizontal, Slate.Metric.space2)
                    .padding(.vertical, Slate.Metric.space2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Slate.Surface.ground)
    }

    /// One macOS tab row: the full chrome (badge / subtitle / process label) plus the
    /// drag-reorder source + drop target. The drop routes `reorderable` → `handleTabDrop` →
    /// ``WorkspaceStore/moveTabRendered(from:to:)`` (the WYSIWYG, rendered-position entry the row uses); the
    /// non-rendered ``WorkspaceStore/moveTab(from:to:)`` is only exercised by tests now. The VOLATILE chrome
    /// is read inside ``SidebarLiveRow`` (perf audit), so a pane's status tick re-renders that one leaf, not
    /// this sidebar body.
    private func macRow(_ row: RailRow) -> some View {
        reorderable(
            SidebarLiveRow(
                store: store,
                row: row,
                active: row.id == selectedPane,
                fallbackTitle: defaultTitle(for: row.kind),
                isWindowRow: false,
                onSelect: { select(row.id) },
                onClose: { store.requestClosePaneTree(row.id) },
                onRename: { commitRename(row, to: $0) },
                onCancelRename: { store.clearTabRenameRequest() },
            ),
            row: row,
        )
        .contextMenu { rowContextMenu(row) }
    }

    /// One macOS WINDOWS row (MERIDIAN C4): the SAME `SlateTabRow` chrome as a tab row (rename / badge /
    /// hover close / context menu) — name-first like every other row (the thumbnail, then the monogram, were
    /// both pruned by user verdict); the owning APP is the instrument-voice subtitle (read live inside
    /// ``SidebarLiveRow`` so the model's own updates stay leaf-local). NOT wrapped
    /// `reorderable` — manual order is a TABS affordance.
    private func windowRow(_ row: RailRow) -> some View {
        SidebarLiveRow(
            store: store,
            row: row,
            active: row.id == selectedPane,
            fallbackTitle: defaultTitle(for: row.kind),
            isWindowRow: true,
            onSelect: { select(row.id) },
            onClose: { store.requestClosePaneTree(row.id) },
            onRename: { commitRename(row, to: $0) },
            onCancelRename: { store.clearTabRenameRequest() },
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
        let allRows = renderedRows
        // TABS · WINDOWS (MERIDIAN C4) — same split as the macOS panel: remote-GUI pane rows render in
        // their own trailing section (iOS keeps the system list rows).
        let tabRows = allRows.filter { $0.kind != .remoteGUI }
        let windows = windowRows(from: allRows)
        let sections = buildSections(tabRows, query: query)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            if allRows.isEmpty {
                Label("No tabs open", systemSymbol: .squareSplit2x1)
                    .foregroundStyle(Slate.Text.secondary)
            } else if sections.isEmpty, windows.isEmpty {
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
                if !windows.isEmpty {
                    Section("Windows") {
                        ForEach(windows) { row in
                            iosRow(row)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Slate.Surface.ground)
        .tint(Slate.State.accent)
        .searchable(text: $query, prompt: "Search tabs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.openChooserPane(.newTab) } label: { Image(systemSymbol: .plus) }
            }
        }
    }

    /// One iOS list row: the system `Label` (navigation wiring via `.tag`) plus the trailing fused badge,
    /// and the same drag-reorder source/target as macOS. The VOLATILE chrome (badge / lock / rename mode)
    /// is read inside ``IOSSidebarLiveRow`` (perf audit), so a pane's status tick re-renders that one leaf,
    /// not this sidebar body. The rename commit reuses ``commitRename(_:to:)`` so the iOS + macOS paths
    /// share the same semantics (rename the pane so the row title wins, then dismiss the field).
    private func iosRow(_ row: RailRow) -> some View {
        reorderable(
            IOSSidebarLiveRow(
                store: store,
                row: row,
                fallbackTitle: defaultTitle(for: row.kind),
                symbol: Self.symbol(for: row.kind),
                onRename: { commitRename(row, to: $0) },
                onCancelRename: { store.clearTabRenameRequest() },
            )
            .tag(row.id),
            row: row,
        )
        .contextMenu { rowContextMenu(row) }
    }
    #endif

    /// Commit an inline row rename (C3 BUG B): rename the pane (so ``RailRowsBuilder/rowTitle`` — which reads
    /// the pane spec — surfaces it, winning over the folder name) then clear the pending state so the field
    /// closes. A blank draft renames nothing (``WorkspaceStore/renamePane(_:to:)`` no-ops), keeping the folder
    /// name; the pending state still clears so the field dismisses. Shared across the macOS + iOS row builders
    /// so both paths land the same commit semantics.
    private func commitRename(_ row: RailRow, to text: String) {
        store.renamePane(row.id, to: text)
        store.clearTabRenameRequest()
    }

    // MARK: - Tab context menu (E13 WI-3 — Clear Badge + per-pane badge overrides + notify toggles)

    /// The right-click / long-press menu for a sidebar row (`docs/ui-shell/screenshots/open-code-agent-history.png`):
    /// the Agent-Behaviour toggles surfaced on the tab. "Clear Badge" acknowledges the pane's completion/attention;
    /// the three BADGE items are PER-PANE override toggles (seeded from the pane's CURRENT effective gates, so
    /// the first flip preserves the other two — an absent override follows the global Settings → Agents
    /// default); the two NOTIFY items toggle the GLOBAL fire-time keys (notify prefs are global, not per-pane).
    /// Claude-only.
    /// **Prevent Sleep While Processing** (Batch 4) is a host-LOCAL `AgentPreferences` flag in
    /// `PreferencesStore` (rides the sidecar → applies on reconnect; default-OFF). Surfaced only when the store
    /// is threaded in (the split-view host now does), bound to the SAME global `agent.preventSleep` Settings →
    /// Agent Behaviour edits. A `nil` store (preview / pre-injection) hides the row.
    @ViewBuilder
    private func rowContextMenu(_ row: RailRow) -> some View {
        // C3 BUG B: a mouse-reachable "Rename" — sets the pending-rename for THIS row's tab so its inline
        // field opens (even on a background tab). Twin of the ⌘R / palette "Rename Pane" entry.
        Button("Rename") { store.requestRenameTab(row.tabID) }
        // C3 BUG C d: an on-demand git-line re-probe for a terminal row (a video pane has no git surface).
        if row.kind == .terminal {
            Button("Refresh Git Status") { store.refreshGitSummary(for: row.id) }
        }
        Divider()
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
        // Prevent Sleep While Processing (E13 ES-E13-3) — the host-LOCAL system-sleep assertion gate. Bound to
        // the GLOBAL `agent.preventSleep` flag (the SAME Settings → Agent Behaviour edits), shown only when the
        // live store is threaded in. `?? false` mirrors the daemon default-OFF (`nil` ⇒ unset).
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
    /// switch to the owning tab (stamps recency), focus the pane, then AUTO-CLEAR every agent
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

    /// The index of the tab that OWNS `paneID` in `session`: `Session.tabIndex(containing:)` delegates to
    /// `Tab.contains`. A pane in a BACKGROUND tab still gets a rail row (`RailRowsBuilder` enumerates
    /// `tab.allPaneIDs()`), so clicking its row must resolve the owning tab and `selectTab` it — the ONLY
    /// path that stamps tab recency (E6 WI-3, floats the tab in the `.updated` sidebar sort). Static + pure
    /// so the resolution is unit-tested without a live view (see `NavigatorColumnSelectTests`).
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
/// the targeting highlight lives here — and paints the insertion-line indicator (a 2pt accent rule on the
/// row's TOP edge) for the landing position between tabs while a tab-reorder drag hovers it. The drag payload,
/// drop handler and reorder gate pass through UNCHANGED from ``NavigatorColumn`` — this view only adds the
/// targeting highlight via the pure ``TabReorderInsertionLine`` placement model.
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

/// One LIVE sidebar row (perf audit): the STRUCTURAL identity (pane id / title / cwd / kind) rides the
/// memoized ``RailRow``, while every VOLATILE field — the fused badge, git-line subtitle, foreground-process
/// label, read-only lock, inline-rename mode — is read fresh HERE via
/// ``RailRowsBuilder/liveChrome(for:store:)``. Observation still invalidates each row body when ANY pane's
/// status dict ticks (dict-granularity tracking), but that re-renders these cheap leaf bodies only — the
/// sidebar body above no longer rebuilds its rows + `disambiguated()` + sections + list diff per tick.
private struct SidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
    let active: Bool
    /// The kind's generic title (``PaneChooserRegistry``) when the row title is empty.
    let fallbackTitle: String
    /// MERIDIAN C4: a WINDOWS-section row prefers the live ``RemoteWindowModel`` app name for line 2.
    let isWindowRow: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        // FIX 1, relocated from the (now memoized) rows build: observe the flash-decay tick at ROW scope so
        // a quiet completed pane still decays its brief `.completed` checkmark to the `.finished` dot —
        // `completionFreshness` reads the wall clock, not an `@Observable` dependency, so without this read
        // nothing would re-render this row at the flash-window boundary. `let _` (not a bare `_ =`) is
        // required — a `@ViewBuilder` rejects a bare Void discard statement.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        SlateTabRow(
            title: row.title.isEmpty ? fallbackTitle : row.title,
            active: active,
            subtitle: (isWindowRow ? remoteAppName : nil) ?? chrome.subtitle,
            gitSummary: chrome.gitSummary,
            processLabel: chrome.processLabel,
            badge: chrome.badge,
            readOnly: chrome.readOnly,
            isEditing: chrome.isEditing,
            helpText: row.cwd,
            onSelect: onSelect,
            onClose: onClose,
            onRename: onRename,
            onCancelRename: onCancelRename,
        )
    }

    /// The live remote-window model's owning app name (E21 WI-5) — the same store-registry lookup
    /// ``ConnectionTelemetry`` uses, read at row scope so the model's own updates stay leaf-local.
    private var remoteAppName: String? {
        guard let model = (store.handle(for: row.id) as? LivePaneSession)?.remoteWindow,
              !model.appName.isEmpty else { return nil }
        return model.appName
    }
}

/// The iOS twin of ``SidebarLiveRow``: the system `Label` row with the trailing lock + fused badge, its
/// volatile chrome read fresh at row scope (perf audit). The layout is byte-identical to the pre-memo
/// inline `HStack` — only WHERE the volatile fields are read moved.
private struct IOSSidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
    let fallbackTitle: String
    let symbol: SFSymbol
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        // FIX 1 at row scope — see ``SidebarLiveRow/body``.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        HStack(spacing: 8) {
            Label {
                if chrome.isEditing {
                    // The iOS inline-rename field (C3 BUG B) — commits on submit/blur (escape is macOS-only).
                    InlineRenameField(
                        seed: row.title.isEmpty ? fallbackTitle : row.title,
                        onCommit: onRename,
                        onCancel: onCancelRename,
                    )
                } else {
                    Text(row.title.isEmpty ? fallbackTitle : row.title)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemSymbol: symbol)
            }
            Spacer(minLength: 6)
            if chrome.readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
            }
            if let badge = chrome.badge {
                TabBadgeView(kind: badge)
            }
        }
    }
}

/// The sidebar's connection footer, split into its own leaf (perf audit): the ``ConnectionTelemetry``
/// reads (ping / fps / kbps) tick at ~1 Hz off the live session models — read HERE so each tick re-renders
/// this footer only, never the sidebar body (which would re-derive the whole rail every second).
private struct SidebarConnectionFooter: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let onConnect: () -> Void

    var body: some View {
        ConnectionCluster(
            connection: connection,
            pingMS: ConnectionTelemetry.pingMS(store),
            fps: ConnectionTelemetry.fps(store),
            kbps: ConnectionTelemetry.kbps(store),
            onConnect: onConnect,
            fillWidth: true,
        )
    }
}

/// A small self-focusing inline rename `TextField` (C3 BUG B, iOS list rows) — owns its own draft `@State` so
/// a `@ViewBuilder` row helper (which cannot hold state) can drop it in. Seeds from `seed` on open, commits on
/// Return / focus-loss (`onCommit`), and — on macOS only — cancels on Escape (`onCancel`). A blank commit is a
/// no-op rename downstream, so the field never blanks the row.
private struct InlineRenameField: View {
    let seed: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    /// Whether the rename was already RESOLVED by Return/Escape — so the focus-loss handler fired at field
    /// teardown does not re-commit (Escape must not rename to the draft). A genuine click-away leaves it
    /// `false` and still commits once. Reset per open via `.onAppear`.
    @State private var resolved = false
    @FocusState private var focused: Bool

    var body: some View {
        let field = TextField("Rename", text: $draft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            .onAppear {
                draft = seed
                resolved = false
                focused = true
            }
            .onSubmit {
                resolved = true
                onCommit(draft)
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, !resolved { onCommit(draft) }
            }
        #if os(macOS)
        return field.onExitCommand {
            resolved = true
            onCancel()
        }
        #else
        return field
        #endif
    }
}
#endif
