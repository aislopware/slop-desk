// ConnectionCluster — connection status for the SIDEBAR FOOTER (resting home) and the titlebar TRAILING
// edge while the sidebar is collapsed. Never jammed into the traffic-light strip.
//
// Layout (one quiet row — host name is the identity; no monogram plate next to it):
//   ·  congs-mac-studio                    11 ms
//   ↑  ↑                                   ↑
//   LED full short hostname                instrument tertiary
//   6pt (health / live)                    (warn/err when slow/bad)
//
// Monogram + hostname was redundant (CM already *is* the host). Monogram alone felt empty in the
// footer. So: LED for state colour, host string for identity, metrics for the number. Full target
// (raw IP etc.) still in the tooltip. Tap → Connect editor; give-up → Retry.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct ConnectionCluster: View {
    let connection: AppConnection
    var pingMS: Double?
    var fps: Int?
    var kbps: Int?
    var onConnect: () -> Void = {}
    /// Sidebar footer: stretch the hit/hover plate full width. Titlebar mount hugs content.
    var fillWidth = false

    @State private var hover = false

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }
    /// Short hostname the chrome speaks ("congs-mac-studio"); raw target only while unresolved.
    private var displayHost: String { connection.hostDisplayName ?? host }
    private var isConnected: Bool { if case .connected = status { true } else { false } }

    private var metrics: [String] {
        var out: [String] = []
        if let pingMS { out.append("\(Int(pingMS.rounded())) ms") }
        if let fps { out.append("\(fps) fps") }
        if let kbps { out.append(Self.bitrateLabel(kbps: kbps)) }
        return out
    }

    static func bitrateLabel(kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    enum NetworkHealth: Equatable {
        case offline
        case good
        case slow
        case bad
    }

    static func health(isConnected: Bool, pingMS: Double?) -> NetworkHealth {
        guard isConnected else { return .offline }
        guard let pingMS else { return .good }
        if pingMS <= 80 { return .good }
        if pingMS <= 180 { return .slow }
        return .bad
    }

    /// 6pt LED — health when live, quiet tertiary when offline. Never traffic-light sized.
    private var ledColor: Color {
        switch Self.health(isConnected: isConnected, pingMS: pingMS) {
        case .offline: Slate.Text.tertiary
        case .good: Slate.Status.ok
        case .slow: Slate.Status.warn
        case .bad: Slate.Status.err
        }
    }

    /// Metric digits: tertiary when healthy, warn/err only when degrading.
    private var metricColor: Color {
        switch Self.health(isConnected: isConnected, pingMS: pingMS) {
        case .offline,
             .good: Slate.Text.tertiary
        case .slow: Slate.Status.warn
        case .bad: Slate.Status.err
        }
    }

    /// Connected: live metrics (or nil if no sample yet). Else short status word.
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
                // Explicit centre alignment: a bare 6pt Circle next to multi-size text otherwise sits off
                // the optical midline (font metrics have asymmetric ascent/descent). LED and labels share
                // the same control-height line box so midpoints match.
                HStack(alignment: .center, spacing: Slate.Metric.space2) {
                    // Status LED — colour is the only ornament; host name carries identity (no monogram
                    // plate that would restate the same name as initials).
                    Circle()
                        .fill(ledColor)
                        .frame(width: Slate.Metric.statusLED, height: Slate.Metric.statusLED)
                        .frame(width: 10, height: Slate.Metric.heightControl, alignment: .center)
                        .animation(isConnected ? Slate.Anim.needle : nil, value: isConnected)

                    Text(displayHost)
                        .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .frame(maxHeight: .infinity, alignment: .center)

                    if fillWidth { Spacer(minLength: Slate.Metric.space1) }

                    if let trailing {
                        Text(trailing.text)
                            .font(
                                trailing.isMetric
                                    ? Slate.Typeface.instrument(Slate.Typeface.small)
                                    : .system(size: Slate.Typeface.small),
                            )
                            .foregroundStyle(trailing.isMetric ? metricColor : Slate.Text.tertiary)
                            .lineLimit(1)
                            .layoutPriority(0)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .transition(.opacity.animation(isConnected ? Slate.Anim.needle.delay(0.08) : nil))
                    }
                }
                .padding(.horizontal, Slate.Metric.space2)
                .frame(height: Slate.Metric.heightControl, alignment: .center)
                .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
                .background(
                    hover ? Slate.State.hover : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusControl),
                )
                .contentShape(.rect)
                .animation(isConnected ? Slate.Anim.needle : nil, value: isConnected)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(Slate.Anim.smallFade, value: hover)
            .help(StatusPresentation.connectionHelp(host: host, status: status))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))

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
