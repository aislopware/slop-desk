// ConnectionReading — the link island's whole content, as VALUES, below either UI.
//
// The island is drawn three ways: the navigator's foot (two lines on a bed), the titlebar band (one
// line on the same bed, one control tall) and the phone's navigation toolbar (the link line alone,
// bedless). With docs/56 stage D the first two became AppKit and the third stayed SwiftUI, so every
// decision the three share had to stop being a static on a `View`:
//
//   • WHICH STATE the link is in (``ConnectionLed``) and how loud each run is allowed to be
//     (``ConnectionAlarm``) — a two-channel ladder, brightness and weight, with NO hue. A row of
//     digits has nothing to hang a palette on, and an instrument that lights a different colour per
//     fault asks the eye to learn one before it can read a number.
//   • WHAT each run SAYS — the ping label, the short status word, the three pulse readings and the
//     four-character disk figure.
//   • WHICH readings may CLIMB, and on what evidence: the link on its round trip, memory on the
//     KERNEL's pressure verdict (a high memory percent is ordinary on a healthy Mac), disk on an
//     ABSOLUTE byte threshold (a percent lies in both directions — 2% of 4 TB still builds, 8% of
//     128 GB does not). CPU never climbs: a build pegging the host is what the machine is FOR, and a
//     readout that shouts every compile teaches the eye to ignore it.
//   • WHICH runs a ONE-LINE mount may PROMOTE — ``ConnectionReading/promotedRuns(_:)``. A bedded
//     island has a second line and draws all three at rest; a navigation toolbar has one line and
//     can only afford the runs that have something to say. That is the SAME quiet/raised/loud ladder
//     read as a gate rather than as ink, so no mount can invent its own idea of what an alarm is.
//
// What stays in each view layer is the INK and the GLYPH — an alarm rung resolved to a `Color` or an
// `NSColor`, a metric role resolved to that framework's symbol — which is the same "one value, two
// views" split ``Slate/Native`` and `AgentReadout` already are.

import SlopDeskProtocol
import SlopDeskWorkspaceCore

/// How the link is doing, as one fused state. The name is historical — the lamp itself is gone; this
/// classifies the island's TEXT inks.
package enum ConnectionLed: Equatable, Sendable {
    /// Every settled not-connected state. A stale ping must never brighten it.
    case dim
    /// A dial in flight — a first connect OR a supervised reconnect.
    case dialing
    case good
    case slow
    case bad
}

/// The round trip, classified. Kept apart from ``ConnectionLed`` because the phone's compact mount
/// reads health directly without ever asking which dial state produced it.
package enum NetworkHealth: Equatable, Sendable {
    case offline
    case good
    case slow
    case bad
}

/// How loud one reading is allowed to be — the island's whole state axis, and the only one it has.
/// `quiet` is the metadata grey every healthy reading rests in, `raised` is worth knowing about,
/// `loud` is worth acting on.
package enum ConnectionAlarm: Equatable, Sendable {
    case quiet
    case raised
    case loud
}

/// Which of the three machine readings a run is. The GLYPH is each framework's to resolve; what is
/// named here is the role, so both halves pick the same drawing for the same number.
///
/// Processor die, memory module, drive — Activity Monitor's own vocabulary, chosen so the three
/// differ in SILHOUETTE (a square pinned on four edges, a wide module pinned on one, a slab with a
/// spindle dot), which is the only difference that survives at the island's size.
package enum ConnectionMetric: Hashable, Sendable, CaseIterable {
    case cpu
    case memory
    case disk

    /// The SF Symbol that names this role. A NAME rather than a typed symbol because the two
    /// frameworks want different types out of it and the value here is the DRAWING — which is the
    /// part that must not differ, or one surface would name the same number with a mark the other
    /// spends on something else.
    package var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        }
    }
}

/// One drawn run of the machine's pulse: its role, its number, and how loud it is allowed to be.
package struct ConnectionMetricRun: Equatable, Sendable {
    package let metric: ConnectionMetric
    package let value: String
    package let alarm: ConnectionAlarm

    package init(metric: ConnectionMetric, value: String, alarm: ConnectionAlarm) {
        self.metric = metric
        self.value = value
        self.alarm = alarm
    }
}

