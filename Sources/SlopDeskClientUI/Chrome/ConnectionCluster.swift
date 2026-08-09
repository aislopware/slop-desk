// ConnectionCluster — the link's one status surface, back in the macOS chrome (user-directed
// 2026-08-09, reversing its removal earlier the same day).
//
// It is ONE ISLAND now, not a block of loose lines: the same tinted bed a project group stands on
// (``SlateProjectIsland`` at ``Slate/ProjectTint/neutralBed`` — the keyless bucket's tone, since the
// host is not a project and must not borrow a project's identity hue). Both registers live inside
// that one bed, so the status reads as an object the chrome contains rather than as text left over
// at the bottom of a column.
//
// It follows the TABS. The tab list is the thing whose axis the window flips, and the status belongs
// beside it in either orientation:
//   • TABS VERTICAL (navigator open) — the island is the sidebar's FOOTER, two lines on the island's
//     own text rail, the last thing under the list.
//   • TABS HORIZONTAL (navigator collapsed) — the island moves into the band with them and anchors
//     to the TRAILING corner, one line, the same bed one control tall.
// One shape, two axes: exactly the move the tab strip and the panel's surface tabs already make.
//
//   mac-studio               12 ms      ← the LINK: who, and how far away
//   ▣ 34%       ▤ 61%       ▨ 240G      ← the MACHINE: how hard it is working
//
// Line two names its metrics with SYMBOLS rather than the words "cpu"/"mem": a readout is a number
// and the thing it measures, and spelling that out in a run of lowercase prose gave the line the
// texture of a sentence set adrift under the identity. The words survive where there is room for
// prose — the tooltip and the accessibility label. The marks stay as they were pending a look at them
// ON the bed (user-directed 2026-08-09): a pictogram that read as bought-in against bare ground may
// well read as an instrument face once the island contains it.
//
// THREE readings, not two: the three ways a host stops being useful are busy, full and out of room.
// They read left to right in order of how FAST each one moves — cpu changes second to second, memory
// over minutes, free disk over days — so the eye scans from the reading that is about right now
// toward the one that is about next week. It also keeps the two PERCENTS adjacent, which is the pair
// a glance actually compares, and leaves the odd reading out at the end: free disk is the one metric
// given in BYTES, since a disk percent lies in both directions (2% of 4 TB still builds; 8% of 128 GB
// does not). Its ink comes from an absolute threshold for the same reason.
//
// State lives in the WORDS and their WEIGHT, on ONE ink axis (``Alarm``): a healthy readout rests in
// the tertiary metadata grey, and a reading in trouble climbs the same brightness ladder the rail's
// git line uses — secondary + semibold when it is worth knowing, primary + bold when it is worth
// acting on. No hue at all. An instrument that lights up in a different colour per fault asks the eye
// to learn a palette before it can read a number; a run that simply gets BRIGHTER and HEAVIER than
// its neighbours says "this one" in the only vocabulary a footer of digits has. Only three readings
// can climb (a degrading link on the PING digits, kernel memory pressure on the MEM digits, a filling
// volume on the DISK run); everything else stays flat. CPU is deliberately NEVER raised — a build
// pegging the host is what the machine is FOR, and a readout that shouts every compile teaches the
// eye to ignore it.
//
// The pulse line is absent, not blanked, until a reading exists: an instrument showing "cpu —"
// advertises breakage, while an island that grows a second line on connect just reports.
//
// iOS (compact) — the link line alone, hugging its content and bedless, and silent (rather than
// saying "connected") in the beat before the first ping sample lands. A navigation toolbar has no
// ground for a bed to be cut out of.
//
// The visible LINK metric is the ping alone, on every mount. Appending fps/kbps made the trailing
// text long enough to truncate the hostname out of its own row — the identity lost to telemetry.
// Those (and the exact pulse numbers) live in the TOOLTIP with the raw target. Tap → Connect
// editor; give-up → Retry.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SwiftUI

struct ConnectionCluster: View {
    /// Which of the three mounts this is — see the header note. The layout is a PARAMETER rather than
    /// three views because the ink rules, the alarm ladder and the copy are identical across them;
    /// only the axis and the bed change.
    enum Layout: Equatable {
        /// The navigator's footer, under a VERTICAL tab list: two lines on the bed.
        case stacked
        /// The band, beside a HORIZONTAL tab strip: one line on the bed, one control tall.
        case inline
        /// iOS's navigation toolbar: the link line alone, no bed.
        case compact
    }

