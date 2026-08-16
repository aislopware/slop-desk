// TreeIntentFixtures — the shape-building tree ops, spelled the way production spells them.
//
// Detach, reattach, close, split, spawn, zoom, swap and the session/tab verbs are INTENTS: the
// client asks and `slopdesk_wire::document::apply`, behind the FFI door, decides. Their Swift twins
// were deleted on 2026-08-17 along with the rest of the applier, so a fixture that used to call one
// calls the same op the gesture that produced it would send.
//
// The signatures mirror the ops they replace — including the no-op contract. A refused intent hands
// the workspace back UNCHANGED and says nothing, because "an absent id no-ops" is a case several of
// these tests assert directly; failing here would turn a pinned behaviour into a fixture error.

import Foundation
import SlopDeskWorkspaceModel

enum TreeIntent {
    // MARK: The door

    /// `nil` is a REFUSAL, which is what lets a two-intent gesture short-circuit the way
    /// `WorkspaceStore` does — it stages the second op only behind `guard stage(first) else`.
    static func staged(_ op: WorkspaceIntentOp, _ args: Data, _ ws: TreeWorkspace) -> TreeWorkspace? {
        WorkspaceIntentApplier.apply(
            op: op.rawValue, args: args, to: WorkspaceTopology(tree: ws), documentIsPristine: true,
        ).topology?.tree
    }

    static func applied(_ op: WorkspaceIntentOp, _ args: Data, _ ws: TreeWorkspace) -> TreeWorkspace {
        staged(op, args, ws) ?? ws
    }

    /// The same door, for the fixtures whose subject lives OUTSIDE the tree — the closed-tab ring,
    /// the sync-input set, the focus MRU.
    static func applied(
        _ op: WorkspaceIntentOp, _ args: Data, _ topology: WorkspaceTopology,
    ) -> WorkspaceTopology {
        WorkspaceIntentApplier.apply(
            op: op.rawValue, args: args, to: topology, documentIsPristine: true,
        ).topology ?? topology
    }

    static func closeTab(_ tab: TabID, in topology: WorkspaceTopology) -> WorkspaceTopology {
        applied(.closeTab, WorkspaceIntentArgs.encode(tab: tab), topology)
    }

    /// `lifoIndex` counts from the NEWEST closed tab — `0` is the one a ⇧⌘T would bring back.
    static func reopenClosedTab(
        _ lifoIndex: Int, at position: NewTabPosition, in topology: WorkspaceTopology,
    ) -> WorkspaceTopology {
        applied(
            .reopenClosedTab,
            WorkspaceIntentArgs.encode(reopenLIFOIndex: lifoIndex, position: position),
            topology,
        )
    }

    /// Writes a minted pane's fixture spec. Every op gives a new pane a plain terminal, and the TITLE
    /// is what these fixtures name their panes by — so it is written here rather than asked for,
    /// because a `renamePane` would also set the authored bit and change the subject.
    static func titling(_ ws: TreeWorkspace, _ pane: PaneID, _ spec: PaneSpec) -> TreeWorkspace {
        guard let index = ws.sessions.firstIndex(where: { $0.specs[pane] != nil }) else { return ws }
        var copy = ws
        copy.sessions[index].specs[pane] = spec
        return copy
    }

    // MARK: Panes

    static func splitPane(
        _ target: PaneID,
        axis: SplitAxis,
        newSpec: PaneSpec,
        before: Bool = false,
        id: PaneID = PaneID(),
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, PaneID) {
        let next = applied(
            .splitPane,
            WorkspaceIntentArgs.encode(
                target: target.raw, axis: axis, before: before, newPane: id, spawnCwd: nil,
            ),
            ws,
        )
        return (titling(next, id, newSpec), id)
    }

