import Foundation

// L0: extracted from the deleted SwiftUI `FloatingPaneHandle.swift`. `PanePresentation` is the
// pure `@MainActor` namespace of pane-header derivations (connection status / running / latency /
// display title / last-command summary) shared by the store + the (now-deleted) chrome. No SwiftUI
// usage; the rebuilt pane chrome (L3) will read these same helpers.
@MainActor
enum PanePresentation {
    /// The connection-status presentation (production handle only; a `.remoteGUI` / faked handle has
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

    /// A one-line summary of the most recently FINISHED command (OSC 133;D) on this pane — exit status
    /// + duration — or `nil` when none has run. `lastCommand` was captured but never surfaced; this is
    /// the formatter the pill tooltip uses so "did my last command pass, and how long?" is answerable.
    static func lastCommandSummary(_ handle: (any PaneSessionHandle)?) -> String? {
        guard let lc = (handle as? LivePaneSession)?.terminalModel?.lastCommand else { return nil }
        return formatCommandResult(exitCode: lc.exitCode, durationMS: lc.durationMS)
    }

    /// Pure formatter for an OSC-133 command result: a green-check / cross prefix by exit status, plus a
    /// human duration ("340ms" / "1.2s" / "2m 3s"). Exposed (and tested) independently of any handle.
    static func formatCommandResult(exitCode: Int32?, durationMS: UInt32) -> String {
        let ms = Int(durationMS)
        let duration: String
        if ms < 1000 {
            duration = "\(ms)ms"
        } else if ms < 60000 {
            duration = String(format: "%.1fs", Double(ms) / 1000)
        } else {
            let totalSeconds = ms / 1000
            duration = "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        guard let code = exitCode else { return duration } // host reported no exit code
        return code == 0 ? "✓ \(duration)" : "✗ exit \(code) · \(duration)"
    }

    /// WB2: the pane's LATEST Warp-style command block (the current/last command), or `nil` when none has
    /// run / the pane has no terminal. Drives the chrome status chip. Reading the `@Observable` block model
    /// re-renders the chip as the latest block's status changes (running → exit badge).
    static func latestBlock(_ handle: (any PaneSessionHandle)?) -> CommandBlock? {
        (handle as? LivePaneSession)?.terminalModel?.blocks.latest
    }

    /// WB2: opens the Command Navigator over `handle`'s pane (the chrome chip's tap action) — routes to the
    /// terminal model's ``TerminalViewModel/onRequestBlockNavigator`` (set by ``TerminalScreenView``). A
    /// no-op for a non-terminal pane / an empty shell / before the view appeared.
    static func openBlockNavigator(_ handle: (any PaneSessionHandle)?) {
        (handle as? LivePaneSession)?.terminalModel?.onRequestBlockNavigator?()
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
