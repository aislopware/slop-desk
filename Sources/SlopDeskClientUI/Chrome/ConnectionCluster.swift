// ConnectionCluster — connection status for the SIDEBAR FOOTER (resting home) and the titlebar TRAILING
// edge while the sidebar is collapsed. Never jammed into the traffic-light strip.
//
// Two mounts, two layouts:
//
// SIDEBAR FOOTER (`railFooter`) — the two-line instrument block on the sidebar's own text rail,
// rhyming with the section headers above it (gutter glyph + name line + mono detail line):
//   ●  mac-studio
//      12 ms
//   ↑  ↑
//   LED in the `tabRowInset` gutter; hostname on the rail (footnote medium), the mono detail line
//   beneath (ping while connected, the short status word otherwise). The LED is a 6pt health lamp
//   (`LedState`): green good / amber slow or dialing / red bad / dimmed offline, with a soft
//   same-hue glow while lit — STATIC, never blinking; the connect handshake colours it in on the
//   needle curve. This is the one place chrome wears a dot besides the attention pip.
//
// TITLEBAR / iOS (compact) — the original one quiet row (host name + trailing ping), no LED, no
// monogram: state lives in the text (digits carry the health colour, hostname dims when offline).
//
// The VISIBLE metric is the ping ALONE in both layouts. Appending fps/kbps ("11 ms · 60 fps ·
// 12.4 Mbps") made the trailing text long enough to truncate the hostname out of its own row at
// sidebar widths — the identity lost to telemetry. Ping is the one number that reads as connection
// HEALTH; the stream numbers are on-demand detail and live in the TOOLTIP with the raw target.
// Tap → Connect editor; give-up → Retry.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct ConnectionCluster: View {
    let connection: AppConnection
    var pingMS: Double?
    /// Stream cadence/bitrate of the active video pane — TOOLTIP-ONLY detail (see the header note).
    var fps: Int?
    var kbps: Int?
    var onConnect: () -> Void = {}
    /// Sidebar footer: stretch the hit/hover plate full width. Titlebar mount hugs content.
    var fillWidth = false
    /// Sidebar footer LAYOUT: the two-line instrument block on the sidebar's text rail (LED in the
    /// gutter, hostname + mono detail stacked — see the header note). The titlebar / iOS mounts
    /// keep the compact one-line cluster.
    var railFooter = false

    @State private var hover = false

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }
    /// Short hostname the chrome speaks ("congs-mac-studio"); raw target only while unresolved.
    private var displayHost: String { connection.hostDisplayName ?? host }
    private var isConnected: Bool { if case .connected = status { true } else { false } }

    /// The one visible metric: the ping. `nil` until the first sample.
    static func pingLabel(_ pingMS: Double?) -> String? {
        pingMS.map { "\(Int($0.rounded())) ms" }
    }

    static func bitrateLabel(kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    /// The stream numbers as tooltip detail (" · 60 fps · 12.4 Mbps"), or empty when neither exists.
    /// Pure + static so the "fps/kbps never render in the row" contract is pinned headlessly.
    static func tooltipDetail(fps: Int?, kbps: Int?) -> String {
        var extras: [String] = []
        if let fps { extras.append("\(fps) fps") }
        if let kbps { extras.append(bitrateLabel(kbps: kbps)) }
        return extras.map { " · \($0)" }.joined()
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

    /// The footer LED's state — the health lamp the rail footer wears in its gutter. Connected
    /// rides the ping classifier (good/slow/bad); a dial in flight (first connect OR a supervised
    /// reconnect) is `dialing` — amber "working on it"; every settled not-connected state dims the
    /// lamp (a stale ping must never resurrect it). Pure + pinned in `ConnectionClusterTests`.
    enum LedState: Equatable {
        case dim
        case dialing
        case good
        case slow
        case bad
    }

    static func ledState(status: ConnectionStatus, pingMS: Double?) -> LedState {
        switch status {
        case .connected:
            switch health(isConnected: true, pingMS: pingMS) {
            case .slow: .slow
            case .bad: .bad
            default: .good
            }
        case .connecting,
             .reconnecting: .dialing
        case .disconnected,
             .failed,
             .unreachable: .dim
        }
    }

    /// The rail footer's SECOND line: the mono ping metric while connected (falling back to the
    /// status word before the first sample), else the short status word (campaign progress
    /// included) — never a stale ping. Pure + pinned in `ConnectionClusterTests`.
    static func footerDetail(status: ConnectionStatus, pingMS: Double?) -> (text: String, isMetric: Bool)? {
        if case .connected = status, let label = pingLabel(pingMS) { return (label, true) }
        return (StatusPresentation.connectionLabel(status), false)
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

    /// Connected: the ping alone (or nil before the first sample). Else short status word.
    private var trailing: (text: String, isMetric: Bool)? {
        if isConnected {
            return Self.pingLabel(pingMS).map { ($0, true) }
        }
        return (StatusPresentation.connectionLabel(status), false)
    }

    /// Hover/accessibility text: host + headline, plus the stream numbers while connected — the
    /// on-demand home of the detail the visible row deliberately drops.
    private var helpText: String {
        StatusPresentation.connectionHelp(host: host, status: status)
            + (isConnected ? Self.tooltipDetail(fps: fps, kbps: kbps) : "")
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Button(action: onConnect) {
                Group {
                    if railFooter { railBody } else { compactBody }
                }
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
            .help(helpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(helpText)

            if StatusPresentation.showsRetry(status) {
                retryButton
            }
        }
    }

    /// The titlebar / iOS one-line cluster (see the header note).
    private var compactBody: some View {
        HStack(alignment: .center, spacing: Slate.Metric.space2) {
            // Host name carries the identity; it DIMS to tertiary when not connected — state
            // lives in the text, not a separate LED, since the metric digits carry health colour.
            Text(displayHost)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(isConnected ? Slate.Text.secondary : Slate.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .frame(maxHeight: .infinity, alignment: .center)

            if fillWidth { Spacer(minLength: Slate.Metric.space1) }

            trailingSlot
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightControl, alignment: .center)
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    /// The sidebar footer's two-line instrument block. The presentational layout lives in
    /// ``ConnectionRailFooter`` (pure values in, so the snapshot rig can mount every LED state);
    /// this maps the live model onto it. The LED colours in on the needle curve — the same
    /// orchestrated moment the handshake already owns.
    private var railBody: some View {
        let led = Self.ledState(status: status, pingMS: pingMS)
        return ConnectionRailFooter(
            displayHost: displayHost,
            led: led,
            detail: Self.footerDetail(status: status, pingMS: pingMS),
        )
        .padding(.vertical, Slate.Metric.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Slate.Anim.needle, value: led)
    }

    /// The row's trailing METRIC slot — the ping (or the short status word). The hostname to its left is
    /// the row's designated truncator; this slot always renders at ideal width.
    @ViewBuilder private var trailingSlot: some View {
        if let trailing {
            Text(trailing.text)
                .font(
                    trailing.isMetric
                        ? Slate.Typeface.instrument(Slate.Typeface.small)
                        : .system(size: Slate.Typeface.small),
                )
                .foregroundStyle(trailing.isMetric ? metricColor : Slate.Text.tertiary)
                .lineLimit(1)
                .transition(.opacity.animation(isConnected ? Slate.Anim.needle.delay(0.08) : nil))
                // Ideal width always (the metric is a short readout — squeezing it into `…` would defeat
                // the instrument; the HOSTNAME is the row's designated truncator, `layoutPriority` above).
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(0)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    /// The give-up Retry affordance (unchanged across layouts).
    private var retryButton: some View {
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

/// The sidebar footer's PRESENTATIONAL layout — pure values in (host / LED state / detail line), no
/// model, so the snapshot rig mounts every state directly. Rhymes with the section headers above
/// it: a glyph in the `tabRowInset` gutter, the name line on the text rail, the mono detail line
/// beneath. Internal (not private) for the rig.
struct ConnectionRailFooter: View {
    let displayHost: String
    let led: ConnectionCluster.LedState
    let detail: (text: String, isMetric: Bool)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The health lamp: 6pt, its bottom resting on the host line's baseline (visually
            // centred on the x-height), with a soft same-hue glow while lit — a LAMP, not a blink;
            // the dim state casts nothing.
            Circle()
                .fill(ledColor)
                .frame(width: 6, height: 6)
                .shadow(color: led == .dim ? .clear : ledColor.opacity(0.55), radius: 2.5)
                .frame(width: Slate.Metric.tabRowInset, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 1) {
                // The hostname — the same register as the project header names (footnote medium,
                // secondary), dimming with the lamp when nothing is connected.
                Text(displayHost)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(led == .dim ? Slate.Text.tertiary : Slate.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    // The instrument line — one metadata voice with the git lines and shell labels.
                    Text(detail.text)
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .foregroundStyle(detailInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var ledColor: Color {
        switch led {
        case .dim: Slate.Text.tertiary
        case .dialing,
             .slow: Slate.Status.warn
        case .good: Slate.Status.ok
        case .bad: Slate.Status.err
        }
    }

    /// Metric digits carry the health colour only while degrading; words stay muted.
    private var detailInk: Color {
        guard let detail, detail.isMetric else { return Slate.Text.tertiary }
        switch led {
        case .slow: return Slate.Status.warn
        case .bad: return Slate.Status.err
        default: return Slate.Text.tertiary
        }
    }
}

#endif
