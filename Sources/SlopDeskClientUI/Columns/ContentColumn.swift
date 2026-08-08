// ContentColumn — the centre content area. Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab).
// The old hover-reveal titlebar overlay is GONE (user-directed 2026-08-07, rail round): its
// controls all found anchored homes — the sidebar toggle in the sidebar/rail strip, the panel
// reopen as the trailing `PanelEdgeHandle`, the connection cluster in the sidebar footer / rail.

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
    /// The cross-container pane-drag rendezvous, threaded down to ``SplitContainer`` (the canvas is both
    /// a drag SOURCE and — for satellite-origin drags — a drop target). `nil` (previews / iOS) keeps the
    /// pane drag canvas-only.
    var paneDrag: PaneDragCoordinator?

    /// The scene overlay reducer, re-injected by the split host (the hosted column does not inherit
    /// the WindowGroup environment). Read for the modal pointer shield below; `nil` (previews /
    /// tests) reads as "no modal up".
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    /// The inherited CHROME scheme (the split subtree's frame-polarity pin) — what the edge
    /// handle reads while it floats over chrome (the empty state); over the island it flips to
    /// the glass polarity instead.
    @Environment(\.colorScheme) private var chromeColorScheme

    var body: some View {
        content
            // The chrome model rides the environment so DEEP descendants (a terminal leaf actuating
            // open-in-code-panel) can reveal the code sidebar without threading the reference
            // through every pane-tree layer. The leaf reads it OPTIONALLY (nil in previews/tests).
            .environment(chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The ONE window field — the same floor tone all three columns and the divider gaps
            // paint (user-directed 2026-08-07, islands round), so the island floats on an
            // uninterrupted ground.
            .background(Slate.Surface.field)
        #if os(macOS)
            // The collapsed RIGHT panel's reopen affordance — an EDGE HANDLE hugging the window's
            // trailing edge (user-directed 2026-08-07, rail round). The floating titlebar reopen
            // plates are GONE with the titlebar itself: the left toggle lives in the sidebar/rail
            // strip now, and a drawer pull fused to the edge it opens from is the one placement
            // that cannot read as adrift over the glass. Glass scheme while an island is under it.
            .overlay(alignment: .trailing) {
                if chrome.codeSidebarCollapsed {
                    PanelEdgeHandle { chrome.toggleCodeSidebar() }
                        .environment(
                            \.colorScheme, hasActiveTab ? Slate.glassColorScheme : chromeColorScheme,
                        )
                }
            }
        #endif
            // ⚠️ THE MODAL POINTER SHIELD — LAST in the chain, so it covers the edge-handle
            // overlay too. This column lives in its OWN NSHostingView inside the AppKit split, and the
            // floating overlay layer lives in the window root's — so a card floating over this
            // column does NOT occlude its hover tracking: AppKit tracking areas are rect-based and
            // keep firing under the card, and the hover-reveal titlebar (and any row hover) lit up
            // while the pointer was on the palette. While a modal card is up the column goes
            // hit-test-deaf, which silences its hover the way the card's dismiss floor already
            // silences its clicks. Global Search (non-modal by design) leaves this open; the
            // terminal's own AppKit tracking is shielded by `TerminalPointerShield` off the same flag.
            .allowsHitTesting(!(overlayCoordinator?.anyModalVisible ?? false))
    }

    /// The pane area fills the whole column — the island runs FULL top→bottom (Canario; no
    /// reserved titlebar band, user-directed 2026-08-07). Nothing floats over its top edge.
    private var content: some View {
        paneArea
    }

    private var paneArea: some View {
        Group {
            if hasActiveTab {
                // The terminal surface runs FULL-BLEED (flat round, user-directed 2026-08-08 —
                // the floating island, its margins and its radius are retired with the frame):
                // the column IS the glass, edge to edge, and the 1px split dividers are the only
                // structure between columns. The forced colour scheme stays: everything drawn ON
                // the glass resolves its semantic colours against the profile, not the OS.
                SplitContainer(store: store, paneDrag: paneDrag)
                    .environment(\.colorScheme, Slate.glassColorScheme)
            } else {
                // The Slate empty-state voice (MERIDIAN C3) — the cause names WHY the area is empty
                // (not-connected vs link-down vs no-tabs) and carries the one next action.
                let cause = Self.emptyCause(status: connection.status, host: connection.target.host)
                SlateEmptyState(cause: cause) {
                    switch cause {
                    case .neverConnected,
                         .connectFailed: onConnect()
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
        case let .failed(reason): .connectFailed(reason: ConnectionPresenter.friendlyFailure(reason))
        case .disconnected,
             .connecting,
             .unreachable: .neverConnected
        }
    }
}
#endif
