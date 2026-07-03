// ContentColumn — the centre content area. Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab),
// with a hover-reveal titlebar floating as a TOP overlay. The titlebar lives here (not at window level)
// so its centred title menu centres over the content area for free, and the terminal extends under it
// for a clean resting silhouette. The shared `WorkspaceChromeState` drives the sidebar/Details toggles.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// Opens the Connect-to-Host editor — wired into the titlebar's connection-status cluster. The no-op
    /// default keeps the column standalone-mountable in previews.
    var onConnect: () -> Void = {}

    /// Whether this column has a tab to show. macOS: the TERMINAL side's displayed tab (the TabSide
    /// partition — remote-window tabs render in the right GUI column); iOS keeps the single-region shell
    /// (the active tab, whatever its side).
    private var hasActiveTab: Bool {
        #if os(macOS)
        store.displayedTab(on: .terminal) != nil
        #else
        store.tree.activeSession?.activeTab != nil
        #endif
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.window)
        #if os(macOS)
            // The hover-reveal titlebar floats as a TOP overlay. New-pane gestures (`+` / title-menu split)
            // mint an in-pane `.chooser` pane directly — the chooser is the pane's CONTENT, not a modal.
            .overlay(alignment: .top) {
                SlateTitlebar(store: store, chrome: chrome, connection: connection, onConnect: onConnect)
            }
        #endif
    }

    /// On macOS the pane area is pushed below the hover-reveal titlebar strip (so the terminal starts under
    /// it, not under the centred title); iOS has no titlebar so the pane area fills directly.
    private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Color.clear.frame(height: Slate.Metric.titlebarHeight)
            paneArea
        }
        #else
        paneArea
        #endif
    }

    private var paneArea: some View {
        Group {
            if hasActiveTab {
                // TabSide partition (macOS): this column renders the TERMINAL side only; the remote-window
                // tabs live in the right GUI column. iOS keeps the single-region shell (side nil = all tabs).
                #if os(macOS)
                SplitContainer(store: store, side: .terminal)
                #else
                SplitContainer(store: store)
                #endif
            } else {
                ContentUnavailableView(
                    "No Session",
                    systemImage: "terminal",
                    description: Text("Connect to a host or open a tab"),
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
