// ConnectionPill — the link's status surface on the PHONE: the link line alone, bedless, in the
// navigation toolbar.
//
//   mac-studio    12 ms      ← who, and how far away
//
// One line, because a navigation toolbar is one line. The MACHINE's pulse — the cpu / memory / disk
// run the Mac's island carries under the identity — is deliberately absent: a phone toolbar has room
// for the answer to "am I connected, and is it fast", and the readings that answer "how hard is the
// host working" are the desktop's question. And it is BEDLESS: a toolbar has no ground for a bed to be
// cut out of.
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
// The visible metric is the ping alone. Appending fps/kbps made the trailing text long enough to
// truncate the hostname out of its own row — the identity lost to telemetry. Those (and the exact
// pulse numbers) live in the TOOLTIP with the raw target. Tap → Connect editor; give-up → Retry.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
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

    /// Connected: the ping alone (or nil before the first sample). Else the short status word.
    private var trailing: (text: String, isMetric: Bool)? {
        if isConnected {
            return ConnectionReading.pingLabel(pingMS).map { ($0, true) }
        }
        return (ConnectionPresenter.shortLabel(for: status), false)
    }

    private var helpText: String {
        ConnectionReading.help(
            host: host, status: status, fps: fps, kbps: kbps, pulse: connection.hostPulse,
        )
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
