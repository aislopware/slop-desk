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
    /// The cross-container pane-drag rendezvous, threaded down to ``SplitContainer`` (the canvas is both
    /// a drag SOURCE and — for satellite-origin drags — a drop target). `nil` (previews / iOS) keeps the
    /// pane drag canvas-only.
    var paneDrag: PaneDragCoordinator?

    /// The scene overlay reducer, re-injected by the split host (the hosted column does not inherit
    /// the WindowGroup environment). Read for the modal pointer shield below; `nil` (previews /
    /// tests) reads as "no modal up".
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    /// The row model for the collapsed-state tab strip — the SAME memo class the navigator uses, so
    /// the strip pays the structural build only when something structural actually moved. Plain
    /// class in `@State` (NOT `@Observable`): its mutation during a body eval must not re-invalidate
    /// anything.
    @State private var rowsMemo = RailRowsMemo()

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    var body: some View {
        content
            // The chrome model rides the environment so DEEP descendants (a terminal leaf actuating
            // open-in-code-panel) can reveal the code sidebar without threading the reference
            // through every pane-tree layer. The leaf reads it OPTIONALLY (nil in previews/tests).
            .environment(chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ONE ISLAND: this column paints GROUND end-to-end and the pane canvas is lifted off it
            // as the window's single island (see ``content``). The band beside the island is that
            // same ground — the tone the navigator and the code panel stand on — so the top of the
            // window reads as one field with one card in it. The old rule ("the band must wear the
            // pane tone or it reads as a mispainted header") belonged to a world where the panes
            // were flush under it; with a moat and a corner between them the band is plainly ground.
            .background(Slate.Surface.field)
        #if os(macOS)
            // The hover-reveal titlebar floats as a TOP overlay. New-pane gestures (`+` / title-menu split)
            // mint a terminal pane directly (the kind chooser is retired — non-terminal kinds have their
            // own explicit shortcuts).
            .overlay(alignment: .top) {
                // The titlebar carries the collapsed-state tab strip, so it needs the same rows the
                // navigator renders. They are built HERE rather than inside the titlebar because
                // this column is not lazy: a rows build in the overlay would re-register every
                // volatile per-pane dict as a dependency of the titlebar body and re-run on each
                // status tick. `RailRowsMemo` returns the cached array when nothing structural
                // moved (`WorkspaceRootView`'s own memo contract), and the strip's chips read their
                // volatile chrome in their own leaves.
                SlateTitlebar(
                    store: store, chrome: chrome,
                    rows: chrome.sidebarCollapsed ? rowsMemo.rows(for: store) : [],
                    // ONE select path with the sidebar's rows: switch to the owning tab, focus the
                    // pane, clear the tab's agent badges.
                    onSelectPane: { NavigatorColumn.selectRow($0, in: store) },
                )
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

    /// On macOS the pane canvas is THE ISLAND — glass, a window-scale corner, and a 12pt moat of
    /// ground on all four sides, so its top edge lands on the band's TOP LINE, level with the
    /// traffic lights and the panel's surface tabs (``slateIsland(clearingBand:)``, user-directed
    /// 2026-08-09). The navigator carries the lights, so nothing in this column needs the clearance —
    /// until the navigator is collapsed and the band's own tab strip moves over this column, which is
    /// what `clearingBand` answers. iOS has no titlebar and no island: the pane area fills its
    /// column directly.
    private var content: some View {
        #if os(macOS)
        paneArea
            .slateIsland(clearingBand: chrome.sidebarCollapsed)
            // The collapsed panel leaves a RAIL on the window's trailing edge rather than vanishing
            // (``PanelRail``, user-directed 2026-08-09), so this column gives back its width. The
            // island's own moat is measured inside what is left, which keeps the rail standing on
            // ground with the usual channel between it and the glass.
            .padding(.trailing, railed ? Slate.Metric.panelRailWidth : 0)
            .animation(Slate.Anim.columnSlide, value: railed)
            .overlay(alignment: .topTrailing) { rail }
        #else
        paneArea
        #endif
    }

    #if os(macOS)
    /// True while the panel is standing in as its rail.
    private var railed: Bool { chrome.codeSidebarCollapsed }

    /// The rail ARRIVES AND LEAVES; it does not appear (user-reported 2026-08-09 — mounted on the
    /// flag it stood, already turned on its side, on top of a terminal that had not yet made room
    /// for it).
    ///
    /// It is mounted at all times and travels instead, which is the only way to time both halves of
    /// the gesture independently:
    ///   • COLLAPSING — the rail waits out most of the column's exit and then slides in from the
    ///     window's trailing edge, so it lands in ground the panel has already vacated. Same
    ///     arrive-on-land contract the horizontal tab strip keeps with the navigator, off the same
    ///     token, so the window only ever has ONE column gesture running.
    ///   • EXPANDING — no delay and a quick out: the rail clears the corner before the panel's own
    ///     edge reaches it. A late exit is what makes a sliding panel look like it is shoving
    ///     furniture.
    /// Slide AND fade, because the distance is one plate: an object crossing 40pt on the emphasized
    /// curve arrives before the eye has caught it, and the opacity is what makes the arrival read.
    private var rail: some View {
        PanelRail(chrome: chrome)
            .offset(x: railed ? 0 : Slate.Metric.panelRailWidth)
            .opacity(railed ? 1 : 0)
            // A rail at zero opacity is still a rail: it sits over the island's trailing moat while
            // the panel is open, and would eat clicks meant for the glass.
            .allowsHitTesting(railed)
            .animation(
                railed
                    ? Slate.Anim.columnSlide.delay(Slate.Anim.columnSlideDuration * 0.55)
                    : Slate.Anim.fadeOut,
                value: railed,
            )
    }
    #endif

    private var paneArea: some View {
        Group {
            if hasActiveTab {
                // The forced colour scheme stays with the pane grid across the layout revert:
                // everything drawn ON the glass resolves its semantic colours against the
                // profile's polarity, not the OS.
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
