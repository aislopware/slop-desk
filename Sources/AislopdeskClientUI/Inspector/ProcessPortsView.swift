// ProcessPortsView — the Info-tab Process + Ports sections of the Details Panel (E4, WI-5).
//
// Ports the otty info-panel's two host-metadata rows (spec/user-interface__details-panel.md §"Process
// section" / "Ports section"): a "Process" list — a filled green dot + process name + PID + right-aligned
// uptime ("-zsh 64628  34s") — and a "Ports" list that reads "No listening ports" when empty. The data is
// the remote host's, decoded into the pane's `PaneMetadataModel` (the Info tab binds this view to it); a
// disconnected pane shows the empty copy without hanging.
//
// otty tokens / fonts only (`Otty.*`, `OttySectionHeader`, `OttyStatusDot`). The `MetadataFormatting`
// helper (compact uptime) is pure + headlessly unit-tested — no view rendering needed to prove it.

#if canImport(SwiftUI)
import AislopdeskProtocol
import AislopdeskWorkspaceCore
import SwiftUI

struct ProcessPortsView: View {
    /// The active pane's decoded host metadata (processes + ports). `@Bindable`-free read-only binding.
    let model: PaneMetadataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            processSection
            portsSection
        }
        .font(.system(size: Otty.Typeface.base))
    }

    // MARK: Process

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttySectionHeader("Process") { refreshButton }
            if model.processes.isEmpty {
                emptyLine(model.isConnected ? "No processes" : "Not connected")
            } else {
                // Index keys (a PID can repeat across a fork/exec race in the snapshot — offset is stable).
                ForEach(Array(model.processes.enumerated()), id: \.offset) { _, proc in
                    processRow(proc)
                }
            }
        }
    }

    private func processRow(_ proc: MetadataCodec.ProcessInfo) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            OttyStatusDot(color: Otty.Status.ok, size: 6)
            Text(proc.name.isEmpty ? "—" : proc.name)
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(String(proc.pid))
                .foregroundStyle(Otty.Text.secondary)
                .monospacedDigit()
            Spacer(minLength: Otty.Metric.space2)
            Text(MetadataFormatting.uptime(proc.uptimeSec))
                .foregroundStyle(Otty.Text.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, 3)
    }

    // MARK: Ports

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttySectionHeader("Ports")
            if model.ports.isEmpty {
                emptyLine("No listening ports")
            } else {
                ForEach(Array(model.ports.enumerated()), id: \.offset) { _, port in
                    portRow(port)
                }
            }
        }
    }

    private func portRow(_ port: MetadataCodec.PortInfo) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            OttyStatusDot(color: Otty.Status.ok, size: 6)
            Text(port.procName.isEmpty ? "—" : port.procName)
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(":\(String(port.port))")
                .foregroundStyle(Otty.Text.secondary)
                .monospacedDigit()
            Spacer(minLength: Otty.Metric.space2)
            Text(MetadataFormatting.portProtocolLabel(port.proto))
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.tertiary)
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, 3)
    }

    // MARK: Shared

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.icon)
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
        .help("Refresh")
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Otty.Text.secondary)
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.vertical, 3)
    }
}

/// Pure formatting helpers for the host-metadata Info tab — extracted so they are headlessly testable
/// (no view, no `Otty` theme read). Mirrors the `CommandBlock.durationLabel` pure-formatting precedent.
enum MetadataFormatting {
    /// Compact uptime like otty's process rows: seconds under a minute ("34s"), then "5m" / "2h" / "3d".
    /// Always a single coarse unit (the panel wants a glanceable hint, not a precise duration).
    static func uptime(_ seconds: UInt32) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// The transport-protocol badge for a raw `PortInfo.proto` byte (0 tcp / 1 udp; unknown → "?"),
    /// forward-tolerant like the codec's `portProtocol`.
    static func portProtocolLabel(_ proto: UInt8) -> String {
        switch MetadataCodec.PortProtocol(rawValue: proto) {
        case .tcp: "TCP"
        case .udp: "UDP"
        case nil: "?"
        }
    }
}
#endif
