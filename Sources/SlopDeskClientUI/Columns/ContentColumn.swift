// ContentColumn — the centre content area. Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab),
// with a hover-reveal titlebar floating as a TOP overlay. The titlebar lives here (not at window level)
// so its controls sit over the content area for free, and the terminal extends under it
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
    /// The cross-container pane-drag rendezvous, threaded down to ``SplitContainer`` (the canvas is both
    /// a drag SOURCE and — for satellite-origin drags — a drop target). `nil` (previews / iOS) keeps the
    /// pane drag canvas-only.
    var paneDrag: PaneDragCoordinator?

    /// The scene overlay reducer, re-injected by the split host (the hosted column does not inherit
    /// the WindowGroup environment). Read for the modal pointer shield below; `nil` (previews /
    /// tests) reads as "no modal up".
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    /// The inherited CHROME scheme (the split subtree's frame-polarity pin) — what the hover
    /// titlebar reads while it floats over chrome (the empty state); over the island it flips to
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
            // The hover-reveal titlebar floats as a TOP overlay — OVER the island's top margin now
            // that the island runs to the window top (no reserved band, user-directed 2026-08-07).
            // It adopts the GLASS scheme while an island is under it, so its title/plates resolve
            // against the dark glass rather than the OS appearance; over the chrome empty state it
            // keeps the OS scheme. New-pane gestures (`+` / title-menu split) mint a terminal pane
            // directly (the kind chooser is retired — non-terminal kinds have their own shortcuts).
            .overlay(alignment: .top) {
                SlateTitlebar(store: store, chrome: chrome, connection: connection, onConnect: onConnect)
                    .environment(\.colorScheme, hasActiveTab ? Slate.glassColorScheme : chromeColorScheme)
            }
        #endif
            // ⚠️ THE MODAL POINTER SHIELD — LAST in the chain, so it covers the titlebar overlay
            // too. This column lives in its OWN NSHostingView inside the AppKit split, and the
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
    /// reserved titlebar band, user-directed 2026-08-07). The hover-reveal titlebar floats over
    /// the island's top edge and shows nothing at rest.
    private var content: some View {
        paneArea
    }

    private var paneArea: some View {
        Group {
            if hasActiveTab {
                // THE TERMINAL ISLAND (JetBrains Islands — user-directed 2026-08-07): the WHOLE split
                // tree is ONE rounded glass card floating on the system chrome; panes divide INSIDE it
                // with subtle lines on the glass, never as separate cards. The forced colour scheme is
                // the glass's own polarity (``Slate/glassColorScheme``): everything drawn ON the glass
                // resolves its semantic colours against the profile, not the OS appearance.
                // NO border ring and NO shadow on the island (islands round, from the reference:
                // JetBrains ships `Island.borderColor` equal to the island fill — separation is the
                // field gap and the radius, nothing drawn). The hairline ring the first island round
                // wore re-boxed the card against the flat floor.
                SplitContainer(store: store, paneDrag: paneDrag)
                    .environment(\.colorScheme, Slate.glassColorScheme)
                    .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusIsland, style: .continuous))
                    .padding(.vertical, Slate.Metric.islandMargin)
                    .padding(.leading, Slate.Metric.islandMargin)
                    // Toward the PANEL ISLAND the margin halves (the panel card carries no leading
                    // margin of its own): with the 1px divider gap the inter-island channel lands
                    // at ~5px — the reference's own island gap, and a step tighter than the 8px
                    // window edges after "closer still" (user-directed 2026-08-07). With the panel
                    // hidden the trailing edge IS a window edge and takes the full margin back.
                    .padding(
                        .trailing,
                        chrome.codeSidebarCollapsed ? Slate.Metric.islandMargin : Slate.Metric.space1,
                    )
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
