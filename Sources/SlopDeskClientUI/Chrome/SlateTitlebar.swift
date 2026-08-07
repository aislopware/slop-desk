// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — sidebar REOPEN (`sidebar.left`), only while the sidebar is collapsed (expanded
//     toggle lives inside the sidebar traffic-light strip). Fixed lead 80 clears the system
//     lights.
//   • centre— EMPTY. The active-title `⋯` menu that lived here was removed (user-directed
//     2026-08-07, islands round): the sidebar's active row already names the pane, and every menu
//     action has a first-class home (⌘D/⌘⇧D splits, ⌥⌘arrows, ⌘W, the palette).
//   • right — the RIGHT-panel REOPEN (`sidebar.right`), only while the panel is collapsed — the
//     expanded-state hide toggle lives in the panel's OWN strip trailing corner (user-directed
//     2026-08-03; the same split the left sidebar has: reopen in the titlebar, hide inside the
//     surface it hides). The `sidebar.*` glyph pair stays: otty's `inset.filled.*third.square`
//     pair was tried and user-rejected 2026-08-03. The connection cluster shows here ONLY while
//     the LEFT sidebar is collapsed (resting home is the sidebar FOOTER).
// The WHOLE strip is HOVER-REVEALED (user-directed 2026-08-07, islands round): at rest the strip
// shows NOTHING — the terminal island runs to the window top (Canario keeps no title band).
// Pointer-in-strip fades in the connection cluster and the reopen plates together (`HoverSensor` —
// hit-test-transparent, so the strip stays draggable/clickable). The reopen button flips the shared
// `WorkspaceChromeState` flag that the split representable reads to collapse the matching
// `NSSplitViewItem` — same machinery the old toolbar drove.

#if canImport(SwiftUI)
import Foundation
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct SlateTitlebar: View {
    let store: WorkspaceStore
    let chrome: WorkspaceChromeState
    /// The app-global connection — drives the trailing status cluster. Optional so the titlebar stays
    /// standalone-mountable in previews / snapshot tests (`nil` simply hides the cluster).
    var connection: AppConnection?
    /// Tapping the status cluster opens the Connect-to-Host editor (``OverlayCoordinator/openConnect()``).
    var onConnect: () -> Void = {}

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }
    private var codeSidebarVisible: Bool { !chrome.codeSidebarCollapsed }

    /// Pointer-in-top-strip — the reveal gate for both reopen buttons (`HoverSensor` below).
    @State private var topHover = false

    var body: some View {
        // Aligns the controls to the TRAFFIC-LIGHT row: top-anchored at `rowTop` so a 24pt plate's icon
        // centres at y≈15 (the row the red/yellow/green buttons sit on), NOT the vertical centre of the 40pt
        // strip.
        let rowTop: CGFloat = 3
        return ZStack(alignment: .top) {
            // Left: sidebar REOPEN only while collapsed AND the top strip is hovered. On reveal-by-collapse
            // fade in after the slide settles (never ride it, x 80→300); on reveal-by-hover just small-fade.
            PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                .opacity(!sidebarVisible && topHover ? 1 : 0)
                .allowsHitTesting(!sidebarVisible && topHover)
                .padding(.leading, 80)
                .animation(sidebarVisible ? nil : Slate.Anim.standard.delay(0.15), value: sidebarVisible)
                .animation(Slate.Anim.smallFade, value: topHover)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, rowTop)

            // Right: the RIGHT-panel REOPEN — only while the panel is COLLAPSED and the top strip
            // is hovered (user-directed 2026-08-03: the expanded-state hide toggle moved into the
            // panel's own strip, so this slot mirrors the left sidebar's reopen exactly). On
            // reveal-by-collapse fade in after the slide settles; on reveal-by-hover just
            // small-fade. The slot is ALWAYS reserved (hidden ⇒ transparent, not absent) so the
            // connection cluster never shifts — the zero-shift rule.
            HStack(spacing: Slate.Metric.space2) {
                if let connection, !sidebarVisible {
                    ConnectionCluster(
                        connection: connection,
                        pingMS: ConnectionTelemetry.pingMS(store),
                        fps: ConnectionTelemetry.fps(store),
                        kbps: ConnectionTelemetry.kbps(store),
                        onConnect: onConnect,
                    )
                    // Hover-revealed with the rest of the strip — at rest the island's top edge
                    // stays clean (the cluster's resting home is the sidebar footer anyway).
                    .opacity(topHover ? 1 : 0)
                    .allowsHitTesting(topHover)
                    .animation(Slate.Anim.smallFade, value: topHover)
                }
                PlateIconButton(symbol: .sidebarRight) { chrome.toggleCodeSidebar() }
                    .opacity(!codeSidebarVisible && topHover ? 1 : 0)
                    .allowsHitTesting(!codeSidebarVisible && topHover)
                    .animation(
                        codeSidebarVisible ? nil : Slate.Anim.standard.delay(0.15),
                        value: codeSidebarVisible,
                    )
                    .animation(Slate.Anim.smallFade, value: topHover)
                    .help("Show the right panel")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Slate.Metric.space3)
            .padding(.top, rowTop)
        }
        .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
        #if os(macOS) // HoverSensor is AppKit; this titlebar only MOUNTS on macOS but compiles for iOS
            .background(HoverSensor { topHover = $0 })
        #endif
            .animation(Slate.Anim.standard, value: sidebarVisible)
    }

    // NOTE: the titlebar carries NO hidden SwiftUI `.keyboardShortcut` for the chrome chords. ⌘⇧L
    // "Toggle Tabs Panel" (sidebar) is owned by the app-level
    // `WorkspaceKeyDispatcher` NSEvent monitor (registry action `.toggleSidebar`,
    // wired to `chrome.toggleSidebar` in `WorkspaceRootView`). A SwiftUI shortcut
    // here would be DEAD — the monitor swallows the chord before the responder chain sees it — so we keep a
    // SINGLE owner per chord. The visible plate buttons (the sidebar's own toggle and this reopen
    // button) still drive the same `chrome` flag on click.
}

#endif
