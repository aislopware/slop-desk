// WorkspaceStore+RemoteWindow — the LIVE tree-path entry point for opening a remote-GUI (PATH 2 video)
// pane PRE-BOUND to a host window (the Remote-Window picker / `/remote-control` pill / "New Remote
// Window Tab" action). The canvas-era counterpart is ``WorkspaceStore/addRemoteWindowPane(windowID:title:
// appName:)``; this one reshapes the TREE so it works under the IDE shell.

import Foundation

public extension WorkspaceStore {
    /// Opens a NEW `.remoteGUI` tab PRE-BOUND to host window `windowID` on the LIVE tree shell — the
    /// tree-path counterpart of the canvas-era ``addRemoteWindowPane(windowID:title:appName:)``. The spec
    /// carries the ``VideoEndpoint`` so the materialized ``RemoteWindowModel`` opens immediately (admission
    /// still flows through ``liveVideoCap`` at activation — a saturated cap shows the gated placeholder).
    /// Selected + focused like ``newTab(kind:)``. Returns the new pane id.
    @discardableResult
    func newRemoteWindowTab(windowID: UInt32, title: String, appName: String) -> PaneID {
        let (next, id) = WorkspaceTreeOps.newTab(
            in: tree, spec: Self.remoteWindowSpec(windowID: windowID, title: title, appName: appName),
        )
        tree = next
        reconcileTree()
        return id
    }

    /// Splits the ACTIVE pane along `axis`, inserting a `.remoteGUI` leaf PRE-BOUND to host window
    /// `windowID` (docs/45 Phase 5 — the rail's "Open in Split" context verbs). The split-with-spec
    /// sibling of ``newRemoteWindowTab(windowID:title:appName:)``: same endpoint persistence + cap
    /// gating; the new leaf lands focused. Falls back to a NEW TAB when no pane is active (an empty
    /// workspace has nothing to split — never a dead verb). Returns the new pane id.
    @discardableResult
    func newRemoteWindowSplit(
        windowID: UInt32, title: String, appName: String, axis: SplitAxis,
    ) -> PaneID {
        guard let active = tree.activeSession?.activeTab?.activePane else {
            return newRemoteWindowTab(windowID: windowID, title: title, appName: appName)
        }
        return newRemoteWindowSplit(
            windowID: windowID, title: title, appName: appName,
            beside: active, axis: axis, before: false,
        )
    }

    /// Splits a SPECIFIC `target` pane along `axis`, inserting a `.remoteGUI` leaf PRE-BOUND to host
    /// window `windowID` on the `before` side — the rail-DRAG drop commit (docs/45: the drop
    /// names the pane under the cursor + the edge; the context-verb overload above always splits the
    /// ACTIVE pane, trailing). Same endpoint persistence + cap gating; the new leaf lands focused.
    /// A vanished `target` (closed mid-drag) makes the underlying op a no-op. Returns the new pane id.
    @discardableResult
    func newRemoteWindowSplit(
        windowID: UInt32, title: String, appName: String,
        beside target: PaneID, axis: SplitAxis, before: Bool,
    ) -> PaneID {
        let (next, id) = WorkspaceTreeOps.splitPane(
            target, axis: axis,
            newSpec: Self.remoteWindowSpec(windowID: windowID, title: title, appName: appName),
            before: before, in: tree,
        )
        tree = next
        reconcileTree()
        return id
    }

    /// Docks a NEW `.remoteGUI` pane PRE-BOUND to host window `windowID` at the ACTIVE tab's outermost
    /// `edge` — the rail-DRAG container-gutter drop commit (docs/45): the window opens as a
    /// full-span column/row on that whole edge. Same endpoint persistence + cap gating as the tab
    /// path; the new leaf lands focused. Returns the new pane id.
    @discardableResult
    func newRemoteWindowAtRootEdge(
        windowID: UInt32, title: String, appName: String, edge: PaneDropEdge,
    ) -> PaneID {
        let (next, id) = WorkspaceTreeOps.insertPaneAtRootEdge(
            spec: Self.remoteWindowSpec(windowID: windowID, title: title, appName: appName),
            edge: edge, in: tree,
        )
        tree = next
        reconcileTree()
        return id
    }

    /// The ONE `.remoteGUI` spec shape every remote-window ingress mints: label falls back
    /// title → appName → "Remote window"; the ``VideoEndpoint`` carries the rebind identity.
    private static func remoteWindowSpec(windowID: UInt32, title: String, appName: String) -> PaneSpec {
        let label = title.isEmpty ? (appName.isEmpty ? "Remote window" : appName) : title
        return PaneSpec(
            kind: .remoteGUI,
            title: label,
            video: VideoEndpoint(windowID: windowID, title: label, appName: appName),
        )
    }

    /// RELEASE STUCK INPUT (the palette's `view.releaseStuckInput`): fire the ACTIVE pane's
    /// synthetic-release escape hatch — a key-up for every held modifier + a mouse-up for every button
    /// through the remote-GUI pane's existing release send paths — for when the host is left holding
    /// input (a latched ⌘/⇧/button) despite the automatic redundancy+dedup. Routed through the
    /// ``PaneSessionHandle`` seam, so it is a graceful no-op for a terminal / empty / read-only /
    /// not-streaming active pane (never a dead command).
    func releaseStuckInputInActivePane() {
        guard let id = activePaneID else { return }
        handle(for: id)?.releaseStuckInput()
    }

    /// PASTE AS KEYSTROKES (the ⌥⌘V chord + the pane context menu): type the CURRENT local clipboard
    /// into the ACTIVE remote-GUI pane's host window as paced per-key `CGEvent`s. Reads the live clipboard
    /// through ``currentLocalClipboard()`` (works even when clipboard-history recording is off), then routes
    /// to the active pane's handle — a graceful no-op for a terminal / empty / read-only / not-streaming
    /// active pane, and when the clipboard is empty (never a dead command). The terminal keeps its own paste.
    func pasteAsKeystrokesInActivePane() {
        guard let text = currentLocalClipboard(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pasteAsKeystrokesInActivePane(text)
    }

    /// PASTE AS KEYSTROKES: type an EXPLICIT `text` (a chosen "Clipboard Ring" entry) into the ACTIVE
    /// remote-GUI pane's host window. Routed through the ``PaneSessionHandle`` seam, so it is a graceful
    /// no-op for a terminal / empty / read-only / not-streaming active pane.
    func pasteAsKeystrokesInActivePane(_ text: String) {
        guard let id = activePaneID else { return }
        handle(for: id)?.pasteAsKeystrokes(text)
    }
}
