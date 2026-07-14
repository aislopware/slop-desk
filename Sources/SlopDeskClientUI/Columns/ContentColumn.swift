// ContentColumn — the centre content area. Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab),
// with a hover-reveal titlebar floating as a TOP overlay. The titlebar lives here (not at window level)
// so its centred title menu centres over the content area for free, and the terminal extends under it
// for a clean resting silhouette. The shared `WorkspaceChromeState` drives the sidebar/Details toggles.

#if canImport(SwiftUI)
import Defaults
import SlopDeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// Opens the Connect-to-Host editor — wired into the titlebar's connection-status cluster. The no-op
    /// default keeps the column standalone-mountable in previews.
    var onConnect: () -> Void = {}

    /// The STAGE zone's width — seeded from the persisted default, live during the divider drag,
    /// persisted on release (`StageDivider`). Owned here (not on the zone) so it survives the zone's
    /// collapse-to-zero unmount when the stage empties.
    @State private var stageWidth: CGFloat = .init(Defaults[.stageWidth])

    /// The Stage zone's width floor — below this a streamed window stops being legible.
    private static let stageMinWidth: CGFloat = 280
    /// The terminal canvas's floor beside the stage — mirrors the macOS shell's centre-column minimum
    /// (`SlopDeskSplitViewController.contentMinWidth`) without referencing the macOS-only type, so the
    /// clamp compiles on iOS too.
    private static let canvasMinWidth: CGFloat = 420

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // MERIDIAN L5, scoped by the user reporting that a titlebar tone differing from the pane below it read as jarringly out of place:
            // the content column is the LIT FACE end-to-end — the titlebar band paints the PANE tone
            // (`card`), never the dimmed chrome `window` tone. Panes are flush under the band (no gap, no
            // radius), so a darker strip here reads as a mispainted header, not a housing; the dimmed
            // housing is the SIDEBAR column only.
            .background(Slate.Surface.face)
        #if os(macOS)
            // The hover-reveal titlebar floats as a TOP overlay. New-pane gestures (`+` / title-menu split)
            // mint a terminal pane directly (the Stage re-scope retired the kind chooser).
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
            paneAndStage
        }
        #else
        paneAndStage
        #endif
    }

    /// The terminal canvas + the STAGE zone (the Stage re-scope): the split tree is terminal-only, the
    /// staged windows dock on the trailing edge behind a hand-draggable seam. An EMPTY stage mounts
    /// nothing (collapse-to-zero — opening a window auto-reveals the zone); the appear/disappear is a
    /// HARD CUT (never animate leaf frames). Width is clamped live against the column geometry so the
    /// canvas always keeps a usable floor.
    private var paneAndStage: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                paneArea
                if !store.stagePaneIDs.isEmpty {
                    StageDivider(
                        width: $stageWidth,
                        range: Self.stageWidthRange(columnWidth: geo.size.width),
                        store: store,
                    )
                    StageZone(store: store)
                        .frame(width: stageWidth.clamped(to: Self.stageWidthRange(columnWidth: geo.size.width)))
                }
            }
        }
    }

    /// The stage width clamp for a column `columnWidth` points wide: at least ``stageMinWidth``, and
    /// never so wide the terminal canvas drops below the shell's content floor. In an over-tight column
    /// the FLOOR wins (a degenerate range collapses to the floor) — same rule as the rail divider.
    static func stageWidthRange(columnWidth: CGFloat) -> ClosedRange<CGFloat> {
        let ceiling = CGFloat.maximum(stageMinWidth, columnWidth - canvasMinWidth)
        return stageMinWidth...ceiling
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
                    case .noTabs: store.newTerminalPane(.newTab)
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
