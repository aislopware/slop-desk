// ConnectionCluster — connection status for the SIDEBAR FOOTER (resting home) and the titlebar TRAILING
// edge while the sidebar is collapsed. Never jammed into the traffic-light strip.
//
// Layout (one quiet row — host name is the identity; no monogram plate, no LED dot):
//   congs-mac-studio                    11 ms
//   ↑                                   ↑
//   full short hostname                 instrument tertiary
//   (secondary; err when offline)       (warn/err when slow/bad)
//
// The VISIBLE metric is the ping ALONE. Appending fps/kbps ("11 ms · 60 fps · 12.4 Mbps") made the
// trailing text long enough to truncate the hostname out of its own row at sidebar widths — the
// identity lost to telemetry. Ping is the one number that reads as connection HEALTH; the stream
// numbers are on-demand detail and live in the TOOLTIP with the raw target.
//
// No monogram plate — the hostname already *is* the host, so a plate would be redundant. No health
// LED either — the attention dot owns the "dot" language elsewhere in the chrome, and a second
// always-on dot here would be noise. State lives in the TEXT instead: the metric digits carry the
// health colour (warn/err when degrading), the trailing status word covers offline, and the hostname
// itself dims to tertiary when not connected. Tap → Connect editor; give-up → Retry.

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

    /// The scene overlay coordinator — read for the workspace-prefix ARMED flag. While the prefix (⌃B)
    /// awaits its follow-up key the cluster's TRAILING metric (the ping) crossfades to the prefix pill
    /// (the `⌃B` capsule) and back on resolve — a state swap of the metric slot ONLY: the hostname stays
    /// put (the identity never blinks; per user direction the cue lives in the right corner where the
    /// ping sits). The cluster is the cue's home because it is the chrome's one running instrument
    /// readout, and the slot exists in BOTH sidebar states (footer while open, titlebar trailing while
    /// collapsed). `nil` (tests / previews / no scene injection) ⇒ the pill never shows.
    @Environment(\.overlayCoordinator) private var overlayCoordinator

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

    /// The row's trailing METRIC slot — the ping (or the short status word) at rest; while the workspace
    /// prefix is ARMED it crossfades to the ``PrefixArmedPill`` in place (trailing-anchored ZStack, so the
    /// right corner never shifts) and back on resolve. The hostname to its left never blinks.
    @ViewBuilder private var trailingSlot: some View {
        let armed = overlayCoordinator?.prefixArmed == true
        if armed || trailing != nil {
            ZStack(alignment: .trailing) {
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
                        .opacity(armed ? 0 : 1)
                        .accessibilityHidden(armed)
                }
                PrefixArmedPill()
                    .opacity(armed ? 1 : 0)
                    .accessibilityHidden(!armed)
            }
            // Ideal width always (the metric is a short readout — squeezing it into `…` would defeat
            // the instrument; the HOSTNAME is the row's designated truncator, `layoutPriority` above).
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(0)
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(Slate.Anim.smallFade, value: armed)
        }
    }

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

/// The workspace-prefix ARMED pill — what the cluster's trailing metric crossfades to while the prefix
/// (⌃B) awaits its follow-up key: the bare chord glyph in a CAPSULE on the raised plate, nothing else (an
/// earlier `…` "awaiting" suffix read as dirt next to the chord — the pill's presence already says
/// "listening"). The chord reads the LIVE registry resolution
/// (``WorkspaceBindingRegistry/resolvedPrefixChord`` — the same source the dispatcher re-keys from), so a
/// Settings rebind shows the new chord with no threading. System face (never monospaced — SF Mono draws
/// the modifier glyphs as cramped fallbacks), primary tone, no icon, no accent: an instrument readout in
/// the cluster's own quiet register, not an alarm.
struct PrefixArmedPill: View {
    var body: some View {
        Text(WorkspaceBindingRegistry.glyph(WorkspaceBindingRegistry.resolvedPrefixChord))
            .font(.system(size: Slate.Typeface.small, weight: .medium))
            .foregroundStyle(Slate.Text.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Surface.raised, in: .capsule)
            .overlay(Capsule().strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline))
            .accessibilityLabel("Prefix key armed, awaiting the next key")
    }
}
#endif
