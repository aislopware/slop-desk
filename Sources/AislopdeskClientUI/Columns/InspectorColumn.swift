// InspectorColumn — the right Details panel (otty port). otty's Details panel (binary §5) is a SEGMENTED
// header (active tab = icon+label pill, inactive = icon only) over a warm panel; hidden until ⌘⇧R. This ports
// that silhouette and keeps aislopdesk's live content under the Info tab:
//   • Info  — the live SESSION (connection dot+label, host:port, ping, agent) + working directory + the
//             first-class command navigator (`BlockHistoryView` over the active pane's `TerminalBlockModel`).
//   • Git / Files — otty-styled empty states for now (no live git/file datum flows to this panel yet).
//
// Resolution mirrors `PaneContainer`: `store.handle(for: paneID) as? LivePaneSession` keyed by the active
// tab's active pane. Reading `connection.status` + `LivePaneSession.claudeStatus` + `connection?.latencyMS`
// (all @Observable) keeps Info live. otty tokens / fonts only.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SwiftUI

struct InspectorColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection

    @State private var selected: DetailsTab = .info

    private enum DetailsTab: String, CaseIterable, Identifiable {
        case info
        case git
        case files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .info: "Info"
            case .git: "Git"
            case .files: "Files"
            }
        }

        var icon: String {
            switch self {
            case .info: "info.circle"
            case .git: "arrow.triangle.branch"
            case .files: "folder"
            }
        }
    }

    /// The active tab's active pane id.
    private var activePaneID: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    /// The active pane's live session (terminal model + per-pane channel + agent status), if materialized.
    private var activeLive: LivePaneSession? {
        guard let id = activePaneID else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    private var terminalModel: TerminalViewModel? { activeLive?.terminalModel }
    private var activePingMS: Double? { activeLive?.connection?.latencyMS }
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

    private var cwd: String? {
        guard let id = activePaneID else { return nil }
        return store.tree.activeSession?.specs[id]?.lastKnownCwd
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Otty.Line.divider).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Otty.Surface.sidebar)
    }

    // MARK: Segmented header (otty Details bar — active = icon+label pill, inactive = icon only)

    private var header: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 8, height: 40) // clear the titlebar strip / traffic lights line
            ForEach(DetailsTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func tabButton(_ tab: DetailsTab) -> some View {
        let active = tab == selected
        return Button {
            withAnimation(Otty.Anim.standard) { selected = tab }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: Otty.Typeface.footnote, weight: .medium))
                if active { Text(tab.title).font(.system(size: Otty.Typeface.footnote, weight: .medium)) }
            }
            .foregroundStyle(active ? Otty.Text.primary : Otty.Text.icon)
            .padding(.horizontal, active ? 8 : 6)
            .frame(height: 24)
            .background(active ? Otty.State.hover : .clear, in: .rect(cornerRadius: Otty.Metric.radiusControl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch selected {
        case .info: infoContent
        case .git: emptyState("No Changes", systemImage: "arrow.triangle.branch", note: "Git status will appear here")
        case .files: emptyState("No Files", systemImage: "folder", note: "The working-directory tree will appear here")
        }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionSection
            Rectangle().fill(Otty.Line.divider).frame(height: 1).padding(.horizontal, Otty.Metric.space3)
            commandsSection
        }
    }

    private var sessionSection: some View {
        let status = connection.status
        return VStack(alignment: .leading, spacing: 8) {
            OttySectionHeader("Session")
            OttyKeyValueRow(label: "Status") {
                HStack(spacing: 6) {
                    OttyStatusDot(
                        color: StatusPresentation.connectionColor(status),
                        glowKey: StatusPresentation.connectionLabel(status),
                    )
                    Text(StatusPresentation.connectionLabel(status))
                }
            }
            OttyKeyValueRow(label: "Host") {
                Text("\(connection.target.host):\(String(connection.target.port))")
                    .lineLimit(1).truncationMode(.middle)
            }
            if case .connected = status, let activePingMS {
                OttyKeyValueRow(label: "Ping") {
                    Text("\(Int(activePingMS.rounded())) ms").monospacedDigit()
                }
            }
            if let cwd {
                OttyKeyValueRow(label: "Dir") {
                    Text(cwd).lineLimit(1).truncationMode(.head)
                }
            }
            if let symbol = StatusPresentation.agentSymbol(activeAgentStatus) {
                OttyKeyValueRow(label: "Agent") {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).foregroundStyle(StatusPresentation.agentTint(activeAgentStatus))
                        Text(StatusPresentation.agentLabel(activeAgentStatus))
                    }
                }
            }
        }
        .font(.system(size: Otty.Typeface.base))
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2 + 2)
    }

    @ViewBuilder private var commandsSection: some View {
        if let terminalModel {
            BlockHistoryView(
                model: terminalModel.blocks,
                requestOutput: { index, completion in
                    terminalModel.copyBlockOutput(index: index, onResult: completion)
                },
            )
        } else {
            emptyState("No Commands", systemImage: "terminal", note: "Select a terminal pane to see its history")
        }
    }

    private func emptyState(_ title: String, systemImage: String, note: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(note))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