    let connection: AppConnection
    var pingMS: Double?
    /// Stream cadence/bitrate of the active video pane — TOOLTIP-ONLY detail (see the header note).
    var fps: Int?
    var kbps: Int?
    var onConnect: () -> Void = {}
    var layout: Layout = .compact

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

    /// The island's fused ink state (the name is historical — the lamp itself is gone; this now
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

    /// How loud one reading is allowed to be — the island's whole state axis, and the only one it has.
    ///
    /// This is a row of digits, so the two channels it can spend are BRIGHTNESS and WEIGHT; hue is a
    /// third that would have to be learned before it could be read (amber-means-slow, red-means-worse) and
    /// that turns a quiet instrument into a row of warning lights. `quiet` is the metadata grey every
    /// healthy reading rests in, `raised` is worth knowing about, `loud` is worth acting on.
    enum Alarm: Equatable {
        case quiet
        case raised
        case loud
    }

    /// The alarm's ink: one step up the text ladder per rung, tertiary → secondary → primary. Resolved in
    /// exactly one place so a theme change repoints the whole island at once.
    static func alarmInk(_ alarm: Alarm) -> Color {
        switch alarm {
        case .quiet: Slate.Text.tertiary
        case .raised: Slate.Text.secondary
        case .loud: Slate.Text.primary
        }
    }

    /// The alarm's weight — the second channel, carrying the same rungs. At the island's 10 pt a
    /// brightness step alone is easy to lose against a hostname on the line above; the weight step is what
    /// makes the raised reading findable without looking for it.
    static func alarmWeight(_ alarm: Alarm) -> Font.Weight {
        switch alarm {
        case .quiet: .regular
        case .raised: .semibold
        case .loud: .bold
        }
    }

    /// The LINK's alarm: a slow round trip is worth knowing, a bad one is worth acting on. Every
    /// not-connected state is quiet — an instrument that has nothing to measure has nothing to shout
    /// about, and the status WORD in the slot already says so.
    static func linkAlarm(_ led: LedState) -> Alarm {
        switch led {
        case .slow: .raised
        case .bad: .loud
        default: .quiet
        }
    }

    /// MEMORY takes the KERNEL's pressure verdict, not the percent: a high memory percent is ordinary on a
    /// healthy Mac (macOS fills the RAM it has), while pressure is the reading that actually predicts a
    /// machine about to crawl.
    static func memoryAlarm(_ pressure: MetadataCodec.MemoryPressure?) -> Alarm {
        switch pressure {
        case .warn: .raised
        case .critical: .loud
        default: .quiet
        }
    }

    /// DISK is the one metric with an ABSOLUTE threshold rather than a verdict from the kernel: there is no
    /// such thing as "disk pressure", and a percent lies in both directions (2% of a 4 TB disk is plenty;
    /// 8% of a 128 GB disk is nothing). Bytes left is the only reading that answers the question, so bytes
    /// left is what climbs. An unreadable volume is quiet, not alarmed — no reading is not bad news.
    static func diskAlarm(freeMiB: UInt32?) -> Alarm {
        guard let freeMiB else { return .quiet }
        if freeMiB < diskCriticalMiB { return .loud }
        if freeMiB < diskWarnMiB { return .raised }
        return .quiet
    }

    /// The island's TRAILING slot: the mono ping metric while connected (falling back to the status
    /// word before the first sample — a connected island with an empty right edge reads as broken,
    /// which is why the bedded mounts speak where the compact one stays silent), else the short
    /// status word (campaign progress included) — never a stale ping. Pure + pinned in
    /// `ConnectionClusterTests`.
    static func footerDetail(status: ConnectionStatus, pingMS: Double?) -> (text: String, isMetric: Bool)? {
        if case .connected = status, let label = pingLabel(pingMS) { return (label, true) }
        return (StatusPresentation.connectionLabel(status), false)
    }

    /// The island's SECOND register spoken as PROSE — the tooltip's and the accessibility label's
    /// copy, where the metric names are words because there is room for words. `nil` until a reading
    /// exists — the line is then absent entirely, never a row of dashes (see the header note).
    /// Pure + static so the copy is pinned headlessly.
    static func pulseLabels(_ pulse: HostPulse?) -> (cpu: String, memory: String)? {
        guard let pulse else { return nil }
        return ("cpu \(pulse.cpuPercent)%", "mem \(pulse.memoryPercent)%")
    }

