import Foundation

// MARK: - Tab (one tiled split tree within a session)

/// One tiled split tree within a ``Session`` (docs/42 §Domain model). A pure
/// `Identifiable`/`Codable`/`Equatable`/`Sendable` value with **no SwiftUI / transport import** so it
/// unit-tests headless. A `Tab` owns:
///
/// - ``root`` — the recursive n-ary ``SplitNode`` tree of ``PaneID``s. **Never empty for a live tab** (a
///   tab with no panes is closed; see ``WorkspaceTreeOps/closePane(_:in:)``).
/// - ``activePane`` — the focused leaf within this tab (the one taking keyboard input). Kept in `root` by
///   the ops + ``Session/normalizingActive()``.
/// - ``zoomedPane`` — the **out-of-tree** zoom (WezTerm `TabInner.zoomed`): render-only, the tree is
///   untouched, all siblings stay mounted at `opacity 0` (the proven no-teardown trick). `nil` = normal
///   tiled view.
/// - ``floatingPanes`` — the overlay layer (docs/41 §7.3 / docs/42 Decisions.9). **LIVE since E21**: a pane
///   id here is rendered as an in-app floating card stacked over the tiled tree (`FloatingPaneCard`,
///   z-ordered last = topmost). The set is mutated by `WorkspaceTreeOps.toggleFloating` /
///   `WorkspaceTreeOps.spawnFloating` (and `toggleFloating(embedAnchor:)` returns a card to the tile); its
///   geometry rides each pane's ``PaneSpec/floatingFrame``. Kind-generic — a terminal, a local web pane, or a
///   `.remoteGUI` video pane all float. Was `[]` through the MVP (schema-reserved since docs/42 to avoid a
///   later migration); E21 made it the live float layer rather than adding a new field.
///
/// A pane's ``PaneSpec`` is **not** stored here — the split tree holds only identity/geometry; specs live
/// in the owning ``Session/specs`` side table (so a rename never churns a tree diff).
public struct Tab: Identifiable, Codable, Sendable, Equatable {
    public let id: TabID
    /// `""` = derive the displayed title from the active pane's OSC title at render time.
    public var title: String
    /// The tiled tree of ``PaneID``s. Never empty for a live tab.
    public var root: SplitNode
    /// The focused leaf within this tab, or `nil` when none is resolved yet.
    public var activePane: PaneID?
    /// Out-of-tree zoom (render-only). `nil` = normal tiled view.
    public var zoomedPane: PaneID?
    /// Overlay layer (docs/42 Decisions.9). LIVE since E21: each id renders as a floating `FloatingPaneCard`
    /// over the tiled tree; mutated by `WorkspaceTreeOps.toggleFloating`/`spawnFloating`. `[]` = no floating
    /// panes (the steady state).
    public var floatingPanes: [PaneID]

    public init(
        id: TabID = TabID(),
        title: String = "",
        root: SplitNode,
        activePane: PaneID? = nil,
        zoomedPane: PaneID? = nil,
        floatingPanes: [PaneID] = [],
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.activePane = activePane
        self.zoomedPane = zoomedPane
        self.floatingPanes = floatingPanes
    }
}

// MARK: - Pure queries

public extension Tab {
    /// Every ``PaneID`` in this tab's tree, in pre-order DFS (the floating layer appended after the tree).
    /// Drives the session/workspace `allPaneIDs()` and the specs == leafIDs invariant — so a floated pane
    /// stays a first-class member (its spec is still required, it is still reconciled into the registry).
    func allPaneIDs() -> [PaneID] {
        root.allPaneIDs() + floatingPanes
    }

    /// Whether `id` is a leaf in this tab (tree or floating layer).
    func contains(_ id: PaneID) -> Bool {
        root.contains(id) || floatingPanes.contains(id)
    }
}
