// PaletteDataSource — the per-domain result providers + the SearchMixer that combines them
// (warp-overlays-actions.md §1.2 / §2.2). A `PaletteDataSource` is registered against a set of
// `QueryFilter`s and returns its `PaletteItem`s for a query; the `SearchMixer` runs the registered sources
// in order, keeps a source iff the query has no filter OR a registered filter matches, ranks the union by
// per-item score, and groups them under section separators.
//
// All sources here are SYNCHRONOUS over a store SNAPSHOT (taken on the @MainActor) so the mixing/ranking is
// pure + unit-testable without a view. The ASYNC file/conversation sources Warp has are represented by the
// `files`/`conversations`/`repos` protocol stubs that return [] (TODO: a host directory-listing wire — see
// logic-api §5.4); the protocol exists so they can be filled later without touching the mixer.

import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import Foundation

// MARK: - Data source protocol

/// A palette result provider for one or more domains (warp-overlays-actions.md §2.2). `results(for:)` is
/// pure over a captured snapshot — the live store read happens when the snapshot is built on the @MainActor.
public protocol PaletteDataSource: Sendable {
    /// The filters this source answers (the mixer runs it when the query filter is nil or one of these).
    var filters: Set<QueryFilter> { get }
    /// The section header label shown above this source's rows (nil ⇒ no separator).
    var sectionTitle: String? { get }
    /// The rows this source returns for `query` (already title/subtitle-matched + scored by the caller — a
    /// source returns its FULL candidate set; the mixer filters + ranks).
    func candidates(query: String) -> [PaletteItem]
}

// MARK: - ACTIONS source (the WorkspaceCommand catalog) — REAL

