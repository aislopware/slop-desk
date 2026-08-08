// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — sidebar REOPEN (`sidebar.left`), only while the sidebar is collapsed (expanded
//     toggle lives inside the sidebar traffic-light strip). Fixed lead 80 clears the system
//     lights.
//   • right — the RIGHT-panel REOPEN (`sidebar.right`), only while the panel is collapsed — the
//     expanded-state hide toggle lives in the panel's OWN strip trailing corner (user-directed
//     2026-08-03; the same split the left sidebar has: reopen in the titlebar, hide inside the
//     surface it hides). The `sidebar.*` glyph pair stays: otty's `inset.filled.*third.square`
//     pair was tried and user-rejected 2026-08-03. The connection cluster shows here ONLY while
//     the LEFT sidebar is collapsed (resting home is the sidebar FOOTER).
// The CENTRE IS EMPTY (user-directed 2026-08-08): the pane title and its `⋯` menu are gone. With the
// terminal lifted as an island, the band above it is the island's top moat — a strip of bare ground —
// and a label floating in it read as chrome the layout no longer has room for. Nothing was lost: split
// / move / close all carry chords, and the cwd readout with its Copy Path row lives in the command
// palette's DIRECTORY section. The window title itself is unaffected (`.navigationTitle` still feeds
// Mission Control, the window menu and screenshots).
//
// The plate buttons are HOVER-REVEALED (the otty behavior): hidden at rest,
// faded in while the pointer is inside the top strip (`HoverSensor` — hit-test-transparent, so the
// strip stays draggable/clickable). The connection cluster stays always-visible: it is STATUS, not a
// control. The reopen button flips the shared `WorkspaceChromeState` flag that the split
// representable reads to collapse the matching `NSSplitViewItem` — same machinery the old toolbar drove.

#if canImport(SwiftUI)
import Foundation
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
#if os(macOS)
import AppKit // NSPasteboard for "Copy Path"
#endif

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
