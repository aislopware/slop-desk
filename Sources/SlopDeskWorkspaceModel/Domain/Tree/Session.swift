import Foundation

// MARK: - DetachedPane (a pane living in its own OS window, outside every tab tree)

/// A pane the user detached into its OWN macOS window: it has left every tab's split tree but stays a
/// first-class member of its ``Session`` — its ``PaneSpec`` remains in the session's side table and the
/// store's reconcile keeps its live handle registered, so the PTY / video session survives the move (only
/// the VIEW remounts in the satellite window). Distinct from the retired in-app floating-card feature
/// (docs/DECISIONS.md 2026-07-03): this is OS-window detach, not an overlay layer.
public struct DetachedPane: Sendable, Equatable, Identifiable {
    /// The detached pane — also the spec/registry key.
    public let pane: PaneID
    /// The tab the pane detached FROM — the preferred reattach destination. `nil` / a since-closed tab
    /// falls back to the session's active tab.
    public var originTab: TabID?

    public var id: PaneID { pane }

    public init(pane: PaneID, originTab: TabID? = nil) {
        self.pane = pane
        self.originTab = originTab
    }
}

// MARK: - Session (the top of the tiled hierarchy)

/// A named, host-scoped group of ``Tab``s — the top of the new `Session → Tab → Pane` hierarchy that
/// replaces the retired infinite canvas (docs/42 §Decisions.1). A pure
/// `Identifiable`/`Equatable`/`Sendable` value with **no SwiftUI / transport import**, and
/// deliberately not `Codable`: both shapes a session arrives in — a host's push and the client's
/// `workspace.json` — are decoded by `rust/slopdesk-workspace` (``WorkspaceFile``).
///
/// A `Session` owns its tabs (``tabs``, ≥ 1 for a live session) and the per-session ``specs`` side
/// table (the **specs == leafIDs invariant**: `Set(specs.keys) == Set(leafIDs across every tab)`).
/// The tree is MIXED-KIND: a leaf's `PaneSpec.kind` decides its content (terminal / desktop / remote
/// window) — the full-desktop pivot, docs/DECISIONS.md 2026-07-14. It carries NO host association: which
/// host this client talks to is device-local, so the committed ``ConnectionTarget`` lives in
/// ``DevicePreferences`` keyed by `host:port` (docs/45 §7.3).
public struct Session: Identifiable, Sendable, Equatable {
    public let id: SessionID
    public var name: String
    /// The session's tabs, in tab-bar order. ≥ 1 for a live session.
    public var tabs: [Tab]
    /// The selected tab. Clamped to `tabs.indices` by ``normalizingActive()`` / the ops.
    public var activeTabIndex: Int
    /// Side table mapping each pane ``PaneID`` (tree leaf OR detached) to its ``PaneSpec`` (so a rename
    /// never churns a tree diff). Invariant: `Set(specs.keys) == leafIDSet() ∪ detachedIDSet()`.
    public var specs: [PaneID: PaneSpec]
    /// Panes detached into their own OS windows, in detach order. Each keeps its spec in ``specs`` and
    /// its live registry handle (the store's reconcile counts detached panes as desired), so detach ↔
    /// reattach never tears a session down. Additive v11 field — absent in older files (a missing or
    /// unreadable list reads as none, `persist::tolerant_array`), written only when non-empty so a
    /// detach-free workspace file stays byte-identical.
    public var detached: [DetachedPane]

    public init(
        id: SessionID = SessionID(),
        name: String,
        tabs: [Tab],
        activeTabIndex: Int = 0,
        specs: [PaneID: PaneSpec],
        detached: [DetachedPane] = [],
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.specs = specs
        self.detached = detached
    }
}

// MARK: - Construction

public extension Session {
    /// A fresh single-tab, single-leaf session — the building block for `newSession` and the default
    /// workspace. The lone leaf's id keys the spec side table so the invariant holds at birth.
    static func singlePane(name: String, spec: PaneSpec) -> Session {
        let paneID = PaneID()
        let tab = Tab(root: .leaf(paneID), activePane: paneID)
        return Session(name: name, tabs: [tab], activeTabIndex: 0, specs: [paneID: spec])
    }
}

// MARK: - Pure queries

public extension Session {
    /// Every ``PaneID`` across every tab, in tab order then pre-order DFS. Drives the workspace
    /// `allPaneIDs()` and the specs == leafIDs invariant.
    func allPaneIDs() -> [PaneID] {
        tabs.flatMap { $0.allPaneIDs() }
    }

    /// The set of leaf ids across every tab.
    func leafIDSet() -> Set<PaneID> {
        Set(allPaneIDs())
    }

    /// The set of pane ids detached into their own windows (see ``detached``).
    func detachedIDSet() -> Set<PaneID> {
        Set(detached.map(\.pane))
    }

    /// Whether `id` is detached into its own window in this session.
    func isDetached(_ id: PaneID) -> Bool {
        detached.contains { $0.pane == id }
    }

    /// The ``PaneSpec`` for pane `id` in this session — a tree leaf OR a detached pane (both are
    /// first-class members of the session's side table), or `nil` if this session does not own it.
    func spec(for id: PaneID) -> PaneSpec? {
        guard contains(id) || isDetached(id) else { return nil }
        return specs[id]
    }

    /// Whether `id` is a leaf anywhere in this session.
    func contains(_ id: PaneID) -> Bool {
        tabs.contains { $0.contains(id) }
    }

    /// The currently selected tab (clamped). `nil` only for a structurally empty session (never live).
    var activeTab: Tab? {
        guard tabs.indices.contains(activeTabIndex) else { return tabs.first }
        return tabs[activeTabIndex]
    }

    /// The index of the tab whose tree contains `id`, or `nil`.
    func tabIndex(containing id: PaneID) -> Int? {
        tabs.firstIndex { $0.contains(id) }
    }
}
