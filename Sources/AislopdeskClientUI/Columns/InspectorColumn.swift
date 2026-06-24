// InspectorColumn — the right inspector (REBUILD-V2, L3 + L4a Session section). Top→bottom:
//   1) a SESSION section — the app connection status (dot + label), host:port, ping (ms) when connected,
//      and the active pane's agent status (`ClaudeStatus`). Git branch is omitted: the wire-type-30 branch
//      field never landed on `main`, so there's no datum to show (the contract says omit, don't fabricate).
//   2) a Divider, then
//   3) the first-class Command Navigator: the ACTIVE pane → its `LivePaneSession.terminalModel.blocks`
//      (the pure `TerminalBlockModel` folded from wire types 28/29) rendered by `BlockHistoryView`.
//
// Resolution mirrors L2's `PaneContainer`: `store.handle(for: paneID) as? LivePaneSession` keyed by the
// active tab's active pane — no new store API. Reading `connection.status` + `LivePaneSession.claudeStatus`
// + `connection?.latencyMS` (all @Observable) keeps the Session section live. SYSTEM colours/fonts only.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SwiftUI

struct InspectorColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection

    /// The active tab's active pane id (same path L2's NavigatorColumn selection uses).
    private var activePaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The active pane's live session (terminal model + per-pane channel + agent status), if materialized.
    private var activeLive: LivePaneSession? {
        guard let id = activePaneID else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The active pane's terminal view-model — carries both the block store and the output-request flow.
    private var terminalModel: TerminalViewModel? { activeLive?.terminalModel }

    /// The active pane's smoothed RTT (ms), if known (ping lives on the per-pane `ConnectionViewModel`).
    private var activePingMS: Double? { activeLive?.connection?.latencyMS }

    /// The active pane's agent status (`.none` when no agent / no live pane).
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionSection
            Divider()
            commandsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Otty.Surface.sidebar)
    }

    // MARK: Session

    private var sessionSection: some View {
        let status = connection.status
        return VStack(alignment: .leading, spacing: 8) {
            Text("Session")
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .foregroundStyle(Otty.State.header)
                .textCase(.uppercase)

            // Connection status — dot + label.
            sessionRow("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(StatusPresentation.connectionColor(status))
                        .frame(width: 7, height: 7)
                    Text(StatusPresentation.connectionLabel(status))
                }
            }

            // Host:port.
            sessionRow("Host") {
                Text("\(connection.target.host):\(String(connection.target.port))")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Ping (ms) — only meaningful while connected and once an RTT probe has completed.
            if case .connected = status, let activePingMS {
                sessionRow("Ping") {
                    Text("\(Int(activePingMS.rounded())) ms")
                        .monospacedDigit()
                }
            }

            // Agent status — only when an agent is active in the active pane.
            if let symbol = StatusPresentation.agentSymbol(activeAgentStatus) {
                sessionRow("Agent") {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .foregroundStyle(StatusPresentation.agentTint(activeAgentStatus))
                        Text(StatusPresentation.agentLabel(activeAgentStatus))
                    }
                }
            }
        }
        .font(.system(size: Otty.Typeface.base))
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2 + 2)
    }

    /// A compact label/value row: a secondary label on the left, the value trailing.
    private func sessionRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Otty.Text.secondary)
            Spacer(minLength: 8)
            value()
                .foregroundStyle(Otty.Text.primary)
        }
    }

    // MARK: Commands

    @ViewBuilder
    private var commandsSection: some View {
        if let terminalModel {
            BlockHistoryView(
                model: terminalModel.blocks,
                requestOutput: { index, completion in
                    terminalModel.copyBlockOutput(index: index, onResult: completion)
                },
            )
        } else {
            ContentUnavailableView(
                "No Commands",
                systemImage: "terminal",
                description: Text("Select a terminal pane to see its command history"),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
