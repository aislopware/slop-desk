// TitlebarConnectionCluster — the titlebar's trailing connection-status cluster (the sidebar-footer
// status line, reseated as window chrome on the traffic-light row). One whisper-quiet line: the host's
// identity MONOGRAM (hash-hue plate; saturation = connection state) + the host in muted text + the live
// telemetry ("9 ms · 30 fps") in tertiary
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
        HStack(spacing: Slate.Metric.space1) {
            Button(action: onConnect) {
                HStack(spacing: Slate.Metric.space2) {
                    // The host-identity MONOGRAM (MERIDIAN C2): the plate's hash-hue is the host's
                    // permanent colour; its SATURATION is the connection state (connected = colour,
                    // else grayscale — L1 applied to identity). Replaces the status dot here — the
                    // plate is the one status pixel, the not-connected states keep their status WORD.
                    SlateMonogram(identity: host, live: isConnected)
                    Text(host)
                        .font(.system(size: Slate.Typeface.base))
                        .foregroundStyle(hover ? Slate.Text.primary : Slate.Text.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let trailing {
                        // The telemetry is a COMPLICATION (MERIDIAN L2): instrument voice for the numbers,
                        // prose voice for a status word. Its INSERTION rides the flood (below) with a small
                        // stagger after the dot's colour-in; its per-sample value ticks never animate.
                        Text(trailing.text)
                            .font(
                                trailing.isMetric
                                    ? Slate.Typeface.instrument(Slate.Typeface.footnote)
                                    : .system(size: Slate.Typeface.footnote),
                            )
                            .foregroundStyle(trailing.isMetric ? Slate.Text.tertiary : Slate.Text.secondary)
                            .lineLimit(1)
                            .transition(.opacity.animation(isConnected ? Slate.Anim.needle.delay(0.08) : nil))
                    }
                }
                .padding(.horizontal, Slate.Metric.space2)
                .frame(height: Slate.Metric.heightControl)
                .background(hover ? Slate.State.hover : .clear, in: .rect(cornerRadius: Slate.Metric.radiusControl))
                .contentShape(.rect)
                // THE FLOOD (MERIDIAN L4 — the one orchestrated moment): on handshake the colour flows IN —
                // the dot needles to green, then the metrics fade in 80ms behind it. Every OTHER transition
                // (connected → reconnecting/failed) is a HARD CUT: the ternary evaluates with the NEW value,
                // so only the entry into `.connected` animates.
                .animation(isConnected ? Slate.Anim.needle : nil, value: isConnected)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(Slate.Anim.smallFade, value: hover)
            .help(StatusPresentation.connectionHelp(host: host, status: status))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))

            // Give-up state (failed / unreachable): a one-tap Retry beside the cluster — the fast re-dial
            // stays one click away while the cluster itself leads to the editor (host/port correction).
            if StatusPresentation.showsRetry(status) {
                Button { Task { await connection.retry() } } label: {
                    Image(systemSymbol: .arrowClockwise)
                        .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                        .foregroundStyle(Slate.Text.secondary)
                        .frame(width: Slate.Metric.plate, height: Slate.Metric.plate)
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