    /// The same reading as it is DRAWN, in the order it is drawn — cpu, memory, disk: fastest-moving
    /// first (see the header note). Disk is `nil` on its own when the host could not read the volume
    /// — one missing metric closes its gap, it does not blank the line.
    static func pulseReadings(_ pulse: HostPulse?) -> (cpu: String, memory: String, disk: String?)? {
        guard let pulse else { return nil }
        return ("\(pulse.cpuPercent)%", "\(pulse.memoryPercent)%", diskLabel(freeMiB: pulse.diskFreeMiB))
    }

    /// Free disk as at most four characters, coarsening with scale (`820M`, `6.4G`, `42G`, `240G`,
    /// `2.1T`) — the middle rail has room for a reading, not for a figure. The coarseness is
    /// deliberate: two significant figures is all a "can I still work here" answer needs, and a
    /// number that only names round values cannot twitch between polls.
    static func diskLabel(freeMiB: UInt32?) -> String? {
        guard let freeMiB else { return nil }
        let gib = Double(freeMiB) / 1024
        if freeMiB < 1024 { return "\(freeMiB)M" }
        if gib < 10 { return String(format: "%.1fG", gib) }
        if gib < 1024 { return "\(Int(gib.rounded()))G" }
        return String(format: "%.1fT", gib / 1024)
    }

    /// Free space below this is worth a raised run: the machine still works, but the next container
    /// pull or clean build is the one that fails.
    static let diskWarnMiB: UInt32 = 15 * 1024
    /// Below this the host is effectively out of disk — a build will fail, and so will the editor's
    /// next save.
    static let diskCriticalMiB: UInt32 = 5 * 1024

