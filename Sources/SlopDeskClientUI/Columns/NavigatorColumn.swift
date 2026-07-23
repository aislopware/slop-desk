// NavigatorColumn — the left sidebar navigator. macOS renders a flat "TABS" panel on a warm
// `Slate.Surface.ground` background (NOT native `.sidebar` vibrancy/inset-grouped selection — the host split
// item is a PLAIN item), a "TABS" header, a flat search field, and the active session's tabs as
// `SlateTabRow`s — ALWAYS grouped into By-Project `SlateSectionHeader` sections (no grouping/sort hamburger
// or manual drag-reorder: sections and rows simply follow creation order, and each pane's key is
// HOST-pushed — see `WorkspaceStore.paneProjectKey`). Top 40pt is reserved
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
import SlopDeskInspector // PendingToolSummary — the working-row tooltip's todo-scent line
import SlopDeskVideoProtocol // AgentPreferences — the `preventSleep` flag the tab context menu toggles
import SlopDeskWorkspaceCore
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The live ``PreferencesStore`` — threaded in so the tab context menu can surface the host-LOCAL
    /// **Prevent Sleep While Processing** flag (`docs/ui-shell/screenshots/open-code-agent-history.png`
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
    /// The cross-container pane-drag rendezvous — makes every sidebar row a DROP TARGET for a live pane
    /// drag (the pane moves BESIDE that row's pane, its tab revealed) and mounts the New-Tab drop slot
    /// while a drag is in flight. Threaded in like `preferences` (the sidebar's `NSHostingController`
    /// inherits no environment); `nil` (previews / iOS) leaves the rows plain.
    var paneDrag: PaneDragCoordinator?
    /// Tapping the cluster opens the Connect-to-Host editor (``OverlayCoordinator/openConnect()``).
    var onConnect: () -> Void = {}

    /// The transient sidebar search query — narrows the rows via the pure ``RailRowsBuilder/filtered``.
    /// View-local `@State`: it is a presentational filter, NOT row order (which lives on the store).
    @State private var query = ""

    /// The memoized row model: the sidebar body reads its rows from HERE so a settled body
    /// registers NO Observation dependency on the store's volatile per-pane dicts — a status/git/progress
    /// tick then re-renders only the cheap ``SidebarLiveRow`` leaves (which read their own pane's chrome
    /// live), never the whole rows + `disambiguated()` + sectioning + list-diff pass. Plain class in
    /// `@State` (NOT `@Observable`): its mutation during a body eval must not re-invalidate anything.
    @State private var rowsMemo = RailRowsMemo()

    #if os(macOS)
    /// Pointer-in-strip — the collapse toggle's hover-reveal gate.
    @State private var stripHover = false
    #endif

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

    var body: some View {
        #if os(macOS)
        macSidebar
        #else
        iosSidebar
        #endif
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
        let sections = buildSections(allRows, query: query)
        return VStack(alignment: .leading, spacing: 0) {
            // Traffic-light strip: ONLY the sidebar-collapse toggle (top-trailing). Connection lives in the
            // footer below — the lights strip is too narrow for host + metrics and always looked jammed.
            // Top 3 centres the 24pt plate on the traffic-light row (y≈15).
            //
            // The toggle is anchored to the sidebar's TRAILING edge, which RIDES the collapse/expand slide —
            // visible mid-slide it glides with the moving edge and reads as a flash. So it shows only in the
            // SETTLED expanded state: hides INSTANTLY when the collapse flag flips (before the slide starts)
            // and, on expand, fades back only after the slide settles (0.25 clears the ~0.25s NSSplitView
            // collapse animation; 0.15 still caught the tail). On top of that it is HOVER-REVEALED:
            // at rest the strip is empty; the pointer entering the strip fades it in (`HoverSensor` —
            // hit-test-transparent, the strip stays draggable).
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
                // The panel label speaks the INSTRUMENT voice (mono + wide tracking) — same
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
                    } else if sections.isEmpty {
                        emptyLabel("No matches")
                    } else {
                        ForEach(sections) { section in
                            if let header = section.header {
                                SidebarSectionHeaderRow(
                                    store: store, title: header, projectKey: section.projectKey,
                                    rows: section.rows,
                                )
                            }
                            ForEach(section.rows) { row in
                                macRow(row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
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

            // Connection footer — full-width status row under the tab list (ScrollView maxHeight: .infinity
            // pins this to the bottom). Hairline separates list from chrome; fillWidth so hover/hit read as
            // one sidebar item. Leading-aligned fixed column keeps ticking telemetry from shifting the host.
            if let connection {
                Rectangle()
                    .fill(Slate.Line.subtle)
                    .frame(maxWidth: .infinity)
                    .frame(height: Slate.Metric.hairline)
                // The telemetry (~1 Hz; ping visible, fps/kbps tooltip-only) is read inside
                // `SidebarConnectionFooter` so its per-second ticks re-render that leaf, never this
                // sidebar body.
                SidebarConnectionFooter(store: store, connection: connection, onConnect: onConnect)
                    .padding(.horizontal, Slate.Metric.space2)
                    .padding(.vertical, Slate.Metric.space2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Slate.Surface.ground)
    }

    /// One macOS tab row: the full chrome (badge / subtitle / process label). The VOLATILE chrome
    /// is read inside ``SidebarLiveRow``, so a pane's status tick re-renders that one leaf, not
    /// this sidebar body.
    private func macRow(_ row: RailRow) -> some View {
        SidebarLiveRow(
            store: store,
            row: row,
            fallbackTitle: defaultTitle(for: row.kind),
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
            .padding(.horizontal, 14)
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
        .background(Slate.Surface.ground)
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
    static func text(cwd: String?, detail: String?, lastCommand: String?) -> String? {
        let parts = [cwd, detail, lastCommand].compactMap { part -> String? in
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

/// The section header LEAF: reads its project's git summary AND its act-now tally INSIDE its own
/// body — the sidebar body never touches the volatile dicts, so a git/status tick re-renders only the
/// (cheap) header leaves, mirroring how ``SidebarLiveRow`` isolates the volatile row chrome. Carries
/// the header-scoped context menu (the project-wide "Refresh Git Status", moved up from the row menu).
/// Internal (not private) so the opt-in snapshot render can mount the REAL header.
struct SidebarSectionHeaderRow: View {
    let store: WorkspaceStore
    let title: String
    let projectKey: String?
    /// The section's structural rows — the tally resolves each row's live badge through the SAME gated
    /// pipeline the rail renders, so the header count and the row badges can never disagree.
    let rows: [RailRow]

    var body: some View {
        let summary = projectKey.flatMap { store.projectGitSummary[$0] }
        // The act-now tally: how many panes in this project wait on YOU right now (a blocked question
        // or an error) — the "which PROJECT needs me" answer at a glance. Counts through the gated
        // badge pipeline; absent at zero (no reserved slot — an empty reserve read as a ragged hole
        // against the right edge, and the rare git-line shift when a tally appears is a real event).
        let actNow = rows.count { row in
            switch RailRowsBuilder.liveChrome(for: row, store: store).badge {
            case .awaitingInput,
                 .error: true
            default: false
            }
        }
        SlateSectionHeader(title) {
            HStack(spacing: Slate.Metric.space2) {
                if let summary { ProjectGitStatusLine(summary: summary) }
                if actNow > 0 {
                    Text("●\(actNow)")
                        .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Status.warn)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("\(actNow) panes need attention")
                }
            }
        }
        // The shared header carries the panel-level `space2` inset; this extra `space1` brings the
        // header text to `space3` — the SAME content inset the row cards use — so the section title
        // sits flush over the rows' glyph column instead of hanging into the gutter. The extra top
        // padding separates a section from the previous section's last row (the header's own top
        // inset is sized for the panel label above the FIRST section).
        .padding(.horizontal, Slate.Metric.space1)
        .padding(.top, Slate.Metric.space2)
        .contextMenu {
            if let projectKey {
                Button("Refresh Git Status") { store.refreshGitSummary(forProject: projectKey) }
            }
        }
    }
}

/// One LIVE sidebar row: the STRUCTURAL identity (pane id / title / cwd / kind) rides the
/// memoized ``RailRow``, while every VOLATILE field — the fused badge, readout line, telemetry value,
/// foreground-process label, read-only lock, inline-rename mode — is read fresh HERE via
/// ``RailRowsBuilder/liveChrome(for:store:)`` + the store dicts. Observation still invalidates each row
/// body when ANY pane's status dict ticks (dict-granularity tracking), but that re-renders these cheap
/// leaf bodies only — the sidebar body above never rebuilds its rows + sections + list diff per tick.
private struct SidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
    /// The kind's generic title (``PaneChooserRegistry``) when the row title is empty.
    let fallbackTitle: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    /// The working-label minimum dwell — a mid-turn label churning faster than this holds the previous
    /// line so the readout reads as a feed, not a flicker.
    private static let labelDwell: TimeInterval = 2
    /// The telemetry re-render cadence — ages tick at minute granularity, so a 10s clock keeps the
    /// reveal boundary honest without per-second work; mounted ONLY while the row's badge can carry a
    /// telemetry value.
    private static let telemetryCadence: TimeInterval = 10

    /// The dwell-committed working label + its commit instant (see ``commitDwell(_:)``).
    @State private var dwellLabel: String?
    @State private var dwellCommittedAt = Date.distantPast
    @State private var dwellTask: Task<Void, Never>?

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
        let isAgent = RailRowsBuilder.isAgentSession(status: chrome.status, processLabel: chrome.processLabel)
        let workingCandidate: String? = chrome.status == .working ? store.agentLabel(for: row.id) : nil
        Group {
            if Self.telemetryEligible(chrome.badge) {
                // The per-row telemetry clock — a fixed epoch anchor so re-renders can't postpone the
                // next tick; mounted only while a value can show (a resting row carries no timer).
                TimelineView(.periodic(
                    from: Date(timeIntervalSinceReferenceDate: 0),
                    by: Self.telemetryCadence,
                )) { context in
                    rowBody(chrome: chrome, active: active, isAgent: isAgent, now: context.date)
                }
            } else {
                rowBody(chrome: chrome, active: active, isAgent: isAgent, now: Date())
            }
        }
        // A fresh mount seeds the dwell machine raw — the leaf's `.id(row.leafIdentity)` re-keys on a
        // structural change (title/cwd), which discards this @State.
        .onAppear {
            dwellLabel = workingCandidate
            dwellCommittedAt = Date()
        }
        .onDisappear {
            dwellTask?.cancel()
        }
        .onChange(of: workingCandidate) { _, candidate in commitDwell(candidate) }
    }

    /// The row body for one clock instant: resolves the readout line, the telemetry value and the
    /// agent-shell rung, then mounts ``SlateTabRow``.
    @ViewBuilder
    private func rowBody(
        chrome: RailRowsBuilder.RailRowChrome, active: Bool, isAgent: Bool, now: Date,
    ) -> some View {
        // The todo SCENT — promoted from the tooltip to the line-2 readout while the agent is WORKING
        // with a live inspector feed reporting an in-flight todo.
        let scent: String? = chrome.badge == .running
            ? (store.handle(for: row.id) as? LivePaneSession)?.inspector.flatMap { vm in
                vm.feedState == .live ? PendingToolSummary.scent(todos: vm.todos) : nil
            }
            : nil
        let blocks = store.commandBlocks(for: row.id)
        // The failed-block attribution is gated on the badge's SOURCE: the `.error` tier is reachable
        // from a finished `.failure` completion OR a LIVE OSC 9;4;2 progress error — and in the live
        // case the alarming command's block is still open (never `.isFailed`), so the newest closed
        // failure would be an OLDER, unrelated command. Only a `.failure` completion may explain the
        // alarm with a block; a progress error keeps the readout/telemetry silent about exit codes.
        let failedBlock = chrome.badge == .error && store.panePendingCompletion[row.id] == .failure
            ? blocks.last(where: \.isFailed)
            : nil
        // Done-unseen surfaces the agent's FINAL assistant line (the wire-27 label at `.done` — it
        // crosses the wire today and was discarded), gated on the agent verdict so a plain command's
        // completion badge can never show a stale agent line.
        let doneLine: String? = (chrome.badge == .completed || chrome.badge == .finished)
            && chrome.status == .done ? store.agentLabel(for: row.id) : nil
        // The RUNNING command readout (busy non-agent shells): the OPEN block's command text — what
        // the row is doing right now — falling back to the coarse foreground-process label when the
        // block model hasn't seen the command (e.g. a command launched before attach).
        let runningCommand: String? = (chrome.badge == .commandRunning || chrome.badge == .commandBusy)
            ? {
                let open = blocks.last(where: { !$0.complete })?
                    .commandText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let open, !open.isEmpty { return open }
                return RailRowsBuilder.processDisplayName(chrome.processLabel)
            }()
            : nil
        let readout = RailRowReadout.resolve(
            question: chrome.question,
            scent: scent,
            workingLabel: chrome.status == .working ? dwellLabel : nil,
            doneLine: doneLine,
            errorLine: RailRowReadout.errorLine(
                exitCode: failedBlock?.exitCode, commandText: failedBlock?.commandText,
            ),
            commandLine: runningCommand,
            strayedCwd: chrome.subtitle,
        )
        let telemetry = RailRowTelemetry.value(
            badge: chrome.badge,
            isAgentSession: isAgent,
            attentionAt: store.paneAttentionAt[row.id],
            completedAt: store.paneCompletedAt[row.id],
            commandStartedAt: store.paneCommandStartedAt[row.id],
            progressPercent: StatusPresentation.progressPercentLabel(store.progress(for: row.id)),
            exitCode: failedBlock?.exitCode,
            now: now,
        )
        let lastCommand = blocks.last(where: { $0.complete || $0.durationMS != nil })
            .flatMap(SidebarRowTooltip.commandLine)
        // The pane's live OSC 9;4 determinate fraction — swept as the glyph column's pie wedge.
        let progressFraction: Double? = {
            if case let .determinate(fraction, _) =
                StatusPresentation.progressPresentation(store.progress(for: row.id)) { return fraction }
            return nil
        }()
        SlateTabRow(
            title: row.title.isEmpty ? fallbackTitle : row.title,
            active: active,
            subtitle: readout?.text,
            subtitleTruncation: readout?.truncation == .middle ? .middle : .tail,
            badge: chrome.badge,
            progressFraction: progressFraction,
            telemetry: telemetry,
            readOnly: chrome.readOnly,
            syncInput: store.syncInputArmed(for: row.id),
            isEditing: chrome.isEditing,
            helpText: SidebarRowTooltip.text(
                cwd: row.cwd,
                // Overflow recovery: the untruncated PROSE readout (a path line already appears via cwd).
                detail: readout?.truncation == .tail ? readout?.text : nil,
                lastCommand: lastCommand,
            ),
            onSelect: onSelect,
            onClose: onClose,
            onRename: onRename,
            onCancelRename: onCancelRename,
        )
    }

    /// Whether the badge can carry a telemetry value at all — the per-row clock mounts only then.
    private static func telemetryEligible(_ badge: TabBadgeKind?) -> Bool {
        switch badge {
        case .awaitingInput,
             .error,
             .running,
             .commandRunning,
             .commandBusy,
             .completed,
             .finished:
            true
        case .caffeinate,
             .sudo,
             nil:
            false
        }
    }

    /// Commits a new working label through the minimum dwell: an update landing within
    /// ``labelDwell`` of the last commit is deferred (the pending task commits it when the dwell
    /// expires), so mid-turn label churn can't strobe the readout. A `nil` (turn over) clears
    /// immediately — state changes are hard cuts.
    private func commitDwell(_ candidate: String?) {
        dwellTask?.cancel()
        dwellTask = nil
        guard let candidate else {
            dwellLabel = nil
            return
        }
        let sinceCommit = Date().timeIntervalSince(dwellCommittedAt)
        if dwellLabel == nil || !sinceCommit.isLess(than: Self.labelDwell) {
            dwellLabel = candidate
            dwellCommittedAt = Date()
        } else {
            dwellTask = Task {
                try? await Task.sleep(for: .seconds(Self.labelDwell - sinceCommit))
                guard !Task.isCancelled else { return }
                dwellLabel = candidate
                dwellCommittedAt = Date()
            }
        }
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
        HStack(spacing: 8) {
            Label {
                if chrome.isEditing {
                    // The iOS inline-rename field — commits on submit/blur (escape is macOS-only).
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

/// The sidebar's connection footer, split into its own leaf: the ``ConnectionTelemetry``
/// reads tick at ~1 Hz off the live session models — read HERE so each tick re-renders this footer
/// only, never the sidebar body (which would re-derive the whole rail every second). Only the ping
/// renders in the row; fps/kbps ride the tooltip (`ConnectionCluster` header note).
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
