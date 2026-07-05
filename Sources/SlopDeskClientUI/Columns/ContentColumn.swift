// ContentColumn — the centre content area. Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab),
// with a hover-reveal titlebar floating as a TOP overlay. The titlebar lives here (not at window level)
// so its centred title menu centres over the content area for free, and the terminal extends under it
// for a clean resting silhouette. The shared `WorkspaceChromeState` drives the sidebar/Details toggles.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
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
                // The Slate empty-state voice (MERIDIAN C3) — the cause names WHY the area is empty
                // (not-connected vs link-down vs no-tabs) and carries the one next action.
                let cause = Self.emptyCause(status: connection.status, host: connection.target.host)
                SlateEmptyState(cause: cause) {
                    switch cause {
                    case .neverConnected: onConnect()
                    case .noTabs: store.openChooserPane(.newTab)
                    case .linkDown: break // redials itself; no user action offered
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Resolves the empty pane area's CAUSE from the live connection: connected ⇒ the only thing
    /// missing is a tab; an active redial ⇒ link-down (named host, no action — the supervisor is
    /// already dialing); anything else (fresh launch, give-up states, a first `connecting`) reads
    /// not-connected, whose action opens the Connect editor. Static + pure so the mapping is pinned
    /// by tests.
    static func emptyCause(status: ConnectionStatus, host: String) -> SlateEmptyState.Cause {
        switch status {
        case .connected: .noTabs
        case .reconnecting: .linkDown(host: host)
        case .disconnected,
             .connecting,
             .unreachable,
             .failed: .neverConnected
        }
    }
}
#endif
