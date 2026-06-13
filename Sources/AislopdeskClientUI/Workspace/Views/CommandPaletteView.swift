#if canImport(SwiftUI)
import SwiftUI

// MARK: - CommandPaletteView (the ⌘K command palette overlay)

/// A native Spotlight / Xcode "Open Quickly"-style command palette (docs/22 §5, WF6 dev-UX): a single
/// search field over a fuzzy-filtered list that combines (a) every ``WorkspaceCommand`` (titled, with
/// its default ⌘/⌥ shortcut hint) and (b) one "switch to tab" entry per ``Tab`` (jump by name).
///
/// ### Why it is conflict-safe with the terminal (the load-bearing §5 rule)
/// The palette is shown by a ⌘/⌥-prefixed chord (⌘K, wired in `WorkspaceRootView` during Integrate),
/// so it never shadows a key the focused terminal needs. While it is up, ALL of its navigation keys
/// (↑/↓ to move the selection, ⏎ to run, ⎋ to dismiss) are handled **locally** by this view via
/// `onKeyPress` on the focused search field — they are consumed here and never fall through to the
/// terminal input host. Closing the palette returns first-responder/keyboard to the workspace.
///
/// ### How it acts on the store
/// Selecting a ``Entry/Kind/command`` entry runs the SAME `apply(_:to:store)` free function the
/// keyboard and menu layers funnel through (docs/22 §5); selecting a ``Entry/Kind/tab`` entry calls
/// `store.selectTab`. Either way the palette then dismisses by clearing its `isPresented` binding.
///
/// ### Mounting (Integrate)
/// `WorkspaceRootView` keeps `@State private var showCommandPalette = false`, adds
/// `.keyboardShortcut("k", modifiers: .command)` toggling it (or a `Commands`/`UIKeyCommand` adapter),
/// and overlays this view:
/// ```swift
/// .overlay { CommandPaletteView(store: store, isPresented: $showCommandPalette) }
/// ```
/// The view renders nothing (a transparent, zero-cost branch) when `isPresented` is false, so an
/// unconditional overlay is cheap.
struct CommandPaletteView: View {
    let store: WorkspaceStore
    /// Drives presentation. The palette dismisses by setting this to `false` (⎋, backdrop tap, or a
    /// run). Owned by the mounting view so the ⌘K shortcut toggles it.
    @Binding var isPresented: Bool

    /// The live query text.
    @State private var query: String = ""
    /// The index of the highlighted row in the CURRENT filtered list (clamped on every recompute).
    @State private var selection: Int = 0
    /// First-responder for the search field so the palette owns the keyboard the instant it appears
    /// (and so the local key handlers below receive the arrow/return/escape presses).
    @FocusState private var searchFocused: Bool

    /// The host windows for the `#`-prefix / fuzzy host-window results, fetched async on open via the
    /// ``RemoteWindowDiscovery`` seam and cached for this presentation. Empty until the query returns
    /// (the palette stays instant even when the host is slow/offline — the rows just appear late).
    @State private var hostWindows: [RemoteWindowSummary] = []
    /// Guards against re-fetching on every keystroke (fetch once per open).
    @State private var didFetchHostWindows = false

