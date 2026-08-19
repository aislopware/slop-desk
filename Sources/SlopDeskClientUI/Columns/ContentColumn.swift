// ContentColumn — the centre content area's CANVAS, and now ONLY that: the active tab's pane tree via
// the identity-preserving `SplitContainer`, or a Slate empty-state when there is no session/tab.
//
// The TITLEBAR BAND and the collapsed panel's RAIL are no longer here. Both are AppKit
// (``SlopDeskMacUI/MacTitlebarBand``, ``SlopDeskMacUI/MacPanelRail``), mounted as this column's
// SIBLINGS by ``SlopDeskMacUI/MacContentColumn`` rather than as overlays on top of it — which is why
// nothing in this file reserves the band's height or hands hit-testing back to either.
//
// AND NEITHER IS THE ISLAND (docs/56 stage F, P5). The moat, the window-scale corner, the glass and
// its rim were `slateIsland(clearingBand:)` applied here, plus a trailing padding giving the rail its
// width back; they are ``SlopDeskMacUI/MacContentColumn``'s constraints and one CALayer now. The point
// is not tidiness. This view is hosted in ONE `NSView`, and the moat was the whole of the difference
// between that view's frame and the canvas the pane drag hit-tests against — the difference
// `DropTargetFrameReader` was written to measure from the SwiftUI side because AppKit could not see
// it. Moved up, the difference is zero, the registration is three AppKit lines in the column, and the
// reader is deleted rather than ported.
//
// The last platform gate went with it: what is left in this file is what BOTH renderers mount.

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
    /// The tone this column stands on wherever nothing covers it — in practice the empty state's
    /// ground, since a mounted canvas paints its own face.
    ///
    /// `nil` means the HOST paints it, which is the Mac: there this column IS the island's interior,
    /// and the island's fill, corner and rim are one AppKit layer's three properties
    /// (``SlopDeskMacUI/MacContentColumn``). A second fill here would lay chrome GROUND over the
    /// island's GLASS — the two tones the one-island law is spent keeping apart.
    var ground: Color? = Slate.Surface.field

    /// The scene overlay reducer, re-injected by the split host (the hosted column does not inherit
    /// the WindowGroup environment). Read for the modal pointer shield below; `nil` (previews /
    /// tests) reads as "no modal up".
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    var body: some View {
        paneArea
            // The chrome model rides the environment so DEEP descendants (a terminal leaf actuating
            // open-in-code-panel) can reveal the code sidebar without threading the reference
            // through every pane-tree layer. The leaf reads it OPTIONALLY (nil in previews/tests).
            .environment(chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Whatever this column stands on where the canvas does not reach — the phone's own
            // ground, and NOTHING on the Mac, where the island under it is the ground (see ``ground``).
            .background(ground ?? .clear)
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