    static func closePane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.closePane, WorkspaceIntentArgs.encode(pane: target), ws)
    }

    static func swapPanes(_ a: PaneID, _ b: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.swapPanes, WorkspaceIntentArgs.encode(swap: a, with: b), ws)
    }

    static func toggleZoom(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        let zoomed = ws.activeSession?.activeTab?.zoomedPane == target
        return applied(.setZoom, WorkspaceIntentArgs.encode(id: target.raw, flag: !zoomed), ws)
    }

    static func setZoom(_ target: PaneID, _ zoomed: Bool, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.setZoom, WorkspaceIntentArgs.encode(id: target.raw, flag: zoomed), ws)
    }

    static func breakPaneToTab(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.breakPaneToTab, WorkspaceIntentArgs.encode(pane: target), ws)
    }

    static func cyclePaneFocus(forward: Bool, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let target = WorkspaceTreeOps.cyclePaneTarget(forward: forward, in: ws) else { return ws }
        return applied(.focusPane, WorkspaceIntentArgs.encode(pane: target), ws)
    }

    // MARK: The satellite window

    static func detachPane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.detachPane, WorkspaceIntentArgs.encode(pane: target), ws)
    }

    static func reattachPane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.reattachPane, WorkspaceIntentArgs.encode(pane: target), ws)
    }

    /// Drag-to-merge onto a tree pane's edge band. TWO intents, exactly as `WorkspaceStore`
    /// stages them: `reattachPane` names only the pane — where a returning pane LANDS is the tree's
    /// own rule — and the placement is then the op that already means "put this beside that".
    static func reattachPane(
        _ target: PaneID,
        beside anchor: PaneID,
        axis: SplitAxis,
        before: Bool,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let docked = staged(.reattachPane, WorkspaceIntentArgs.encode(pane: target), ws) else {
            return ws
        }
        return applied(
            .movePane,
            WorkspaceIntentArgs.encode(source: target, target: anchor, axis: axis, before: before),
            docked,
        )
    }

    /// The drag-to-merge gutter drop on the main canvas.
    static func reattachPane(
        _ target: PaneID,
        toActiveTabRootEdge edge: PaneDropEdge,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let docked = staged(.reattachPane, WorkspaceIntentArgs.encode(pane: target), ws),
              let tab = docked.activeSession?.activeTab?.id
        else { return ws }
        return applied(
            .dockPaneAtTabEdge, WorkspaceIntentArgs.encode(dock: target, tab: tab, edge: edge), docked,
        )
    }

    /// The drag-to-merge "New Tab" drop. A reattach that already landed in a fresh tab leaves nothing
    /// to break out of, and the op refuses a lone leaf — so the second intent is the "it went home to
    /// a shared tab" case.
    static func reattachPaneToNewTab(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let docked = staged(.reattachPane, WorkspaceIntentArgs.encode(pane: target), ws) else {
            return ws
        }
        return breakPaneToTab(target, in: docked)
    }

    static func closeDetachedPane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.closePane, WorkspaceIntentArgs.encode(pane: target), ws)
    }

    static func mintDetachedPane(
        spec: PaneSpec,
        id: PaneID = PaneID(),
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, PaneID) {
        let next = applied(
            .spawnDetachedPane,
            WorkspaceIntentArgs.encode(detachedPane: id, kind: spec.kind, video: spec.video),
            ws,
        )
        return (next, id)
    }

    // MARK: Tabs and sessions

    static func newTab(
        in ws: TreeWorkspace,
        spec: PaneSpec,
        at position: NewTabPosition = .end,
        id: PaneID = PaneID(),
    ) -> (TreeWorkspace, PaneID) {
        guard let session = ws.activeSessionID else { return (ws, id) }
        let next = applied(
            .spawnTab,
            WorkspaceIntentArgs.encode(session: session, newPane: id, position: position, spawnCwd: nil),
            ws,
        )
        return (titling(next, id, spec), id)
    }

    /// `selectTab(index)` named the active session's tab by ORDINAL; the intent names it by identity,
    /// which is the only thing that survives a reorder. Out of range stays a no-op.
    static func selectTab(_ index: Int, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let tabs = ws.activeSession?.tabs, tabs.indices.contains(index) else { return ws }
        return applied(.focusTab, WorkspaceIntentArgs.encode(tab: tabs[index].id), ws)
    }

    static func newSession(
        in ws: TreeWorkspace,
        name: String,
        spec: PaneSpec,
        id: PaneID = PaneID(),
    ) -> (TreeWorkspace, PaneID) {
        let next = applied(
            .newSession,
            WorkspaceIntentArgs.encode(newSession: SessionID(), newPane: id, name: name, spawnCwd: nil),
            ws,
        )
        return (titling(next, id, spec), id)
    }

    static func closeSession(_ sessionID: SessionID, in ws: TreeWorkspace) -> TreeWorkspace {
        applied(.closeSession, WorkspaceIntentArgs.encode(session: sessionID), ws)
    }
}
