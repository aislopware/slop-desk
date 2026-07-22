// WorkspaceStore+Desktop — the tree-path entry point for the FULL-DESKTOP (PATH 2 video) pane plus
// the video-pane verbs the palette/chords route through the active pane's session handle. The
// whole-display stream is the ONLY remote-viewing mode (docs/DECISIONS.md 2026-07-22 — the
// per-window remote-window kind is removed).

import Foundation

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
