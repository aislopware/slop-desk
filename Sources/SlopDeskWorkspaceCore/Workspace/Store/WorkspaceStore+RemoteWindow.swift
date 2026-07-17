// WorkspaceStore+RemoteWindow — the tree-path entry point for opening a remote-GUI (PATH 2 video)
// pane PRE-BOUND to a host window. The full-desktop pivot (docs/DECISIONS.md 2026-07-14) makes this
// the SECONDARY viewing path (Open Quickly / palette Host rows); the primary is the whole-display
// desktop pane (`WorkspaceStore+Desktop`). Both are ordinary tree leaves — the Stage is retired.

import Foundation

/// One already-streaming host window's place in the workspace: the `.remoteGUI` pane mirroring it and
/// that pane's 1-based tab ordinal in the active session.
public struct StreamedWindowRef: Equatable, Sendable {
    public let paneID: PaneID
    public let tabOrdinal: Int

    public init(paneID: PaneID, tabOrdinal: Int) {
        self.paneID = paneID
        self.tabOrdinal = tabOrdinal
    }
}

public extension WorkspaceStore {
    /// Opens a NEW FULL-DESKTOP tab (⌥⌘N / palette): a `.desktop` pane streaming the host's whole
    /// display (`displayID`, `0` = main). Always mints — unlike windows, a second desktop pane is a
    /// legitimate ask (e.g. one per display), so there is no reveal-dedupe. Selected + focused like
    /// ``newTab(kind:)``. Returns the new pane id.
    @discardableResult
    func newDesktopTab(displayID: UInt32 = 0) -> PaneID {
        let (next, id) = WorkspaceTreeOps.newTab(in: tree, spec: Self.desktopSpec(displayID: displayID))
        tree = next
        reconcileTree()
        return id
    }

    /// The ONE `.desktop` spec shape: the endpoint carries the display target (windowID 0 unused).
    internal static func desktopSpec(displayID: UInt32 = 0) -> PaneSpec {
        PaneSpec(
            kind: .desktop,
            title: "Desktop",
            video: VideoEndpoint(windowID: 0, title: "Desktop", displayID: displayID),
        )
    }

    /// Opens host window `windowID` on the tree shell — the ONE remote-window ingress (Open Quickly,
    /// palette). A window already streaming in the active session is REVEALED (tab switch + focus),
    /// never duplicated; a fresh window opens as a new `.remoteGUI` tab. Returns the pane id, or `nil`
    /// with no active session.
    @discardableResult
    func openRemoteWindow(windowID: UInt32, title: String, appName: String) -> PaneID? {
        if let existing = streamedWindowPane(for: windowID) {
            focusPaneTree(existing.paneID)
            return existing.paneID
        }
        return newRemoteWindowTab(windowID: windowID, title: title, appName: appName)
    }

    /// Opens a NEW `.remoteGUI` tab PRE-BOUND to host window `windowID`. The spec carries the
    /// ``VideoEndpoint`` so the materialized ``RemoteWindowModel`` opens immediately (admission
    /// still flows through ``liveVideoCap`` at activation — a saturated cap shows the gated
    /// placeholder). Selected + focused like ``newTab(kind:)``. Returns the new pane id.
    @discardableResult
    func newRemoteWindowTab(windowID: UInt32, title: String, appName: String) -> PaneID {
        let (next, id) = WorkspaceTreeOps.newTab(
            in: tree, spec: Self.remoteWindowSpec(windowID: windowID, title: title, appName: appName),
        )
        tree = next
        reconcileTree()
        return id
    }

    /// Where host window `windowID` is already streaming: the pane + its 1-based tab ordinal in the
    /// ACTIVE session. The earliest tab wins for a window streamed twice. Reads `PaneSpec.video` — the
    /// binding `RemoteWindowModel` persists on every open/rebind, so the answer self-corrects through
    /// `WindowRebind` after a host restart. This is the ONE "is it already open?" rule every ingress
    /// shares (two resolutions would drift). Active-session-only ON PURPOSE: every consumer acts on
    /// the visible workspace.
    func streamedWindowPane(for windowID: UInt32) -> StreamedWindowRef? {
        guard let session = tree.activeSession else { return nil }
        for (index, tab) in session.tabs.enumerated() {
            for paneID in tab.allPaneIDs() {
                guard let spec = session.specs[paneID], spec.kind == .remoteGUI,
                      spec.video?.windowID == windowID else { continue }
                return StreamedWindowRef(paneID: paneID, tabOrdinal: index + 1)
            }
        }
        return nil
    }

    /// The ONE `.remoteGUI` spec shape every remote-window ingress mints: label falls back
    /// title → appName → "Remote window"; the ``VideoEndpoint`` carries the rebind identity.
    internal static func remoteWindowSpec(windowID: UInt32, title: String, appName: String) -> PaneSpec {
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

    /// LOCK VIEWPORT POSITION (the ⌥⌘L chord / palette `view.lockViewport`): toggle the ACTIVE remote-GUI
    /// pane's edge-hover auto-pan freeze — the viewport stays put as the pointer nudges the pane edges.
    /// A pure client compositor gate (never touches the host). Routed through the ``PaneSessionHandle``
    /// seam, so it is a graceful no-op for a terminal / empty / not-streaming active pane (never a dead
    /// chord).
    func toggleViewportLockInActivePane() {
        guard let id = activePaneID else { return }
        handle(for: id)?.toggleViewportLock()
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
