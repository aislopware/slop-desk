import Foundation
import CoreGraphics

// MARK: - Workspace (the whole tree of intent — ONE canvas, no tabs)

/// The entire **workspace of intent** (docs/31): a single infinite ``Canvas`` of free-floating panes,
/// the focused / maximized pane, and the named ``PaneGroup``s the panes are organized into. This pure
/// value type *is* the persistence format (docs/22 §6) — `Codable`, round-trippable, holding no live
/// object. ``WorkspaceStore`` owns one of these as its single source of truth and reconciles the
/// liveness registry against it after every mutation.
///
/// ### Tabs are gone (docs/31)
/// The old `[Tab]` layer (one canvas per tab, an `activeTabID`) is removed: everything lives on ONE
/// canvas. Tab switching used to unmount/rebuild the active tab's libghostty surfaces (a naive
/// byte-ring replay → render corruption); a single always-mounted canvas removes that path entirely.
/// Organization that tabs provided is now ``groups`` — pure sidebar/box metadata, NOT a layout layer.
///
/// All workspace-level arithmetic lives here as **pure functions returning a new `Workspace`** (group
/// CRUD + the normalizing repairs). The canvas-level ops (move/resize/raise/camera/…) live on
/// ``Canvas``; the store composes both then reconciles.
public struct Workspace: Codable, Sendable, Equatable {
    /// The current schema version for forward migration (docs/22 §6). Bumped when the persisted shape
    /// changes; an unknown/old version simply falls back to ``defaultWorkspace()`` (this is a
    /// single-user project — there is deliberately NO backward-compat migration path).
    public var schemaVersion: Int
    /// THE single infinite plane of free-floating panes (was one `Canvas` per tab).
    public var canvas: Canvas
    /// The pane that currently has focus, or `nil` when the canvas is empty. Kept valid by the ops below
    /// + ``normalizingFocus()`` (a closed / dangling focus repoints to a surviving pane).
    public var focusedPane: PaneID?
    /// `nil` = normal canvas; non-nil = that pane is maximized to fill the viewport (a pure presentation
    /// flag — no model surgery, registry untouched, the proven no-teardown property of the old
    /// `zoomedPane`).
    public var maximizedPane: PaneID?
    /// The named groups panes can be organized into, in sidebar order. Pure metadata: a pane's
    /// membership lives on its ``CanvasItem/groupID``; a `PaneGroup` here only carries id + name.
    public var groups: [PaneGroup]
    /// The ONE app-global host the whole app connects to (docs/31): every terminal pane is a channel on
    /// the shared mux at this host, every video pane a lane on the shared UDP flow at this host. Replaces
    /// the old per-pane `PaneSpec.endpoint`. Persisted so the connect-gate prefills the last-used host;
    /// `nil` until the user first connects (the gate then shows ``ConnectionTarget/default``).
    public var connection: ConnectionTarget?

    public init(
        schemaVersion: Int = Workspace.currentSchemaVersion,
        canvas: Canvas,
        focusedPane: PaneID?,
        maximizedPane: PaneID? = nil,
        groups: [PaneGroup] = [],
        connection: ConnectionTarget? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.canvas = canvas
        self.focusedPane = focusedPane
        self.maximizedPane = maximizedPane
        self.groups = groups
        self.connection = connection
    }
}

// MARK: - Schema + default

public extension Workspace {
    /// The schema version this build writes (the single-canvas + groups shape, docs/31). A
    /// higher/unrecognized version — or any older on-disk shape that no longer decodes — falls back to
    /// ``defaultWorkspace()``. Single-user project: there is no backward-compatibility path by design.
    static let currentSchemaVersion = 4

    /// The fresh-launch / decode-failure fallback: one terminal pane at the origin, focused, ungrouped.
    static func defaultWorkspace() -> Workspace {
        let paneID = PaneID()
        let item = CanvasItem(
            id: paneID,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            frame: CGRect(origin: .zero, size: Canvas.defaultItemSize),
            z: 0
        )
        return Workspace(canvas: Canvas(items: [item]), focusedPane: paneID)
    }
}

// MARK: - Lookups

public extension Workspace {
    /// The group with `id`, or `nil`.
    func group(_ id: PaneGroupID) -> PaneGroup? { groups.first { $0.id == id } }