    var body: some View {
        if isPresented {
            ZStack {
                backdrop
                panel
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    // MARK: Backdrop (dim + tap-to-dismiss)

    /// A dimming scrim that swallows clicks outside the panel and dismisses on tap — the native
    /// "click-away closes the palette" behaviour.
    private var backdrop: some View {
        Rectangle()
            .fill(.black.opacity(0.18))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
    }

    // MARK: Panel (the floating card)

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(maxWidth: 560)
        .frame(maxHeight: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        .padding(.horizontal, 24)
        // Sit the card near the top third — Spotlight/Open-Quickly placement, not dead-centre.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 80)
        .onAppear {
            resetState()
            searchFocused = true
            fetchHostWindowsIfNeeded()
        }
    }

    /// Fetches the host's shareable windows once per presentation (async, non-blocking) so the
    /// host-window section is populated without stalling the palette. Degrades to an empty section
    /// when no discovery seam is registered or the host is unreachable.
    private func fetchHostWindowsIfNeeded() {
        guard !didFetchHostWindows, let query = RemoteWindowDiscovery.shared else { return }
        didFetchHostWindows = true
        let t = store.workspace.connection ?? .default
        Task { @MainActor in
            let windows = await query(t.host, t.mediaPort, t.cursorPort)
            // Only apply if the palette is still up (the user may have dismissed it mid-fetch).
            if isPresented { hostWindows = windows }
        }
    }

    // MARK: Search field (owns the keyboard + the local nav keys)

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15, weight: .regular))

            TextField("Run a command, jump to a pane, or open a window  (> @ #)", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onChange(of: query) { _, _ in
                    // A new query rebuilds the filtered list; reset to the top so the best fuzzy match
                    // is highlighted.
                    selection = 0
                }
                // ⏎ runs the highlighted entry. (`.onSubmit` also fires this on iOS soft-return.)
                .onSubmit(runSelection)
                // Palette-local key handlers — consumed here, so they never reach the terminal.
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(.return) { runSelection(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Results list

    @ViewBuilder
    private var resultsList: some View {
        let rows = entries
        if rows.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            row(for: entry, selected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { run(entry) }
                                #if os(macOS)
                                .onHover { hovering in
                                    if hovering { selection = index }
                                }
                                #endif
                        }
                    }
                    .padding(6)
                }
                // Keep the highlighted row visible as the user arrows through the list.
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.white : .primary)
                    .lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let shortcut = entry.shortcutHint {
                Text(shortcut)
                    .font(.system(.caption, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
    }

    // MARK: Actions

    /// Runs the currently highlighted entry (the ⏎ path). No-op if the list is empty.
    private func runSelection() {
        let rows = entries
        guard rows.indices.contains(selection) else { return }
        run(rows[selection])
    }

    /// Performs an entry's action against the store, then dismisses.
    private func run(_ entry: Entry) {
        switch entry.kind {
        case let .command(command):
            // Recents are recorded inside apply() (the chokepoint for palette + menu + keyboard), so
            // it is NOT recorded here — that would double-count the palette path only.
            apply(command, to: store)
        case let .group(id):
            // Jump to a group: pan the camera to frame its panes (groups are spatial clusters now).
            store.centerOnGroup(id)
        case let .pane(paneID):
            // Jump to a pane: focus it AND pan the camera to centre it (it may be far off-viewport on
            // the infinite canvas).
            store.focus(paneID)
            store.centerOnPane(paneID)
        case let .hostWindow(summary):
            // Spawn a Remote Window pane already bound to this host window — no create-then-pick step.
            store.addRemoteWindowPane(windowID: summary.windowID, title: summary.title, appName: summary.appName)
        case let .switchLayout(name):
            store.switchToLayoutPreset(name: name)
        case let .snippet(id):
            // A no-placeholder snippet runs immediately; a parameterized one arms the value-entry sheet
            // (WorkspaceRootView) so its `{{slots}}` are resolved before injection rather than sent
            // literally. Either way routes to the focused pane, or the broadcast group when armed.
            store.beginRunSnippet(id)
        }
        dismiss()
    }

    /// Moves the highlighted row by `delta`, clamped to the current list bounds (no wrap — a list
    /// stops at its ends, matching Spotlight/Open-Quickly).
    private func moveSelection(by delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// Clears state and lowers the presentation binding. Called by ⎋, backdrop tap, and after a run.
    private func dismiss() {
        searchFocused = false
        isPresented = false
        resetState()
    }

    private func resetState() {
        query = ""
        selection = 0
        hostWindows = []
        didFetchHostWindows = false
    }

    // MARK: - Entries (the catalog + the fuzzy filter)

    /// The filtered, ranked list for the current `query`. Built fresh from the command catalog plus
    /// the live tab list every render (the lists are tiny — a dozen commands + N tabs — so there is no
    /// need to cache). An empty query shows the full catalog in catalog order; a non-empty query keeps
    /// only fuzzy-subsequence matches, ranked best-first.
    private var entries: [Entry] {
        // Prefix filters scope the search: '>' actions, '@' panes, '#' host windows. The prefix is
        // stripped before fuzzy matching; an empty post-prefix query lists just that section.
        let raw = query.trimmingCharacters(in: .whitespaces)
        let (scope, stripped) = Self.parseScope(raw)
        let all: [Entry]
        switch scope {
        case .all:        all = commandEntries + layoutEntries + snippetEntries + groupEntries + paneEntries + bookmarkEntries + hostWindowEntries
        case .commands:   all = commandEntries + layoutEntries + snippetEntries
        case .panes:      all = groupEntries + paneEntries + bookmarkEntries
        case .hostWindows: all = hostWindowEntries
        }
        let trimmed = stripped
        // Empty query (the '.all' / '.commands' scopes): float the recently-run commands to the top so
        // the verbs you use most are one keystroke away. Only on an empty query — once the user types,
        // fuzzy ranking over the full list takes over (a recent command is already in `commandEntries`).
        guard !trimmed.isEmpty else {
            if scope == .all || scope == .commands {
                let recents = recentEntries
                let recentIDs = Set(recents.map(\.id))
                return recents + all.filter { !recentIDs.contains($0.id) }
            }
            return all
        }

        let scored: [(entry: Entry, score: Int)] = all.compactMap { entry in
            guard let score = Self.fuzzyScore(query: trimmed, in: entry.searchText) else { return nil }
            return (entry, score)
        }
        // Higher score first; stable by original catalog order for ties (enumerate to keep it total).
        return scored
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score
                    : lhs.offset < rhs.offset
            }
            .map(\.element.entry)
    }

    /// Every palette-runnable command, built fresh on the main actor from the pure ``commandCatalog``
    /// so each entry's `shortcutHint` reverse-looks-up the (main-actor-isolated)
    /// ``CommandInterpreter/defaultBindings``. Cheap — the catalog is a fixed handful of verbs.
    private var commandEntries: [Entry] {
        Self.commandCatalog.map { item in
            Entry(
                id: "cmd.\(item.title)",
                kind: .command(item.command),
                title: item.title,
                symbol: item.symbol,
                shortcutHint: Self.shortcutHint(for: item.command),
                keywords: item.keywords
            )
        }
    }

    /// One "jump to group" entry per group, in sidebar order. Selecting one pans the camera to frame the
    /// group's panes. Derived live so a renamed / added / removed group is reflected next open.
    private var groupEntries: [Entry] {
        store.workspace.groups.map { group in
            Entry(
                id: "group.\(group.id.raw.uuidString)",
                kind: .group(group.id),
                title: group.name,
                subtitle: "Jump to group",
                symbol: "square.on.square.dashed"
            )
        }
    }

    /// One "jump to pane" entry per pane on the canvas. Selecting one focuses the pane and centres the
    /// camera on it. Built live from the canvas so it tracks adds/closes.
    private var paneEntries: [Entry] {
        Self.buildPaneEntries(workspace: store.workspace)
    }

    /// The recently-run commands as entries, in recency order — surfaced at the top of an empty-query
    /// palette. Each maps a stored ``WorkspaceCommand`` back to its catalog item for the title/glyph,
    /// reusing the SAME `id` ("cmd.<title>") as ``commandEntries`` so the catalog section can dedup it.
    /// A recent command no longer in the catalog (none today) is skipped.
    private var recentEntries: [Entry] {
        store.recentCommands.compactMap { command -> Entry? in
            guard let item = Self.commandCatalog.first(where: { $0.command == command }) else { return nil }
            return Entry(
                id: "cmd.\(item.title)",
                kind: .command(item.command),
                title: item.title,
                subtitle: "Recent",
                symbol: item.symbol,
                shortcutHint: Self.shortcutHint(for: item.command)
            )
        }
    }

    /// One "go to bookmark" entry per saved viewport bookmark, in slot order. Selecting one recalls the
    /// bookmark (pans the camera back / re-focuses its pane) via the same `.recallBookmark` command the
    /// ⌘1–9 chords run. Lets a named viewport be reached by name from ⌘K, not just by its digit.
    private var bookmarkEntries: [Entry] { Self.buildBookmarkEntries(workspace: store.workspace) }

    /// Pure builder for the bookmark recall entries (factored out so it is unit-testable without a view).
    /// `@MainActor` because `shortcutHint` reads the main-actor `defaultBindings` table.
    @MainActor static func buildBookmarkEntries(workspace: Workspace) -> [Entry] {
        workspace.bookmarks.keys.sorted().compactMap { slot -> Entry? in
            guard let bm = workspace.bookmarks[slot] else { return nil }
            return Entry(
                id: "bookmark.\(slot)",
                kind: .command(.recallBookmark(slot)),
                title: "Go to \(bm.name)",
                subtitle: "Bookmark \(slot)",
                symbol: "bookmark",
                shortcutHint: Self.shortcutHint(for: .recallBookmark(slot)),
                keywords: "bookmark viewport jump go to \(slot)"
            )
        }
    }

    /// One "switch to layout" entry per saved named layout. Selecting one swaps the whole canvas.
    private var layoutEntries: [Entry] {
        store.layoutPresetNames.map { name in
            Entry(
                id: "layout.\(name)",
                kind: .switchLayout(name),
                title: "Switch to “\(name)”",
                subtitle: "Saved layout",
                symbol: "rectangle.on.rectangle.angled",
                keywords: "layout preset workspace context"
            )
        }
    }

    /// One entry per saved snippet. Selecting it runs the macro into the focused pane (or the broadcast
    /// group). A parameterized snippet shows its placeholder names so it is discoverable.
    private var snippetEntries: [Entry] {
        store.snippets.map { snippet in
            let slots = snippet.placeholders
            return Entry(
                id: "snippet.\(snippet.id.uuidString)",
                kind: .snippet(snippet.id),
                title: "Run “\(snippet.name)”",
                subtitle: slots.isEmpty ? "Snippet" : "Snippet · needs \(slots.joined(separator: ", "))",
                symbol: "scroll",
                keywords: "snippet macro run send keys \(snippet.name)"
            )
        }
    }

    /// One "open this host window" entry per discovered host window. Selecting one spawns a Remote
    /// Window pane pre-bound to it. Built from the async-fetched ``hostWindows`` cache.
    private var hostWindowEntries: [Entry] {
        hostWindows.map { window in
            Entry(
                id: "hostwin.\(window.windowID)",
                kind: .hostWindow(window),
                title: window.title.isEmpty ? window.appName : window.title,
                subtitle: "Open “\(window.appName)” window  ·  \(window.width)×\(window.height)",
                symbol: "macwindow.badge.plus",
                keywords: "\(window.appName) window remote stream"
            )
        }
    }

    /// The palette search scope, selected by a leading prefix character.
    enum Scope { case all, commands, panes, hostWindows }

    /// Parses a leading scope prefix off `raw`: '>' → commands, '@' → panes/groups, '#' → host windows;
    /// anything else → `.all` with the query unchanged. Pure (tested).
    nonisolated static func parseScope(_ raw: String) -> (Scope, String) {
        guard let first = raw.first else { return (.all, raw) }
        let rest = String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch first {
        case ">": return (.commands, rest)
        case "@": return (.panes, rest)
        case "#": return (.hostWindows, rest)
        default:  return (.all, raw)
        }
    }

    /// Pure builder for the per-pane jump entries (factored out so it is unit-testable without a view):
    /// one entry per pane titled by `spec.title`, subtitled by its group name (or "Pane" when ungrouped),
    /// carrying the `PaneID` so the run handler focuses + centres it. `@MainActor` because the pane glyph
    /// (`PaneLeafView.icon`) is main-actor-isolated; the view's `paneEntries` and the `@MainActor` test
    /// suite are the only callers.
    @MainActor static func buildPaneEntries(workspace: Workspace) -> [Entry] {
        workspace.canvas.allIDs().compactMap { id -> Entry? in
            guard let spec = workspace.canvas.spec(for: id) else { return nil }
            let groupName = workspace.group(ofPane: id)?.name
            return Entry(
                id: "pane.\(id.raw.uuidString)",
                kind: .pane(id),
                title: spec.title,
                subtitle: groupName.map { "Pane in \($0)" } ?? "Pane",
                symbol: PaneLeafView.icon(for: spec.kind)
            )
        }
    }

    // MARK: - Fuzzy matching (case-insensitive subsequence)

    /// Scores `query` against `text` as a case-insensitive subsequence match, or `nil` if `query`'s
    /// characters do not appear in order. Higher is better: contiguous runs and an early first match
    /// are rewarded, so "sp" ranks "Split…" above a scattered match. Deliberately small and pure —
    /// the catalog is tiny, so a hand-rolled scorer beats pulling in a dependency. `nonisolated` so it
    /// runs from any context.
    nonisolated static func fuzzyScore(query: String, in text: String) -> Int? {
        let haystack = Array(text.lowercased())
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }

        var score = 0
        var hayIndex = 0
        var lastMatch = -2
        for ch in needle {
            var found = false
            while hayIndex < haystack.count {
                if haystack[hayIndex] == ch {
                    // Reward adjacency to the previous matched char (a contiguous run).
                    if hayIndex == lastMatch + 1 { score += 8 } else { score += 1 }
                    // Reward matches near the start of the string.
                    if hayIndex < 4 { score += 2 }
                    lastMatch = hayIndex
                    hayIndex += 1
                    found = true
                    break
                }
                hayIndex += 1
            }
            if !found { return nil }    // a needle char never appeared in order ⇒ no match
        }
        return score
    }

    // MARK: - Entry model

    /// One row in the palette: an action plus its display shape. `Identifiable` by a stable string so
    /// `ForEach` keeps row identity across re-filters (commands by case, tabs by `TabID`).
    struct Entry: Identifiable {
        enum Kind {
            case command(WorkspaceCommand)
            /// Jump to a group: pans the camera to frame the group's panes.
            case group(PaneGroupID)
            /// Jump to a pane: focuses it and centres the camera on it.
            case pane(PaneID)
            /// Spawn a Remote Window pane PRE-BOUND to this host window (skips the create-then-pick step).
            case hostWindow(RemoteWindowSummary)
            /// Switch the canvas to a saved named layout.
            case switchLayout(String)
            /// Run a saved command snippet (by id) into the focused pane (or the broadcast group).
            case snippet(UUID)
        }

        let id: String
        let kind: Kind
        let title: String
        let subtitle: String?
        let symbol: String
        let shortcutHint: String?
        /// Extra, non-displayed match terms folded into ``searchText`` (e.g. "select tab 3" so the
        /// menu-learned phrasing finds a tab not literally named "3"). Never rendered.
        let keywords: String?

        /// The text the fuzzy filter matches against (title + subtitle + keywords, so "tab" / "select
        /// tab 3" also surface tab rows even when the user types the action word, not the tab name).
        var searchText: String {
            [title, subtitle, keywords].compactMap { $0 }.joined(separator: " ")
        }

        init(
            id: String,
            kind: Kind,
            title: String,
            subtitle: String? = nil,
            symbol: String,
            shortcutHint: String? = nil,
            keywords: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.symbol = symbol
            self.shortcutHint = shortcutHint
            self.keywords = keywords
        }
    }

    // MARK: - The command catalog (pure data: command + title + glyph)

    /// One catalog item: a palette-runnable command with its display title and SF Symbol. Pure value
    /// data (no shortcut lookup, so the catalog stays nonisolated) — the shortcut hint is resolved per
    /// render in ``commandEntries`` against the main-actor `defaultBindings` table.
    struct CatalogItem: Sendable {
        let command: WorkspaceCommand
        let title: String
        let symbol: String
        /// Extra, non-displayed synonyms folded into the fuzzy haystack so the verbs people actually type
        /// — "sync"/"fullscreen"/"split"/"mission control"/"recenter" — find the right command even though
        /// none appear in the title. Never rendered.
        let keywords: String?

        init(command: WorkspaceCommand, title: String, symbol: String, keywords: String? = nil) {
            self.command = command
            self.title = title
            self.symbol = symbol
            self.keywords = keywords
        }
    }

    /// Every palette-runnable ``WorkspaceCommand``, titled with an SF Symbol, in a sensible discovery
    /// order (splits, panes, tabs, focus, view). `.selectTab` is intentionally NOT here — switching to
    /// a specific tab is covered far more usefully by the per-tab entries (by name); the catalog keeps
    /// only the verbs that read well as commands. `.renameTab` is included as a discoverable verb even
    /// though its store effect is a UI affordance (the command layer treats it as a no-op marker,
    /// docs/22 §5).
    nonisolated static let commandCatalog: [CatalogItem] = [
        CatalogItem(command: .newPane(.terminal), title: "New Terminal Pane", symbol: "plus.rectangle", keywords: "split window shell add open create"),
        CatalogItem(command: .newPane(.claudeCode), title: "New Claude Code Pane", symbol: "sparkles.rectangle.stack", keywords: "split ai assistant add open create"),
        CatalogItem(command: .newPane(.remoteGUI), title: "New Remote Window Pane", symbol: "macwindow.badge.plus", keywords: "split video screen share desktop add open create"),
        CatalogItem(command: .duplicatePane, title: "Duplicate Pane", symbol: "plus.square.on.square", keywords: "copy clone"),
        CatalogItem(command: .newGroup, title: "New Group", symbol: "square.on.square.dashed", keywords: "cluster organize folder"),
        CatalogItem(command: .groupSelection, title: "Group Selected Panes", symbol: "square.stack.3d.up", keywords: "cluster combine merge organize selection"),
        CatalogItem(command: .tidy, title: "Tidy Layout", symbol: "square.grid.2x2", keywords: "arrange pack grid clean up organize auto layout"),
        CatalogItem(command: .centerFocusedPane, title: "Center on Pane", symbol: "scope", keywords: "recenter focus jump go to camera"),
        CatalogItem(command: .centerAll, title: "Center on All", symbol: "dot.scope", keywords: "recenter fit zoom out frame everything camera"),
        CatalogItem(command: .toggleZoom, title: "Maximize Pane", symbol: "arrow.up.left.and.arrow.down.right", keywords: "fullscreen full screen zoom expand enlarge"),
        CatalogItem(command: .toggleOverview, title: "Overview", symbol: "rectangle.grid.2x2", keywords: "mission control fit all zoom out birdseye exposé show all panes"),
        CatalogItem(command: .toggleBroadcast, title: "Broadcast Input", symbol: "dot.radiowaves.left.and.right", keywords: "sync synchronize panes tmux mirror type everywhere"),
        CatalogItem(command: .renamePane, title: "Rename Pane", symbol: "pencil", keywords: "title label"),
        CatalogItem(command: .reconnectPane, title: "Reconnect Pane", symbol: "arrow.clockwise", keywords: "redial retry reconnect reopen recover refresh"),
        CatalogItem(command: .closePane, title: "Close Pane", symbol: "xmark", keywords: "quit kill end terminate remove"),
        CatalogItem(command: .reopenClosedPane, title: "Reopen Closed Pane", symbol: "arrow.uturn.backward", keywords: "restore undo close reopen tab"),
        CatalogItem(command: .cycleFocus(forward: true), title: "Focus Next Pane", symbol: "arrow.forward.square", keywords: "cycle next tab switch"),
        CatalogItem(command: .cycleFocus(forward: false), title: "Focus Previous Pane", symbol: "arrow.backward.square", keywords: "cycle previous prev tab switch"),
        CatalogItem(command: .focus(.left), title: "Focus Left", symbol: "arrow.left", keywords: "move navigate"),
        CatalogItem(command: .focus(.right), title: "Focus Right", symbol: "arrow.right", keywords: "move navigate"),
        CatalogItem(command: .focus(.up), title: "Focus Up", symbol: "arrow.up", keywords: "move navigate"),
        CatalogItem(command: .focus(.down), title: "Focus Down", symbol: "arrow.down", keywords: "move navigate"),
        CatalogItem(command: .manageSnippets, title: "Manage Snippets…", symbol: "scroll", keywords: "macro send keys library edit create snippet"),
        CatalogItem(command: .saveLayout, title: "Save Current Layout…", symbol: "rectangle.badge.plus", keywords: "layout preset workspace snapshot save"),
        // Align + distribute (the Arrange ops) — previously menu-bar-only. They act on the multi-selection
        // (≥2 selected) else all panes, exactly like Pane ▸ Arrange.
        CatalogItem(command: .align(.left), title: "Align Left", symbol: "align.horizontal.left", keywords: "arrange edge"),
        CatalogItem(command: .align(.right), title: "Align Right", symbol: "align.horizontal.right", keywords: "arrange edge"),
        CatalogItem(command: .align(.top), title: "Align Top", symbol: "align.vertical.top", keywords: "arrange edge"),
        CatalogItem(command: .align(.bottom), title: "Align Bottom", symbol: "align.vertical.bottom", keywords: "arrange edge"),
        CatalogItem(command: .align(.centerHorizontal), title: "Align Center Horizontally", symbol: "align.horizontal.center", keywords: "arrange centre middle"),
        CatalogItem(command: .align(.centerVertical), title: "Align Center Vertically", symbol: "align.vertical.center", keywords: "arrange centre middle"),
        CatalogItem(command: .distribute(horizontal: true), title: "Distribute Horizontally", symbol: "arrow.left.and.right", keywords: "arrange even space spread"),
        CatalogItem(command: .distribute(horizontal: false), title: "Distribute Vertically", symbol: "arrow.up.and.down", keywords: "arrange even space spread"),
    ]

    // MARK: - Shortcut hint rendering (chord → glyph string)

    /// Renders the default chord bound to `command` (from ``CommandInterpreter/defaultBindings``) as a
    /// human shortcut string (e.g. `⇧⌘D`, `⌥⌘←`). `nil` when the command has no default binding. One
    /// source of truth: it reverse-looks-up the SAME table the keyboard layer binds, so a rebinding
    /// would be reflected here too (the catalog uses the defaults).
    ///
    /// `@MainActor` because it reads ``CommandInterpreter/defaultBindings`` (a static member of the
    /// `@MainActor` ``CommandInterpreter``). Always called from the main-actor-isolated entry builders.
    @MainActor
    static func shortcutHint(for command: WorkspaceCommand) -> String? {
        // The CANONICAL chord (deterministic; a command may carry alias chords — ⌘N/⌘T both make a
        // terminal pane, and the hint must not flap with dictionary order).
        guard let chord = CommandInterpreter.defaultChords(for: command).first else { return nil }
        return render(chord)
    }

    /// Renders a ``KeyChord`` in the native modifier-glyph order (⌃⌥⇧⌘ + key). Pure — `nonisolated`
    /// so it composes from any context.
    nonisolated static func render(_ chord: KeyChord) -> String {
        var out = ""
        if chord.modifiers.contains(.control) { out += "⌃" }
        if chord.modifiers.contains(.option)  { out += "⌥" }
        if chord.modifiers.contains(.shift)   { out += "⇧" }
        if chord.modifiers.contains(.command) { out += "⌘" }
        out += keyGlyph(chord.key)
        return out
    }

    private nonisolated static func keyGlyph(_ key: KeyChord.Key) -> String {
        switch key {
        case let .character(c): return c.uppercased()
        case .tab:        return "⇥"
        case .return:     return "↩"
        case .leftArrow:  return "←"
        case .rightArrow: return "→"
        case .upArrow:    return "↑"
        case .downArrow:  return "↓"
        }
    }
}
#endif
