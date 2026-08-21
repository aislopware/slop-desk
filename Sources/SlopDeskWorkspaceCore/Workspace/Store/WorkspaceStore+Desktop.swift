// WorkspaceStore+Desktop — the tree-path entry point for the FULL-DESKTOP (PATH 2 video) pane plus
// the video-pane verbs the palette/chords route through the active pane's session handle. The
// whole-display stream is the ONLY remote-viewing mode (docs/DECISIONS.md 2026-07-22 — the
// per-window remote-window kind is removed).

import Foundation
import SlopDeskWorkspaceModel

public extension WorkspaceStore {
    /// Opens the REMOTE DESKTOP WINDOW (⌥⌘N / palette): a `.desktop` pane streaming the host's whole
    /// display (`displayID`, `0` = main), born DIRECTLY into ``TreeWorkspace``'s detached set — the
    /// desktop is ALWAYS its own OS window, never a pane or tab in the workspace window
    /// (docs/DECISIONS.md 2026-07-22). Reveal-dedupe is PER DISPLAY: a second ⌥⌘N on the same display
    /// raises the existing window (``revealSatelliteWindow``); a different display mints a sibling
    /// window. Returns the pane id.
    @discardableResult
    func openDesktopWindow(displayID: UInt32 = 0) -> PaneID {
        if let existing = detachedDesktopPane(displayID: displayID) {
            _ = revealSatelliteWindow?(existing)
            return existing
        }
        let spec = Self.desktopSpec(displayID: displayID)
        let id = PaneID()
        guard stage(.spawnDetachedPane, WorkspaceIntentArgs.encode(
            detachedPane: id, kind: spec.kind, video: spec.video,
        )) else { return id }
        reconcileTree()
        return id
    }

    /// Where display `displayID` is already streaming: the detached `.desktop` pane bound to it in
    /// the ACTIVE session, else nil. The ONE "is it already open?" rule the desktop ingress uses —
    /// a desktop window that exists is revealed, never duplicated (a second live stream of the same
    /// display would double the decode + bandwidth for nothing).
    func detachedDesktopPane(displayID: UInt32) -> PaneID? {
        guard let session = tree.activeSession else { return nil }
        return session.detached.map(\.pane).first { id in
            guard let spec = session.specs[id], spec.kind == .desktop else { return false }
            // STRICT optional compare: a WINDOW-shaped endpoint (displayID nil — the automation
            // seam) is never a display match, so ⌥⌘N on display 0 mints a real display stream
            // instead of revealing the automation pane. Every ⌥⌘N mint sets displayID (desktopSpec).
            return spec.video?.displayID == displayID
        }
    }

    /// The ONE `.desktop` spec shape: the endpoint carries the display target (windowID 0 unused).
    internal static func desktopSpec(displayID: UInt32 = 0) -> PaneSpec {
        PaneSpec(
            kind: .desktop,
            title: TreeWorkspaceDefaults.desktopPaneTitle,
            video: VideoEndpoint(
                windowID: 0, title: TreeWorkspaceDefaults.desktopPaneTitle, displayID: displayID,
            ),
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

    /// FIT VIEWPORT TO PANE (the palette `view.fitViewportToPane`): the discoverability twin of the
    /// footer [fit] button — shrink/grow the ACTIVE remote-GUI pane's whole window to be fully visible
    /// inside the pane. Routed through the ``PaneSessionHandle`` seam, so it is a graceful no-op for a
    /// terminal / empty / not-streaming / locked active pane (never a dead chord).
    func fitViewportToPaneInActivePane() {
        guard let id = activePaneID else { return }
        handle(for: id)?.fitViewportToPane()
    }

    /// ACTUAL SIZE (the palette `view.resetViewportZoom`): the discoverability twin of the footer [1×]
    /// button — reset the ACTIVE remote-GUI pane's zoom to 1× and re-anchor top-left. Same no-op family
    /// as ``fitViewportToPaneInActivePane()``.
    func resetViewportZoomInActivePane() {
        guard let id = activePaneID else { return }
        handle(for: id)?.resetViewportZoom()
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
