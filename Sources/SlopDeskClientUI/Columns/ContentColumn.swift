// ContentColumn — the centre content area's CANVAS: the active tab's pane tree via the
// identity-preserving `SplitContainer` (a Slate empty-state when there is no session/tab) and the
// island geometry that lifts it off the ground.
//
// The TITLEBAR BAND and the collapsed panel's RAIL are no longer here. Both are AppKit now
// (``SlopDeskMacUI/MacTitlebarBand``, ``SlopDeskMacUI/MacPanelRail``), mounted as this column's
// SIBLINGS by ``SlopDeskMacUI/MacContentColumn`` rather than as overlays on top of it — which is why
// nothing in this file reserves the band's height or hands hit-testing back to either.
//
// What DOES stay is the rail's WIDTH. The moat is measured inside what the rail leaves, so the column
// that draws the island is the one that has to give the width back.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// Opens the Connect-to-Host editor — the empty state's one next action. The no-op default keeps
    /// the column standalone-mountable in previews.
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
            // ⚠️ THE MODAL POINTER SHIELD. A hosted column lives in its OWN NSHostingView inside the
            // AppKit split while the floating overlay layer lives in the window root's — so a card
            // floating over this column does NOT occlude its hover tracking: AppKit tracking areas
            // are rect-based and keep firing under the card, and every hover inside lit up while the
            // pointer was on the palette. While a modal card is up the column goes hit-test-deaf,
            // which silences its hover the way the card's dismiss floor already silences its clicks.
            // Global Search (non-modal by design) leaves this open; the terminal's own AppKit
            // tracking is shielded by `TerminalPointerShield` off the same flag.
            //
            // On the Mac the AppKit root above this one shields the BAND off the same flag
            // (``SlopDeskMacUI/MacModalShield``); this modifier is what the phone has instead.
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
            // (``SlopDeskMacUI/MacPanelRail``, user-directed 2026-08-09), so this column gives back
            // its width. The island's own moat is measured inside what is left, which keeps the rail
            // standing on ground with the usual channel between it and the glass.
            .padding(.trailing, railed ? Slate.Metric.panelRailWidth : 0)
            .animation(Slate.Anim.columnSlide, value: railed)
        #else
        paneArea
        #endif
    }

    #if os(macOS)
    /// True while the panel is standing in as its rail.
    private var railed: Bool { chrome.codeSidebarCollapsed }
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
                let cause = PaneEmptyCause.resolve(
                    status: connection.status, host: connection.target.host,
                )
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
        // THE ISLAND'S CHIP STACK — the copy receipt, the transient notice and the collapsed-sidebar
        // connection indicator, centred on the ISLAND and standing off its foot. Mounted here rather
        // than on the window root so the stack is centred on the canvas it is talking about (the
        // window's own centre includes the navigator and the code panel) and so its inset is measured
        // from the glass's bottom edge instead of the window's (user-directed 2026-08-09).
        .overlay(alignment: .bottom) {
            if let overlayCoordinator {
                IslandChipStack(
                    store: store, coordinator: overlayCoordinator,
                    sidebarCollapsed: chrome.sidebarCollapsed,
                )
            }
        }
    }
}
#endif
