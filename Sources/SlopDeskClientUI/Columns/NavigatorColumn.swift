// NavigatorColumn — the left sidebar navigator: a flat tabs panel on the `Slate.Surface.field`
// chrome floor (NOT native `.sidebar` vibrancy — the host split item is a PLAIN item), a header
// SEARCH FIELD spanning the full row width (it shares the tab cards' gutter — no trailing
// controls), and rows ALWAYS grouped into By-Project sections under a gutter-chevron + NAME group
// header that shares ONE left rail with its rows — the live git line (mono metadata) on a second
// line beneath the name, the hidden-row count trailing while collapsed
// (``SidebarSectionHeaderRow``, collapsible with an animated glide; each pane's key is
// HOST-pushed — see `WorkspaceStore.paneProjectKey`; sections and rows follow creation order).
// Top 40pt is reserved for the traffic lights under the hidden titlebar.
//
// iOS: a `List(selection:)` so NavigationSplitView pushes to the content column on a compact iPhone (a custom
// button list does not drive column navigation). Themed to match macOS but keeps the system list's navigation
// wiring; keeps the system `.searchable` field, grouped `Section`s, and badge under `#if os(iOS)`.

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskInspector // PendingToolSummary — the working-row tooltip's todo-scent line
import SlopDeskVideoProtocol // AgentPreferences — the `preventSleep` flag the tab context menu toggles
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The app-global connection — the FOOTER island's model (user-directed 2026-08-09: the status
    /// came back, and with a vertical tab list its home is under that list). `nil` (previews / iOS,
    /// which mounts the cluster in its own toolbar) simply omits the footer.
    var connection: AppConnection?

    /// Opens the Connect-to-Host editor from the footer island. No-op default keeps the column
    /// standalone-mountable.
    var onConnect: () -> Void = {}

    /// The live ``PreferencesStore`` — threaded in so the tab context menu can surface the host-LOCAL
    /// **Prevent Sleep While Processing** flag (`docs/ui-shell/screenshots/open-code-agent-history.png`
    /// shows it on the tab menu). The macOS sidebar is hosted in a SEPARATE `NSHostingController` that does not
    /// inherit the WindowGroup environment, so the split-view host passes it explicitly (`nil` on a preview /
    /// pre-injection ⇒ the Prevent-Sleep row is hidden, never a dead control). iOS inherits it via the
    /// `NavigationSplitView` but still passes it explicitly for parity.
    var preferences: PreferencesStore?

    /// The cross-container pane-drag rendezvous — makes every sidebar row a DROP TARGET for a live pane
    /// drag (the pane moves BESIDE that row's pane, its tab revealed) and mounts the New-Tab drop slot
    /// while a drag is in flight. Threaded in like `preferences` (the sidebar's `NSHostingController`
    /// inherits no environment); `nil` (previews / iOS) leaves the rows plain.
    var paneDrag: PaneDragCoordinator?

    /// The transient sidebar search query — narrows the rows via the pure
    /// ``RailRowsBuilder/filtered``. On iOS it feeds the system `.searchable`; on macOS the
    /// panel's own header search field (user-directed 2026-08-03: the header row IS the search
    /// bar — it replaced the caps "TABS" label). Session-scoped, never persisted.
    @State private var query = ""

    /// The memoized row model: the sidebar body reads its rows from HERE so a settled body
    /// registers NO Observation dependency on the store's volatile per-pane dicts — a status/git/progress
    /// tick then re-renders only the cheap ``SidebarLiveRow`` leaves (which read their own pane's chrome
    /// live), never the whole rows + `disambiguated()` + sectioning + list-diff pass. Plain class in
    /// `@State` (NOT `@Observable`): its mutation during a body eval must not re-invalidate anything.
    @State private var rowsMemo = RailRowsMemo()

    #if os(macOS)
    /// The COLLAPSED project groups (header chevron toggled shut), keyed by ``collapseKey(_:)``.
    /// Session-scoped presentation state — a fresh launch opens every group.
    @State private var collapsedSections: Set<String> = []

    /// The selection plate's morph namespace, shared by EVERY row in the panel — including rows in
    /// different project islands, so the plate travels across a group boundary the same way it
    /// travels between two rows of one project.
    @Namespace private var selectionMorph
    #endif

    /// The focused pane — the ONE volatile value the sidebar body watches, and only so the selection
    /// plate's morph has an animated transaction to ride (see the list's `.animation`).
    private var focusedPaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The collapse-set key for a section: its normalized project key, or the sentinel for the
    /// keyless "Other" bucket (whose `projectKey` is `nil` but which still collapses).
    static func collapseKey(_ projectKey: String?) -> String {
        projectKey ?? "\u{2205}other"
    }

    /// The rows the sidebar renders this eval — ALWAYS the memoized structural rows. The query filter
    /// (``RailRowsBuilder/filtered``) applies DOWNSTREAM over these same rows
    /// (`sectionedByProject(_:tabOrder:query:)`), so search composes over the memo rather than bypassing it.
    /// Calling `RailRowsBuilder.rows(for: store)` directly for a non-empty query instead would re-register
    /// every volatile store dict as an Observation dependency of this body — while a query sat in the field
    /// (it is never auto-cleared) EVERY agent/progress/git tick on ANY pane would re-run the full O(panes)
    /// build + sectioning + list diff on the main thread: exactly the storm ``RailRowsMemo`` exists to kill.
    /// Trade-off accepted: the filter matches the CACHED copies of the volatile match fields (git-line
    /// subtitle / process label), which can be one memo generation stale — same staleness contract as the
    /// rest of the cached row chrome. The structural match fields (title / cwd) re-key the memo on every
    /// change, so they are never stale. Parity + memo-hit pinned in `RailRowsMemoTests`.
    private var renderedRows: [RailRow] {
        rowsMemo.rows(for: store)
    }

    /// The active tab's active pane — drives which row reads as selected. iOS-only consumer (the system
    /// `List(selection:)` binding); the macOS rows read selection LIVE inside ``SidebarLiveRow`` so a focus
    /// change repaints the two affected leaves directly — passing it down as an init param would leave the OLD
    /// selected row's raised card on screen (the same lazy-container stale-value class as the "row title
    /// frozen at first render" fix; see ``RailRow/leafIdentity``).
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The scene overlay reducer, re-injected by the split host (the hosted column does not inherit
    /// the WindowGroup environment). Read for the modal pointer shield below; `nil` (previews /
    /// tests) reads as "no modal up".
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    var body: some View {
        Group {
            #if os(macOS)
            macSidebar
            #else
            iosSidebar
            #endif
        }
        // ⚠️ THE MODAL POINTER SHIELD — the sidebar lives in its OWN NSHostingView inside the AppKit
        // split, so a modal card floating over it (the window root's overlay layer) does NOT occlude
        // its hover tracking: AppKit tracking areas are rect-based and keep firing under the card,
        // and the tab rows lit their hover plates while the pointer was on the palette. While a
        // modal card is up the column goes hit-test-deaf — hover obeys the same occlusion the card's
        // dismiss floor already imposes on clicks. Global Search (non-modal by design) leaves it open.
        .allowsHitTesting(!(overlayCoordinator?.anyModalVisible ?? false))
    }

    // MARK: - Sections (store-derived order × pane rows × search filter)

    /// One rendered sidebar section: an optional `header` (the group title, `nil` ⇒ the ungrouped flat list),
    /// the section's normalized By-Project key (the ``WorkspaceStore/projectGitSummary`` lookup for the
    /// header's git segment; `nil` ⇒ the "Other" bucket), and the rows in render order. A pure
    /// presentational value — identity is the group's stable key so the `ForEach` does not churn when a
    /// sibling section's contents change.
    private struct RowSection: Identifiable {
        let id: String
        let header: String?
        let projectKey: String?
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
                RowSection(
                    id: "\(index)|\(group.header ?? "")", header: group.header,
                    projectKey: group.projectKey, rows: group.rows,
                )
            }
    }

    #if os(macOS)
    /// macOS: the flat "TABS" panel — name rows + white-card active, grouped By-Project sections.
    /// Paints its own warm background (the host `NSSplitViewItem` is a plain item, so there is no
    /// native vibrancy/rounding).
    private var macSidebar: some View {
        let allRows = renderedRows
        let sections = buildSections(allRows, query: query)
        // The beds are dealt for the WHOLE column at once — a group whose basename hashes onto the
        // island above it is re-dealt, which no per-section lookup could know (see
        // ``Slate/ProjectTint/Deal``). A HEADERLESS section deals as keyless: it draws no bed, so it
        // must neither consume an identity nor constrain the group under it.
        let deal = Slate.ProjectTint.Deal(
            keys: sections.map { $0.header == nil ? nil : $0.projectKey },
        )
        return VStack(alignment: .leading, spacing: 0) {
            // Traffic-light strip — BARE. The column reserves the band the lights stand in and
            // nothing else: the sidebar toggle that used to sit here is mounted at WINDOW level now
            // (``WindowSidebarToggle``, user-directed 2026-08-09). It had to leave, because THIS
            // column travels: the split animates its width on a collapse, so a button parked in it
            // slid leftward under the traffic lights every time it was clicked. A control that never
            // moves cannot live inside a container that does.
            Color.clear
                .frame(height: Slate.Metric.titlebarHeight)
            // The header row IS the search bar (user-directed 2026-08-03 — it replaced the caps
            // "TABS" label AND its trailing groups menu, both user-retired): a quiet inset field
            // on the hover tint, filtering the rows below through the SAME pure
            // `RailRowsBuilder.filtered` the iOS `.searchable` rides. Clearing is one click (the
            // ⓧ appears only while a query is live). Full-row width — the field shares the LIST's
            // 8pt gutter, so it reads as wide as the tab cards under it.
            HStack(spacing: Slate.Metric.space1) {
                Image(systemSymbol: .magnifyingglass)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.icon)
                // AppKit-backed on purpose: a SwiftUI `TextField` at footnote size bumps its
                // text up 1pt on focus (cell-draw vs field-editor baseline split — see
                // `SlateSearchField`'s header). User-reported 2026-08-03.
                SlateSearchField(placeholder: "Search tabs", text: $query)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemSymbol: .xmarkCircleFill)
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.icon)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .frame(height: Slate.Metric.heightControl)
            .slateChromeFieldPlate()
            // The list's own gutter (the LazyVStack below pads 8) — search bar and tab cards
            // share one width.
            .padding(.horizontal, 8)
            // The band between the field and the first project island. `space3`, not the old 6:
            // the islands are beds now, and a bed starting a breath under the search plate read as
            // if the field were part of the first group (user-reported 2026-08-09).
            .padding(.bottom, Slate.Metric.space3)

            ScrollView {
                // `space2` between islands, not the old 2pt row gap: the beds are the grouping now,
                // and two beds a hairline apart would read as one striped surface.
                LazyVStack(alignment: .leading, spacing: Slate.Metric.space2) {
                    if allRows.isEmpty {
                        emptyLabel("No tabs open")
                    } else if sections.isEmpty {
                        emptyLabel("No matching tabs")
                    } else {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            projectIsland(section, tint: deal[index])
                        }
                    }
                }
                .padding(.horizontal, 8)
                // THE MORPH'S TRANSACTION. `matchedGeometryEffect` interpolates only inside an
                // animated transaction, and the rows that flip `active` are leaves the container
                // does not otherwise re-render — so without an explicit `value` to watch here the
                // plate would still teleport. Reading the focused pane id costs this body ONE cheap
                // dependency (the id, not the volatile per-pane dicts `RailRowsMemo` exists to keep
                // out); the rows array is memoized, so the re-eval is a sectioning pass, not a
                // rebuild. Selection is STILL read inside each leaf — that contract is about
                // correctness (a param-carried `active` strands the old row lit) and stands.
                .animation(Slate.Anim.selectionMorph, value: focusedPaneID)
                // Captures the enclosing NSScrollView (must sit INSIDE the scroll content) so a pane
                // drag parked at the list's top/bottom edge auto-scrolls rows into reach.
                .background(sidebarScrollCapturer)
            }
            .scrollIndicators(.hidden) // scrollbars stay invisible for the flat sidebar look
            .frame(maxHeight: .infinity)
            // The list VIEWPORT rect — a pane-drag row hit counts only inside it (LazyVStack keeps
            // scrolled-away rows mounted, so a bare row rect could sit outside the visible clip).
            .background(sidebarListFrameReader)

            // The New-Tab drop slot: mounted (and its frame registered) only while a pane drag is in
            // flight, pinned ABOVE the footer so it never needs scrolling into view.
            if let paneDrag {
                NewTabDropSlot(coordinator: paneDrag)
            }

            // THE CONNECTION ISLAND, anchored to this column's foot (user-directed 2026-08-09).
            // It is the LAST BED in a column of beds — same tint family, same corner, same gutter as
            // the project islands above it — which is what earns it the sidebar's most permanent
            // slot: it is not a status widget bolted under a list, it is the list's final member,
            // and the one whose subject is the machine the rest of them run on. When the tabs turn
            // horizontal the island goes with them (``SlateTitlebar``); there is exactly one of it
            // on screen at any time.
            if let connection {
                ConnectionStatusMount(
                    store: store, connection: connection, onConnect: onConnect, layout: .stacked,
                )
                // The list's own gutter — the island lines up with the project beds above it.
                .padding(.horizontal, 8)
                // The air the island needs is ABOVE it, not inside it: `space3` separates it from
                // the last project bed by more than the `space2` that separates two projects, so it
                // reads as the column's foot rather than as one more group.
                .padding(.top, Slate.Metric.space3)
                .padding(.bottom, Slate.Metric.space2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Slate.Surface.field)
    }

    /// One project's ISLAND: the group's header and its rows on one bed washed in the project's
    /// identity hue (``SlateProjectIsland``). A section with no header is the ungrouped flat list —
    /// it gets no bed, because there is no project for a colour to name.
    @ViewBuilder
    private func projectIsland(_ section: RowSection, tint: Color) -> some View {
        let collapseKey = Self.collapseKey(section.projectKey)
        let collapsed = collapsedSections.contains(collapseKey)
        let rows = VStack(alignment: .leading, spacing: 2) {
            if let header = section.header {
                SidebarSectionHeaderRow(
                    store: store, title: header, projectKey: section.projectKey,
                    collapsed: collapsed, count: section.rows.count,
                    rows: section.rows,
                    onToggle: {
                        // Animated (otty snaps its collapse in one frame; the glide is a deliberate
                        // refinement) — the chevron turns, the rows fade, and the islands below
                        // slide up in the same curve.
                        withAnimation(Slate.Anim.standard) {
                            if collapsed { collapsedSections.remove(collapseKey) }
                            else { collapsedSections.insert(collapseKey) }
                        }
                    },
                )
            }
            if !collapsed {
                ForEach(section.rows) { row in
                    macRow(row)
                }
            }
        }
        if section.header == nil {
            rows
        } else {
            SlateProjectIsland(tint: tint) { rows }
        }
    }

    /// One macOS tab row: the full chrome (badge / subtitle / process label). The VOLATILE chrome
    /// is read inside ``SidebarLiveRow``, so a pane's status tick re-renders that one leaf, not
    /// this sidebar body.
    private func macRow(_ row: RailRow) -> some View {
        SidebarLiveRow(
            store: store,
            row: row,
            fallbackTitle: defaultTitle(for: row.kind),
            morph: selectionMorph,
            onSelect: { select(row.id) },
            onClose: { store.requestClosePaneTree(row.id) },
            onRename: { commitRename(row, to: $0) },
            onCancelRename: { store.clearTabRenameRequest() },
        )
        // Keys the leaf's identity on the memoized fields it renders (``RailRow/leafIdentity``) so a
        // structural rebuild that retitles this row (cwd landed / chooser resolved / rename) replaces
        // the leaf instead of leaving the first-render title on screen. Volatile chrome — including
        // SELECTION — is read live inside the leaf; focus-only changes keep the same identity (no churn).
        .id(row.leafIdentity)
        .contextMenu { rowContextMenu(row) }
        // Pane-drag drop target: register this row's screen rect (lazily — nothing publishes per
        // layout) + draw the accent ring while it is the live drag's resolved destination.
        .background(rowFrameReader(row.id))
        .overlay(RowDropHighlight(coordinator: paneDrag, paneID: row.id))
    }

    /// The per-row screen-frame reader — a no-op without a drag coordinator (previews).
    @ViewBuilder
    private func rowFrameReader(_ paneID: PaneID) -> some View {
        if let paneDrag {
            DropTargetFrameReader(key: .sidebarRow(paneID), coordinator: paneDrag)
        }
    }

    /// The sidebar list viewport reader — see the ScrollView mount above.
    @ViewBuilder
    private var sidebarListFrameReader: some View {
        if let paneDrag {
            DropTargetFrameReader(key: .sidebarList, coordinator: paneDrag)
        }
    }

    /// The enclosing-NSScrollView capturer for the drag auto-scroll — see the LazyVStack mount above.
    @ViewBuilder
    private var sidebarScrollCapturer: some View {
        if let paneDrag {
            SidebarScrollCapturer(coordinator: paneDrag)
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.secondary)
            .padding(.horizontal, Slate.Metric.tabRowInset) // the rows' text rail
            .padding(.vertical, 6)
    }
    #else
    /// iOS: a system `List(selection:)` so NavigationSplitView pushes to content on compact; themed to match. Gains
    /// the system `.searchable` field (keeps the `List` as the column root so the navigation push is unchanged),
    /// grouped `Section`s, and badge.
    private var iosSidebar: some View {
        // TERMINAL panes only, matching the macOS panel — see `macSidebar`.
        let allRows = renderedRows
        let sections = buildSections(allRows, query: query)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
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
        .background(Slate.Surface.field)
        .tint(Slate.State.accent)
        .searchable(text: $query, prompt: "Search tabs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.newTerminalPane(.newTab) } label: { Image(systemSymbol: .plus) }
            }
        }
    }

    /// One iOS list row: the system `Label` (navigation wiring via `.tag`) plus the trailing fused badge.
    /// The VOLATILE chrome (badge / lock / rename mode)
    /// is read inside ``IOSSidebarLiveRow``, so a pane's status tick re-renders that one leaf,
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

    /// Commit an inline row rename: rename the pane (so ``RailRowsBuilder/rowTitle`` — which reads
    /// the pane spec — surfaces it, winning over the folder name) then clear the pending state so the field
    /// closes. A blank draft renames nothing (``WorkspaceStore/renamePane(_:to:)`` no-ops), keeping the folder
    /// name; the pending state still clears so the field dismisses. Shared across the macOS + iOS row builders
    /// so both paths land the same commit semantics.
    private func commitRename(_ row: RailRow, to text: String) {
        store.renamePane(row.id, to: text)
        store.clearTabRenameRequest()
    }

    // MARK: - Tab context menu (Clear Badge + per-pane badge overrides + notify toggles)

    /// The right-click / long-press menu for a sidebar row (`docs/ui-shell/screenshots/open-code-agent-history.png`):
    /// the Agent-Behaviour toggles surfaced on the tab. "Clear Badge" acknowledges the pane's completion/attention;
    /// the three BADGE items are PER-PANE override toggles (seeded from the pane's CURRENT effective gates, so
    /// the first flip preserves the other two — an absent override follows the global Settings → Agents
    /// default); the two NOTIFY items toggle the GLOBAL fire-time keys (notify prefs are global, not per-pane).
    /// Claude-only.
    /// **Prevent Sleep While Processing** is a host-LOCAL `AgentPreferences` flag in
    /// `PreferencesStore` (rides the sidecar → applies on reconnect; default-OFF). Surfaced only when the store
    /// is threaded in (the split-view host now does), bound to the SAME global `agent.preventSleep` Settings →
    /// Agent Behaviour edits. A `nil` store (preview / pre-injection) hides the row.
    @ViewBuilder
    private func rowContextMenu(_ row: RailRow) -> some View {
        // A mouse-reachable "Rename" — sets the pending-rename for THIS row's tab so its inline
        // field opens (even on a background tab). Twin of the ⌘R / palette "Rename Pane" entry.
        // ("Refresh Git Status" moved to the SECTION HEADER's menu — git is project-scoped now.)
        Button("Rename") { store.requestRenameTab(row.tabID) }
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
        // Prevent Sleep While Processing — the host-LOCAL system-sleep assertion gate. Bound to
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

/// The sidebar row tooltip's pure text assembly, pulled out of ``SidebarLiveRow/body`` so it's
/// headlessly testable: the full raw cwd, the row's untruncated prose readout (question / scent /
/// label — overflow recovery for what line 2 clipped), and the last command's
/// `make check · 1.3s · exit 0` line. Only non-empty parts render; a raw `\(cwd)` interpolation of the
/// `String?` field would render the literal `Optional(...)` wrapper, so every part is unwrapped first.
enum SidebarRowTooltip {
    static func text(
        cwd: String?, detail: String?, lastCommand: String?, viewers: [String] = [],
        holders: [String] = [],
    ) -> String? {
        // Who ELSE has this pane ON SCREEN (``WorkspaceStore/paneViewers(for:)``) and who else holds
        // a CHANNEL on its PTY (``WorkspaceStore/paneHolders(for:)``). Two different facts, both
        // useful: a client can be looking at a pane it does not hold, and holding one it is not
        // showing. Viewing first — it is the softer claim.
        let alsoOpen = viewers.isEmpty ? nil : "Also open on \(viewers.joined(separator: ", "))"
        let heldBy = holders.isEmpty ? nil : "Held by \(holders.joined(separator: ", "))"
        let parts = [cwd, detail, lastCommand, alsoOpen, heldBy].compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The tooltip's last-command line from a finished block: `command · duration · exit N` (parts
    /// missing on the block are simply omitted). Pure so the assembly is unit-pinned.
    static func commandLine(_ block: CommandBlock) -> String? {
        let command = block.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [command.isEmpty ? nil : command, block.durationLabel, block.statusLabel]
            .compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The project section header — the top line of the group's ``SlateProjectIsland``: the FOLDER
/// glyph, the group's NAME (11pt system, semibold — the parent stands a step firmer than its rows)
/// and the live git line under it (the instrument mono — data, not identity).
///
/// The header stands on the island's own text rail (``Slate/Metric/islandRail``), the SAME rail the
/// row titles keep, so the folder glyph and the titles below it read off one line. It used to indent
/// past its rows because a disclosure chevron hung in a gutter before it; that chevron now stands at
/// the island's TRAILING rail instead (user-directed 2026-08-08). Inside an island the group is
/// already drawn — the bed IS the grouping — so an arrow parked in the reading column was restating
/// a boundary the surface had already stated, and it was the one glyph pinned hardest to the left.
///
/// The name is the basename `section.header` already carries
/// (worktree-collision-qualified), never the full path; the path lives in the hover tooltip. While
/// open the git line (`main ↑2 !3`) rides a SECOND full-width line so name and git never fight for
/// one row; while collapsed the header folds to one line with the hidden-row COUNT trailing — mono
/// metadata that borrows the strongest ATTENTION ink of the rows it hides
/// (``StatusPresentation/attentionRollupInk(_:)``), so folding a group never mutes a waiting
/// agent. No caps, no rule: groups separate by the header band's own air (a bare header keeps the
/// 24pt band; a git-lined one grows to fit). Tapping toggles the group shut. Reads its git summary
/// + roll-up chrome INSIDE its own body so a git/status tick re-renders only the (cheap) header
/// leaves, mirroring ``SidebarLiveRow``. Internal (not private) so the opt-in snapshot render can
/// mount the REAL header.
struct SidebarSectionHeaderRow: View {
    let store: WorkspaceStore
    /// The group's display name — the basename header (`section.header`), which is also the keyless
    /// bucket's visible label ("Other") and the AX label.
    let title: String
    let projectKey: String?
    var collapsed: Bool = false
    /// The group's row count — the muted trailing number while collapsed (how many tabs are hidden).
    var count: Int = 0
    /// The group's rows — read while collapsed to fuse the hidden rows' badges into the count's
    /// roll-up ink, and always to work out whether the FOCUSED pane lives in this group. Structural
    /// identity; the volatile badge reads happen in `body` so a status tick re-renders this leaf,
    /// never the sidebar body. Default keeps the snapshot-render mount unchanged.
    var rows: [RailRow] = []
    var onToggle: () -> Void = {}

    var body: some View {
        let summary = projectKey.flatMap { store.projectGitSummary[$0] }
        // Which project is FOCUSED — read here, in the header leaf, not in the sidebar body: a focus
        // change then repaints the two affected headers instead of re-running the whole rows +
        // sectioning + list-diff pass (the same leaf-scoped contract `SidebarLiveRow` keeps for
        // selection).
        let current = Self.holdsFocus(rows: rows, store: store)
        // The header's leading anatomy: the dim folder, then the name — both on the island's text
        // rail, so the glyph starts exactly where the row titles below it do. Baseline-aligned: the
        // folder sits on the NAME line; the git line hangs beneath.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The folder — the group is a place, spoken in the header's own ink; the one pictogram
            // the monochrome rail keeps. It stays MONOCHROME even though the group now has an
            // identity hue: the bed carries that colour, and tinting the glyph too would say the
            // same thing twice (user-directed 2026-08-08).
            Image(systemSymbol: .folderFill)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(headerInk(current: current))
                .padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 1) {
                // `nerdAware` — a project folder named with a nerd-font glyph draws it from the
                // bundled symbols face instead of a notdef box.
                Text.nerdAware(title, size: Slate.Typeface.footnote)
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(headerInk(current: current))
                    .lineLimit(1)
                    .truncationMode(.tail)
                let segments = Self.detailSegments(collapsed: collapsed, summary: summary)
                if !segments.isEmpty {
                    // The git line is DATA — the instrument mono, one register with the rows' process
                    // labels. But it is data with STATES, and rendering all of them in one flat grey
                    // made the counts that matter (a conflict, unpushed work) read exactly like the
                    // ones that don't. Each run wears its own ink instead; the mono grid keeps the
                    // line from turning into confetti.
                    Self.gitDetailLine(segments)
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .accessibilityLabel(segments.map(\.text).joined(separator: " "))
                }
            }
            Spacer(minLength: 6)
            if let trailing = Self.trailingCount(collapsed: collapsed, count: count) {
                // The hidden-row count — mono metadata that wears the strongest attention ink of
                // the rows it hides (`nil` ⇒ the muted register): a collapsed group still says
                // "something in here waits".
                let rollup = StatusPresentation.attentionRollupInk(
                    rows.map { RailRowsBuilder.liveChrome(for: $0, store: store).badge },
                )
                Text(trailing)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(rollup ?? Slate.Text.tertiary)
                    .padding(.trailing, 6)
            }
            // One chevron glyph rotating 0°↔90° (not a `.chevronDown` swap) so the toggle TURNS
            // with the group animation instead of teleporting between two symbols. It stands at the
            // island's TRAILING rail, out of the reading column — see the type note.
            Image(systemSymbol: .chevronRight)
                // `.medium`, not `.semibold` — a 1px-stroke glyph; semibold at this size reads a
                // full step chunkier.
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.State.header)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
        }
        // Both rails are the island's, so the folder lands on the row titles' x and the chevron on
        // their trailing-slot x.
        .padding(.horizontal, Slate.Metric.islandRail)
        .padding(.vertical, 4)
        // A bare header keeps the measured 24pt band; a git-lined one grows to fit its second line.
        .frame(minHeight: Slate.Metric.heightSectionHeader)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .help(Self.tooltip(projectKey: projectKey, summary: summary) ?? "")
        .contextMenu {
            if let projectKey {
                Button("Refresh Git Status") { store.refreshGitSummary(forProject: projectKey) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    /// WHICH project is open, said on the ink ladder the sidebar just rebuilt: the focused group's
    /// folder and name step up to the body ink; every other group stays on the quiet rung. Chosen
    /// over a second alpha on the bed, a hue edge, and dropping the other groups' colour altogether
    /// (user-directed 2026-08-08) — a step on a ladder that already exists spends no new vocabulary,
    /// and it cannot collide with the SELECTED ROW's dark chip standing inside the same island.
    private func headerInk(current: Bool) -> Color {
        current ? Slate.Text.primary : Slate.Text.secondary
    }

    /// Does the FOCUSED pane live in this group? Pure over the rows + the tree's focus, so the
    /// marking rule is unit-pinnable and the leaf's only store read is the focus itself.
    static func holdsFocus(rows: [RailRow], store: WorkspaceStore) -> Bool {
        guard let focused = store.tree.activeSession?.activeTab?.activePane else { return false }
        return rows.contains { $0.id == focused }
    }

    /// The header's muted trailing slot: the hidden-row count while COLLAPSED (the otty
    /// collapsed-header number — `nil` guards the impossible empty group). An open header keeps the
    /// slot empty; its git line lives on the second line. Pure + static so the swap is unit-pinned.
    static func trailingCount(collapsed: Bool, count: Int) -> String? {
        collapsed && count > 0 ? "\(count)" : nil
    }

    /// The header's SECOND line: the live git line (branch + dirt) on a full-width line of its own
    /// under the folder name, so neither fights the other for one row's width. A collapsed header
    /// folds it away — the count speaks instead. Pure + static so the swap is unit-pinned.
    static func detailLine(collapsed: Bool, summary: PaneGitSummary?) -> String? {
        collapsed ? nil : summary.flatMap(gitLine)
    }

    /// ``detailLine(collapsed:summary:)`` in its RENDERED form — the per-run segments the header paints,
    /// empty when the line is folded away or there is no repo. Same swap, same dialect, one ink per run.
    static func detailSegments(collapsed: Bool, summary: PaneGitSummary?) -> [GitSegment] {
        guard !collapsed, let summary else { return [] }
        return gitSegments(summary)
    }

    /// The header's hover tooltip: the full project path (the name line deliberately shows only the
    /// basename), then the git line. Pure + static so the assembly is unit-pinned.
    static func tooltip(projectKey: String?, summary: PaneGitSummary?) -> String? {
        let parts = [projectKey, summary.flatMap(Self.gitLine)].compactMap { part -> String? in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The git line (the open header's second line AND the tooltip's second line):
    /// `main ↑2 ↓1 +3 !4 ?5 ~1 $2` — branch first, then only the NON-ZERO sigils in fixed order
    /// (ahead/behind/staged/modified/untracked/conflicted/stash). The sigils speak the prompt-theme
    /// dialect every git prompt already taught the eye: `↑`/`↓` divergence, `+` staged, `!`
    /// modified, `?` untracked, `~` merge conflicts, `$` stash. `nil` for a non-repo summary (a
    /// plain directory has no git concept). Pure + static so the dialect is unit-pinned.
    static func gitLine(_ g: PaneGitSummary) -> String? {
        let segments = gitSegments(g)
        guard !segments.isEmpty else { return nil }
        return segments.map(\.text).joined(separator: " ")
    }

    /// What one run of the git line MEANS — the axis its ink is chosen on. Roles, not colours: the
    /// palette resolution lives in ``ink(_:)`` so the dialect stays pure and headlessly pinnable.
    enum GitInk: CaseIterable, Sendable {
        /// The branch name — identity, not a count.
        case branch
        /// `↑`/`↓` — where this branch sits against its upstream.
        case divergence
        /// `+` — staged and ready to commit.
        case staged
        /// `!` — unstaged worktree changes.
        case modified
        /// `?` — files git does not know about yet.
        case untracked
        /// `~` — an unmerged state. The one run that genuinely needs a human.
        case conflicted
        /// `$` — parked work.
        case stash
    }

    /// One run of the git line: the text exactly as ``gitLine(_:)`` spells it, plus its ink role.
    struct GitSegment: Equatable, Sendable {
        let text: String
        let ink: GitInk

        /// The run stripped to its SIGIL — the leading glyph the dialect gives it (`↑2` → `↑`), which
        /// is the whole run minus the count. `nil` for the branch: it is a NAME, not a sigil, so it
        /// has no compact form (it truncates instead).
        var symbol: String? {
            guard ink != .branch else { return nil }
            return text.first.map(String.init)
        }
    }

    /// The git line SPLIT into its runs — the dialect above, one segment per sigil. Empty for a
    /// non-repo summary (a plain directory has no git concept). Pure + static so the dialect is
    /// unit-pinned in one place: ``gitLine(_:)`` joins these, so the painted line and the tooltip /
    /// accessibility line can never drift.
    static func gitSegments(_ g: PaneGitSummary) -> [GitSegment] {
        guard g.hasRepo else { return [] }
        var parts = [GitSegment(text: g.branch.isEmpty ? "detached" : g.branch, ink: .branch)]
        if g.ahead > 0 { parts.append(GitSegment(text: "↑\(g.ahead)", ink: .divergence)) }
        if g.behind > 0 { parts.append(GitSegment(text: "↓\(g.behind)", ink: .divergence)) }
        if g.staged > 0 { parts.append(GitSegment(text: "+\(g.staged)", ink: .staged)) }
        if g.modified > 0 { parts.append(GitSegment(text: "!\(g.modified)", ink: .modified)) }
        if g.untracked > 0 { parts.append(GitSegment(text: "?\(g.untracked)", ink: .untracked)) }
        if g.conflicted > 0 { parts.append(GitSegment(text: "~\(g.conflicted)", ink: .conflicted)) }
        if g.stash > 0 { parts.append(GitSegment(text: "$\(g.stash)", ink: .stash)) }
        return parts
    }

    /// The ink for one run — every role its own, no two alike (hue RESTORED, user-directed
    /// 2026-08-10: the rail is no longer held to a monochrome readout).
    ///
    /// The four WORKTREE states are a RAMP, not a set of labels: `+staged` → `!modified` → `?untracked` →
    /// `~conflicted` is "how far this work is from being committed" (in the index → in the worktree → git
    /// has never seen it → it is broken), and the palette's chromatics sweep that distance exactly:
    /// green → yellow → orange → red, monotone, in the SAME left-to-right order the sigils already appear.
    /// The ramp is the reason `?` is orange rather than one more grey — it is not a sixth arbitrary
    /// colour, it is the rung between "you changed it" and "it is broken".
    ///
    /// Off the ramp: `↑↓` divergence is where the branch sits against its upstream and `$` stash is work
    /// parked to one side — neither is a worktree state, so both take a cool hue and stay out of the warm
    /// sweep. The BRANCH keeps the body ink: it is the line's identity, not a count.
    ///
    /// The hues cannot collide with the ground they stand on: a project island's bed is solved to the
    /// 195°–340° arc precisely so red / amber / green stay the status vocabulary's alone
    /// (``Slate/ProjectTint``).
    ///
    /// Nothing here resolves to the tertiary metadata grey — painting the whole line in it is what made a
    /// conflict count read exactly like a branch name.
    static func ink(_ role: GitInk) -> Color {
        switch role {
        case .branch: Slate.Text.secondary
        case .divergence: Slate.Status.info
        case .staged: Slate.Status.ok
        case .modified: Slate.Status.warn
        case .untracked: Slate.Chroma.orange
        case .conflicted: Slate.Status.err
        case .stash: Slate.Chroma.purple
        }
    }

    /// The weight for one run — a second channel the palette cannot supply, on three rungs.
    ///
    /// Every COUNT is set heavy: the sigil runs are the readout, and at 10 pt mono a regular weight
    /// leaves them thin enough that the colour is doing all the work. The BRANCH stays regular — it is
    /// the line's identity, not a status, and keeping it light is what lets the counts read as a group.
    ///
    /// `~conflicted` goes one rung further still, to fix a ranking hue gets backwards: the palette's red
    /// is a mid tone while its yellow is bright, so by contrast against the sidebar the ONE state that
    /// genuinely needs a human pulls the eye LEAST of the coloured runs. That inversion cannot be fixed by
    /// re-assigning hues without lying about what the states mean. Weight is free of the palette — and it
    /// survives the CVD collapse the hue set has (under protanopia `+staged` and `~conflicted` land close
    /// enough to be indistinguishable by hue alone; the sigils already carry the meaning, and the weight
    /// step adds a second non-colour cue).
    static func weight(_ role: GitInk) -> Font.Weight {
        switch role {
        case .branch: .regular
        case .conflicted: .bold
        case .divergence,
             .modified,
             .staged,
             .stash,
             .untracked: .semibold
        }
    }

    /// The STATUS runs stripped to their sigils — `↑2 ↓1 !3` → `↑ ↓ !` — for the line's compact form.
    /// The counts go; the ink and the weight stay, so a squeezed line still says exactly WHICH states
    /// are live. The branch is dropped (it has no sigil; it truncates instead), and the full numbers
    /// stay one hover away in the tooltip. Pure + static so the fold is unit-pinned.
    static func compactStatus(_ segments: [GitSegment]) -> [GitSegment] {
        segments.compactMap { segment in
            segment.symbol.map { GitSegment(text: $0, ink: segment.ink) }
        }
    }

    /// The order the status runs GIVE UP their place when the branch runs out of room, least important
    /// first. It is a ranking of "how much does knowing this right now change what I do next":
    ///
    /// `$` stash is work you parked on purpose. `↑↓` divergence is bookkeeping against a remote — unpushed
    /// commits are safely committed, and pushing is a thing you do on your own schedule. `?` untracked is
    /// usually build output and scratch files. Those three are worth a glance when there is room and worth
    /// nothing when there isn't. What survives is the WORKTREE: `+staged`, `!modified`, `~conflicted` —
    /// uncommitted work and broken merges, the states that decide whether this project is safe to leave.
    ///
    /// Nothing is lost by shedding: the full line with its numbers is one hover away in the tooltip, and
    /// the accessibility label always speaks every run.
    static let shedLadder: [GitInk] = [.stash, .divergence, .untracked, .staged, .modified, .conflicted]

    /// The status runs left after giving up `level` RUNGS of ``shedLadder``. A rung is a ROLE, not a run:
    /// `↑` and `↓` are one fact about one remote and leave together, and a role the line never had costs
    /// no rung (so the rungs always narrow the readout — otherwise a clean-but-diverged repo would spend
    /// its whole ladder shedding sigils it does not have).
    ///
    /// The last runs standing are never shed — a git line that reports nothing is not a tighter readout, it
    /// is a missing one — so a repo whose only dirt is `↑2` keeps its `↑` however narrow the rail gets.
    static func shedding(_ status: [GitSegment], to level: Int) -> [GitSegment] {
        var kept = status
        var shed = 0
        for role in shedLadder where shed < level {
            let remaining = kept.filter { $0.ink != role }
            guard remaining.count < kept.count else { continue } // the line never had this role
            guard !remaining.isEmpty else { break } // shedding it would leave nothing to read
            kept = remaining
            shed += 1
        }
        return kept
    }

    /// The git line as it PAINTS, across the widths the sidebar's real column asks for.
    ///
    /// Roomy: the whole dialect inline, branch then counts. Tight: the counts fold to
    /// ``compactStatus(_:)``'s bare sigils pinned flush to the trailing edge, one cluster with no gaps so
    /// they read as a single readout rather than a second sentence. Presence is what a sigil reports — `!`
    /// says there is uncommitted work at any width — so the numbers retreat to the tooltip first.
    ///
    /// Narrower still, the branch and the readout are competing for the same line, and the readout starts
    /// SHEDDING down ``shedLadder`` — one rung per candidate — rather than crowding the name into a stub.
    /// Only when even the worktree core cannot buy the branch enough room does the name truncate (tail: a
    /// long branch loses its end, which is the part that repeats).
    ///
    /// The whole ladder exists because one tail-truncating `Text` took the counts down WITH the branch:
    /// `feature/some-very-long-name…` spelled three more characters of a name you already know and ate the
    /// readout you were actually watching.
    @ViewBuilder
    static func gitDetailLine(_ segments: [GitSegment]) -> some View {
        let branch = segments.filter { $0.ink == .branch }
        let status = segments.filter { $0.ink != .branch }
        if status.isEmpty {
            gitDetailText(segments)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            ViewThatFits(in: .horizontal) {
                gitDetailText(segments)
                    .lineLimit(1)
                // The branch is held at its FULL width in every rung but the last, so a rung stops
                // fitting exactly when the name would start losing characters — that is the signal to
                // shed one more sigil instead.
                tightGitLine(branch, shedding(status, to: 0), branchTruncates: false)
                tightGitLine(branch, shedding(status, to: 1), branchTruncates: false)
                tightGitLine(branch, shedding(status, to: 2), branchTruncates: false)
                tightGitLine(branch, shedding(status, to: 3), branchTruncates: false)
                tightGitLine(branch, shedding(status, to: 3), branchTruncates: true)
            }
        }
    }

    /// One rung of the tight form: the branch on the left, a cluster of bare sigils pinned right.
    /// `branchTruncates` is the last rung's escape hatch — every rung above it holds the name whole so the
    /// fit test asks "does the branch still fit?" rather than silently eating it.
    static func tightGitLine(
        _ branch: [GitSegment], _ status: [GitSegment], branchTruncates: Bool,
    ) -> some View {
        HStack(spacing: 0) {
            gitDetailText(branch)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !branchTruncates, vertical: false)
            // The one gap the tight form keeps: the branch never touches the readout, however little
            // room is left for it.
            Spacer(minLength: 4)
            gitDetailText(compactStatus(status), separator: "")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The painted line: one `Text` run per segment, joined by `separator`, so the whole thing still
    /// truncates as a single line (an `HStack` of runs would clip a whole run instead of the tail).
    /// The compact form passes an EMPTY separator — bare sigils cluster tighter than they space out.
    static func gitDetailText(_ segments: [GitSegment], separator: String = " ") -> Text {
        var line = AttributedString()
        for (index, segment) in segments.enumerated() {
            var run = AttributedString(index == 0 ? segment.text : separator + segment.text)
            run.foregroundColor = ink(segment.ink)
            run.font = Slate.Typeface.instrument(Slate.Typeface.small, weight: weight(segment.ink))
            line.append(run)
        }
        return Text(line)
    }
}

/// One LIVE sidebar row: the STRUCTURAL identity (pane id / title / cwd / kind) rides the
/// memoized ``RailRow``, while every VOLATILE field — the fused badge, foreground-process label,
/// read-only lock, inline-rename mode — is read fresh HERE via
/// ``RailRowsBuilder/liveChrome(for:store:)`` + the store dicts. Observation still invalidates each row
/// body when ANY pane's status dict ticks (dict-granularity tracking), but that re-renders these cheap
/// leaf bodies only — the sidebar body above never rebuilds its rows + sections + list diff per tick.
/// The row itself is otty-bare (title + one trailing slot); the live DETAIL (question / todo scent /
/// agent line / failing command) rides the hover tooltip via ``RailRowReadout``.
private struct SidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
    /// The kind's generic title (``PaneChooserRegistry``) when the row title is empty.
    let fallbackTitle: String
    /// The sidebar's shared selection-morph namespace — see ``SlateCompactIsland/morph``.
    let morph: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        // Observes the flash-decay tick at ROW scope (not in the memoized rows build) so a quiet
        // completed pane still re-renders at the flash-window boundary — `completionFreshness` reads the
        // wall clock, not an `@Observable` dependency. `let _` (not a bare `_ =`) is required — a
        // `@ViewBuilder` rejects a bare Void discard statement.
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
        // The todo SCENT — the tooltip's live line while the agent is WORKING with a live inspector
        // feed reporting an in-flight todo. Gated on the RAW status (like the working reading below), not the
        // gated badge — the "Badge while processing" toggle silences the badge glyph, not the fact.
        let scent: String? = chrome.status == .working
            ? (store.handle(for: row.id) as? LivePaneSession)?.inspector.flatMap { vm in
                vm.feedState == .live ? PendingToolSummary.scent(todos: vm.todos) : nil
            }
            : nil
        let blocks = store.commandBlocks(for: row.id)
        // The failure this row's alarm may be blamed on — source-gated, so a live progress error is
        // never pinned on an older command (see `RailRowsBuilder.failedBlock`). It names both the
        // tooltip's error line and the trailing slot's red receipt.
        let failedBlock = RailRowsBuilder.failedBlock(for: row.id, badge: chrome.badge, store: store)
        // Whose finish this is — the agent's turn ending, or a plain command's clean exit. ONE
        // predicate feeds both consumers (see `RailRowsBuilder.finishIsAgents`): the agent's FINAL
        // assistant line below (a command's exit must never surface a stale agent line) and the
        // trailing mark's geometry (the agent's finish closes its ring; a command's takes the dot).
        let agentFinish = RailRowsBuilder.finishIsAgents(
            badge: chrome.badge, status: chrome.status,
            unseenDone: store.paneUnseenDone.contains(row.id),
        )
        // Done-unseen surfaces the agent's FINAL assistant line (the wire-27 label at `.done`).
        let doneLine: String? = agentFinish ? store.agentLabel(for: row.id) : nil
        // The RUNNING command (busy non-agent shells): the host document's own open block, this
        // client's newest open block, then the coarse foreground-process label — one resolver, so the
        // macOS and iOS rows cannot drift.
        let runningCommand: String? = (chrome.badge == .commandRunning || chrome.badge == .commandBusy)
            ? store.liveRunningCommand(
                for: row.id, processLabel: RailRowsBuilder.processDisplayName(chrome.processLabel),
            )
            : nil
        // The SHOWN title resolves in the live leaf (rename → agent-session intent → structural →
        // running command → last executed command → generic) because intent + blocks are volatile —
        // the memoized structural `row.title` stays put, so the search corpus never drifts. The
        // running rung reuses `runningCommand` (busy-badge-gated, so it appears with the busy
        // ring's reveal and a fast `ls` never flashes in) — the row answers "what is this pane
        // running".
        let agent = RailRowsBuilder.isAgentSession(
            status: chrome.status, processLabel: chrome.processLabel,
        )
        let shownTitle = RailRowsBuilder.liveRowTitle(
            structuralTitle: row.title,
            userRenamed: store.tree.activeSession?.specs[row.id]?.userRenamed == true,
            isAgent: agent,
            intent: store.paneAgentIntent[row.id],
            runningCommand: runningCommand,
            // The running PROGRAM's own OSC title, gated on the workspace document's `titleFresh`
            // verdict (agent glyphs stripped) — beats the raw command line wherever the running rung
            // would title the row.
            programTitle: RailRowsBuilder.normalizedProgramTitle(store.liveProgramTitle(for: row.id)),
            processTitle: RailRowsBuilder.processDisplayName(chrome.processLabel),
            blocks: blocks,
            kind: row.kind,
            cwdTitle: RailRowsBuilder.cwdFolderName(row.cwd),
            fallback: fallbackTitle,
        )
        let lastCommand = blocks.last(where: { $0.complete || $0.durationMS != nil })
            .flatMap(SidebarRowTooltip.commandLine)
        // The row's live line — TOOLTIP-only (the rendered row stays otty-bare).
        let detail = RailRowReadout.resolve(
            question: chrome.question,
            scent: scent,
            workingLabel: chrome.status == .working ? store.agentLabel(for: row.id) : nil,
            doneLine: doneLine,
            errorLine: RailRowReadout.errorLine(
                exitCode: failedBlock?.exitCode, commandText: failedBlock?.commandText,
            ),
            commandLine: runningCommand,
            title: shownTitle,
        )
        // The WORKING-agent reading (the accent ring + primary title ink + AX value). Keyed on
        // the RAW `.working` status, NOT the gated badge — "Badge while processing" (default OFF)
        // masks `.working` out of the badge resolver, and reading the badge here would render a
        // thinking agent exactly like an idle shell for every default-settings install. The
        // toggle governs the badge GLYPH; the working reading is the row's own affordance. A
        // running COMMAND mounts no mark at all — the trailing ring is the agent's column.
        let busyLabel: String? = chrome.status == .working
            ? StatusPresentation.tabBadgeLabel(.running) : nil
        // The ⌘-held digit hint — read LIVE here, never via the memoized row: closing a pane
        // renumbers every pane after it in the drawn order without touching any surviving row's
        // `leafIdentity`, so an init-param number could go stale inside the lazy container (the
        // same class of bug as the frozen title). `nil` (the resting state, or a row past ⌘9)
        // keeps the row's normal leading run.
        let shortcutHint = store.shortcutHintActive ? store.shortcutNumber(for: row.id) : nil
        SlateTabRow(
            title: shownTitle,
            active: active,
            // The otty agent-integration look: an agent session's title wears the leading `✳`.
            agentMarker: agent,
            shortcutHint: shortcutHint,
            // The FULL fused badge, busy tiers included — the row's own maps keep the busy kinds
            // out of the title ink, the slot text AND (since the mark became the agent's column)
            // the trailing ring.
            badge: chrome.badge,
            workingLabel: busyLabel,
            // A code agent PRESENT and at rest — the muted ring's only source. The `.idle`
            // verdict is the detection's own "claude is here, waiting for a prompt"; a plain
            // shell (agent `.none`) never reaches it, however busy it is.
            agentIdle: chrome.status == .idle,
            // Whose finish it is — the agent's ring closes, a command's takes the outcome dot.
            agentFinish: agentFinish,
            // The foreground process labels the slot — a real program (`vim`, `make`) AND a bare
            // shell (`zsh`): unlike the TITLE (where "zsh" says as little as "Terminal"), the
            // metadata slot answers "what is this pane running", and an idle shell row with an
            // empty slot reads as missing data. Only an AGENT row leaves it empty: the `✳` marker
            // and the mark already say it, and any trailing text there just repeats them.
            processLabel: agent ? nil : RailRowsBuilder.slotProcessName(chrome.processLabel),
            // A finished COMMAND takes that same slot and names itself in the outcome's ink — the
            // whole rendering of an exit on this rail, since round 24 pulled the outcome marks.
            commandReceipt: RailRowsBuilder.commandReceipt(
                badge: chrome.badge, agentFinish: agentFinish, blocks: blocks,
                failedBlock: failedBlock, processLabel: chrome.processLabel,
            ),
            readOnly: chrome.readOnly,
            syncInput: store.syncInputArmed(for: row.id),
            isEditing: chrome.isEditing,
            helpText: SidebarRowTooltip.text(
                cwd: row.cwd,
                detail: detail,
                lastCommand: lastCommand,
                viewers: store.paneViewers(for: row.id),
                holders: store.paneHolders(for: row.id),
            ),
            morph: morph,
            onSelect: onSelect,
            onClose: onClose,
            onRename: onRename,
            onCancelRename: onCancelRename,
            // Double-click opens the inline rename on this row's tab — the same pending-rename the
            // context-menu "Rename" / ⌘R sets, so all three affordances share one field.
            onBeginRename: { store.requestRenameTab(row.tabID) },
        )
    }
}

/// The iOS twin of ``SidebarLiveRow``: the system `Label` row with the trailing lock + fused badge, its
/// volatile chrome read fresh at row scope, keeping the layout equivalent to a plain inline `HStack`
/// while only WHERE the volatile fields are read differs.
private struct IOSSidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
    let fallbackTitle: String
    let symbol: SFSymbol
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        // Same flash-decay-tick read at row scope — see ``SidebarLiveRow/body``.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        // Same live-title chain as the macOS ``SidebarLiveRow`` (one shared resolver), including
        // the busy-badge-gated RUNNING rung.
        let blocks = store.commandBlocks(for: row.id)
        let runningCommand: String? = (chrome.badge == .commandRunning || chrome.badge == .commandBusy)
            ? store.liveRunningCommand(
                for: row.id, processLabel: RailRowsBuilder.processDisplayName(chrome.processLabel),
            )
            : nil
        let shownTitle = RailRowsBuilder.liveRowTitle(
            structuralTitle: row.title,
            userRenamed: store.tree.activeSession?.specs[row.id]?.userRenamed == true,
            isAgent: RailRowsBuilder.isAgentSession(
                status: chrome.status, processLabel: chrome.processLabel,
            ),
            intent: store.paneAgentIntent[row.id],
            runningCommand: runningCommand,
            programTitle: RailRowsBuilder.normalizedProgramTitle(store.liveProgramTitle(for: row.id)),
            processTitle: RailRowsBuilder.processDisplayName(chrome.processLabel),
            blocks: blocks,
            kind: row.kind,
            cwdTitle: RailRowsBuilder.cwdFolderName(row.cwd),
            fallback: fallbackTitle,
        )
        // Same busy split as the macOS row: only the AGENT tier gets the working reading (the
        // terse label as the title's AX value, the accent ring as the mark), keyed on the RAW
        // `.working` status — the badge gate must not kill it (see ``SidebarLiveRow``); a running
        // command mounts no mark at all.
        let busyLabel: String? = chrome.status == .working
            ? StatusPresentation.tabBadgeLabel(.running) : nil
        // Whose finish it is — the same predicate the macOS row uses, resolved once here because
        // both the trailing mark and the command receipt need the answer.
        let agentFinish = RailRowsBuilder.finishIsAgents(
            badge: chrome.badge, status: chrome.status,
            unseenDone: store.paneUnseenDone.contains(row.id),
        )
        // The finished command's receipt — the same resolver as the macOS row, so an exit reads the
        // same on both platforms.
        let receipt = RailRowsBuilder.commandReceipt(
            badge: chrome.badge, agentFinish: agentFinish, blocks: blocks,
            failedBlock: RailRowsBuilder.failedBlock(for: row.id, badge: chrome.badge, store: store),
            processLabel: chrome.processLabel,
        )
        HStack(spacing: 8) {
            Label {
                if chrome.isEditing {
                    // The iOS inline-rename field — commits on submit/blur (escape is macOS-only).
                    InlineRenameField(
                        seed: shownTitle,
                        onCommit: onRename,
                        onCancel: onCancelRename,
                    )
                } else {
                    // The same reading as the macOS row: the title stays neutral — state is the
                    // trailing ring mark's hue; the AX value keeps it VoiceOver-legible.
                    let attentionLabel = chrome.badge.flatMap { badge in
                        StatusPresentation.attentionInk(badge) != nil
                            ? StatusPresentation.tabBadgeLabel(badge) : nil
                    }
                    Text(shownTitle)
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                        .accessibilityValue(busyLabel ?? attentionLabel ?? "")
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
            // A privilege marker, else a finished command's receipt — the two things that mount
            // trailing TEXT. Everything else is the ring mark's hue.
            if let badge = chrome.badge, StatusPresentation.tabBadge(badge) != nil {
                TabBadgeView(kind: badge)
            } else if let receipt {
                Text(receipt.name)
                    .font(Slate.Typeface.instrument(
                        Slate.Typeface.small, weight: StatusPresentation.outcomeWeight,
                    ))
                    .foregroundStyle(StatusPresentation.outcomeInk(receipt.outcome))
                    .lineLimit(1)
                    .fixedSize()
            }
            // The same trailing status mark as the macOS row (the T3 Code port) — rightmost, so
            // state reads down one fixed column on iOS too.
            if let dot = StatusPresentation.statusDot(
                working: busyLabel != nil, badge: chrome.badge,
                agentIdle: chrome.status == .idle,
                agentFinish: agentFinish,
            ) {
                StatusDotView(style: dot)
            }
        }
    }
}

#if os(macOS)
/// The accent ring a sidebar row wears while it is the live pane drag's resolved destination. Its own
/// leaf view so the per-transition Observation invalidation re-renders these cheap bodies only — never
/// the sidebar body (which would re-derive the whole rail per destination change).
private struct RowDropHighlight: View {
    let coordinator: PaneDragCoordinator?
    let paneID: PaneID

    var body: some View {
        if let coordinator, coordinator.drag?.destination == .sidebarRow(paneID) {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                .strokeBorder(Slate.State.accent, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}

/// The "New Tab" drop slot — mounted only while a pane drag is live (so its frame reader registers
/// exactly for the drag's duration), pinned above the sidebar footer. Dropping here breaks the pane
/// into its own fresh tab (`breakPaneToTab` for a tree pane, reattach-to-new-tab for a satellite).
private struct NewTabDropSlot: View {
    let coordinator: PaneDragCoordinator

    var body: some View {
        if let drag = coordinator.drag {
            let active = drag.destination == .newTab
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemSymbol: .plusSquareOnSquare)
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                Text("New Tab")
                    .font(.system(size: Slate.Typeface.body, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? Slate.Text.primary : Slate.Text.secondary)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .fill(active ? Slate.State.accentMuted : Color.clear),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .strokeBorder(
                        active ? Slate.State.accent : Slate.Line.subtle,
                        style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]),
                    ),
            )
            .background(DropTargetFrameReader(key: .newTabZone, coordinator: coordinator))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}
#endif

/// A small self-focusing inline rename `TextField` (iOS list rows) — owns its own draft `@State` so
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
                // An untouched draft is a CANCEL, not a rename — committing the seed verbatim would
                // freeze the row's LIVE title (intent / running command / generic) as a sticky
                // `userRenamed` identity. Same guard as ``SlateTabRow``'s macOS field.
                if draft == seed { onCancel() } else { onCommit(draft) }
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused, !resolved else { return }
                if draft == seed { onCancel() } else { onCommit(draft) }
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
