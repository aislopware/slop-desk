// TitlebarConnectionCluster — the titlebar's trailing connection-status cluster (the sidebar-footer
// status line, reseated as window chrome on the traffic-light row). One whisper-quiet line: a
// state-coloured dot + the host in muted text + the live telemetry ("9 ms · 30 fps") in tertiary
// monospaced digits — or, when not connected, the status word ("Connecting…", "Unreachable") plus a
// one-tap Retry in the give-up states. ALWAYS visible (not hover-gated like the pane controls): the
// connection is ambient window state, and it must stay readable while the sidebar is collapsed. The
// whole cluster taps through to the Connect-to-Host editor. Reads `connection.status` (an
// `@Observable`) so it stays live; ping/fps are resolved by the parent titlebar off the live store.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct TitlebarConnectionCluster: View {
    /// The app-global connection. Reading `connection.status` (an `@Observable`) in `body` registers
    /// observation, so the cluster stays live; no `$`-binding is needed (plain property, not `@Bindable`).
    let connection: AppConnection
    /// The smoothed RTT (ms) to show, or `nil` when unknown — the ACTIVE pane's per-channel `latencyMS`,
    /// falling back to any live pane's (every pane pings the SAME host), resolved by the titlebar.
    var pingMS: Double?
    /// The active VIDEO pane's host-announced stream cadence (frames/sec); `nil` for a terminal pane.
    var fps: Int?
    /// Opens the Connect-to-Host editor (pre-seeded with the current host/port).
    var onConnect: () -> Void = {}

    @State private var hover = false

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }
    private var isConnected: Bool { if case .connected = status { true } else { false } }

    /// The live telemetry segments — ping (when known) then fps (when a live video pane is focused).
    private var metrics: [String] {
        var out: [String] = []
        if let pingMS { out.append("\(Int(pingMS.rounded())) ms") }
        if let fps { out.append("\(fps) fps") }
        return out
    }

    /// The trailing summary: live metrics ("9 ms · 30 fps", tertiary mono) when connected, else the status
    /// word ("Connecting…", "Unreachable") — the dropped-"Connected" rule: a green dot + a ping already say
    /// it. `nil` ⇒ connected with no sample yet (dot + host alone read as connected).
    private var trailing: (text: String, isMetric: Bool)? {
        if isConnected {
            let m = metrics
            return m.isEmpty ? nil : (m.joined(separator: " · "), true)
        }
        return (StatusPresentation.connectionLabel(status), false)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onConnect) {
                HStack(spacing: 8) {
                    SlateStatusDot(
                        color: StatusPresentation.connectionColor(status),
                        glowKey: StatusPresentation.connectionLabel(status),
                    )
                    Text(host)
                        .font(.callout)
                        .foregroundStyle(hover ? Color.primary : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let trailing {
                        Text(trailing.text)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(trailing.isMetric ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                // The Xcode activity-pill bezel: a faint fill at rest (the cluster now sits CENTRED in the
                // titlebar, so it needs a resting shape, not just a hover wash), a touch stronger on hover.
                .background(
                    hover ? Color.primary.opacity(0.1) : Color.primary.opacity(0.045),
                    in: .rect(cornerRadius: 6),
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
            .help(StatusPresentation.connectionHelp(host: host, status: status))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))

            // Give-up state (failed / unreachable): a one-tap Retry beside the cluster — the fast re-dial
            // stays one click away while the cluster itself leads to the editor (host/port correction).
            if StatusPresentation.showsRetry(status) {
                Button { Task { await connection.retry() } } label: {
                    Image(systemSymbol: .arrowClockwise)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Retry connecting to \(host)")
                .accessibilityLabel("Retry connecting to \(host)")
            }
        }
    }
}
#endif