    /// The three metric marks. Processor die, drive, memory module — Activity Monitor's own
    /// vocabulary, chosen so the three differ in SILHOUETTE (a square pinned on four edges, a slab
    /// with a spindle dot, a wide module pinned on one edge), which is the only difference that
    /// survives at the island's size.
    static let cpuSymbol: SFSymbol = .cpu
    static let diskSymbol: SFSymbol = .internaldrive
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
        let disk = diskLabel(freeMiB: pulse.diskFreeMiB).map { " · \($0) free" } ?? ""
        return " · \(labels.cpu) · \(labels.memory)\(pressure)\(disk)"
    }

    /// Metric digits: flat metadata grey while the link is healthy, climbing the alarm ladder as it
    /// degrades. Same classifier as the bedded mounts' — one dialect across all three.
    private var metricAlarm: Alarm {
        switch Self.health(isConnected: isConnected, pingMS: pingMS) {
        case .offline,
             .good: .quiet
        case .slow: .raised
        case .bad: .loud
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
                    if layout == .compact { compactBody } else { islandBody }
                }
                // BEHIND the bed, not over it: the bed is a low-alpha wash, so the hover tint
                // composites up through it and the whole island lifts as one object. An overlay
                // would instead grey the digits it is meant to make reachable.
                .background(
                    hover ? Slate.State.hover : .clear,
                    in: .rect(
                        cornerRadius: layout == .compact
                            ? Slate.Metric.radiusControl
                            : Slate.Metric.islandRadiusCompact,
                    ),
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

    /// The iOS one-line cluster (see the header note) — bedless, hugging its content.
    private var compactBody: some View {
        HStack(alignment: .center, spacing: Slate.Metric.space2) {
            // Host name carries the identity; it DIMS to tertiary when not connected — state
            // lives in the text, not a separate LED, since the metric digits carry the health.
            Text(displayHost)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(isConnected ? Slate.Text.secondary : Slate.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .frame(maxHeight: .infinity, alignment: .center)

            trailingSlot
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightControl, alignment: .center)
    }

    /// The two BEDDED mounts. The presentational layout lives in ``ConnectionStatusIsland`` (pure
    /// values in, so the snapshot rig can mount every ink state); this maps the live model onto it.
    /// The inks brighten on the needle curve — the same orchestrated moment the handshake already owns.
    private var islandBody: some View {
        let led = Self.ledState(status: status, pingMS: pingMS)
        return ConnectionStatusIsland(
            displayHost: displayHost,
            led: led,
            detail: Self.footerDetail(status: status, pingMS: pingMS),
            pulse: connection.hostPulse,
            layout: layout == .inline ? .inline : .stacked,
        )
        .animation(Slate.Anim.needle, value: led)
    }

    /// The row's trailing METRIC slot — the ping (or the short status word). The hostname to its left is
    /// the row's designated truncator; this slot always renders at ideal width.
    @ViewBuilder private var trailingSlot: some View {
        if let trailing {
            let alarm = trailing.isMetric ? metricAlarm : .quiet
            Text(trailing.text)
                .font(
                    trailing.isMetric
                        ? Slate.Typeface.instrument(Slate.Typeface.small, weight: Self.alarmWeight(alarm))
                        : .system(size: Slate.Typeface.small),
                )
                .foregroundStyle(Self.alarmInk(alarm))
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

/// The bedded island's LIVE mount — the one place either chrome surface names it.
///
/// It exists to keep the telemetry read at LEAF scope. `ConnectionTelemetry.pingMS` walks the live
/// pane sessions, so resolving it in the navigator's or the titlebar's own body would make that body
/// a dependent of every pane's ~1 Hz latency tick — re-running the sidebar's sectioning pass, or the
/// tab strip's whole `Deal`, once a second for a number neither of them draws. Reading it HERE is the
/// same contract ``SidebarLiveRow`` and ``TabStripChip`` keep with their volatile chrome.
struct ConnectionStatusMount: View {
    let store: WorkspaceStore
    let connection: AppConnection
    var onConnect: () -> Void = {}
    var layout: ConnectionCluster.Layout

    var body: some View {
        ConnectionCluster(
            connection: connection,
            pingMS: ConnectionTelemetry.pingMS(store),
            fps: ConnectionTelemetry.fps(store),
            kbps: ConnectionTelemetry.kbps(store),
            onConnect: onConnect,
            layout: layout,
        )
    }
}

/// The bedded island's PRESENTATIONAL layout — pure values in (host / ink state / detail / pulse /
/// axis), no model, so the snapshot rig mounts every state directly. Internal (not private) for the rig.
///
/// ONE bed, two axes (see ``ConnectionCluster``'s header note). `stacked` is the navigator's footer:
/// two lines spanning the island's own text rail, so the hostname starts on the exact x every project
/// row title starts on and the island reads as the last member of the list rather than a widget
/// bolted underneath. `inline` is the band: the same runs laid across, one control tall, hugging
/// their own width so the island can anchor to a corner.
struct ConnectionStatusIsland: View {
    enum Layout: Equatable {
        case stacked
        case inline
    }

    let displayHost: String
    let led: ConnectionCluster.LedState
    let detail: (text: String, isMetric: Bool)?
    /// The host machine's pulse; `nil` ⇒ no second register at all (see the header note).
    var pulse: HostPulse?
    var layout: Layout = .stacked

    /// The keyless bucket's tone. The host is NOT a project, so it must not wear a project's identity
    /// hue — the neutral bed is ΔE2000 ≥ 7.21 from every register entry, which is exactly the
    /// guarantee that says "this bed names no project".
    private var bed: Color { Slate.ProjectTint.neutralBed }

    var body: some View {
        SlateProjectIsland(
            tint: bed,
            // The footer's bed wears the sidebar's collar; the band's wears none, for the SAME
            // reason the horizontal tab strip's does not — any collar at all makes it the one taller
            // object in a band where everything else is a plain control rung.
            verticalInset: layout == .stacked ? Slate.Metric.space2 : 0,
            horizontalInset: layout == .stacked ? Slate.Metric.projectIslandInset : Slate.Metric.space2,
        ) {
            switch layout {
            case .stacked: stacked
            case .inline: inline
            }
        }
        .modifier(IslandSizing(layout: layout))
    }

    /// The FOOTER form: the link over the pulse, both on the island's text rail
    /// (``Slate/Metric/islandRail`` inside the bed's own inset — the 18pt the project rows above hold).
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            linkLine
            if let readings = ConnectionCluster.pulseReadings(pulse) {
                pulseLine(readings)
            }
        }
        .padding(.horizontal, Slate.Metric.islandRail)
    }

    /// The BAND form: identity, link and pulse laid across one control-tall row. The gaps are the
    /// grid's — a wide step between the three GROUPS (who / how far / how hard), the narrow one
    /// inside a group, so the row parses without a separator drawn anywhere.
    private var inline: some View {
        HStack(alignment: .center, spacing: Slate.Metric.space3) {
            Text(displayHost)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(led == .dim ? Slate.Text.tertiary : Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let detail {
                detailText(detail)
            }
            if let readings = ConnectionCluster.pulseReadings(pulse) {
                HStack(alignment: .center, spacing: Slate.Metric.space2) {
                    readingRuns(readings)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pulseSpoken)
            }
        }
        .frame(height: Slate.Metric.heightControl)
    }

    /// Line one — who we are talking to, and how far away it feels. On the CONTROL band, not the
    /// list's 32pt row band: the two lines are one block and have to read as a pair, and a row band
    /// under a row band put ~17pt of air between two lines that belong together.
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
                detailText(detail)
            }
        }
        .frame(height: Slate.Metric.heightControl)
    }

    /// The link's trailing slot, shared by both axes: a metric is INSTRUMENT mono — one metadata
    /// voice with the git lines and shell labels; a status WORD is prose and keeps the system face.
    private func detailText(_ detail: (text: String, isMetric: Bool)) -> some View {
        Text(detail.text)
            .font(
                detail.isMetric
                    ? Slate.Typeface.instrument(
                        Slate.Typeface.small, weight: ConnectionCluster.alarmWeight(linkAlarm),
                    )
                    : .system(size: Slate.Typeface.small),
            )
            .foregroundStyle(ConnectionCluster.alarmInk(linkAlarm))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Line two — the machine's own pulse: a mark and a number at each rail. The digits are
    /// INSTRUMENT mono (they are readings, not prose), so the pair reads as one quiet instrument
    /// under the identity rather than a second row competing with it. The line speaks its full prose
    /// to VoiceOver, which cannot see a silhouette.
    private func pulseLine(_ readings: (cpu: String, memory: String, disk: String?)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            // Spread across the island's two rails — the same leading and trailing edges line one
            // uses — so the two lines read as one block with a shared measure.
            reading(ConnectionCluster.cpuSymbol, readings.cpu, alarm: .quiet)
            Spacer(minLength: Slate.Metric.space1)
            reading(
                ConnectionCluster.memorySymbol, readings.memory,
                alarm: ConnectionCluster.memoryAlarm(pulse?.memoryPressure),
            )
            if let disk = readings.disk {
                Spacer(minLength: Slate.Metric.space1)
                reading(
                    ConnectionCluster.diskSymbol, disk,
                    alarm: ConnectionCluster.diskAlarm(freeMiB: pulse?.diskFreeMiB),
                )
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pulseSpoken)
    }

    /// The same three runs WITHOUT the rail spreaders — the band has no measure to span, so the runs
    /// simply follow each other at the grid's step.
    @ViewBuilder
    private func readingRuns(_ readings: (cpu: String, memory: String, disk: String?)) -> some View {
        reading(ConnectionCluster.cpuSymbol, readings.cpu, alarm: .quiet)
        reading(
            ConnectionCluster.memorySymbol, readings.memory,
            alarm: ConnectionCluster.memoryAlarm(pulse?.memoryPressure),
        )
        if let disk = readings.disk {
            reading(
                ConnectionCluster.diskSymbol, disk,
                alarm: ConnectionCluster.diskAlarm(freeMiB: pulse?.diskFreeMiB),
            )
        }
    }

    /// One reading: its mark, then its number, at ONE alarm — the glyph climbs WITH the digits, because a
    /// half-raised readout reads as a rendering bug rather than a warning. The mark sits a step above the
    /// digits (`footnote`) so a drawing built from strokes holds its silhouette next to type built from
    /// stems.
    private func reading(_ symbol: SFSymbol, _ value: String, alarm: ConnectionCluster.Alarm) -> some View {
        let weight = ConnectionCluster.alarmWeight(alarm)
        return HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space1) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.footnote, weight: weight))
                .symbolRenderingMode(.monochrome)
            Text(value)
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: weight))
        }
        .foregroundStyle(ConnectionCluster.alarmInk(alarm))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The pulse as words, for the readers that get no glyph.
    private var pulseSpoken: String {
        guard let labels = ConnectionCluster.pulseLabels(pulse) else { return "" }
        let disk = ConnectionCluster.diskLabel(freeMiB: pulse?.diskFreeMiB).map { ", \($0) free" } ?? ""
        return "\(labels.cpu), \(labels.memory)\(disk)"
    }

    /// The ping digits climb the alarm ladder as the link degrades; a status WORD is prose, and prose
    /// that has already said "disconnected" gains nothing from being shouted.
    private var linkAlarm: ConnectionCluster.Alarm {
        guard let detail, detail.isMetric else { return .quiet }
        return ConnectionCluster.linkAlarm(led)
    }

    /// ``SlateProjectIsland`` always spans its container (a sidebar bed has to reach both gutters).
    /// The footer wants exactly that; the band's island has to HUG instead, or it would stretch
    /// across the whole strip and stop reading as a corner anchor.
    private struct IslandSizing: ViewModifier {
        let layout: Layout

        func body(content: Content) -> some View {
            switch layout {
            case .stacked: content
            case .inline: content.fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

#endif