/// The action catalog source (warp-overlays-actions.md §4.4) — the workspace verbs (new tab, close pane,
/// split H/V, toggle sidebar, open settings, …). Each row runs a tree-path store mutation directly (under
/// `.tree`, per logic-api §7.5 / W6) and records a recent command where the verb is recents-worthy. REAL
/// (the only fully client-side-wired source besides TABS).
public struct ActionsPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.actions]
    public let sectionTitle: String? = "Actions"

    public init() {}

    public func candidates(query _: String) -> [PaletteItem] { Self.catalog }

    /// The fixed action catalog. IDs are stable so recents/tests can reference them. Each `.store` closure
    /// drives the tree-path store API (not the canvas-era `apply`), then records the matching recent command.
    ///
    /// Shortcut hints are NEVER hardcoded — each row derives its glyph from
    /// ``WorkspaceBindingRegistry/glyph(for:)`` (the SAME single source the keyboard bank registers and the
    /// cheat sheet renders) so a chord change can't desync the displayed glyph. A verb with no registry
    /// chord (New Remote Window Tab, Reconnect Pane, …) resolves to `nil` ⇒ no hint chip — correct, since
    /// the chord genuinely does not exist.
    public static let catalog: [PaletteItem] = [
        item(
            id: "action.newTerminalTab", icon: "plus.rectangle", title: "New Tab",
            shortcut: glyph(.newTab),
            run: { store in
                store.newTab(kind: .terminal)
                store.recordRecentCommand(.newPane(.terminal))
            },
        ),
        // L6 / W1: "New Remote Window Tab" opens the Remote-Window picker (the host window list) rather
        // than minting an UNBOUND `.remoteGUI` pane — the pick then opens a pre-bound streaming pane. The
        // overlay coordinator handles `.openRemotePicker` (it records the recent command on open). No
        // registry chord exists for it ⇒ no hint.
        PaletteItem(
            id: "action.newRemoteTab", icon: "rectangle.on.rectangle", title: "New Remote Window Tab",
            shortcut: nil, filter: .actions, action: .openRemotePicker,
        ),
        item(
            id: "action.splitRight", icon: "rectangle.split.2x1", title: "Split Pane Right",
            shortcut: glyph(.splitRight),
            run: { store in
                store.splitActivePane(axis: .horizontal, kind: .terminal)
            },
        ),
        item(
            id: "action.splitDown", icon: "rectangle.split.1x2", title: "Split Pane Down",
            shortcut: glyph(.splitDown),
            run: { store in
                store.splitActivePane(axis: .vertical, kind: .terminal)
            },
        ),
        item(
            id: "action.closePane", icon: "xmark.square", title: "Close Pane",
            shortcut: glyph(.closePane),
            run: { store in
                store.requestCloseActivePaneTree()
                store.recordRecentCommand(.closePane)
            },
        ),
        item(
            id: "action.closeTab", icon: "xmark.rectangle", title: "Close Tab",
            shortcut: glyph(.closeTab),
            run: { store in store.closeActiveTab() },
        ),
        item(
            id: "action.toggleZoom", icon: "arrow.up.left.and.arrow.down.right", title: "Toggle Maximize Pane",
            shortcut: glyph(.toggleZoom),
            run: { store in
                store.toggleZoomActivePane()
                store.recordRecentCommand(.toggleZoom)
            },
        ),
        item(
            id: "action.toggleSidebar", icon: "sidebar.left", title: "Toggle Tabs Panel",
            shortcut: glyph(.toggleSidebar),
            run: { store in store.toggleSidebarCollapsed() },
        ),
        item(
            id: "action.renamePane", icon: "pencil", title: "Rename Pane",
            shortcut: glyph(.renamePane),
            run: { store in store.requestRenameActivePane() },
        ),
        // No registry chord exists for reconnect (the keyboard bank never registers one) ⇒ no hint chip.
        item(
            id: "action.reconnect", icon: "arrow.clockwise", title: "Reconnect Pane",
            shortcut: nil,
            run: { store in
                if let pane = store.tree.activeSession?.activeTab?.activePane {
                    store.reconnect(pane)
                }
                store.recordRecentCommand(.reconnectPane)
            },
        ),
        // Connect to a (possibly non-default) host — the only entry point to the host/port editor besides
        // the top-bar status pill. No registry chord ⇒ no hint chip.
        PaletteItem(
            id: "action.connect", icon: "network", title: "Connect to Host…",
            subtitle: nil, shortcut: nil, filter: .actions, action: .openConnect,
        ),
        PaletteItem(
            id: "action.openSettings", icon: "slider.horizontal.3", title: "Open Settings",
            subtitle: nil, shortcut: nil, filter: .actions, action: .openSettings,
        ),
        // The cheat sheet is also reachable by ⌘/; surfacing it here means the keyboard reference is
        // discoverable without knowing the chord. Its hint derives from the registry (no drift).
        PaletteItem(
            id: "action.cheatSheet", icon: "keyboard", title: "Keyboard Shortcuts",
            subtitle: nil, shortcut: glyph(.cheatSheet), filter: .actions, action: .openCheatSheet,
        ),
    ]

    /// The live registry glyph for `action`'s default chord (nil when unbound) — the ONE source the catalog
    /// hints derive from, so the displayed chord can never drift from the keyboard bank.
    private static func glyph(_ action: WorkspaceAction) -> String? {
        WorkspaceBindingRegistry.glyph(for: action)
    }

    /// Build a `.store` action row.
    private static func item(
        id: String, icon: String, title: String, shortcut: String? = nil,
        run: @escaping @MainActor @Sendable (WorkspaceStore) -> Void,
    ) -> PaletteItem {
        PaletteItem(id: id, icon: icon, title: title, shortcut: shortcut, filter: .actions, action: .store(run))
    }
}

// MARK: - TABS source (jump to a pane/tab) — REAL

/// Jump-to-tab/pane source (warp-overlays-actions.md §2.2 navigation). One row per visible pane of the
/// active session's tabs (the same enumeration the rail uses); selecting it focuses that pane. REAL.
public struct TabsPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter> = [.tabs]
    public let sectionTitle: String? = "Tabs"

    /// A snapshot row (the store read is done when the snapshot is built).
    public struct Entry: Sendable {
        public let paneID: PaneID
        public let tabIndex: Int
        public let title: String
        public let subtitle: String?
        public let isAgent: Bool
    }

    private let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Build a snapshot from the live store (active session's tabs → one entry per visible pane).
    @preconcurrency
    @MainActor
    public static func snapshot(_ store: WorkspaceStore) -> Self {
        guard let session = store.tree.activeSession else { return Self(entries: []) }
        var out: [Entry] = []
        for (tabIndex, tab) in session.tabs.enumerated() {
            for paneID in tab.root.allPaneIDs() {
                let spec = session.specs[paneID]
                let title = spec?.lastKnownTitle ?? spec?.title ?? "Terminal"
                let subtitle = spec?.lastKnownCwd
                let isAgent = (store.paneAgentStatus[paneID] ?? .none) != .none
                out.append(Entry(
                    paneID: paneID, tabIndex: tabIndex,
                    title: title.isEmpty ? "Terminal" : title, subtitle: subtitle, isAgent: isAgent,
                ))
            }
        }
        return Self(entries: out)
    }

    public func candidates(query _: String) -> [PaletteItem] {
        entries.map { entry in
            PaletteItem(
                id: "tab.\(entry.paneID.raw.uuidString)",
                icon: entry.isAgent ? "asterisk" : "terminal",
                title: entry.title,
                subtitle: entry.subtitle,
                shortcut: nil,
                filter: .tabs,
                action: .store { store in store.focusPaneTree(entry.paneID) },
            )
        }
    }
}

