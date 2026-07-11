// NavigatorColumn — the left sidebar navigator. macOS renders a flat "TABS" panel on a warm
// `Slate.Surface.ground` background (NOT native `.sidebar` vibrancy/inset-grouped selection — the host split
// item is a PLAIN item), a "TABS" header, a flat search field, and the active session's tabs as
// `SlateTabRow`s — ALWAYS grouped into By-Project `SlateSectionHeader` sections (the 2026-07-10 re-scope:
// the grouping/sort hamburger and manual drag-reorder are deleted; sections and rows follow creation
// order, and each pane's key is HOST-pushed — see `WorkspaceStore.paneProjectKey`). Top 40pt is reserved
// for the traffic lights under the hidden titlebar.
//
//   • the flat search field filters via the pure ``RailRowsBuilder/filtered(_:query:)`` (reused, not rebuilt);
//   • the rendered SECTIONS are the per-pane ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``
//     (a split tab's panes bucket into their OWN projects, so a header can't flicker with focus);
//   • each row carries the ``RailRow`` chrome (subtitle / fused badge / process label).
//
// iOS: a `List(selection:)` so NavigationSplitView pushes to the content column on a compact iPhone (a custom
// button list does not drive column navigation). Themed to match macOS but keeps the system list's navigation
// wiring; gains the same search field, grouped `Section`s, and badge under `#if os(iOS)`.

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

    #if os(macOS)
    /// Pointer-in-strip — the collapse toggle's hover-reveal gate (the otty behavior, 2026-07-11).
    @State private var stripHover = false
    #endif

    /// The rows the sidebar renders this eval — ALWAYS the memoized structural rows. The query filter
    /// (``RailRowsBuilder/filtered``) applies DOWNSTREAM over these same rows (`windowRows(from:)` +
    /// `sectionedByProject(_:tabOrder:query:)`), so search composes over the memo rather than bypassing it.
    /// The old non-empty-query arm called `RailRowsBuilder.rows(for: store)` directly, which re-registered
    /// every volatile store dict as an Observation dependency of this body — while a query sat in the field
    /// (it is never auto-cleared) EVERY agent/progress/git tick on ANY pane re-ran the full O(panes) build +
    /// sectioning + list diff on the main thread: exactly the storm ``RailRowsMemo`` exists to kill.
    /// Trade-off accepted: the filter now matches the CACHED copies of the volatile match fields (git-line
    /// subtitle / process label), which can be one memo generation stale — same staleness contract as the
    /// rest of the cached row chrome. The structural match fields (title / cwd) re-key the memo on every
    /// change, so they are never stale. Parity + memo-hit pinned in `RailRowsMemoTests`.
    private var renderedRows: [RailRow] {
        rowsMemo.rows(for: store)
    }

    /// The active tab's active pane — drives which row reads as selected. iOS-only consumer (the system
    /// `List(selection:)` binding); the macOS rows read selection LIVE inside ``SidebarLiveRow`` so a focus
    /// change repaints the two affected leaves directly — passing it down as an init param left the OLD
    /// selected row's raised card on screen (the same lazy-container stale-value class as the 2026-07-11
    /// "row title frozen at first render" fix; see ``RailRow/leafIdentity``).
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

    /// Map the always-on By-Project grouping onto the FILTERED rail rows, then attach a stable `ForEach`
    /// identity to each surviving section. Renders via the PER-PANE sectioning
    /// (``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``) so a split tab's panes bucket into their
    /// OWN projects and the section header can't flicker with focus; sections and rows follow creation
    /// order (`session.tabs` array order).
    private func buildSections(_ rows: [RailRow], query: String) -> [RowSection] {
        RailRowsBuilder.sectionedByProject(rows, tabOrder: store.flatOrderedTabIDs(), query: query)
            .enumerated()
            .map { index, group in
                RowSection(id: "\(index)|\(group.header ?? "")", header: group.header, rows: group.rows)
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
            // collapse animation; 0.15 still caught the tail). On top of that it is HOVER-REVEALED
            // (2026-07-11, the otty behavior): at rest the strip is empty; the pointer entering the strip
            // fades it in (`HoverSensor` — hit-test-transparent, the strip stays draggable).
            ZStack(alignment: .topTrailing) {
                Color.clear
                if let chrome {
                    PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                        .opacity(!chrome.sidebarCollapsed && stripHover ? 1 : 0)
                        .allowsHitTesting(!chrome.sidebarCollapsed && stripHover)
                        .animation(
                            chrome.sidebarCollapsed ? nil : Slate.Anim.standard.delay(0.25),
                            value: chrome.sidebarCollapsed,
                        )
                        .animation(Slate.Anim.smallFade, value: stripHover)
                        .padding(.top, 3)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: Slate.Metric.titlebarHeight)
            .background(HoverSensor { stripHover = $0 })
            HStack(spacing: 0) {
                // MERIDIAN L2: the panel label speaks the INSTRUMENT voice (mono + wide tracking) — same
                // register as `SlateSectionHeader`, one size up for the panel-level label.
                Text("TABS")
                    .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .semibold))
                    .tracking(Slate.Typeface.instrumentTracking)
                    .foregroundStyle(Slate.State.header)
                Spacer(minLength: 0)
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
                        // with the identity monogram; a window row's home is this derived section.
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

    /// One macOS tab row: the full chrome (badge / subtitle / process label). The VOLATILE chrome
    /// is read inside ``SidebarLiveRow`` (perf audit), so a pane's status tick re-renders that one leaf, not
    /// this sidebar body.
    private func macRow(_ row: RailRow) -> some View {
        SidebarLiveRow(
            store: store,
            row: row,
            fallbackTitle: defaultTitle(for: row.kind),
            isWindowRow: false,
            onSelect: { select(row.id) },
            onClose: { store.requestClosePaneTree(row.id) },
            onRename: { commitRename(row, to: $0) },
            onCancelRename: { store.clearTabRenameRequest() },
        )
        // The "row title frozen at first render" fix (2026-07-11): key the leaf's identity on the
        // memoized fields it renders (``RailRow/leafIdentity``) so a structural rebuild that retitles
        // this row (cwd landed / chooser resolved / rename) replaces the leaf instead of leaving the
        // first-render title on screen. Volatile chrome — including SELECTION — is read live inside
        // the leaf; focus-only changes keep the same identity (no churn).
        .id(row.leafIdentity)
        .contextMenu { rowContextMenu(row) }
    }

    /// One macOS WINDOWS row (MERIDIAN C4): the SAME `SlateTabRow` chrome as a tab row (rename / badge /
    /// hover close / context menu) — name-first like every other row (the thumbnail, then the monogram, were
    /// both pruned by user verdict); the owning APP is the instrument-voice subtitle (read live inside
    /// ``SidebarLiveRow`` so the model's own updates stay leaf-local).
    private func windowRow(_ row: RailRow) -> some View {
        SidebarLiveRow(
            store: store,
            row: row,
            fallbackTitle: defaultTitle(for: row.kind),
            isWindowRow: true,
            onSelect: { select(row.id) },
            onClose: { store.requestClosePaneTree(row.id) },
            onRename: { commitRename(row, to: $0) },
            onCancelRename: { store.clearTabRenameRequest() },
        )
        // Same leaf-identity key as ``macRow(_:)`` — see there.
        .id(row.leafIdentity)
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
    /// grouped `Section`s, and badge.
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

    /// One iOS list row: the system `Label` (navigation wiring via `.tag`) plus the trailing fused badge.
    /// The VOLATILE chrome (badge / lock / rename mode)
    /// is read inside ``IOSSidebarLiveRow`` (perf audit), so a pane's status tick re-renders that one leaf,
    /// not this sidebar body. The rename commit reuses ``commitRename(_:to:)`` so the iOS + macOS paths
    /// share the same semantics (rename the pane so the row title wins, then dismiss the field).
    private func iosRow(_ row: RailRow) -> some View {
        IOSSidebarLiveRow(
            store: store,
            row: row,
            fallbackTitle: defaultTitle(for: row.kind),
            symbol: Self.symbol(for: row.kind),
            onRename: { commitRename(row, to: $0) },
            onCancelRename: { store.clearTabRenameRequest() },
        )
        .tag(row.id)
        // Same leaf-identity key as the macOS ``macRow(_:)`` — see there.
        .id(row.leafIdentity)
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
    /// switch to the owning tab, focus the pane, then AUTO-CLEAR every agent
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
    /// `tab.allPaneIDs()`), so clicking its row must resolve the owning tab and `selectTab` it. Static + pure
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

/// One LIVE sidebar row (perf audit): the STRUCTURAL identity (pane id / title / cwd / kind) rides the
/// memoized ``RailRow``, while every VOLATILE field — the fused badge, git-line subtitle, foreground-process
/// label, read-only lock, inline-rename mode — is read fresh HERE via
/// ``RailRowsBuilder/liveChrome(for:store:)``. Observation still invalidates each row body when ANY pane's
/// status dict ticks (dict-granularity tracking), but that re-renders these cheap leaf bodies only — the
/// sidebar body above no longer rebuilds its rows + `disambiguated()` + sections + list diff per tick.
private struct SidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
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
        // SELECTION is volatile chrome and must be read HERE, not passed in from the sidebar body: inside
        // the lazy container a leaf can re-render (its own Observation deps) with the init-param values it
        // was CREATED with, so a param-carried `active` left the PREVIOUSLY selected row's raised card on
        // screen next to the new one (two "selected" rows). Reading `activePane` in the leaf both keeps the
        // paint correct (this body recomputes it every re-render) and makes a focus change invalidate
        // exactly the row leaves, never the sidebar body.
        let active = row.id == store.tree.activeSession?.activeTab?.activePane
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
