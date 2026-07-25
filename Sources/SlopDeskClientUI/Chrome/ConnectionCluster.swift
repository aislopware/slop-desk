// ConnectionCluster — connection status for the SIDEBAR FOOTER (resting home) and the titlebar TRAILING
// edge while the sidebar is collapsed. Never jammed into the traffic-light strip.
//
// Two mounts, one shape — a quiet row of pure TEXT (no dot, no glyph — a status lamp is exactly the
// ornament this chrome refuses), host leading and metric trailing:
//
// SIDEBAR FOOTER (`railFooter`) — two lines under the tab list, laid on the sidebar's OWN rails:
//   mac-studio               12 ms      ← the LINK: who, and how far away
//   ▣ 34%                    ▤ 61%      ← the MACHINE: how hard it is working
//   Line two names its two metrics with SYMBOLS rather than the words "cpu"/"mem": a readout is a
//   number and its unit, and spelling the unit out in a run of lowercase prose gave the line the
//   texture of a sentence set adrift under the identity. The chip glyphs anchor each end, so the
//   pair reads as two instruments instead of a half-empty row of text. The words survive where
//   there is room for prose — the tooltip and the accessibility label.
//   Both lines share the two rails: the leading edge is the x every row title starts on, the
//   trailing edge is the column the rows' status marks stand in. So the footer reads as the last
//   lines of the list rather than a widget bolted underneath, and the right rail becomes the one
//   place a number can turn amber.
//   State lives in the WORDS and their ink (`LedState` is the ink classifier): the hostname dims
//   to tertiary while nothing is connected, and the status hues appear ONLY when something has
//   gone wrong (a degrading link colours the PING digits; kernel memory pressure colours the MEM
//   digits) — the ink dialect's rule, colour means trouble.
//   The pulse line is absent, not blanked, until a reading exists: an instrument showing "cpu —"
//   advertises breakage, while a footer that grows a second line on connect just reports.
//   CPU is deliberately NEVER coloured — a build pegging the host is what the machine is FOR, and a
//   readout that goes amber every compile teaches the eye to ignore it.
//
// TITLEBAR / iOS (compact) — the link line alone, hugging its content instead of the rails, and
// silent (rather than saying "connected") in the beat before the first ping sample lands. The
// machine's pulse belongs to the sidebar's instrument column, not to a window's top edge.
//
// The visible LINK metric is the ping alone, on both mounts. Appending fps/kbps made the trailing
// text long enough to truncate the hostname out of its own row — the identity lost to telemetry.
// Those (and the exact pulse numbers) live in the TOOLTIP with the raw target. Tap → Connect
// editor; give-up → Retry.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskProtocol
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
    /// Sidebar footer LAYOUT: the instrument block on the sidebar's two rails (the link line, plus
    /// the host-pulse line once the machine has reported — see the header note). The titlebar / iOS
    /// mounts keep the compact one-line cluster.
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

    /// The rail footer's TRAILING slot: the mono ping metric while connected (falling back to the
    /// status word before the first sample — a connected footer with an empty right edge reads as
    /// broken, which is why this mount speaks where the compact one stays silent), else the short
    /// status word (campaign progress included) — never a stale ping. Pure + pinned in
    /// `ConnectionClusterTests`.
    static func footerDetail(status: ConnectionStatus, pingMS: Double?) -> (text: String, isMetric: Bool)? {
        if case .connected = status, let label = pingLabel(pingMS) { return (label, true) }
        return (StatusPresentation.connectionLabel(status), false)
    }

    /// The footer's SECOND line spoken as PROSE — the tooltip's and the accessibility label's copy,
    /// where the metric names are words because there is room for words. `nil` until a reading
    /// exists — the line is then absent entirely, never a row of dashes (see the header note).
    /// Pure + static so the copy is pinned headlessly.
    static func pulseLabels(_ pulse: HostPulse?) -> (cpu: String, memory: String)? {
        guard let pulse else { return nil }
        return ("cpu \(pulse.cpuPercent)%", "mem \(pulse.memoryPercent)%")
    }

    /// The same reading as it is DRAWN: the bare percents, each named by ``cpuSymbol`` /
    /// ``memorySymbol`` beside it rather than by a repeated word.
    static func pulseReadings(_ pulse: HostPulse?) -> (cpu: String, memory: String)? {
        guard let pulse else { return nil }
        return ("\(pulse.cpuPercent)%", "\(pulse.memoryPercent)%")
    }

    /// The two metric marks. The processor die and the memory module are the pair Activity Monitor
    /// itself uses, and they differ in SILHOUETTE (a square with pins on four edges vs a wide module
    /// with pins on one) — which is the only difference that survives at the footer's size.
    static let cpuSymbol: SFSymbol = .cpu
    static let memorySymbol: SFSymbol = .memorychip

    /// The pulse as TOOLTIP prose — the exact numbers plus the pressure verdict the visible line
    /// only hints at through ink. Empty when there is no reading.
    static func pulseTooltip(_ pulse: HostPulse?) -> String {
        guard let labels = pulseLabels(pulse), let pulse else { return "" }
        let pressure =
            switch pulse.memoryPressure {
            case .normal: ""
            case .warn: " (memory pressure)"
            case .critical: " (memory pressure critical)"
            }
        return " · \(labels.cpu) · \(labels.memory)\(pressure)"
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
            + Self.pulseTooltip(connection.hostPulse)
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

    /// The sidebar footer's status line. The presentational layout lives in
    /// ``ConnectionRailFooter`` (pure values in, so the snapshot rig can mount every ink state);
    /// this maps the live model onto it. The inks brighten on the needle curve — the same
    /// orchestrated moment the handshake already owns.
    private var railBody: some View {
        let led = Self.ledState(status: status, pingMS: pingMS)
        return ConnectionRailFooter(
            displayHost: displayHost,
            led: led,
            detail: Self.footerDetail(status: status, pingMS: pingMS),
            pulse: connection.hostPulse,
        )
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

/// The sidebar footer's PRESENTATIONAL layout — pure values in (host / ink state / detail / pulse),
/// no model, so the snapshot rig mounts every state directly. Two lines of pure text spanning the
/// sidebar's two rails: the leading rail is the x the section names and row titles share (the
/// `tabRowInset` gutter stays EMPTY — no lamp, no glyph), the trailing rail is the rows' status-mark
/// column. Line one is the LINK (host + ping), line two the MACHINE (cpu + mem), and it exists only
/// once the host has reported. Internal (not private) for the rig.
struct ConnectionRailFooter: View {
    let displayHost: String
    let led: ConnectionCluster.LedState
    let detail: (text: String, isMetric: Bool)?
    /// The host machine's pulse; `nil` ⇒ no second line at all (see the header note).
    var pulse: HostPulse?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            linkLine
            if let readings = ConnectionCluster.pulseReadings(pulse) {
                pulseLine(readings)
            }
        }
        .padding(.horizontal, Slate.Metric.tabRowInset)
    }

    /// Line one — who we are talking to, and how far away it feels. On the CONTROL band, not the
    /// list's 32pt row band: the two lines are one block and have to read as a pair, and a row band
    /// under a row band put ~17pt of air between two lines that belong together. The air the footer
    /// needs is ABOVE it (the mount's `space3` gap), not inside it.
    private var linkLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            // The hostname — the same register as the project header names (footnote medium,
            // secondary), dimming to tertiary while nothing is connected. The row's designated
            // truncator: a long host gives way, the short metric never does.
            Text(displayHost)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(led == .dim ? Slate.Text.tertiary : Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: Slate.Metric.space1)
            if let detail {
                // A metric is INSTRUMENT mono — one metadata voice with the git lines and shell
                // labels; a status WORD is prose and keeps the system face, like the compact
                // mount's trailing slot.
                Text(detail.text)
                    .font(
                        detail.isMetric
                            ? Slate.Typeface.instrument(Slate.Typeface.small)
                            : .system(size: Slate.Typeface.small),
                    )
                    .foregroundStyle(detailInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: Slate.Metric.heightControl)
    }

    /// Line two — the machine's own pulse: a mark and a number at each rail. The digits are
    /// INSTRUMENT mono (they are readings, not prose), so the pair reads as one quiet instrument
    /// under the identity rather than a second row competing with it. The line speaks its full prose
    /// to VoiceOver, which cannot see a silhouette.
    private func pulseLine(_ readings: (cpu: String, memory: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            reading(ConnectionCluster.cpuSymbol, readings.cpu, ink: Slate.Text.tertiary)
            Spacer(minLength: Slate.Metric.space1)
            reading(ConnectionCluster.memorySymbol, readings.memory, ink: memoryInk)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pulseSpoken)
    }

    /// One reading: its mark, then its number, in ONE ink — when memory pressure colours the metric
    /// the glyph turns with the digits, because a half-tinted readout reads as a rendering bug
    /// rather than a warning. The mark sits a step above the digits (`footnote`) so a drawing built
    /// from strokes holds its silhouette next to type built from stems.
    private func reading(_ symbol: SFSymbol, _ value: String, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space1) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.footnote))
                .symbolRenderingMode(.monochrome)
            Text(value)
                .font(Slate.Typeface.instrument(Slate.Typeface.small))
        }
        .foregroundStyle(ink)
    }

    /// The pulse as words, for the readers that get no glyph.
    private var pulseSpoken: String {
        guard let labels = ConnectionCluster.pulseLabels(pulse) else { return "" }
        return "\(labels.cpu), \(labels.memory)"
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

    /// The memory metric takes the KERNEL's pressure verdict, not the percent: a high memory percent
    /// is ordinary on a healthy Mac (macOS fills the RAM it has), while pressure is the reading that
    /// actually predicts a machine about to crawl. CPU has no such ink by design.
    private var memoryInk: Color {
        switch pulse?.memoryPressure {
        case .warn: Slate.Status.warn
        case .critical: Slate.Status.err
        default: Slate.Text.tertiary
        }
    }
}

#endif