package enum ConnectionReading {
    // MARK: - The link

    /// The one visible metric: the ping. `nil` until the first sample.
    package static func pingLabel(_ pingMS: Double?) -> String? {
        pingMS.map { "\(Int($0.rounded())) ms" }
    }

    package static func bitrateLabel(kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    /// The stream numbers as tooltip detail (" · 60 fps · 12.4 Mbps"), or empty when neither exists.
    /// They are deliberately absent from every visible row: appending them made the trailing text
    /// long enough to truncate the hostname out of its own line — the identity lost to telemetry.
    package static func tooltipDetail(fps: Int?, kbps: Int?) -> String {
        var extras: [String] = []
        if let fps { extras.append("\(fps) fps") }
        if let kbps { extras.append(bitrateLabel(kbps: kbps)) }
        return extras.map { " · \($0)" }.joined()
    }

    package static func health(isConnected: Bool, pingMS: Double?) -> NetworkHealth {
        guard isConnected else { return .offline }
        guard let pingMS else { return .good }
        if pingMS <= 80 { return .good }
        if pingMS <= 180 { return .slow }
        return .bad
    }

    /// Connected rides the ping classifier; a dial in flight is `dialing`; every settled
    /// not-connected state is `dim`.
    package static func ledState(status: ConnectionStatus, pingMS: Double?) -> ConnectionLed {
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

    /// The LINK's alarm: a slow round trip is worth knowing, a bad one is worth acting on. Every
    /// not-connected state is quiet — an instrument with nothing to measure has nothing to shout
    /// about, and the status WORD in the slot already says so.
    package static func linkAlarm(_ led: ConnectionLed) -> ConnectionAlarm {
        switch led {
        case .slow: .raised
        case .bad: .loud
        default: .quiet
        }
    }

    /// The island's TRAILING slot: the mono ping metric while connected (falling back to the status
    /// word before the first sample — a connected island with an empty right edge reads as broken,
    /// which is why the bedded mounts speak where the compact one stays silent), else the short
    /// status word — never a stale ping.
    package static func footerDetail(
        status: ConnectionStatus, pingMS: Double?,
    ) -> (text: String, isMetric: Bool)? {
        if case .connected = status, let label = pingLabel(pingMS) { return (label, true) }
        return (ConnectionPresenter.shortLabel(for: status), false)
    }

    /// Whether a manual Retry affordance applies — only the GIVE-UP states. A campaign still in
    /// flight has a retry already running, and offering a second one races it.
    package static func showsRetry(_ status: ConnectionStatus) -> Bool {
        switch status {
        case .failed,
             .unreachable: true
        default: false
        }
    }

    /// The trailing slot's alarm: the ping digits climb as the link degrades; a status WORD is prose,
    /// and prose that has already said "disconnected" gains nothing from being shouted.
    package static func detailAlarm(
        detail: (text: String, isMetric: Bool)?, led: ConnectionLed,
    ) -> ConnectionAlarm {
        guard let detail, detail.isMetric else { return .quiet }
        return linkAlarm(led)
    }

    // MARK: - The machine

    /// MEMORY takes the KERNEL's pressure verdict, not the percent — see this file's header.
    package static func memoryAlarm(_ pressure: MetadataCodec.MemoryPressure?) -> ConnectionAlarm {
        switch pressure {
        case .warn: .raised
        case .critical: .loud
        default: .quiet
        }
    }

    /// DISK climbs on BYTES LEFT, the only reading that answers "can I still work here". An
    /// unreadable volume is quiet, not alarmed — no reading is not bad news.
    package static func diskAlarm(freeMiB: UInt32?) -> ConnectionAlarm {
        guard let freeMiB else { return .quiet }
        if freeMiB < diskCriticalMiB { return .loud }
        if freeMiB < diskWarnMiB { return .raised }
        return .quiet
    }

    /// Free space below this is worth a raised run: the machine still works, but the next container
    /// pull or clean build is the one that fails.
    package static let diskWarnMiB: UInt32 = 15 * 1024
    /// Below this the host is effectively out of disk — a build will fail, and so will the editor's
    /// next save.
    package static let diskCriticalMiB: UInt32 = 5 * 1024

    /// Free disk as at most four characters, coarsening with scale (`820M`, `6.4G`, `42G`, `240G`,
    /// `2.1T`) — the middle rail has room for a reading, not for a figure. The coarseness is
    /// deliberate: two significant figures is all a "can I still work here" answer needs, and a
    /// number that only names round values cannot twitch between polls.
    package static func diskLabel(freeMiB: UInt32?) -> String? {
        guard let freeMiB else { return nil }
        let gib = Double(freeMiB) / 1024
        if freeMiB < 1024 { return "\(freeMiB)M" }
        if gib < 10 { return String(format: "%.1fG", gib) }
        if gib < 1024 { return "\(Int(gib.rounded()))G" }
        return String(format: "%.1fT", gib / 1024)
    }

    /// The pulse as it is DRAWN, in the order it is drawn — cpu, memory, disk: fastest-moving first,
    /// so the eye scans from the reading that is about right now toward the one that is about next
    /// week. It also keeps the two PERCENTS adjacent, which is the pair a glance actually compares.
    ///
    /// EMPTY (not a row of dashes) until a reading exists: an instrument showing "cpu —" advertises
    /// breakage, while an island that grows a second line on connect just reports. A host that could
    /// not read its volume drops the DISK run alone — one missing metric closes its gap.
    package static func metricRuns(_ pulse: HostPulse?) -> [ConnectionMetricRun] {
        guard let pulse else { return [] }
        var runs = [
            // CPU is deliberately never raised — see this file's header.
            ConnectionMetricRun(metric: .cpu, value: "\(pulse.cpuPercent)%", alarm: .quiet),
            ConnectionMetricRun(
                metric: .memory, value: "\(pulse.memoryPercent)%",
                alarm: memoryAlarm(pulse.memoryPressure),
            ),
        ]
        if let disk = diskLabel(freeMiB: pulse.diskFreeMiB) {
            runs.append(ConnectionMetricRun(
                metric: .disk, value: disk, alarm: diskAlarm(freeMiB: pulse.diskFreeMiB),
            ))
        }
        return runs
    }

    /// Whether a run has earned a place on a mount with ONE line to spend. The ladder already draws
    /// the boundary — `quiet` is the metadata grey a healthy reading rests in — so the gate is that
    /// boundary read as a yes/no, not a second threshold anyone has to keep in step with the first.
    package static func promotes(_ alarm: ConnectionAlarm) -> Bool { alarm != .quiet }

    /// The pulse as a ONE-LINE mount draws it: the runs that are ``promotes(_:)``, in ``metricRuns``'
    /// own order, and NOTHING at all while the host is calm.
    ///
    /// The phone's toolbar is one line, and the ambient question — how hard is the host working —
    /// really is the desktop's: a mount that cannot afford three resting readings should not carry a
    /// worse version of them. What it must never do is go SILENT on a state the bedded island
    /// escalates, because a memory verdict of `critical` or a volume with no room left is not
    /// ambient, it is the reason the next build will fail. So the calm runs stay behind and the
    /// alarmed ones promote themselves — the reading appears exactly when there is something to see,
    /// which is also what makes it worth looking at.
    package static func promotedRuns(_ pulse: HostPulse?) -> [ConnectionMetricRun] {
        metricRuns(pulse).filter { promotes($0.alarm) }
    }

    // MARK: - The words

    /// The second register spoken as PROSE — where the metric names are words because there is room
    /// for words. `nil` until a reading exists.
    package static func pulseLabels(_ pulse: HostPulse?) -> (cpu: String, memory: String)? {
        guard let pulse else { return nil }
        return ("cpu \(pulse.cpuPercent)%", "mem \(pulse.memoryPercent)%")
    }

    /// The pulse as words, for the readers that get no glyph.
    package static func pulseSpoken(_ pulse: HostPulse?) -> String {
        guard let labels = pulseLabels(pulse) else { return "" }
        let disk = diskLabel(freeMiB: pulse?.diskFreeMiB).map { ", \($0) free" } ?? ""
        return "\(labels.cpu), \(labels.memory)\(disk)"
    }

    /// The pulse as TOOLTIP prose — the exact numbers plus the pressure verdict the visible line only
    /// hints at through ink. Empty when there is no reading.
    package static func pulseTooltip(_ pulse: HostPulse?) -> String {
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

    /// The island's hover text and its accessibility label: host + headline, plus the stream numbers
    /// while connected — the on-demand home of the detail the visible row deliberately drops.
    package static func help(
        host: String, status: ConnectionStatus, fps: Int?, kbps: Int?, pulse: HostPulse?,
    ) -> String {
        let connected = if case .connected = status { true } else { false }
        return "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
            + (connected ? tooltipDetail(fps: fps, kbps: kbps) : "")
            + pulseTooltip(pulse)
    }
}
