// WorkspaceRootView — the top-level window composition (warp-window-chrome.md §9).
//
// Stack: 1pt WORKSPACE_PADDING inset → window background (theme.background) → a column of
// [WindowTopBar (35pt)] over a [body row: VerticalTabRail | 1pt PanelSeparator | content area]. The
// content area is a themed placeholder at L2 (real panes/terminal land in L3, behind the renderer seam).
//
// The rail is hidden when `store.sidebarCollapsed`. All chrome reads `@Environment(\.theme)`; mutations
// route through the store.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

public struct WorkspaceRootView: View {
    @Environment(\.theme) private var theme

    private let store: WorkspaceStore
    private let connection: AppConnection

    /// Hook to open the command palette (wired in L5). No-op at L2.
    var onOpenPalette: () -> Void = {}
    /// Hook to open settings (wired later). No-op at L2.
    var onOpenSettings: () -> Void = {}

    public init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTopBar(
                sidebarCollapsed: store.sidebarCollapsed,
                onToggleSidebar: { store.toggleSidebarCollapsed() },
                onOpenSettings: onOpenSettings,
                onOpenOmnibar: onOpenPalette,
            )
            HStack(spacing: 0) {
                if !store.sidebarCollapsed {
                    VerticalTabRail(store: store)
                    PanelSeparator()
                }
                ContentPlaceholderView(store: store, connection: connection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(WarpSpace.workspacePadding)
        .background(theme.background)
        #if os(macOS)
            .background(WindowConfigurator())
        #endif
    }
}

/// A themed placeholder for the content area at L2 — the active pane's title + a build-status-style
/// liveness summary. Real terminal/video panes land in L3 behind the `TerminalRendererFactory` seam.
struct ContentPlaceholderView: View {
    @Environment(\.theme) private var theme
    let store: WorkspaceStore
    let connection: AppConnection

    private var activePaneTitle: String {
        guard let session = store.tree.activeSession,
              let tab = session.activeTab,
              let active = tab.activePane,
              let spec = session.specs[active]
        else { return "No active pane" }
        let title = spec.lastKnownTitle ?? spec.title
        return title.isEmpty ? "Terminal" : title
    }

    var body: some View {
        VStack(spacing: WarpSpace.m) {
            AgentBrandGlyph(color: theme.agentFooterBrand, size: 40)
            Text(activePaneTitle)
                .font(WarpType.header)
                .foregroundStyle(theme.textMain)
            Text("Workspace content renders here (panes arrive in L3).")
                .font(WarpType.ui(WarpType.uiSize))
                .foregroundStyle(theme.textSub)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
