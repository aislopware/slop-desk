import Foundation
import SlopDeskWorkspaceModel

// L0: extracted from the deleted SwiftUI `FloatingPaneHandle.swift`. `PanePresentation` is the
// pure `@MainActor` namespace of pane-header derivations (connection status / running / latency /
// display title / last-command summary) shared by the store + the (now-deleted) chrome. No SwiftUI
// usage; the rebuilt pane chrome (L3) will read these same helpers.
@MainActor
enum PanePresentation {
    /// The connection-status presentation (production handle only; a video / faked handle has
    /// no PATH-1 connection ⇒ `.none` ⇒ no dot).
    static func connectionStatus(_ handle: (any PaneSessionHandle)?) -> PaneConnectionStatus {
        PaneConnectionStatus.from((handle as? LivePaneSession)?.connection?.status)
    }

    /// Whether an OSC 133 command is currently executing in this pane's shell (the protocol-level
    /// ``PaneSessionHandle/isShellBusy`` — the same signal the store's busy-close guard consults).
    static func isRunning(_ handle: (any PaneSessionHandle)?) -> Bool {
        handle?.isShellBusy ?? false
    }

    /// The smoothed app-layer ping/pong RTT (`nil` until the first sample).
    static func latencyMS(_ handle: (any PaneSessionHandle)?) -> Double? {
        (handle as? LivePaneSession)?.connection?.latencyMS
    }

    /// The display title: the LIVE OSC 0/2 terminal title when the shell has set one, else the static
    /// `spec.title` (whitespace-only titles fall back so a pane is never blank).
    static func displayTitle(_ handle: (any PaneSessionHandle)?, spec: PaneSpec) -> String {
        let raw: String =
            if let live = (handle as? LivePaneSession)?.terminalModel?.title,
            !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                live
            } else {
                spec.title
            }
        // A remote shell controls the OSC title; mask any secret before it lands on the sidebar / pill /
        // bookmark name (the title flows to several persistent surfaces). Gated so it is an opt-out.
        return SettingsKey.redactSecretsEnabled ? SecretRedactor.redact(raw) : raw
    }
}
