// NavigatorColumn — the left sidebar navigator (native-chrome migration, 2026-07-03). ONE implementation
// for both platforms now: a system `List(selection:)` with `.listStyle(.sidebar)` — native vibrancy/glass,
// native rounded selection, `.searchable` for the filter field, and a native sort/group `Menu` in the
// sidebar's toolbar. (The old macOS-only flat "TABS" panel — warm `Slate.Surface.sidebar` backdrop,
// hand-built search plate, `SlateTabRow` white-card rows — is deleted; the flat doctrine survives only
// inside the terminal/video canvases.)
//
// On macOS the sidebar is the whole window's navigator (dock removal, 2026-07-04): the terminal tabs
// first, then a "Windows" section — one native row per OPEN remote-window tab (real app icon via
// ``AppIconResolver``, window title, host-app subtitle). Selecting a Windows row activates its GUI tab
// (the right column's displayed tab). Browsing NOT-yet-open host windows is the Remote-Window picker,
// minted from the footer's window-`+` (this replaces the GUI column's launcher dock strip).
//
// E6 WI-5 wiring is unchanged — the STORE stays the single source of row order:
//   • `.searchable`'s query filters via the pure ``RailRowsBuilder/filtered(_:query:)``;
//   • the rendered SECTIONS are ``WorkspaceStore/orderedTabGroups(now:)`` (grouping/sort/recency), so the
//     sort menu's choice — and a manual drag — mutate the STORE, never local `@State`;
//   • each row carries the ``RailRow`` chrome (subtitle / fused badge / process label / read-only lock);
//   • dragging a row reorders via ``WorkspaceStore/moveTabRendered(from:to:)`` (WYSIWYG by RENDERED
//     position, flips Sort → Manual); drag is OFF whenever grouping or a search filter is active.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol // AgentPreferences — the `preventSleep` flag the tab context menu toggles (B4)
import AislopdeskWorkspaceCore
import Defaults
import SFSafeSymbols
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The live ``PreferencesStore`` — threaded in so the tab context menu can surface the host-LOCAL
    /// **Prevent Sleep While Processing** flag (Batch 4). `nil` (a preview / pre-injection scene) hides
    /// the row. Inherited via the environment on both platforms now that the shell is one SwiftUI
    /// hierarchy, but still passed explicitly for preview-mountability.
    var preferences: PreferencesStore?

    /// Opens the Remote-Window picker modal (``OverlayCoordinator/openRemotePicker()``) — the sidebar
    /// footer's window-`+` affordance (the dock's old mint, relocated with the Windows section). No-op
    /// default keeps the column standalone-mountable in previews / iOS.
    var onOpenPicker: () -> Void = {}

    /// The transient sidebar search query — narrows the rows via the pure ``RailRowsBuilder/filtered`` (E6
    /// WI-5). View-local `@State`: it is a presentational filter, NOT row order (which lives on the store).
    @State private var query = ""

    /// The active tab's active pane — drives which row reads as selected.
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    var body: some View {
        // TabSide partition (macOS): the sidebar is the whole window's navigator now — the terminal tabs
        // first, then a "Windows" section listing the OPEN remote-window tabs (the right GUI column is
        // pure content since the dock removal; browsing/opening host windows is the picker). iOS keeps
        // the single-region shell (one flat list, all tabs).
        #if os(macOS)
        let allRows = RailRowsBuilder.rows(for: store, side: .terminal)
        let windowRows = RailRowsBuilder.filtered(
            RailRowsBuilder.rows(for: store, side: .gui), query: query,
        )
        #else
        let allRows = RailRowsBuilder.rows(for: store)
        let windowRows: [RailRow] = []
        #endif
        let sections = buildSections(allRows, query: query)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            if allRows.isEmpty, windowRows.isEmpty {
                Label("No tabs open", systemSymbol: .squareSplit2x1)
                    .foregroundStyle(.secondary)
            } else if sections.isEmpty, windowRows.isEmpty {
                Label("No matches", systemSymbol: .magnifyingglass)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections) { section in
                    if let header = section.header {
                        Section(header) {
                            ForEach(section.rows) { row in
                                navRow(row)
                            }
                        }
                    } else if windowRows.isEmpty {
                        ForEach(section.rows) { row in
                            navRow(row)
                        }
                    } else {
                        // With a Windows section below, the flat terminal list gets its own header so
                        // the two groups read as named peers (a bare list over a labelled section looks
                        // like a rendering accident).
                        Section("Terminals") {
                            ForEach(section.rows) { row in
                                navRow(row)
                            }
                        }
                    }
                }
                #if os(macOS)
                if !windowRows.isEmpty {
                    Section("Windows") {
                        ForEach(windowRows) { row in
                            windowRow(row)
                        }
                    }
                }
                #endif
            }
        }
        .listStyle(.sidebar)
        // `.sidebar` placement pins the field at the TOP OF THE SIDEBAR column (the System-Settings
        // idiom) — the default placement floated it into the window toolbar's trailing edge, where it
        // ate half the unified toolbar.
        .searchable(text: $query, placement: .sidebar, prompt: "Search tabs")
        #if os(macOS)
            // The sidebar FOOTER New-Tab affordance (the Things/Reminders "Add List" idiom): before this the
            // ONLY macOS entry points were ⌘T / the palette / the pane-actions menu — no mouse-visible mint
            // anywhere in the window. iOS keeps its toolbar `+` instead.
            .safeAreaInset(edge: .bottom, spacing: 0) { newTabFooter }
        #endif
            .toolbar { navToolbar }
    }

    #if os(macOS)
    /// The pinned sidebar footer: a borderless "New Tab" mint on the left (terminal tabs — the sidebar's
    /// primary kind) and the window-`+` on the right, which opens the Remote-Window picker (the mint for
    /// the Windows section — relocated here from the deleted GUI-column dock).
    private var newTabFooter: some View {
        HStack {
            Button {
                store.newTab(kind: .terminal)
            } label: {
                Label("New Tab", systemSymbol: .plusCircle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            Spacer(minLength: 0)
            Button {
                onOpenPicker()
            } label: {
                Image(systemSymbol: .macwindowBadgePlus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open a Remote Window…")
            .accessibilityLabel("Open a Remote Window")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    /// One Windows-section row: the same native ``NavigatorRow`` chrome as a terminal row (real app icon
    /// via the row's `bundleID`, window title, host-app subtitle, hover close) — but NOT drag-reorderable
    /// (the section lists open order; the terminal rail's manual reorder stays terminal-scoped) and with
    /// the slim window context menu (rename/close — the agent-badge cluster is terminal chrome).
    private func windowRow(_ row: RailRow) -> some View {
        NavigatorRow(
            row: row,
            title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
            active: row.id == selectedPane,
            symbol: Self.symbol(for: row.kind),
            onClose: { store.requestClosePaneTree(row.id) },
            onRename: { commitRename(row, to: $0) },
            onCancelRename: { store.clearTabRenameRequest() },
        )
        .tag(row.id)
        .contextMenu {
            Button("Rename") { store.requestRenameTab(row.tabID) }
            Button("Close Window Tab", role: .destructive) { store.requestClosePaneTree(row.id) }
        }
    }
    #endif

    /// One sidebar row: the native `Label` row (title / subtitle / trailing status cluster / hover close)
    /// plus the drag-reorder source + drop target and the tab context menu. The drop routes `reorderable`
    /// → `handleTabDrop` → ``WorkspaceStore/moveTabRendered(from:to:)``.
    private func navRow(_ row: RailRow) -> some View {
        reorderable(
            NavigatorRow(
                row: row,
                title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
                active: row.id == selectedPane,
                symbol: Self.symbol(for: row.kind),
                onClose: { store.requestClosePaneTree(row.id) },
                onRename: { commitRename(row, to: $0) },
                onCancelRename: { store.clearTabRenameRequest() },
            )
            .tag(row.id),
            row: row,
        )
        .contextMenu { rowContextMenu(row) }
    }

    /// The sidebar toolbar: the native sort/group menu (writes the STORE — the single source of row
    /// order), plus the iOS `+` (macOS mints tabs via ⌘T / the palette / the pane-actions menu).
    @ToolbarContentBuilder
    private var navToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Group By", selection: Binding(
                    get: { store.tabGrouping },
                    set: { store.setTabGrouping($0) },
                )) {
                    Label("No Grouping", systemImage: "list.bullet").tag(TabGrouping.none)
                    Label("By Project", systemImage: "folder").tag(TabGrouping.byProject)
                    Label("By Date", systemImage: "calendar").tag(TabGrouping.byDate)
                }
                Picker("Order", selection: Binding(
                    get: { store.tabSort },
                    set: { store.setTabSort($0) },
                )) {
                    Label("Created Time", systemImage: "clock").tag(TabSort.created)
                    Label("Updated Time", systemImage: "clock.arrow.circlepath").tag(TabSort.updated)
                    Label("Manual", systemImage: "arrow.up.arrow.down").tag(TabSort.manual)
                }
            } label: {
                Label("Sort Tabs", systemSymbol: .line3HorizontalDecrease)
            }
            .help("Group / sort the tab list")
        }
        #if os(iOS)
        ToolbarItem(placement: .primaryAction) {
            Button { store.openChooserPane(.newTab) } label: { Image(systemSymbol: .plus) }
        }
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

    /// Commit an inline row rename (C3 BUG B): rename the pane (so ``RailRowsBuilder/rowTitle`` — which reads
    /// the pane spec — surfaces it, winning over the folder name) then clear the pending state so the field
    /// closes. A blank draft renames nothing (``WorkspaceStore/renamePane(_:to:)`` no-ops), keeping the folder
    /// name; the pending state still clears so the field dismisses.
    private func commitRename(_ row: RailRow, to text: String) {
        store.renamePane(row.id, to: text)
        store.clearTabRenameRequest()
    }

    // MARK: - Tab context menu (E13 WI-3 — Clear Badge + per-pane badge overrides + notify toggles)

    /// The right-click / long-press menu for a sidebar row (`docs/ui-shell/screenshots/open-code-agent-history.png`):
    /// the Agent-Behaviour toggles surfaced on the tab. "Clear Badge" acknowledges the pane's completion/attention;
    /// the three BADGE items are PER-PANE override toggles (seeded from the pane's CURRENT effective gates, so
    /// the first flip preserves the other two — an absent override follows the global Settings → Agents
    /// default); the two NOTIFY items toggle the GLOBAL fire-time keys (notify preferences are global, not
    /// per-pane). Claude-only.
    /// **Prevent Sleep While Processing** (Batch 4) is a host-LOCAL `AgentPreferences` flag living in
    /// `PreferencesStore` (it rides the sidecar → applies on reconnect; default-OFF), bound to the SAME global
    /// `agent.preventSleep` Settings → Agent Behaviour edits. A `nil` store (preview / pre-injection) simply
    /// hides the row.
    @ViewBuilder
    private func rowContextMenu(_ row: RailRow) -> some View {
        // C3 BUG B: a mouse-reachable "Rename" — sets the pending-rename for THIS row's tab so its inline
        // field opens (even on a background tab). Twin of the ⌘R / palette "Rename Pane" entry.
        Button("Rename") { store.requestRenameTab(row.tabID) }
        // C3 BUG C d: an on-demand git-line re-probe for a terminal row (a video pane has no git surface).
        if row.kind == .terminal {
            Button("Refresh Git Status") { store.refreshGitSummary(for: row.id) }
        }
        // The mouse-reachable close (twin of the row's hover `×` and ⌘W on the focused pane).
        Button("Close Tab", role: .destructive) { store.requestClosePaneTree(row.id) }
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

    /// Type-safe SF Symbol for a pane kind. Reads the symbol *name* from the shared
    /// ``PaneChooserRegistry`` and wraps it in a type-safe `SFSymbol`.
    private static func symbol(for kind: PaneKind) -> SFSymbol {
        SFSymbol(rawValue: PaneChooserRegistry.option(for: kind).symbol)
    }
}

/// One native sidebar row: a system `Label` (icon + title, an optional muted subtitle line) with the
/// trailing status cluster — the read-only lock, the fused ``TabBadgeView`` badge, and the foreground-
/// process label on the ACTIVE row — and a hover-revealed close `×` (macOS). Selection/hover chrome is
/// the SYSTEM list selection (no custom card/plate). Inline rename swaps the title for the shared
/// committing ``InlineRenameField``.
private struct NavigatorRow: View {
    let row: RailRow
    let title: String
    let active: Bool
    let symbol: SFSymbol
    var onClose: () -> Void
    var onRename: (String) -> Void
    var onCancelRename: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    if row.isEditing {
                        InlineRenameField(seed: title, onCommit: onRename, onCancel: onCancelRename)
                    } else {
                        Text(title).lineLimit(1)
                    }
                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } icon: {
                #if os(macOS)
                if row.kind == .remoteGUI, let icon = AppIconResolver.icon(bundleID: row.bundleID) {
                    // A Windows row shows the HOST app's real icon (resolved locally from the endpoint's
                    // bundleID — both ends are Macs), the Mail-account/Finder-favorite source-list idiom.
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    // Accent-tinted sidebar icons — the modern system-sidebar idiom (Mail/Finder); the row
                    // text stays primary/secondary.
                    Image(systemSymbol: symbol)
                        .foregroundStyle(Color.accentColor)
                }
                #else
                Image(systemSymbol: symbol)
                    .foregroundStyle(Color.accentColor)
                #endif
            }
            Spacer(minLength: 4)
            if !row.isEditing {
                trailingMeta
                    .opacity(hovering ? 0 : 1)
            }
        }
        #if os(macOS)
        .overlay(alignment: .trailing) {
            if hovering, !row.isEditing {
                Button(action: onClose) {
                    Image(systemSymbol: .xmark)
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
            }
        }
        #endif
        .onHover { hovering = $0 }
        .help(row.cwd ?? "")
    }

    /// The trailing status cluster: the read-only lock (if locked), the fused `badge` (if any), then the
    /// foreground-process label on the ACTIVE row — all muted, right-aligned. Fades under the hover `×`.
    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if row.readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Read only")
                    .help("Read only")
            }
            if let badge = row.badge {
                TabBadgeView(kind: badge, progress: row.progress)
            }
            if active, let processLabel = row.processLabel, !processLabel.isEmpty {
                Text(processLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
                    .fill(Color.accentColor)
                    .frame(height: TabReorderInsertionLine.thickness)
                    .opacity(showsInsertionLine ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: showsInsertionLine)
                    .accessibilityHidden(true)
            }
    }
}

/// A small self-focusing inline rename `TextField` (C3 BUG B) — owns its own draft `@State` so
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
