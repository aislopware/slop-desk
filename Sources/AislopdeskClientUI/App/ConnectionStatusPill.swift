// ConnectionStatusPill — the unified-toolbar centre status pill (REBUILD-V2, L4a). A state-coloured dot +
// host name + status label, plus the current ping (ms) when connected. Reading `connection.status` (an
// @Observable) keeps it live as the supervisor flips connecting → connected → reconnecting. Tapping it
// runs the Retry path in a give-up state; otherwise it's the future connect-overlay affordance.
//
// SYSTEM colours/fonts only — no design-system.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct ConnectionStatusPill: View {
    @Bindable var connection: AppConnection
    /// The active pane's smoothed RTT (ms), or nil when unknown. Resolved by the parent from the active
    /// `LivePaneSession.connection?.latencyMS` (ping lives on the per-pane channel, not on AppConnection).
    var pingMS: Double?
    /// Opens the connect-host flow. Defaults to a no-op (no overlay exists yet — see the TODO at the call
    /// site); a give-up state runs Retry instead so the pill is never inert when there's something to do.
    var onTap: () -> Void = {}

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(StatusPresentation.connectionColor(status))
                    .frame(width: 7, height: 7)
                Text(host)
                    .font(.system(size: Otty.Typeface.base, weight: .medium))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                Text(StatusPresentation.connectionLabel(status))
                    .font(.system(size: Otty.Typeface.small + 1))
                    .foregroundStyle(Otty.Text.secondary)
                    .lineLimit(1)
                if case .connected = status, let pingMS {
                    Text("· \(Int(pingMS.rounded())) ms")
                        .font(.system(size: Otty.Typeface.small + 1).monospacedDigit())
                        .foregroundStyle(Otty.Text.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Otty.Surface.element, in: Capsule())
        .overlay(Capsule().strokeBorder(Otty.Line.subtle, lineWidth: 1))
        .help(StatusPresentation.connectionHelp(host: host, status: status))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))
    }

    private func tap() {
        if StatusPresentation.showsRetry(status) {
            Task { await connection.retry() }
        } else {
            onTap()
        }
    }
}
#endif
