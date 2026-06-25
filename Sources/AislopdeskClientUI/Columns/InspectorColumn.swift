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

    /// Whether the "View Session History" viewer (`AgentSessionHistoryView`) is presented over the panel.
    /// Set by the Info tab's agent-sessions action; the viewer binds the focused pane's model (its session
    /// list + the `readAgentSession` fetch). E4/WI-6.
    @State private var showSessionHistory = false

    /// PER-PANE decoded host metadata (E4): processes / ports / git / files / cwd. One model per pane the
    /// inspector has shown — so each pane RETAINS its data and a slow `refresh()` for the pane you just left
    /// can never clobber the pane you switched TO (a single shared model would race two in-flight refreshes).
    /// Pruned to live panes (a closed pane drops out) so the cache stays bounded.
    @State private var models: [PaneID: PaneMetadataModel] = [:]
    /// A stable, never-bound empty model rendered for the one frame before the focused pane's model is
    /// created (the `.task` populates `models` off the body-update path), and when no pane is focused. Its
    /// `nil` client makes every read an empty state — never a hang.
    @State private var placeholder = PaneMetadataModel()

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

    /// The focused pane's typed metadata façade, or `nil` while it is disconnected.
    private var activeMetadataClient: MetadataClient? {
        activeLive?.connection?.activeMetadataClient
    }

    /// Identity of "what the panel is showing": the focused pane AND its (re)connected metadata façade.
    /// A change — switching panes, or a pane (re)connecting with a fresh `MetadataClient` — re-fires the
    /// bind+refresh `.task` (which auto-cancels the prior, so a stale in-flight fetch can't land late).
    private struct RefreshKey: Equatable {
        let pane: PaneID?
        let client: ObjectIdentifier?
    }

    private var refreshKey: RefreshKey {
        RefreshKey(pane: activePaneID, client: activeMetadataClient.map { ObjectIdentifier($0) })
    }

    /// The focused pane's metadata model (its cached one, or the empty placeholder until the `.task` mints
    /// it). The tabs always have a non-`nil` model to render, so there is no missing-data layout jump.
    private var activeModel: PaneMetadataModel {
        guard let id = activePaneID, let model = models[id] else { return placeholder }
        return model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Otty.Line.divider).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Otty.Surface.sidebar)
        .task(id: refreshKey) { await bindAndRefresh() }
        .sheet(isPresented: $showSessionHistory) {
            AgentSessionHistoryView(model: activeModel, onClose: { showSessionHistory = false })
        }
    }

    /// Binds the focused pane's metadata model to its façade and fetches its Info/Git/Files data, then
    /// mirrors the host-resolved cwd into the pane's `lastKnownCwd` (so the titlebar / rail / palette pick it
    /// up). Each pane has its OWN model, so a stale in-flight refresh writes to the pane you left, never the
    /// one you switched to. A disconnected pane (`nil` client) just clears its model — no fetch, no hang.
    private func bindAndRefresh() async {
        pruneClosedPaneModels()
        guard let id = activePaneID else { return }
        let model: PaneMetadataModel
        if let existing = models[id] {
            model = existing
        } else {
            model = PaneMetadataModel()
            models[id] = model
        }
        let client = activeMetadataClient
        model.setClient(client)
        guard client != nil else { return }
        await model.refresh()
        if let cwd = model.cwd, !cwd.isEmpty {
            store.setLastKnownCwd(cwd, for: id)
        }
    }

    /// Drops models for panes the inspector once showed but that are now closed (no live session handle),
    /// keeping the per-pane cache bounded. The active pane is always materialized, so a missing handle ⇒
    /// the pane is gone.
    private func pruneClosedPaneModels() {
        for id in Array(models.keys) where store.handle(for: id) == nil {
            models[id]?.setClient(nil)
            models.removeValue(forKey: id)
        }
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
        // `.id(activePaneID)` resets each tab's local interaction state (selected diff file / find query)
        // when the focused pane changes — `activeModel` already switches to that pane's data.
        case .git: GitStatusView(model: activeModel).id(activePaneID)
        case .files: RemoteFileTreeView(model: activeModel).id(activePaneID)
        }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionSection
            sectionDivider
            ProcessPortsView(model: activeModel)
                .padding(.bottom, Otty.Metric.space2)
            if !activeModel.agentSessions.isEmpty {
                sectionDivider
                agentSessionsSection
            }
            sectionDivider
            commandsSection
        }
    }

    /// The Info-tab agent-history affordance (E4/WI-6): a "View Session History" action — otty's green
    /// clock row — shown only when the pane project has captured agent sessions. Tapping it presents
    /// `AgentSessionHistoryView` over the panel; the trailing count hints how many sessions are available.
    private var agentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttySectionHeader("Sessions")
            Button {
                showSessionHistory = true
            } label: {
                HStack(spacing: Otty.Metric.space2) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("View Session History")
                    Spacer(minLength: Otty.Metric.space2)
                    Text(String(activeModel.agentSessions.count))
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.Text.tertiary)
                        .monospacedDigit()
                }
                .font(.system(size: Otty.Typeface.base))
                .foregroundStyle(Otty.State.accent)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, Otty.Metric.space2)
    }

    private var sectionDivider: some View {
        Rectangle().fill(Otty.Line.divider).frame(height: 1).padding(.horizontal, Otty.Metric.space3)
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