    /// The index of the group with `id`, or `nil`.
    func groupIndex(of id: PaneGroupID) -> Int? { groups.firstIndex { $0.id == id } }

    /// The group a pane belongs to, or `nil` if it is ungrouped / absent.
    func group(ofPane paneID: PaneID) -> PaneGroup? {
        guard let gid = canvas.item(paneID)?.groupID else { return nil }
        return group(gid)
    }
}

// MARK: - Normalizing repairs (applied on load — never crash on a hand-edited file)

public extension Workspace {
    /// Repairs the `focusedPane` / `maximizedPane` invariants: a focus pointing at a pane no longer on
    /// the canvas repoints to the first pane (or `nil` when empty); a dangling maximize clears. Applied
    /// on persistence load so keyboard focus is never pinned to a ghost pane and no stale maximize
    /// survives (R13, ported to the single canvas).
    func normalizingFocus() -> Workspace {
        var copy = self
        let ids = canvas.allIDs()
        if let f = copy.focusedPane, !ids.contains(f) {
            copy.focusedPane = ids.first
        } else if copy.focusedPane == nil {
            copy.focusedPane = ids.first
        }
        if let m = copy.maximizedPane, !ids.contains(m) {
            copy.maximizedPane = nil
        }
        return copy
    }

    /// Repairs group membership: an item whose `groupID` names a group not in ``groups`` is reset to
    /// ungrouped (a hand-edited / partially-deleted file). Empty groups are KEPT (a user may create a
    /// group before assigning panes). Pure.
    func normalizingGroups() -> Workspace {
        let valid = Set(groups.map(\.id))
        var copy = self
        copy.canvas = Canvas(
            items: canvas.items.map { item in
                guard let gid = item.groupID, !valid.contains(gid) else { return item }
                var c = item
                c.groupID = nil
                return c
            },
            camera: canvas.camera
        )
        return copy
    }
}

// MARK: - Focus (pure)

public extension Workspace {
    /// Focuses pane `id` if it is on the canvas (no-op otherwise). Maximize follows focus: if a pane is
    /// maximized and focus jumps elsewhere, the maximize re-points so the on-screen pane always equals
    /// the one taking keyboard input (never type into an invisible pane behind a maximized one).
    func focusing(_ id: PaneID) -> Workspace {
        guard canvas.contains(id) else { return self }
        var copy = self
        copy.focusedPane = id
        if copy.maximizedPane != nil { copy.maximizedPane = id }
        return copy
    }
}

// MARK: - Pure group arithmetic (each returns a NEW workspace)

public extension Workspace {
    /// Appends a new empty group named `name`, returning the new workspace and the minted id. The new
    /// group has no members yet (the caller assigns panes via ``assigning(pane:toGroup:)``).
    func addingGroup(name: String) -> (Workspace, PaneGroupID) {
        let group = PaneGroup(name: name)
        var copy = self
        copy.groups.append(group)
        return (copy, group.id)
    }

    /// Renames group `id` to `name` (no-op if absent).
    func renamingGroup(_ id: PaneGroupID, to name: String) -> Workspace {
        guard let i = groupIndex(of: id) else { return self }
        var copy = self
        copy.groups[i].name = name
        return copy
    }

    /// Removes group `id`: drops it from ``groups`` AND clears the `groupID` of its members (they
    /// survive as ungrouped panes — deleting a group never closes a pane). No-op if absent.
    func removingGroup(_ id: PaneGroupID) -> Workspace {
        guard groupIndex(of: id) != nil else { return self }
        var copy = self
        copy.groups.removeAll { $0.id == id }
        copy.canvas = copy.canvas.clearingGroup(id)
        return copy
    }

    /// Assigns pane `paneID` to group `groupID` (or ungroups it when `groupID` is `nil`). Disjoint —
    /// a pane is in at most one group, so this moves it. No-op if the pane is absent.
    func assigning(pane paneID: PaneID, toGroup groupID: PaneGroupID?) -> Workspace {
        var copy = self
        copy.canvas = copy.canvas.assigning(paneID, toGroup: groupID)
        return copy
    }

    /// Reorders groups (SwiftUI `onMove` semantics). Pure reorder; membership unchanged.
    func movingGroup(from source: IndexSet, to destination: Int) -> Workspace {
        var copy = self
        copy.groups.move(fromOffsets: source, toOffset: destination)
        return copy
    }
}
