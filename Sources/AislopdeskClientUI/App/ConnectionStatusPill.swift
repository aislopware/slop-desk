// ConnectionStatusPill — the unified-toolbar centre status pill (REBUILD-V2, L4a). A state-coloured dot +
// host name + status label, plus the current ping (ms) when connected. Reading `connection.status` (an
// @Observable) keeps it live as the supervisor flips connecting → connected → reconnecting.
//
// TAP (ES-E2-6): tapping the pill ALWAYS opens the Connect-to-Host editor (`onTap` → `overlay.openConnect`),
// pre-seeded with the current (possibly failing) host/port — never a silent re-dial. In a give-up state
// (failed / unreachable) a SECONDARY "Retry" affordance sits beside the pill so the one-tap re-dial is still
// one tap away, but the primary surface is the editor where the host/port can be corrected.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
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
        HStack(spacing: 6) {
            pill
            // Give-up state (failed / unreachable): the pill opened the editor; offer Retry as a SECONDARY
            // one-tap re-dial beside it so the fast path stays reachable without hijacking the pill.
            if StatusPresentation.showsRetry(status) {
                retryButton
            }
        }
    }

    /// The status pill itself. Tapping it ALWAYS opens the Connect-to-Host editor (`onTap`), pre-seeded with
    /// the current host/port — never a silent re-dial.
    private var pill: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                SlateStatusDot(
                    color: StatusPresentation.connectionColor(status),
                    glowKey: StatusPresentation.connectionLabel(status),
                )
                Text(host)
                    .font(.system(size: Slate.Typeface.base, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                Text(StatusPresentation.connectionLabel(status))
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
                if case .connected = status, let pingMS {
                    Text("· \(Int(pingMS.rounded())) ms")
                        .font(.system(size: Slate.Typeface.footnote).monospacedDigit())
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Slate.Surface.element, in: Capsule())
        .overlay(Capsule().strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline))
        .help(StatusPresentation.connectionHelp(host: host, status: status))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))
    }

    /// The secondary Retry affordance, shown only in a give-up state — the one-tap re-dial the pill no longer
    /// performs (so the pill can lead to the editor instead).
    private var retryButton: some View {
        Button {
            Task { await connection.retry() }
        } label: {
            Image(systemSymbol: .arrowClockwise)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Slate.Surface.element, in: Capsule())
        .overlay(Capsule().strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline))
        .help("Retry connecting to \(host)")
        .accessibilityLabel("Retry connecting to \(host)")
    }
}
#endif
