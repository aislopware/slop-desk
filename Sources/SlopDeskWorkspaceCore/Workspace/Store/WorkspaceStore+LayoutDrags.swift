import CoreGraphics
import Foundation
import Network
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskNet
import SlopDeskTransport
import SlopDeskWorkspaceModel

// MARK: - Interactive layout drags (commit-on-release)

/// The interactive layout drags, whose whole shape is commit-on-release.
///
/// Split out of ``WorkspaceStore``'s own file rather than its body: the primary declaration already
/// factored two entry points into same-file extensions to stay inside `type_body_length`, and a file
/// that reaches 3 700 lines costs a reader the same way a type body does.
public extension WorkspaceStore {
    /// Swaps two leaves in the active tab — the commit for a drag-to-move: you grabbed `source`'s top handle
    /// and dropped it onto `target`. Both keep their `PaneID`, so reconcile is a registry no-op (no surface
    /// teardown) and only the solved geometry changes. ONE reconcile, fired from the gesture's `.onEnded`
    /// (the live drag is the view's overlay) so the keystroke / terminal-resize path stays quiet during the
    /// drag. No-op if the ids are equal or either is absent / they are in different tabs.
    func swapPanesTree(_ source: PaneID, _ target: PaneID) {
        guard source != target else { return }
        guard stage(.swapPanes, WorkspaceIntentArgs.encode(swap: source, with: target)) else { return }
        reconcileTree()
    }

    /// Relocates `source` to sit beside `target` along `axis`, on the BEFORE side when `before` (else after)
    /// — the commit for a drag-to-EDGE drop: you grabbed `source`'s top handle and dropped it on an edge of
    /// `target`, so it becomes a new row/column on that side (the directional re-split — this is also how a
    /// split is reoriented from side-by-side to stacked). `source` keeps its `PaneID`, so reconcile tears
    /// down nothing — only the solved geometry changes. ONE reconcile, fired from the gesture's `.onEnded`.
    /// No-op if the ids are equal / either is absent / they are in different tabs, or the relocation would
    /// not change the tree.
    func moveLeafTree(_ source: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) {
        guard source != target else { return }
        guard stage(.movePane, WorkspaceIntentArgs.encode(
            source: source, target: target, axis: axis, before: before,
        )) else { return }
        reconcileTree()
    }

    /// Docks `source` to the OUTERMOST `edge` of its tab — the commit for a drag-to-CONTAINER-edge drop: you
    /// dragged `source`'s handle into the container's outer gutter, so it becomes a full-span column
    /// (`.left`/`.right`) or row (`.top`/`.bottom`). `source` keeps its `PaneID`, so reconcile tears down
    /// nothing. ONE reconcile, fired from the gesture's `.onEnded`. No-op if `source` is absent, its tab has
    /// only one leaf, the dock would breach the depth ceiling, or it would not change the tree (already
    /// docked there).
    func moveLeafToRootEdgeTree(_ source: PaneID, edge: PaneDropEdge) {
        guard let tab = tree.tab(containing: source)?.1 else { return }
        guard stage(.dockPaneAtTabEdge, WorkspaceIntentArgs.encode(
            dock: source, tab: tab, edge: edge,
        )) else { return }
        reconcileTree()
    }

    /// Relocates `source` beside `target` — ACROSS tabs of the same session when needed. The commit for a
    /// rail-drag MOVE of an already-streamed window dropped on a pane's edge band (docs/45): the window's
    /// existing pane leaves its tab (a sole-leaf tab closes) and lands beside the pane under the cursor,
    /// KEEPING its `PaneID` so reconcile tears down nothing — the live stream survives the move. ONE
    /// reconcile on release. Same-tab drops keep `moveLeafTree`'s no-op rules; cross-session moves are
    /// no-ops (the pane's spec cannot leave its session's side table).
    func moveLeafAcrossTabsTree(_ source: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) {
        guard source != target else { return }
        guard stage(.movePane, WorkspaceIntentArgs.encode(
            source: source, target: target, axis: axis, before: before,
        )) else { return }
        reconcileTree()
    }

    /// Docks `source` at the ACTIVE tab's outermost `edge` — across tabs of the same session when needed.
    /// The commit for a rail-drag MOVE of an already-streamed window dropped in the container gutter
    /// (docs/45). KEEPS `PaneID` (no surface teardown); ONE reconcile on release; no-op when nothing
    /// would change (already docked there / sole pane of the active tab).
    func moveLeafToActiveTabRootEdgeTree(_ source: PaneID, edge: PaneDropEdge) {
        guard let tab = activeTreeTab else { return }
        guard stage(.dockPaneAtTabEdge, WorkspaceIntentArgs.encode(
            dock: source, tab: tab, edge: edge,
        )) else { return }
        reconcileTree()
    }

    /// Brings pane `id` fully into view — the one-call "take me to this pane" the right rail's streamed
    /// rows and the rail-drag move commit share. A background-tab pane routes through ``selectTab(_:)``
    /// FIRST: `focusPaneTree` alone would also land on the right tab (`focusPane` repoints session + tab),
    /// but it skips `selectTab`'s badge auto-clear — and a tab the user was just taken to has been seen,
    /// the same rule a left-rail row click applies.
    func revealPaneTree(_ id: PaneID) {
        if let session = tree.activeSession,
           let index = session.tabIndex(containing: id),
           index != session.activeTabIndex
        {
            selectTab(index)
        }
        focusPaneTree(id)
    }

