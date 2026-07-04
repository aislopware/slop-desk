// ConnectionStatusItem — the ONE cross-platform ambient connection-status control (UI restructure,
// 2026-07-04; docs/research/ui-restructure-2026-07-04.md §2.2). Replaces the centred macOS
// `TitlebarConnectionCluster` / iOS `ConnectionStatusPill` pair, which duplicated the same semantic
// content with two divergent geometries.
//
// AMBIENT-WHEN-HEALTHY (the researched consensus — VS Code / Linear / Tailscale collapse a healthy
// connection to near-nothing): a state-coloured dot + the host in muted text + the live telemetry in
// tertiary monospaced digits. No resting fill, no border, no embedded action buttons. CLICK opens the
// detail POPOVER (status headline, telemetry rows, Retry + the Connect-to-Host editor); a degraded
// state earns space inline: the trailing text swaps to the status word, the dot glows on change (Pow),
// and the give-up states surface a one-tap Retry glyph.
//
// GEOMETRY RULE (the old cluster's overflow bug): height is CONTENT-driven — padding, never a fixed
// `frame(height:)`. And NO custom hover background: the macOS 26 toolbar draws its OWN glass capsule +
// hover highlight around every item, so a second wash inside it reads as a stray fill floating in the
// middle of the system pill (HW-caught 2026-07-04). Hover feedback = the host-text brighten only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct ConnectionStatusItem: View {
    /// The app-global connection. Reading `connection.status` (an `@Observable`) in `body` registers
    /// observation, so the item stays live.
    let connection: AppConnection
    /// The smoothed RTT (ms) to show, or `nil` when unknown — the ACTIVE pane's per-channel `latencyMS`,
    /// falling back to any live pane's (every pane pings the SAME host), resolved by the shell.
    var pingMS: Double?
    /// The active VIDEO pane's host-announced stream cadence (frames/sec); `nil` for a terminal pane.
    var fps: Int?
    /// Opens the Connect-to-Host editor (pre-seeded with the current host/port) — the popover's
    /// "Connect…" action.
    var onConnect: () -> Void = {}

    @State private var hover = false
    @State private var showDetail = false
    /// Mute the ambient item when the window isn't key — status is window state, and an inactive
    /// window's chrome should recede with it (macOS 26 replacement for `controlActiveState`).
    @Environment(\.appearsActive) private var appearsActive

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }

    var body: some View {
        HStack(spacing: 4) {
            statusButton
            // Give-up state (failed / unreachable): a one-tap Retry beside the item — the fast re-dial
            // stays one click away while the item itself leads to the detail popover.
            if StatusPresentation.showsRetry(status) {
                retryButton
            }
        }
        .opacity(appearsActive ? 1 : 0.5)
    }

    private var statusButton: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 6) {
                SlateStatusDot(
                    color: StatusPresentation.connectionColor(status),
                    size: 6,
                    glowKey: StatusPresentation.connectionLabel(status),
                )
                Text(host)
                    .font(.subheadline)
                    .foregroundStyle(hover ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let summary = StatusPresentation.connectionSummary(status: status, pingMS: pingMS, fps: fps) {
                    Text(summary.text)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(summary.isMetric ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        // Rolling-digit swap for the live telemetry (ping/fps tick without a full cross-fade).
                        .contentTransition(.numericText())
                }
            }
            // The macOS 26 toolbar wraps every item in its own glass capsule WITH a hover highlight —
            // a second, smaller wash of our own renders as a stray fill floating inside the system
            // pill (HW-caught 2026-07-04). So: no custom background here; padding only sizes the
            // system capsule + hit area, and hover feedback is the host-text brighten below.
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            ConnectionDetailPopover(connection: connection, pingMS: pingMS, fps: fps, onConnect: onConnect)
        }
        .help(StatusPresentation.connectionHelp(host: host, status: status))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))
    }

    /// The give-up-state Retry glyph — plain icon, no capsule chrome (the ambient rule: only degraded
    /// states earn extra ink, and even then a glyph, not a boxed button).
    private var retryButton: some View {
        Button { Task { await connection.retry() } } label: {
            Image(systemSymbol: .arrowClockwise)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Retry connecting to \(host)")
        .accessibilityLabel("Retry connecting to \(host)")
    }
}

/// The click-through detail surface: status headline + live telemetry rows + the actions the old pills
/// embedded inline (Retry when applicable, and the Connect-to-Host editor). Reading `connection.status`
/// keeps it live while open — a Retry's connecting → connected progress renders in place.
private struct ConnectionDetailPopover: View {
    let connection: AppConnection
    var pingMS: Double?
    var fps: Int?
    var onConnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var status: ConnectionStatus { connection.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SlateStatusDot(
                    color: StatusPresentation.connectionColor(status),
                    glowKey: StatusPresentation.connectionLabel(status),
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.target.host)
                        .font(.body.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(ConnectionPresenter.headline(for: status))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if pingMS != nil || fps != nil {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if let pingMS {
                        telemetryRow("Latency", value: "\(Int(pingMS.rounded())) ms")
                    }
                    if let fps {
                        telemetryRow("Stream", value: "\(fps) fps")
                    }
                }
            }
            Divider()
            HStack {
                if StatusPresentation.showsRetry(status) {
                    Button("Retry") { Task { await connection.retry() } }
                }
                Spacer()
                Button("Connect…") {
                    dismiss()
                    onConnect()
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
    }

    private func telemetryRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .contentTransition(.numericText())
        }
    }
}
#endif
