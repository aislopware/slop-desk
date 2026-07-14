// WorkspaceStore+RemoteWindow — the shared remote-window (PATH 2 video) pieces every ingress uses.
// The Stage re-scope: streamed windows open in the STAGE (`WorkspaceStore+Stage`'s
// `openWindowInStage`), never in the split tree — the tree-path tab/split/root-edge mints are gone
// with it. What remains here: the one `.remoteGUI` spec shape, the streamed-window reference type, and
// the active-pane input escape hatches (stage-aware).

import Foundation

/// One already-streaming host window's place in the workspace: the `.remoteGUI` pane mirroring it and
/// that pane's 1-based STAGE tab-strip ordinal (the right rail's accent marker).
public struct StreamedWindowRef: Equatable, Sendable {
    public let paneID: PaneID
    public let tabOrdinal: Int

    public init(paneID: PaneID, tabOrdinal: Int) {
        self.paneID = paneID
        self.tabOrdinal = tabOrdinal
    }
}

public extension WorkspaceStore {
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

    /// The pane the remote-GUI input escape hatches target: the ACTIVE STAGE tab while input
    /// ownership sits in the Stage (``stageFocused``), else the canvas's active pane. Keeps ⌥⌘V /
    /// release-stuck-input meaningful for a streamed window that is not (and cannot be) the tree's
    /// focused pane under the hard split.
    internal var inputTargetPaneID: PaneID? {
        if stageFocused, let staged = tree.activeSession?.activeStagePane { return staged }
        return activePaneID
    }

    /// RELEASE STUCK INPUT (the palette's `view.releaseStuckInput`): fire the ACTIVE pane's
    /// synthetic-release escape hatch — a key-up for every held modifier + a mouse-up for every button
    /// through the remote-GUI pane's existing release send paths — for when the host is left holding
    /// input (a latched ⌘/⇧/button) despite the automatic redundancy+dedup. Routed through the
    /// ``PaneSessionHandle`` seam, so it is a graceful no-op for a terminal / empty / read-only /
    /// not-streaming active pane (never a dead command). Stage-aware: while the stage holds input
    /// ownership the verb targets the active stage tab.
    func releaseStuckInputInActivePane() {
        guard let id = inputTargetPaneID else { return }
        handle(for: id)?.releaseStuckInput()
    }

    /// PASTE AS KEYSTROKES (the ⌥⌘V chord + the pane context menu): type the CURRENT local clipboard
    /// into the ACTIVE remote-GUI pane's host window as paced per-key `CGEvent`s. Reads the live clipboard
    /// through ``currentLocalClipboard()`` (works even when clipboard-history recording is off), then routes
    /// to the target pane's handle — a graceful no-op for a terminal / empty / read-only / not-streaming
    /// pane, and when the clipboard is empty (never a dead command). The terminal keeps its own paste.
    func pasteAsKeystrokesInActivePane() {
        guard let text = currentLocalClipboard(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pasteAsKeystrokesInActivePane(text)
    }

    /// PASTE AS KEYSTROKES: type an EXPLICIT `text` (a chosen "Clipboard Ring" entry) into the ACTIVE
    /// remote-GUI pane's host window. Routed through the ``PaneSessionHandle`` seam, so it is a graceful
    /// no-op for a terminal / empty / read-only / not-streaming pane. Stage-aware like
    /// ``releaseStuckInputInActivePane()``.
    func pasteAsKeystrokesInActivePane(_ text: String) {
        guard let id = inputTargetPaneID else { return }
        handle(for: id)?.pasteAsKeystrokes(text)
    }
}
