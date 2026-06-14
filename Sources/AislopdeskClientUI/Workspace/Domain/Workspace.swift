import CoreGraphics
import Foundation

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
    /// Viewport bookmarks by slot (1–9): ⇧⌘n saves, ⌘n recalls — the single-key spatial jumps of the
    /// daily loop (terminal → browser pane → Claude pane) on a pan-only canvas.
    public var bookmarks: [Int: CanvasBookmark]
    /// Named, savable canvas layouts ("ios-build", "monitoring", …): the user snapshots the current
    /// canvas under a name and switches contexts in one action. Snapshot = canvas + groups + focus,
    /// NOT the app connection (one host per session) — see ``LayoutPreset``.
    public var layoutPresets: [LayoutPreset]
    /// Saved command macros runnable from ⌘K (`ssh {{host}}`, `git add -A<Enter>git commit<Enter>`, …).
    /// See ``Snippet``. Persisted like ``layoutPresets``.
    public var snippets: [Snippet]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        canvas: Canvas,
        focusedPane: PaneID?,
        maximizedPane: PaneID? = nil,
        groups: [PaneGroup] = [],
        connection: ConnectionTarget? = nil,
        bookmarks: [Int: CanvasBookmark] = [:],
        layoutPresets: [LayoutPreset] = [],
        snippets: [Snippet] = [],
    ) {
        self.schemaVersion = schemaVersion
        self.canvas = canvas
        self.focusedPane = focusedPane
        self.maximizedPane = maximizedPane
        self.groups = groups
        self.connection = connection
        self.bookmarks = bookmarks
        self.layoutPresets = layoutPresets
        self.snippets = snippets
    }
}

// MARK: - LayoutPreset (a named saved canvas)

/// A named snapshot of a canvas LAYOUT — the panes (with their video bindings by app+title), groups,
/// and which pane was focused. Deliberately NOT the app connection (a layout is host-agnostic; the one
/// connection persists separately) and never recursive (no nested presets). Restoring it rebuilds every
/// session through the store's reconcile diff; a remote-window binding whose host window is gone
/// degrades to the picker, exactly like a normal restore.
public struct LayoutPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var canvas: Canvas
    public var groups: [PaneGroup]
    public var focusedPane: PaneID?
    /// When set, this layout AUTO-SWITCHES the moment a host window owned by this app first appears
    /// (case-insensitive match on the app name) — e.g. "monitoring" snaps in when you launch Grafana
    /// on the host. `nil` = no trigger (manual switch only).
    public var triggerAppName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        canvas: Canvas,
        groups: [PaneGroup],
        focusedPane: PaneID?,
        triggerAppName: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.groups = groups
        self.focusedPane = focusedPane
        self.triggerAppName = triggerAppName
    }
}

// MARK: - CanvasBookmark (a saved viewport jump)

/// One saved viewport bookmark: the FOCUSED PANE at save time plus the raw camera origin. Recall
/// prefers following the pane when it still exists (live panes relocate — a raw coordinate goes
/// stale the moment the pane is dragged); the camera origin is the fallback when the pane is gone.
/// `name` (the pane's title at save time) labels the menu items.
public struct CanvasBookmark: Codable, Sendable, Equatable {
    public var pane: PaneID?
    public var cameraOrigin: CGPoint
    public var name: String

    public init(pane: PaneID?, cameraOrigin: CGPoint, name: String) {
        self.pane = pane
        self.cameraOrigin = cameraOrigin
        self.name = name
    }
}

// MARK: - Schema + default

public extension Workspace {
    /// The schema version this build writes (the single-canvas + groups shape, docs/31). A
    /// higher/unrecognized version — or any older on-disk shape that no longer decodes — falls back to
    /// ``defaultWorkspace()``. Single-user project: there is no backward-compatibility path by design.
    /// 5 (2026-06-12): `VideoEndpoint` gained `appName` (pane rebind by app+title).
    /// 6 (2026-06-12): ``Workspace/bookmarks`` (viewport bookmarks, ⇧⌘n/⌘n).
    /// 7 (2026-06-13): ``Workspace/layoutPresets`` (named savable canvas layouts).
    /// 8 (2026-06-13): ``LayoutPreset/triggerAppName`` (auto-switch a layout on host app launch).
    /// 9 (2026-06-13): ``Workspace/snippets`` (saved command macros runnable from ⌘K).
    static let currentSchemaVersion = 9

    /// The fresh-launch / decode-failure fallback: one terminal pane at the origin, focused, ungrouped.
    static func defaultWorkspace() -> Workspace {
        let paneID = PaneID()
        let item = CanvasItem(
            id: paneID,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            frame: CGRect(origin: .zero, size: Canvas.defaultItemSize),
            z: 0,
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
            camera: canvas.camera,
        )
        return copy
    }

    /// Repairs the SIDE collections (groups / snippets / presets) against a corrupt or hand-edited file —
    /// the same defensive contract the canvas gets from ``dedupingItemIDs``. Applied on BOTH the on-disk
    /// load and a portable import: a duplicate ``PaneGroupID`` (two groups → one SwiftUI Identifiable id →
    /// undefined render results) drops to the first occurrence; every ``Snippet`` id is re-minted (snippet
    /// ids are referenced by nothing, and a duplicate id would collide the palette's id-keyed entries); a
    /// duplicate preset NAME (the layout palette entries are name-keyed) drops to the first. Pure.
    func normalizingCollections() -> Workspace {
        var copy = self
        var seenGroups = Set<PaneGroupID>()
        copy.groups = groups.filter { seenGroups.insert($0.id).inserted }
        // Re-mint ONLY a DUPLICATE snippet id (keep the first occurrence's id), so a clean file round-trips
        // verbatim — an unconditional re-mint made load() non-idempotent (every launch changed the ids).
        var seenSnippetIDs = Set<UUID>()
        copy.snippets = snippets
            .map { seenSnippetIDs.insert($0.id).inserted ? $0 : Snippet(name: $0.name, body: $0.body) }
        var seenPresetNames = Set<String>()
        copy.layoutPresets = layoutPresets.filter { seenPresetNames.insert($0.name).inserted }
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
