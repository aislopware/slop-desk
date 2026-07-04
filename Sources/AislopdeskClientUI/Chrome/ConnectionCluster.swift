// ConnectionCluster — the connection-status cluster. Resting home: the SIDEBAR TOP (full-width row);
// the titlebar hosts it only while the sidebar is collapsed. One whisper-quiet line: the host's
// identity MONOGRAM whose plate colour IS the network health at a glance (gray offline · green good ·
// yellow slow · red bad — classified from the live ping) + the live telemetry ("9 ms · 30 fps") in
// tertiary monospaced digits — or, when not connected, the status word ("Connecting…", "Unreachable")
// plus a one-tap Retry in the give-up states. The whole cluster taps through to the Connect-to-Host
// editor. Reads `connection.status` (an `@Observable`) so it stays live; ping/fps/kbps are resolved by
// the mount off the live store (`ConnectionTelemetry`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct ConnectionCluster: View {
    /// The app-global connection. Reading `connection.status` (an `@Observable`) in `body` registers
    /// observation, so the cluster stays live; no `$`-binding is needed (plain property, not `@Bindable`).
    let connection: AppConnection
    /// The smoothed RTT (ms) to show, or `nil` when unknown — the ACTIVE pane's per-channel `latencyMS`,
    /// falling back to any live pane's (every pane pings the SAME host), resolved by the titlebar.
    var pingMS: Double?
    /// The active VIDEO pane's host-announced stream cadence (frames/sec); `nil` for a terminal pane.
    var fps: Int?
    /// The active VIDEO pane's client-measured stream bitrate (kilobits/sec, ~1 Hz); `nil` for a
    /// terminal pane / until the first reading.
    var kbps: Int?
    /// Opens the Connect-to-Host editor (pre-seeded with the current host/port).
    var onConnect: () -> Void = {}
    /// Stretch the tappable row to the mount's full width (the SIDEBAR mount — the row reads as one
    /// full-width sidebar item, hover plate included). The titlebar fallback keeps content width.
    var fillWidth = false

    @State private var hover = false

    private var status: ConnectionStatus { connection.status }
    /// The raw committed host (IP or name) — the tooltip/accessibility detail, never the display label.
    private var host: String { connection.target.host }
    /// The identity the cluster SPEAKS (label + monogram): the resolved short hostname ("mac-studio"),
    /// falling back to the raw target host only while unresolved (the user asked the chrome to talk
    /// hostnames, not IPs).
    private var displayHost: String { connection.hostDisplayName ?? host }
    private var isConnected: Bool { if case .connected = status { true } else { false } }

    /// The live telemetry segments — ping (when known), then the focused video pane's stream cadence and
    /// client-measured payload bitrate (the stream's health numbers; absent for a terminal pane).
    private var metrics: [String] {
        var out: [String] = []
        if let pingMS { out.append("\(Int(pingMS.rounded())) ms") }
        if let fps { out.append("\(fps) fps") }
        if let kbps { out.append(Self.bitrateLabel(kbps: kbps)) }
        return out
    }

    /// Formats a kbps reading for the cluster: ≥ 1 Mbps reads in megabits with one decimal ("12.4 Mbps"),
    /// below that in whole kilobits ("850 kbps"). Static + pure so the mapping is unit-testable.
    static func bitrateLabel(kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    /// Network health at a glance — the monogram plate's colour scale (user: "nhìn phát biết tình trạng
    /// mạng"). Classified from the smoothed ping while connected; a connected link with no sample yet
    /// reads `good` (the EWMA lands within a beat, and green-then-degrade is honest for a fresh link).
    enum NetworkHealth: Equatable {
        case offline
        case good
        case slow
        case bad
    }

    /// Pure classifier: ≤ 80 ms feels immediate for a remote coding session, ≤ 180 ms is workable-but-
    /// noticeable, beyond that typing hurts. Static so the thresholds are pinned by tests.
    static func health(isConnected: Bool, pingMS: Double?) -> NetworkHealth {
        guard isConnected else { return .offline }
        guard let pingMS else { return .good }
        if pingMS <= 80 { return .good }
        if pingMS <= 180 { return .slow }
        return .bad
    }

    /// The plate tint for the current health — theme status colours; `nil` (offline) lets the monogram
    /// drain to its own grayscale.
    private var plateTint: Color? {
        switch Self.health(isConnected: isConnected, pingMS: pingMS) {
        case .offline: nil
        case .good: Slate.Status.ok
        case .slow: Slate.Status.warn
        case .bad: Slate.Status.err
        }
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
                    // The host MONOGRAM as the one status pixel (MERIDIAN L1: colour = live data): the
                    // plate's colour IS the network health — green good / yellow slow / red bad (ping-
                    // classified), gray when offline. The initials are the whole name (no hostname text
                    // at rest — the full host lives in the hover tooltip); the identity hash-hue yields
                    // to the health tint here because two colour meanings on one plate would be noise.
                    SlateMonogram(identity: displayHost, live: isConnected, tint: plateTint)
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
                // Sidebar mount: the row stretches to the column width so it reads (and hovers, and hits)
                // as ONE full-width sidebar item; the titlebar fallback hugs its content.
                .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
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
