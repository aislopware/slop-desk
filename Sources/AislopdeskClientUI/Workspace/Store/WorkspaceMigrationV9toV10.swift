import CoreGraphics
import Foundation

// MARK: - WorkspaceMigrationV9toV10 (the first non-trivial schema step)

/// The **pure** v9 → v10 migration (docs/42 §Migration): the frozen ``WorkspaceV9`` shadow (single
/// infinite ``Canvas`` of free-floating panes + named ``PaneGroup``s) → the tree-rooted ``TreeWorkspace``
/// (`Session → Tab → Pane`).
///
/// ### Mapping rules (deterministic, pinned by `WorkspaceMigrationV9toV10Tests`)
/// - **One default ``Session``**, named from `v9.connection?.host ?? "Local"`, carrying `v9.connection`.
/// - **Groups → tabs**: every ungrouped pane goes into a leading `"Main"` tab (omitted when nothing is
///   ungrouped); each ``PaneGroup`` becomes one ``Tab`` (group name → tab title, group order preserved).
///   An EMPTY group (no member panes) yields **no** tab — a live tab must have ≥ 1 pane. A pane whose
///   `groupID` names a group NOT in `v9.groups` (a hand-edited / partially-deleted file) is treated as
///   ungrouped (→ the "Main" tab), mirroring ``Workspace/normalizingGroups()`` so no pane is lost.
/// - **Tab.root**: a tab's panes are arranged into a valid ``SplitNode`` — 1 pane → `.leaf`; ≥ 2 →
///   a flat, **even-weight** `.split(axis: .horizontal)`, ordered by `frame.minX` then `frame.minY` so the
///   layout (and round-trips) are deterministic.
/// - **Specs preserved 1:1**: `Session.specs[paneID] = item.spec` for every leaf in that session — every
///   ``PaneID`` + ``PaneSpec`` survives verbatim. The dropped fields are `frame` / `z` / `groupID` /
///   `camera` / `bookmarks` (none are representable in the tree). `maximizedPane` is NOT dropped — it is
///   carried onto the owning tab's `zoomedPane` (see "Active state carried" below).
/// - **Active state carried**: `activePane = v9.focusedPane` when it lands in a tab; `zoomedPane =
///   v9.maximizedPane` when it lands in a tab; `activeTabIndex` follows the focused pane's owning tab.
/// - **Client state carried**: `snippets` + `layoutPresets` (both schemas share these) are kept verbatim.
///
/// The result is `normalized()` so the **`Set(specs.keys) == Set(leafIDs)` invariant** holds even for a
/// hand-edited / partial v9 file (validate-then-repair). The function is total — it never force-unwraps or
/// traps on a degenerate input (no panes / one pane / one group / a focus pointing at a missing pane).
enum WorkspaceMigrationV9toV10 {
    /// Migrates a decoded ``WorkspaceV9`` value to a ``TreeWorkspace``. Pure + total — see the type doc.
    static func migrate(_ v9: WorkspaceV9) -> TreeWorkspace {
        let session = makeSession(from: v9)
        let workspace = TreeWorkspace(
            sessions: [session],
            activeSessionID: session.id,
            // Both schemas share these client-state collections — carry them verbatim (docs/42 §Migration).
            snippets: v9.snippets,
            layoutPresets: v9.layoutPresets,
        )
        // Repair the invariant (drop orphan specs / re-seed missing ones) + the active selection. A
        // degenerate v9 (no panes) normalizes into the default single-leaf workspace rather than an empty one.
        return workspace.normalized()
    }

    // MARK: - Session assembly

    /// Builds the single default session: one tab per group (+ a leading "Main" for ungrouped panes), the
    /// spec side table, and the carried connection / active state.
    private static func makeSession(from v9: WorkspaceV9) -> Session {
        let items = v9.canvas.items
        // The set of groups that actually exist. A pane whose `groupID` names a group NOT in this set
        // (hand-edited / partially-deleted file) must NOT be lost — the LIVE load path repairs it via
        // `Workspace.normalizingGroups()` (resets the dangling membership to nil). Mirror that here so
        // the dangling pane survives as ungrouped (→ the "Main" tab) instead of bucketing into NEITHER
        // group nor ungrouped and becoming an orphan spec that `.normalized()` then deletes.
        let validGroupIDs = Set(v9.groups.map(\.id))
        // Bucket panes by group, preserving group order; ungrouped (incl. a dangling groupID) → "Main".
        let ungrouped = items.filter { item in
            guard let gid = item.groupID else { return true }
            return !validGroupIDs.contains(gid)
        }
        var tabs: [Tab] = []

        // Leading "Main" tab for ungrouped panes (only when there are any — never an empty tab).
        if !ungrouped.isEmpty {
            tabs.append(makeTab(title: "Main", panes: ungrouped))
        }
        // One tab per group, in the v9 group order; an empty group yields no tab.
        for group in v9.groups {
            let members = items.filter { $0.groupID == group.id }
            guard !members.isEmpty else { continue }
            tabs.append(makeTab(title: group.name, panes: members))
        }

        // The spec side table: every leaf's PaneSpec, preserved verbatim (the join contract).
        var specs: [PaneID: PaneSpec] = [:]
        for item in items { specs[item.id] = item.spec }

        // Carry focus → the owning tab's activePane; maximize → that tab's zoomedPane; select that tab.
        var activeTabIndex = 0
        if let focused = v9.focusedPane {
            for (index, tab) in tabs.enumerated() where tab.contains(focused) {
                tabs[index].activePane = focused
                activeTabIndex = index
            }
        }
        if let maximized = v9.maximizedPane {
            for (index, tab) in tabs.enumerated() where tab.contains(maximized) {
                tabs[index].zoomedPane = maximized
            }
        }

        return Session(
            name: v9.connection?.host ?? "Local",
            tabs: tabs,
            activeTabIndex: activeTabIndex,
            specs: specs,
            connection: v9.connection,
        )
    }

    // MARK: - Tab assembly

    /// Arranges a tab's panes into a valid ``SplitNode``: 1 pane → `.leaf`; ≥ 2 → a flat even-weight
    /// horizontal split, ordered by `frame.minX` then `frame.minY` (deterministic).
    private static func makeTab(title: String, panes: [CanvasItemV9]) -> Tab {
        let ordered = panes.sorted { lhs, rhs in
            // Ordered comparison (no bare `<` on a NaN-bearing value): minX primary, minY tiebreak,
            // PaneID UUID string as a final stable tiebreaker so two coincident frames still order
            // deterministically (and the round-trip is byte-stable).
            let lx = lhs.frame.minX
            let rx = rhs.frame.minX
            if lx != rx { return lx < rx }
            let ly = lhs.frame.minY
            let ry = rhs.frame.minY
            if ly != ry { return ly < ry }
            return lhs.id.raw.uuidString < rhs.id.raw.uuidString
        }
        let root = makeRoot(from: ordered.map(\.id))
        return Tab(title: title, root: root, activePane: ordered.first?.id)
    }

    /// 1 id → `.leaf`; ≥ 2 → a flat even-weight `.split(axis: .horizontal)`. (A 0-id list cannot occur —
    /// the callers only build a tab from a non-empty bucket — but is handled by seeding a fresh leaf so
    /// the function is total.)
    private static func makeRoot(from ids: [PaneID]) -> SplitNode {
        switch ids.count {
        case 0:
            return .leaf(PaneID())
        case 1:
            return .leaf(ids[0])
        default:
            let children = ids.map { WeightedChild(weight: .flex(1), node: .leaf($0)) }
            return .split(id: SplitNodeID(), axis: .horizontal, children: children)
        }
    }
}
