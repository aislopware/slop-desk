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
///
/// A pane's ``PaneSpec`` is **not** stored here — the split tree holds only identity/geometry; specs live
/// in the owning ``Session/specs`` side table (so a rename never churns a tree diff).
///
/// A stale `floatingPanes` key (floating-pane feature removed 2026-07-03) in a persisted file is simply
/// not a stored property → decode-ignored; the ids it named are then dropped as orphan specs by
/// ``TreeWorkspace/normalizingSpecs()`` (the tiled tree survives intact).
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

    public init(
        id: TabID = TabID(),
        title: String = "",
        root: SplitNode,
        activePane: PaneID? = nil,
        zoomedPane: PaneID? = nil,
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.activePane = activePane
        self.zoomedPane = zoomedPane
    }
}

// MARK: - Pure queries

public extension Tab {
    /// Every ``PaneID`` in this tab's tree, in pre-order DFS. Drives the session/workspace `allPaneIDs()`
    /// and the specs == leafIDs invariant.
    func allPaneIDs() -> [PaneID] {
        root.allPaneIDs()
    }

    /// Whether `id` is a leaf in this tab.
    func contains(_ id: PaneID) -> Bool {
        root.contains(id)
    }
}
