// WorkspaceStore+RemoteWindow — the LIVE tree-path entry point for opening a remote-GUI (PATH 2 video)
// pane PRE-BOUND to a host window (the L6 Remote-Window picker / `/remote-control` pill / "New Remote
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
        let label = title.isEmpty ? (appName.isEmpty ? "Remote window" : appName) : title
        let spec = PaneSpec(
            kind: .remoteGUI,
            title: label,
            video: VideoEndpoint(windowID: windowID, title: label, appName: appName),
        )
        let (next, id) = WorkspaceTreeOps.newTab(in: tree, spec: spec)
        tree = next
        reconcileTree()
        return id
    }

    /// RELEASE STUCK INPUT (C5, the palette's `view.releaseStuckInput`): fire the ACTIVE pane's
    /// synthetic-release escape hatch — a key-up for every held modifier + a mouse-up for every button
    /// through the remote-GUI pane's existing release send paths — for when the host is left holding
    /// input (a latched ⌘/⇧/button) despite the automatic redundancy+dedup. Routed through the
    /// ``PaneSessionHandle`` seam, so it is a graceful no-op for a terminal / empty / read-only /
    /// not-streaming active pane (never a dead command).
    func releaseStuckInputInActivePane() {
        guard let id = activePaneID else { return }
        handle(for: id)?.releaseStuckInput()
    }

    /// PASTE AS KEYSTROKES (C7, the ⌥⌘V chord + the pane context menu): type the CURRENT local clipboard
    /// into the ACTIVE remote-GUI pane's host window as paced per-key `CGEvent`s. Reads the live clipboard
    /// through ``currentLocalClipboard()`` (works even when clipboard-history recording is off), then routes
    /// to the active pane's handle — a graceful no-op for a terminal / empty / read-only / not-streaming
    /// active pane, and when the clipboard is empty (never a dead command). The terminal keeps its own paste.
    func pasteAsKeystrokesInActivePane() {
        guard let text = currentLocalClipboard(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pasteAsKeystrokesInActivePane(text)
    }

    /// PASTE AS KEYSTROKES (C7): type an EXPLICIT `text` (a chosen "Clipboard Ring" entry) into the ACTIVE
    /// remote-GUI pane's host window. Routed through the ``PaneSessionHandle`` seam, so it is a graceful
    /// no-op for a terminal / empty / read-only / not-streaming active pane.
    func pasteAsKeystrokesInActivePane(_ text: String) {
        guard let id = activePaneID else { return }
        handle(for: id)?.pasteAsKeystrokes(text)
    }
}
