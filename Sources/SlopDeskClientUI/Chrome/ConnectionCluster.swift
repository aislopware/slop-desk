// ConnectionCluster — connection status for the SIDEBAR FOOTER (resting home) and the titlebar TRAILING
// edge while the sidebar is collapsed. Never jammed into the traffic-light strip.
//
// Layout (one quiet row — host name is the identity; no monogram plate, no LED dot):
//   congs-mac-studio                    11 ms
//   ↑                                   ↑
//   full short hostname                 instrument tertiary
//   (secondary; err when offline)       (warn/err when slow/bad)
//
// Monogram + hostname was redundant (CM already *is* the host); the 6pt health LED went next
// (2026-07-10: the attention dot owns the "dot" language now — a second always-on dot in the chrome was
// noise). State lives in the TEXT: the metric digits carry the health colour (warn/err when degrading),
// the trailing status word covers offline, and the hostname itself dims to tertiary when not connected.
// Full target (raw IP etc.) still in the tooltip. Tap → Connect editor; give-up → Retry.

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
                HStack(alignment: .center, spacing: Slate.Metric.space2) {
                    // Host name carries the identity; it DIMS to tertiary when not connected (state in
                    // the text — the old 6pt health LED is gone, the metric digits carry health colour).
                    Text(displayHost)
                        .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                        .foregroundStyle(isConnected ? Slate.Text.secondary : Slate.Text.tertiary)
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