    /// Suspends/resumes host grid-resize delivery for EVERY live terminal pane — the shell raises this for
    /// the duration of a sidebar/inspector-divider drag. Dragging an AppKit `NSSplitView` divider
    /// live-resizes the content column every cell-step; for a remote terminal each forward is a host PTY
    /// reflow + a re-streamed redraw. Holding them and flushing the final grid ONCE on release keeps the
    /// content from re-rendering per drag step (the same commit-on-release rule as the pane divider). The
    /// non-terminal handles (`.desktop`) have no `terminalModel`, so they are skipped.
    func setTerminalResizeSuspended(_ suspended: Bool) {
        // The interactive-resize bracket for BOTH dividers (the pane divider's own begin/end —
        // `MacPaneDivider` / `PaneDividerView` — and the AppKit sidebar divider's drag-active/settle).
        // Drives the pane scrim's "drag in progress" hold so
        // a PAUSED drag keeps the overlay up (see ``isInteractiveResizeActive``).
        isInteractiveResizeActive = suspended
        for handle in allSessions {
            (handle as? LivePaneSession)?.terminalModel?.setResizeSuspended(suspended)
        }
    }

    /// LIVE pane-divider drag: set the leading child's ABSOLUTE flex weight (clamped) and re-solve the layout,
    /// WITHOUT reconciling the registry or persisting. A divider drag changes only weights, not the SET of
    /// panes, so each frame is a pure tree assign + a canvas re-layout (the panes resize live). The shell
    /// brackets the drag with ``setTerminalResizeSuspended(_:)`` — holding the host grid-resize send until
    /// release, the "update the layout live but defer the server event to drag-end" rule — and commits once on
    /// release via ``commitDividerResize()``.
    ///
    /// A PREVIEW, not an intent: one intent per drag frame would flood the channel and make every
    /// other client watch the drag. ``WorkspaceStore/tree`` overlays it onto the projection, and
    /// ``commitDividerResize()`` discards it the instant the single real intent is staged.
    func setDividerWeightLive(splitID: SplitNodeID, leadingChildIndex: Int, leadingWeight: Double) {
        setLiveDividerWeight((split: splitID, index: leadingChildIndex, weight: leadingWeight))
    }

    /// Commits a finished live divider drag: reconcile (housekeeping) + persist the settled ratio ONCE. The
    /// per-frame ``setDividerWeightLive(splitID:leadingChildIndex:leadingWeight:)`` skips this, so it runs a
    /// single time on release rather than every frame.
    func commitDividerResize() {
        // Read the CLAMPED weight off the preview rather than the raw drag number: the op is
        // sum-preserving, so what the user actually saw is what must travel.
        if let live = liveDividerWeight,
           let settled = Self.leadingWeight(splitID: live.split, index: live.index, in: tree)
        {
            setLiveDividerWeight(nil)
            stage(.setDividerWeight, WorkspaceIntentArgs.encode(
                split: live.split, leadingIndex: live.index, leadingWeight: settled,
            ))
        }
        reconcileTree()
    }

    /// Evens ONLY the double-clicked seam — the divider between children `leadingChildIndex` and
    /// `leadingChildIndex + 1` of split `splitID` resets to an equal pair share (sum-preserving), while
    /// every OTHER divider's dragged ratio survives. The `PaneDivider` double-click target; the whole-tab
    /// even reset stays on ``balanceActivePaneSplits()`` (the ⌃⌘= chord). The leaf set is unchanged, so
    /// reconcile is a registry no-op.
    func evenDividerTree(splitID: SplitNodeID, leadingChildIndex: Int) {
        let next = WorkspaceTreeOps.evenDivider(splitID: splitID, leadingChildIndex: leadingChildIndex, in: tree)
        guard let weight = Self.leadingWeight(splitID: splitID, index: leadingChildIndex, in: next) else { return }
        guard stage(.setDividerWeight, WorkspaceIntentArgs.encode(
            split: splitID, leadingIndex: leadingChildIndex, leadingWeight: weight,
        )) else { return }
        reconcileTree()
    }

    /// The bounds the tree's geometric ops (directional focus / move-pane) solve the active tab into:
    /// the union of the frames the view last reported via ``updateSolvedLayout(_:)`` (the exact geometry
    /// the user sees), else the reported container bounds (``updateContainerBounds(_:)``), else a nominal
    /// desktop rect — a directional neighbour is scale-invariant on the tiled tree (cf.
    /// `FocusResolver.neighbor(of:_:in:)`, which reads solved frames), so a chord fired
    /// before the first layout report still resolves correctly instead of dying.
    var treeGeometryBounds: CGRect {
        if let solved = lastSolvedLayout, !solved.frames.isEmpty {
            var bounds = CGRect.null
            for rect in solved.frames.values { bounds = bounds.union(rect) }
            if !bounds.isNull, bounds.width > 0, bounds.height > 0 { return bounds }
        }
        if let reported = lastContainerBounds, reported.width > 0, reported.height > 0 {
            return reported
        }
        return CGRect(x: 0, y: 0, width: 1280, height: 800)
    }
}
