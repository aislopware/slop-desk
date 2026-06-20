// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneStatusBar (the bottom status strip — Muxy ProjectStatusBar)

/// The 28pt bottom status bar (Muxy `ProjectStatusBar`): since the Muxy redesign removed the per-pane
/// header, the FOCUSED pane's connection dot / title / RTT / agent status live here instead — one quiet
/// strip at the bottom of the detail rather than a header bar on every pane. The bar is the theme `bg`
/// with a 1px `border` hairline along its TOP edge; the left side carries a kind glyph + the display
/// title, the right CLUSTER carries the live status (running / agent / RTT) split by 1px vertical
/// separators. Reads the same shared ``PanePresentation`` derivations the old header used, so nothing
/// drifts; reading the `@Observable` handle re-renders the strip as the focused pane's status changes.
struct PaneStatusBar: View {
    @Bindable var store: WorkspaceStore

    /// The active session's active tab's focused pane — the one the status bar describes.
    private var focusedPaneID: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    /// Cached last non-nil focused pane ID. Prevents a blank flash during the single render pass
    /// where `focusedPaneID` is transiently nil (close + reseed reconciliation gap).
    @State private var lastKnownPaneID: PaneID?

    /// Resolve the pane ID to render: live value when available, cached value during the transient
    /// nil window, nil only when no pane has ever been focused (truly empty workspace).
    private var resolvedPaneID: PaneID? { focusedPaneID ?? lastKnownPaneID }

    var body: some View {
        HStack(spacing: AislopdeskTheme.Space.m) {
            if let id = resolvedPaneID, let spec = store.tree.spec(for: id) {
                content(id: id, spec: spec)
            } else {
                // Guard nil focus: render an empty 28pt bar so the shell keeps its bottom strip.
                Spacer()
            }
        }
        .padding(.horizontal, AislopdeskTheme.Space.l)
        .frame(height: AislopdeskTheme.Metrics.statusBarHeight)
        .background(AislopdeskTheme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(AislopdeskTheme.border).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
        .onChange(of: focusedPaneID) { _, newID in
            if let newID { lastKnownPaneID = newID }
        }
    }

    @ViewBuilder
    private func content(id: PaneID, spec: PaneSpec) -> some View {
        let handle = store.handle(for: id)
        let status = PanePresentation.connectionStatus(handle)
        let running = PanePresentation.isRunning(handle)

        // Left: kind glyph + display title (PanePresentation.displayTitle).
        Image(systemName: PaneLeafView.icon(for: spec.kind))
            .font(.system(size: UIMetrics.fontCaption, weight: .semibold))
            .foregroundStyle(AislopdeskTheme.fgMuted)
            .accessibilityHidden(true)
        Text(PanePresentation.displayTitle(handle, spec: spec))
            .font(.system(size: UIMetrics.fontCaption))
            .foregroundStyle(AislopdeskTheme.fgMuted)
            .lineLimit(1)
            .truncationMode(.middle)

        Spacer(minLength: AislopdeskTheme.Space.m)

        // Right cluster: PaneStatusDot · running · AgentStatusDot · RTT, split by 1px separators.
        separator
        PaneStatusDot(status: status, running: running, size: 7)

        if running {
            separator
            Text("running…")
                .font(.system(size: UIMetrics.fontMicro))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }

        // The per-pane Claude/agent status dot (hidden when `.none`).
        if store.agentStatus(for: id) != .none {
            separator
            AgentStatusDot(status: store.agentStatus(for: id), size: 7)
        }

        // Live RTT (the same smoothed app-layer ping the old header showed): amber past 100ms.
        if case .connected = status.phase, let ms = PanePresentation.latencyMS(handle) {
            separator
            Text(ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms")
                .font(.system(size: UIMetrics.fontMicro).monospacedDigit())
                .foregroundStyle(ms > 100 ? AnyShapeStyle(.orange) : AnyShapeStyle(AislopdeskTheme.fgDim))
                .help("Round-trip time to the host")
        }

        // Sync-input chip: shown while per-tab sync is ON for the active pane's tab (⌘⇧I).
        if let tabID = store.tree.activeSession?.activeTab?.id,
           store.syncInputTabs.contains(tabID)
        {
            separator
            Label("sync", systemImage: "keyboard.badge.ellipsis")
                .font(.system(size: UIMetrics.fontMicro))
                .foregroundStyle(AislopdeskTheme.accent)
                .help(
                    "Sync Input to All Panes is ON — keystrokes are mirrored to every pane in this tab (⌘⇧I to toggle)",
                )
        }
    }

    /// A 1px vertical separator between right-cluster items (Muxy `ProjectStatusBar.separator`), ~14pt tall.
    private var separator: some View {
        Rectangle()
            .fill(AislopdeskTheme.border)
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }
}
#endif
