// ConnectionPill — the link's status surface on the PHONE: the link line alone, bedless, in the
// navigation toolbar.
//
//   mac-studio    12 ms                  ← who, and how far away
//   mac-studio    12 ms   ▤ 97%  ▨ 3.1G  ← …and what is about to stop the host working
//
// One line, because a navigation toolbar is one line. The MACHINE's pulse — the cpu / memory / disk
// run the Mac's island carries under the identity — is here on the ALARM RUNGS ONLY
// (``ConnectionReading/promotedRuns(_:)``). The half of the old argument that still holds: a phone
// toolbar has room for the answer to "am I connected, and is it fast", and the AMBIENT question —
// how hard is the host working, right now, at rest — is the desktop's, which has a second line to
// spend on it. The half that did not: a `critical` memory verdict or a volume with nothing left on it
// is not ambient. The Mac ESCALATES those, and a phone that could only stay silent about them was
// missing a capability, not a layout. So a calm host adds nothing to this row and an alarmed one
// grows exactly the runs that are alarmed — which is also why they are worth a glance when they
// appear. The resting numbers keep their one home here, the accessibility label. And it is BEDLESS:
// a toolbar has no ground for a bed to be cut out of.
//
// It is silent (rather than saying "connected") in the beat before the first ping sample lands, which
// is the one place its copy differs from the Mac's — the bedded island there speaks, because a
// connected island with an empty right edge reads as broken, while a toolbar item that has not
// appeared yet reads as nothing at all.
//
// ⚠️ The Mac's two mounts are AppKit now (``SlopDeskMacUI/MacConnectionIsland``, docs/56 stage D).
// That is not the banned duplicate: every WORD, every threshold and every alarm rung both halves read
// is ``ConnectionReading``'s, one floor down, and the ALARM'S PALETTE (docs/56 batch 3) is
// ``Slate/connectionAlarmInk(_:)`` / ``Slate/connectionAlarmWeight(_:)`` — one shared switch each
// framework reads its own spelling of, the same "one value, two views" split ``Slate/Native`` and
// ``AgentReadout`` already are. What is NOT allowed is a second answer to what the ping says or when a
// reading climbs; there is no such answer in this file.
//
// The link's visible metric is the ping alone. Appending fps/kbps made the trailing text long enough
// to truncate the hostname out of its own row — the identity lost to telemetry. Those, and the pulse
// numbers no rung has promoted, live in the label ``ConnectionReading/help(host:status:fps:kbps:pulse:)``
// builds — which is the TOOLTIP on the Mac and, on a device with no pointer to hover, is what
// VoiceOver reads. Tap → Connect editor; give-up → Retry.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct ConnectionPill: View {
    let connection: AppConnection
    var pingMS: Double?
    /// Stream cadence/bitrate of the active video pane — TOOLTIP-ONLY detail (see the header note).
    var fps: Int?
    var kbps: Int?
    var onConnect: () -> Void = {}

    @State private var hover = false

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }
    /// Short hostname the chrome speaks ("congs-mac-studio"); raw target only while unresolved.
    private var displayHost: String { connection.hostDisplayName ?? host }
    private var isConnected: Bool { if case .connected = status { true } else { false } }

    /// Metric digits: flat metadata grey while the link is healthy, climbing the ladder as it degrades.
    private var metricAlarm: ConnectionAlarm {
        switch ConnectionReading.health(isConnected: isConnected, pingMS: pingMS) {
        case .offline,
             .good: .quiet
        case .slow: .raised
        case .bad: .loud
        }
    }

    /// Connected: the ping alone (or nothing before the first sample). Else the short status word.
    ///
    /// The whole reading is ``ConnectionReading/trailingDetail(status:pingMS:mount:)``'s, the same door
    /// the Mac's island calls — `.compact` is what buys the silence this file's header argues for, and
    /// it is a named mount rather than a second copy of the rule.
    private var trailing: (text: String, isMetric: Bool)? {
        ConnectionReading.trailingDetail(status: status, pingMS: pingMS, mount: .compact)
    }

    private var helpText: String {
        ConnectionReading.help(
            host: host, status: status, fps: fps, kbps: kbps, pulse: connection.hostPulse,
        )
    }

    /// The machine's pulse, cut to what one line can carry: the runs on an alarm rung, none while the
    /// host is calm. The GATE is ``ConnectionReading/promotedRuns(_:)``, one floor down — this half
    /// only decides which glyph and which ink draw the rung it is handed.
    private var promoted: [ConnectionMetricRun] {
        ConnectionReading.promotedRuns(connection.hostPulse)
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Button(action: onConnect) {
                HStack(alignment: .center, spacing: Slate.Metric.space2) {
                    // The hostname carries the identity; it DIMS to tertiary when not connected —
                    // state lives in the text, not a separate LED, since the metric digits carry the
                    // health. It is also the row's designated truncator: a long host gives way, the
                    // short metric never does.
                    Text(displayHost)
                        .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                        .foregroundStyle(isConnected ? Slate.Text.secondary : Slate.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .frame(maxHeight: .infinity, alignment: .center)
                    trailingSlot
                    pulseSlot
                }
                .padding(.horizontal, Slate.Metric.space2)
                .frame(height: Slate.Metric.heightControl, alignment: .center)
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

            if ConnectionReading.showsRetry(status) {
                retryButton
            }
        }
    }

    /// The trailing METRIC slot — a metric is INSTRUMENT mono (one metadata voice with the git lines
    /// and shell labels); a status WORD is prose and keeps the system face.
    @ViewBuilder private var trailingSlot: some View {
        if let trailing {
            let alarm = trailing.isMetric ? metricAlarm : ConnectionAlarm.quiet
            Text(trailing.text)
                .font(
                    trailing.isMetric
                        ? Slate.Typeface.instrument(
                            Slate.Typeface.small, weight: Slate.connectionAlarmWeight(alarm),
                        )
                        : .system(size: Slate.Typeface.small),
                )
                .foregroundStyle(Slate.connectionAlarmInk(alarm))
                .lineLimit(1)
                .transition(.opacity.animation(isConnected ? Slate.Anim.needle.delay(0.08) : nil))
                // Ideal width always — squeezing a short readout into `…` would defeat the
                // instrument.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(0)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    /// The PULSE slot — the promoted runs, in ``ConnectionReading/metricRuns(_:)``' own order, so the
    /// phone never reorders what the Mac's island reads left to right. Empty on a calm host, which is
    /// most of the time: the row it lives in is the ping's, and a reading that is only there when it
    /// is an alarm costs nothing at rest.
    ///
    /// One gap, `space2`, both between the ping and the pulse and inside it — where the Mac's band
    /// mount spends the wide step between its three GROUPS. There is nothing to group here: at rest
    /// the pulse is absent, so the row is never three things that have to be told apart, and a wider
    /// step would only push the alarm further from the identity it belongs to.
    private var pulseSlot: some View {
        HStack(alignment: .center, spacing: Slate.Metric.space2) {
            ForEach(promoted, id: \.metric) { run in
                metricRun(run)
            }
        }
    }

    /// One promoted run: its mark, then its number, at ONE alarm — the glyph climbs WITH the digits,
    /// because a half-raised readout reads as a rendering bug rather than as a warning. The mark sits
    /// a step above the digits (`footnote`) so a drawing built from strokes holds its silhouette next
    /// to type built from stems. Both are the Mac run's rules; the SYMBOL is the role's, one floor
    /// down, so the two halves cannot name the same number with different marks.
    private func metricRun(_ run: ConnectionMetricRun) -> some View {
        let weight = Slate.connectionAlarmWeight(run.alarm)
        let ink = Slate.connectionAlarmInk(run.alarm)
        return HStack(alignment: .center, spacing: Slate.Metric.space1) {
            Image(systemName: run.metric.symbolName)
                .font(.system(size: Slate.Typeface.footnote, weight: weight))
            Text(run.value)
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: weight))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        // Ideal width always, like the ping: an alarm squeezed into `…` is not an alarm.
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(0)
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true) // the pill speaks the whole pulse as prose in its own label
    }

    /// The give-up Retry affordance.
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
#endif