// MARK: - Empty stub sources (protocol present, no client data — TODO host)

/// A source that returns no rows but registers its filter so the chip appears and the wiring is in place.
/// Files/conversations/repos have no client-side data yet (logic-api §5.4) — TODO host directory/AI wires.
public struct EmptyPaletteSource: PaletteDataSource {
    public let filters: Set<QueryFilter>
    public let sectionTitle: String?

    public init(filter: QueryFilter, sectionTitle: String? = nil) {
        filters = [filter]
        self.sectionTitle = sectionTitle
    }

    public func candidates(query _: String) -> [PaletteItem] { [] }
}

// MARK: - The mixer

/// Combines registered sources into one ordered, sectioned result list (warp-overlays-actions.md §2.2).
/// Pure + `@MainActor`-free for the mix step (the live store reads happen when the snapshot sources are
/// built). Ranks by per-item score, keeps source-registration order for ties, and inserts section
/// separators before each non-empty source group.
public struct SearchMixer: Sendable {
    /// The maximum rows returned (warp `MAX_SEARCH_RESULTS = 250`).
    public static let maxResults = 250

    private let sources: [any PaletteDataSource]

    public init(sources: [any PaletteDataSource]) { self.sources = sources }

    /// All filters any registered source answers (drives the zero-state chips, registration order).
    public var availableFilters: [QueryFilter] {
        var seen = Set<QueryFilter>()
        var out: [QueryFilter] = []
        for source in sources {
            for f in QueryFilter.allCases where source.filters.contains(f) && !seen.contains(f) {
                seen.insert(f)
                out.append(f)
            }
        }
        return out
    }

    /// Whether `source` runs for `activeFilter` (no filter ⇒ all sources; else only matching sources).
    private func runs(_ source: any PaletteDataSource, for activeFilter: QueryFilter?) -> Bool {
        guard let activeFilter else { return true }
        return source.filters.contains(activeFilter)
    }

    /// Produce the ordered, sectioned result list for `query` under an optional `activeFilter`. Each
    /// source's matched rows are ranked highest-score-first (stable for ties), prefixed by a separator when
    /// the source declares a section title and contributes ≥1 row. Capped to `maxResults`.
    public func results(query: String, activeFilter: QueryFilter? = nil) -> [PaletteItem] {
        var out: [PaletteItem] = []
        for source in sources where runs(source, for: activeFilter) {
            let ranked = source.candidates(query: query)
                .filter { $0.score(for: query) > 0 }
                .enumerated()
                .sorted { lhs, rhs in
                    let (ls, rs) = (lhs.element.score(for: query), rhs.element.score(for: query))
                    if ls != rs { return ls > rs }
                    return lhs.offset < rhs.offset // stable: keep source order for equal scores
                }
                .map(\.element)
            guard !ranked.isEmpty else { continue }
            if let title = source.sectionTitle {
                out.append(.separator(title, filter: source.filters.first ?? .actions))
            }
            out.append(contentsOf: ranked)
            if out.count >= Self.maxResults { break }
        }
        return Array(out.prefix(Self.maxResults))
    }

    /// The selectable (non-separator) rows of a result list — for keyboard ↑/↓ navigation + ⏎ accept.
    public static func selectable(_ items: [PaletteItem]) -> [PaletteItem] {
        items.filter { !$0.isSeparator }
    }
}
