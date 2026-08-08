// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — sidebar REOPEN (`sidebar.left`), only while the sidebar is collapsed, ALWAYS VISIBLE
//     (user-directed 2026-08-09) at ``Slate/Metric/windowControlsLead`` — the same window x as the
//     hide twin inside the navigator's own strip, so the toggle never appears to move.
//   • then  — the ``WorkspaceTabStrip``, also collapsed-only: the tab list the hidden sidebar took
//     with it, laid horizontally on the project beds it already had.
//   • right — the RIGHT-panel REOPEN (`sidebar.right`), only while the panel is collapsed — the
//     expanded-state hide toggle lives in the panel's OWN strip trailing corner (user-directed
//     2026-08-03; the same split the left sidebar has: reopen in the titlebar, hide inside the
//     surface it hides). The `sidebar.*` glyph pair stays: otty's `inset.filled.*third.square`
//     pair was tried and user-rejected 2026-08-03.
// The CENTRE IS EMPTY (user-directed 2026-08-08): the pane title and its `⋯` menu are gone. With the
// terminal lifted as an island, the band above it is the island's top moat — a strip of bare ground —
// and a label floating in it read as chrome the layout no longer has room for. Nothing was lost: split
// / move / close all carry chords, and the cwd readout with its Copy Path row lives in the command
// palette's DIRECTORY section. The window title itself is unaffected (`.navigationTitle` still feeds
// Mission Control, the window menu and screenshots).
//
// NO CONNECTION STATUS (user-directed 2026-08-09). The cluster used to appear here whenever the
// sidebar was collapsed, mirroring the sidebar footer's resting copy; both are gone from the macOS
// chrome. The link still speaks where it MATTERS — the empty pane area names not-connected /
// link-down as its cause and carries the Connect action — and Connect-to-Host stays reachable from
// the palette. `ConnectionCluster` itself lives on: iOS mounts it in the navigation toolbar.
//
// The RIGHT-panel reopen plate is still HOVER-REVEALED (the otty behavior): hidden at rest, faded in
// while the pointer is inside the top strip (`HoverSensor` — hit-test-transparent, so the strip
// stays draggable/clickable). The reopen buttons flip the shared `WorkspaceChromeState` flag that
// the split representable reads to collapse the matching `NSSplitViewItem` — same machinery the old
// toolbar drove.

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
    /// The memoized structural rows the collapsed-state tab strip renders — handed down from the
    /// content column so the strip and the sidebar share ONE rows build. Empty (previews / iOS /
    /// tests) simply mounts no strip.
    var rows: [RailRow] = []
    /// Focus a pane from the strip. No-op default keeps the titlebar standalone-mountable.
    var onSelectPane: (PaneID) -> Void = { _ in }

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }
    private var codeSidebarVisible: Bool { !chrome.codeSidebarCollapsed }

    /// Pointer-in-top-strip — the reveal gate for both reopen buttons (`HoverSensor` below).
    @State private var topHover = false

    var body: some View {
        // Everything in the band is CENTRED on it. That used to be wrong — AppKit's default corner
        // inset put the traffic lights high in the 40pt band, so the controls had to be top-anchored
        // to meet them. `SlopDeskClientApp.positionWindowControls` now centres the lights instead
        // (user-directed 2026-08-09), so the band has ONE row and plain centring finds it.
        ZStack {
            // Left: the sidebar REOPEN and, beside it, the tabs the hidden sidebar took with it.
            // Both are collapsed-only; the button is ALWAYS visible in that state (it is the only
            // way back without knowing ⌘⇧L) and stands at the same window x as its hide twin inside
            // the navigator strip, so the toggle reads as one button that stays put.
            HStack(spacing: Slate.Metric.space2) {
                PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                    .help("Show the tabs panel")
                if !rows.isEmpty {
                    WorkspaceTabStrip(store: store, rows: rows, onSelect: onSelectPane)
                }
            }
            .opacity(sidebarVisible ? 0 : 1)
            .allowsHitTesting(!sidebarVisible)
            .padding(.leading, Slate.Metric.windowControlsLead)
            // Reserve the trailing plate's slot so a long run of tabs scrolls instead of sliding
            // under the right-panel reopen button.
            .padding(.trailing, Slate.Metric.plate + 2 * Slate.Metric.space3)
            // Never RIDE the collapse slide (the column edge travels x 80→300): fade in only once
            // it has settled.
            .animation(sidebarVisible ? nil : Slate.Anim.standard.delay(0.15), value: sidebarVisible)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: the RIGHT-panel REOPEN — only while the panel is COLLAPSED and the top strip
            // is hovered (user-directed 2026-08-03: the expanded-state hide toggle moved into the
            // panel's own strip, so this slot mirrors the left sidebar's reopen exactly). On
            // reveal-by-collapse fade in after the slide settles; on reveal-by-hover just
            // small-fade.
            HStack(spacing: Slate.Metric.space2) {
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
        }
        .frame(height: Slate.Metric.titlebarHeight)
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
