// ContentColumn — the centre content area. Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab).
// The window chrome is NATIVE now (native-chrome migration, 2026-07-03): the titlebar/toolbar is the
// system's — the old hover-reveal `SlateTitlebar` overlay and its reserved 40pt strip are gone, so the
// pane area fills the column directly on both platforms.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState

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
        paneArea
            // Card-canvas: pad by half the inter-card gap — with each card's own half-gap inset
            // (SplitContainer) the outer margin equals the gap between split cards.
            .padding(Slate.Metric.paneGap / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.margin)
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
