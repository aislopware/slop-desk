// ConnectionCluster — connection status for the SIDEBAR FOOTER (resting home) and the titlebar TRAILING
// edge while the sidebar is collapsed. Never jammed into the traffic-light strip.
//
// Two mounts, two layouts:
//
// SIDEBAR FOOTER (`railFooter`) — the two-line instrument block on the sidebar's own text rail,
// pure TEXT (no dot, no glyph — a status lamp is exactly the ornament this chrome refuses):
//   mac-studio
//   12 ms
//   Hostname on the rail (footnote medium), the mono detail line beneath (the instrument readout
//   while connected — the ping, then the stream numbers while a video pane streams OR the link
//   uptime otherwise: "12 ms · 60 fps · 12.4 Mbps" / "12 ms · up 2h 14m" — or the short status
//   word when nothing is up).
//   State lives in the WORDS and their ink (`LedState` is the ink classifier): the hostname dims
//   to tertiary while nothing is connected, and the status hues appear ONLY when a live link
//   degrades (slow = warn, bad = err on the PING digits alone — the continuation stays tertiary) —
//   the ink dialect's rule, colour means trouble.
//
// TITLEBAR / iOS (compact) — the original one quiet row (host name + trailing ping), no LED, no
// monogram: state lives in the text (digits carry the health colour, hostname dims when offline).
//
// The COMPACT row's visible metric is the ping ALONE. Appending fps/kbps there made the trailing
// text long enough to truncate the hostname out of its own row — the identity lost to telemetry —
// so the one-line mounts keep the stream numbers in the TOOLTIP with the raw target. The RAIL
// footer's detail line is a whole line of its own (the hostname owns line one), so it carries the
// full readout. Tap → Connect editor; give-up → Retry.

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
    /// Sidebar footer LAYOUT: the two-line instrument block on the sidebar's text rail (hostname
    /// + mono detail stacked, pure text — see the header note). The titlebar / iOS mounts keep
    /// the compact one-line cluster.
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

    /// The footer's fused ink state (the name is historical — the lamp itself is gone; this now
    /// classifies the TEXT inks). Connected rides the ping classifier (good/slow/bad); a dial in
    /// flight (first connect OR a supervised reconnect) is `dialing`; every settled not-connected
    /// state is `dim` (a stale ping must never brighten it). Pure + pinned in
    /// `ConnectionClusterTests`.
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

    /// The rail detail line's CONTINUATION — the stream numbers while a video pane streams
    /// (" · 60 fps · 12.4 Mbps"), else the link uptime (" · up 2h 14m"). Never both: the line is
    /// one sidebar-width instrument, and together they truncate the tail into "· u…" — while a
    /// stream is live it IS the story, and the uptime returns the moment it stops. Connected-only
    /// (a dead link has no telemetry) and always on the tertiary ink: the health colour belongs to
    /// the ping digits (``footerDetail``), never to this trail. `nil` when nothing rides. Pure +
    /// pinned in `ConnectionClusterTests`.
    static func footerExtras(status: ConnectionStatus, fps: Int?, kbps: Int?, uptime: String?) -> String? {
        guard case .connected = status else { return nil }
        var parts: [String] = []
        if let fps { parts.append("\(fps) fps") }
        if let kbps { parts.append(bitrateLabel(kbps: kbps)) }
        if parts.isEmpty, let uptime { parts.append(uptime) }
        guard !parts.isEmpty else { return nil }
        return parts.map { " · \($0)" }.joined()
    }

    /// The link-uptime readout ("up 2h 14m") for the rail's detail line. Hidden for the first
    /// minute — a seconds counter would tick every render, motion the resting footer refuses —
    /// then minute-granular: hours carry minutes, days carry hours. Pure + pinned in
    /// `ConnectionClusterTests`.
    static func uptimeLabel(since: Date?, now: Date) -> String? {
        guard let since else { return nil }
        let minutes = Int(now.timeIntervalSince(since)) / 60
        guard minutes >= 1 else { return nil }
        if minutes < 60 { return "up \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "up \(hours)h \(minutes % 60)m" }
        return "up \(hours / 24)d \(hours % 24)h"
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
    /// ``ConnectionRailFooter`` (pure values in, so the snapshot rig can mount every ink state);
    /// this maps the live model onto it. The inks brighten on the needle curve — the same
    /// orchestrated moment the handshake already owns.
    private var railBody: some View {
        let led = Self.ledState(status: status, pingMS: pingMS)
        return ConnectionRailFooter(
            displayHost: displayHost,
            led: led,
            detail: Self.footerDetail(status: status, pingMS: pingMS),
            extras: Self.footerExtras(
                status: status, fps: fps, kbps: kbps,
                uptime: Self.uptimeLabel(since: connection.connectedSince, now: Date()),
            ),
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

/// The sidebar footer's PRESENTATIONAL layout — pure values in (host / ink state / detail line),
/// no model, so the snapshot rig mounts every state directly. Pure text on the sidebar's rail
/// (indented onto the same x the section names and row titles share — the `tabRowInset` gutter
/// stays EMPTY: no lamp, no glyph): the hostname line, the mono detail line beneath. Internal
/// (not private) for the rig.
struct ConnectionRailFooter: View {
    let displayHost: String
    let led: ConnectionCluster.LedState
    let detail: (text: String, isMetric: Bool)?
    /// The tertiary continuation after the ping (``ConnectionCluster/footerExtras``) — stream
    /// numbers + uptime, `nil` when nothing rides.
    var extras: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // The hostname — the same register as the project header names (footnote medium,
            // secondary), dimming to tertiary while nothing is connected.
            Text(displayHost)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(led == .dim ? Slate.Text.tertiary : Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let line = detailLine {
                // The instrument line — one metadata voice with the git lines and shell labels.
                line
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, Slate.Metric.tabRowInset)
    }

    /// The detail line as ONE text run (so the pair truncates as a single tail, never each half
    /// independently): the ping/status segment on its health ink, the extras trail always
    /// tertiary — the hue stays on the digits that mean trouble.
    private var detailLine: Text? {
        let metric = detail.map { Text($0.text).foregroundStyle(detailInk) }
        let trail = extras.map { Text($0).foregroundStyle(Slate.Text.tertiary) }
        switch (metric, trail) {
        case (nil, nil): return nil
        case let (line?, nil),
             let (nil, line?): return line
        case let (metric?, trail?): return Text("\(metric)\(trail)")
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
