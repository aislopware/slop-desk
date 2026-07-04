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

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // MERIDIAN L5, scoped by user report ("title màu khác với pane ở dưới nhìn rất lạc quẻ"):
            // the content column is the LIT FACE end-to-end — the titlebar band paints the PANE tone
            // (`card`), never the dimmed chrome `window` tone. Panes are flush under the band (no gap, no
            // radius), so a darker strip here reads as a mispainted header, not a housing; the dimmed
            // housing is the SIDEBAR column only.
            .background(Slate.Surface.face)
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
                SplitContainer(store: store)
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
