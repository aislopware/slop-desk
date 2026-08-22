// ConnectionReading — the link island's whole content, as VALUES, below either UI.
//
// The island is drawn three ways: the navigator's foot (two lines on a bed), the titlebar band (one
// line on the same bed, one control tall) and the phone's navigation toolbar (the link line alone,
// bedless). With docs/56 stage D the first two became AppKit and the third stayed SwiftUI, so every
// decision the three share had to stop being a static on a `View` — and with increment 83 they stop
// being SWIFT. This file is the face; the rules are `slopdesk_workspace::connection`:
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
// views" split ``Slate/Native`` and `AgentReadout` already are. What stays HERE, in Swift, is the
// OPTIONALITY: a `nil` ping, a `nil` pulse and an unreadable volume are absences the C boundary
// spells as presence flags, and this is where the two spellings meet.

import CSlopDeskFFI
import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// How the link is doing, as one fused state. The name is historical — the lamp itself is gone; this
/// classifies the island's TEXT inks.
package enum ConnectionLed: Equatable, Sendable, CaseIterable {
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
package enum NetworkHealth: Equatable, Sendable, CaseIterable {
    case offline
    case good
    case slow
    case bad
}

// ``ConnectionAlarm`` — the quiet/raised/loud rung — is `SlopDeskWorkspaceModel`'s, because
// `SlopDeskSlate` resolves it to an ink and a weight and the design floor must not name this whole
// reading to do it.

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
        wsAnswer { slopdesk_connection_metric_symbol(code, $0, $1) } ?? ""
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
    ///
    /// The `nil` is this side's: the door takes a figure and answers a figure, because "no sample
    /// yet" is a fact about the client's clock and not about how a millisecond count is written.
    package static func pingLabel(_ pingMS: Double?) -> String? {
        pingMS.flatMap { ms in wsAnswer { slopdesk_connection_ping_label(ms, $0, $1) } }
    }

    package static func bitrateLabel(kbps: Int) -> String {
        wsAnswer { slopdesk_connection_bitrate_label(Int64(kbps), $0, $1) } ?? ""
    }

    /// The stream numbers as tooltip detail (" · 60 fps · 12.4 Mbps"), or empty when neither exists.
    /// They are deliberately absent from every visible row: appending them made the trailing text
    /// long enough to truncate the hostname out of its own line — the identity lost to telemetry.
    package static func tooltipDetail(fps: Int?, kbps: Int?) -> String {
        wsAnswer {
            slopdesk_connection_tooltip_detail(
                fps != nil, Int64(fps ?? 0), kbps != nil, Int64(kbps ?? 0), $0, $1,
            )
        } ?? ""
    }

    package static func health(isConnected: Bool, pingMS: Double?) -> NetworkHealth {
        NetworkHealth(
            code: slopdesk_connection_health(isConnected, pingMS != nil, pingMS ?? 0),
        )
    }

    /// Connected rides the ping classifier; a dial in flight is `dialing`; every settled
    /// not-connected state is `dim`.
    package static func ledState(status: ConnectionStatus, pingMS: Double?) -> ConnectionLed {
        ConnectionLed(
            code: slopdesk_connection_led(status.terms.code, pingMS != nil, pingMS ?? 0),
        )
    }

    /// The LINK's alarm: a slow round trip is worth knowing, a bad one is worth acting on. Every
    /// not-connected state is quiet — an instrument with nothing to measure has nothing to shout
    /// about, and the status WORD in the slot already says so.
    package static func linkAlarm(_ led: ConnectionLed) -> ConnectionAlarm {
        ConnectionAlarm(code: slopdesk_connection_link_alarm(led.code))
    }

    /// Where the link's reading is mounted — the ONE thing about the trailing slot the two shells
    /// genuinely disagree on, named rather than re-derived.
    package enum ConnectionMount: Sendable, Equatable {
        /// A bed cut out of the chrome (the Mac's titlebar island). A bed is already on screen, so an
        /// empty right edge inside it reads as broken.
        case bedded
        /// A bedless run of text in a toolbar (the phone's pill). There is no plate for a gap to appear
        /// in, so a slot that has not filled yet reads as nothing at all rather than as a fault.
        case compact

        var code: UInt32 {
            switch self {
            case .bedded: SLOPDESK_CONNECTION_MOUNT_BEDDED
            case .compact: SLOPDESK_CONNECTION_MOUNT_COMPACT
            }
        }
    }

    /// The link's TRAILING slot: the mono ping metric while connected, else the short status word —
    /// never a stale ping.
    ///
    /// The one branch `mount` decides is CONNECTED-BUT-UNSAMPLED, the beat before the first ping
    /// lands. A ``ConnectionMount/bedded`` reading falls back to the status word, because a connected
    /// island with an empty right edge reads as broken; a ``ConnectionMount/compact`` one stays
    /// silent. That is a layout ruling about the two mounts, not two answers to what the link says —
    /// which is why it is a parameter to the rule rather than a second copy of it at the pill.
    ///
    /// The door answers a SOURCE, not the text: the two sources want different payloads (a figure
    /// this side already has, and a word the presenter delivers) and this side is holding both.
    package static func trailingDetail(
        status: ConnectionStatus, pingMS: Double?, mount: ConnectionMount,
    ) -> (text: String, isMetric: Bool)? {
        switch slopdesk_connection_trailing_slot(status.terms.code, pingMS != nil, mount.code) {
        case SLOPDESK_CONNECTION_TRAILING_PING:
            pingLabel(pingMS).map { ($0, true) }
        case SLOPDESK_CONNECTION_TRAILING_STATUS_WORD:
            (ConnectionPresenter.shortLabel(for: status), false)
        default:
            nil
        }
    }

    /// Whether a manual Retry affordance applies — only the GIVE-UP states. A campaign still in
    /// flight has a retry already running, and offering a second one races it.
    package static func showsRetry(_ status: ConnectionStatus) -> Bool {
        slopdesk_connection_shows_retry(status.terms.code)
    }

    /// The trailing slot's alarm: the ping digits climb as the link degrades; a status WORD is prose,
    /// and prose that has already said "disconnected" gains nothing from being shouted.
    package static func detailAlarm(
        detail: (text: String, isMetric: Bool)?, led: ConnectionLed,
    ) -> ConnectionAlarm {
        let slot: UInt32 =
            switch detail?.isMetric {
            case true: SLOPDESK_CONNECTION_TRAILING_PING
            case false: SLOPDESK_CONNECTION_TRAILING_STATUS_WORD
            default: SLOPDESK_CONNECTION_TRAILING_ABSENT
            }
        return ConnectionAlarm(code: slopdesk_connection_detail_alarm(slot, led.code))
    }

    // MARK: - The machine

    /// MEMORY takes the KERNEL's pressure verdict, not the percent — see this file's header.
    package static func memoryAlarm(_ pressure: MetadataCodec.MemoryPressure?) -> ConnectionAlarm {
        ConnectionAlarm(
            code: slopdesk_connection_memory_alarm(pressure?.rawValue ?? 0),
        )
    }

    /// DISK climbs on BYTES LEFT, the only reading that answers "can I still work here". An
    /// unreadable volume is quiet, not alarmed — no reading is not bad news.
    package static func diskAlarm(freeMiB: UInt32?) -> ConnectionAlarm {
        ConnectionAlarm(
            code: slopdesk_connection_disk_alarm(freeMiB != nil, freeMiB ?? 0),
        )
    }

    /// Free disk as at most four characters, coarsening with scale (`820M`, `6.4G`, `42G`, `240G`,
    /// `2.1T`) — the middle rail has room for a reading, not for a figure. The coarseness is
    /// deliberate: two significant figures is all a "can I still work here" answer needs, and a
    /// number that only names round values cannot twitch between polls.
    package static func diskLabel(freeMiB: UInt32?) -> String? {
        freeMiB.flatMap { mib in wsAnswer { slopdesk_connection_disk_label(mib, $0, $1) } }
    }

    /// The pulse as it is DRAWN, in the order it is drawn — cpu, memory, disk: fastest-moving first,
    /// so the eye scans from the reading that is about right now toward the one that is about next
    /// week. It also keeps the two PERCENTS adjacent, which is the pair a glance actually compares.
    ///
    /// EMPTY (not a row of dashes) until a reading exists: an instrument showing "cpu —" advertises
    /// breakage, while an island that grows a second line on connect just reports. A host that could
    /// not read its volume drops the DISK run alone — one missing metric closes its gap.
    package static func metricRuns(_ pulse: HostPulse?) -> [ConnectionMetricRun] {
        runs(pulse, promotedOnly: false)
    }

    /// The pulse as a ONE-LINE mount draws it: the runs that have earned a place, in ``metricRuns``'
    /// own order, and NOTHING at all while the host is calm.
    ///
    /// The gate is the alarm ladder read as a yes/no — `quiet` is the metadata grey a healthy
    /// reading rests in — and not a second threshold anyone has to keep in step with the first. It
    /// is the door's `promoted_only` flag rather than a filter here, so the two mounts cannot come
    /// to differ about which runs are worth a line.
    ///
    /// The phone's toolbar is one line, and the ambient question — how hard is the host working —
    /// really is the desktop's: a mount that cannot afford three resting readings should not carry a
    /// worse version of them. What it must never do is go SILENT on a state the bedded island
    /// escalates, because a memory verdict of `critical` or a volume with no room left is not
    /// ambient, it is the reason the next build will fail. So the calm runs stay behind and the
    /// alarmed ones promote themselves — the reading appears exactly when there is something to see,
    /// which is also what makes it worth looking at.
    package static func promotedRuns(_ pulse: HostPulse?) -> [ConnectionMetricRun] {
        runs(pulse, promotedOnly: true)
    }

    // MARK: - The words

    /// The pulse as words, for the readers that get no glyph.
    package static func pulseSpoken(_ pulse: HostPulse?) -> String {
        prose(pulse).spoken
    }

    /// The pulse as TOOLTIP prose — the exact numbers plus the pressure verdict the visible line only
    /// hints at through ink. Empty when there is no reading.
    package static func pulseTooltip(_ pulse: HostPulse?) -> String {
        prose(pulse).tooltip
    }

    /// The island's hover text and its accessibility label: host + headline, plus the stream numbers
    /// while connected — the on-demand home of the detail the visible row deliberately drops.
    ///
    /// The HOST NAME never crosses. It is an identity the caller is already holding, and a door that
    /// took it would be interpolating a string this side can interpolate for free.
    package static func help(
        host: String, status: ConnectionStatus, fps: Int?, kbps: Int?, pulse: HostPulse?,
    ) -> String {
        let connected = if case .connected = status { true } else { false }
        return "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
            + (connected ? tooltipDetail(fps: fps, kbps: kbps) : "")
            + pulseTooltip(pulse)
    }

    // MARK: - The crossings

    /// The drawn runs, in ONE crossing: `[UInt16 count]`, then a role, a rung and a length-prefixed
    /// figure per run. A door per run would have been three crossings inside a SwiftUI body.
    private static func runs(_ pulse: HostPulse?, promotedOnly: Bool) -> [ConnectionMetricRun] {
        guard let pulse else { return [] }
        let blob = wsAnswerBytes { slopdesk_connection_metric_runs(pulse.crossing, promotedOnly, $0, $1) }
        guard blob.count >= 2 else { return [] }
        let count = Int(blob[0]) << 8 | Int(blob[1])
        var cursor = 2
        var answer: [ConnectionMetricRun] = []
        answer.reserveCapacity(count)
        for _ in 0..<count {
            guard blob.count - cursor >= 6 else { break }
            let metric = ConnectionMetric(code: blob[cursor])
            let alarm = ConnectionAlarm(code: UInt32(blob[cursor + 1]))
            var length = 0
            for offset in 2..<6 { length = length << 8 | Int(blob[cursor + offset]) }
            cursor += 6
            guard blob.count - cursor >= length else { break }
            // swiftlint:disable:next optional_data_string_conversion
            let value = String(decoding: blob[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            answer.append(ConnectionMetricRun(metric: metric, value: value, alarm: alarm))
        }
        return answer
    }

    /// The pulse's two prose registers in ONE crossing — spoken, then tooltip. The surfaces that want
    /// prose want a hover string and an accessibility label from the same sample.
    private static func prose(_ pulse: HostPulse?) -> (spoken: String, tooltip: String) {
        guard let pulse else { return ("", "") }
        let blob = wsAnswerBytes { slopdesk_connection_pulse_prose(pulse.crossing, $0, $1) }
        let parts = wsRuns(blob, count: 2)
        return (spoken: parts[0], tooltip: parts[1])
    }
}

// MARK: - The vocabulary the doors speak

private extension HostPulse {
    /// This sample as the door's flat struct. `diskFreeMiB`'s absence becomes a presence FLAG rather
    /// than a sentinel, because zero free bytes is the loudest real reading there is.
    var crossing: SlopDeskHostPulse {
        SlopDeskHostPulse(
            cpu_percent: UInt32(max(0, cpuPercent)),
            memory_percent: UInt32(max(0, memoryPercent)),
            memory_pressure: memoryPressure.rawValue,
            disk_free_mib: diskFreeMiB ?? 0,
            has_disk: diskFreeMiB != nil,
        )
    }
}

private extension ConnectionLed {
    init(code: UInt32) {
        switch code {
        case SLOPDESK_CONNECTION_LED_DIALING: self = .dialing
        case SLOPDESK_CONNECTION_LED_GOOD: self = .good
        case SLOPDESK_CONNECTION_LED_SLOW: self = .slow
        case SLOPDESK_CONNECTION_LED_BAD: self = .bad
        default: self = .dim
        }
    }

    var code: UInt32 {
        switch self {
        case .dim: SLOPDESK_CONNECTION_LED_DIM
        case .dialing: SLOPDESK_CONNECTION_LED_DIALING
        case .good: SLOPDESK_CONNECTION_LED_GOOD
        case .slow: SLOPDESK_CONNECTION_LED_SLOW
        case .bad: SLOPDESK_CONNECTION_LED_BAD
        }
    }
}

private extension NetworkHealth {
    init(code: UInt32) {
        switch code {
        case SLOPDESK_CONNECTION_HEALTH_GOOD: self = .good
        case SLOPDESK_CONNECTION_HEALTH_SLOW: self = .slow
        case SLOPDESK_CONNECTION_HEALTH_BAD: self = .bad
        default: self = .offline
        }
    }
}

private extension ConnectionAlarm {
    init(code: UInt32) {
        switch code {
        case SLOPDESK_CONNECTION_ALARM_RAISED: self = .raised
        case SLOPDESK_CONNECTION_ALARM_LOUD: self = .loud
        default: self = .quiet
        }
    }
}

private extension ConnectionMetric {
    init(code: UInt8) {
        switch UInt32(code) {
        case SLOPDESK_CONNECTION_METRIC_MEMORY: self = .memory
        case SLOPDESK_CONNECTION_METRIC_DISK: self = .disk
        default: self = .cpu
        }
    }

    var code: UInt32 {
        switch self {
        case .cpu: SLOPDESK_CONNECTION_METRIC_CPU
        case .memory: SLOPDESK_CONNECTION_METRIC_MEMORY
        case .disk: SLOPDESK_CONNECTION_METRIC_DISK
        }
    }
}
