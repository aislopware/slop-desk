// StatusPresentation — pure view-side mapping of connection + agent state to native SwiftUI presentation
// (REBUILD-V2, L4a). Recovers the connection-pill derivation (label / colour-role / dot) from the deleted
// `Chrome/TopBarConnectionPill.swift`, but maps the colour role straight to a SYSTEM semantic `Color` (no
// design-system token). Shared by the unified-toolbar status pill and the inspector's Session section so
// the copy + dot colour can't drift. The label copy itself comes from `ConnectionPresenter` (the one
// source of truth) — this only adds the view-layer colour + dot.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SwiftUI

enum StatusPresentation {
    // MARK: Connection

    /// The compact pill label (e.g. "connected", "reconnecting 3/20", "failed").
    static func connectionLabel(_ status: ConnectionStatus) -> String {
        ConnectionPresenter.shortLabel(for: status)
    }

    /// The status-dot colour — otty status palette (cohesive on the active theme).
    static func connectionColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected: Otty.Status.ok
        case .connecting,
             .reconnecting: Otty.Status.warn
        case .failed,
             .unreachable: Otty.Status.err
        case .disconnected: Otty.Text.secondary
        }
    }

    /// Whether a manual Retry affordance applies (only the give-up states).
    static func showsRetry(_ status: ConnectionStatus) -> Bool {
        switch status {
        case .failed,
             .unreachable: true
        default: false
        }
    }

    /// The hover/accessibility help: host + the actionable headline.
    static func connectionHelp(host: String, status: ConnectionStatus) -> String {
        "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
    }

    // MARK: Agent (Claude Code)

    /// SF Symbol for an agent status. `nil` ⇒ render nothing (no active agent).
    static func agentSymbol(_ status: ClaudeStatus) -> String? {
        switch status {
        case .none: nil
        case .idle: "circle.fill"
        case .working: "gearshape.fill"
        case .done: "checkmark.circle.fill"
        case .needsPermission: "exclamationmark.triangle.fill"
        }
    }

    /// otty-palette tint for an agent status (matches docs/42 glyph palette: idle🟢 working🟡 done🔵 needs🔴).
    static func agentTint(_ status: ClaudeStatus) -> Color {
        switch status {
        case .none: Otty.Text.secondary
        case .idle: Otty.Status.ok
        case .working: Otty.Status.warn
        case .done: Otty.Status.info
        case .needsPermission: Otty.Status.err
        }
    }

    /// The short agent label (the one source — `ClaudeStatus.displayLabel`).
    static func agentLabel(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }
}
#endif
