// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — the ``WorkspaceTabStrip``, collapsed-only: the tab list the hidden sidebar took with
//     it, laid horizontally on the project beds it already had. It starts one plate + one gap to the
//     right of ``Slate/Metric/windowControlsLead``, leaving the slot the window-level sidebar toggle
//     stands in. That toggle is NOT mounted here (user-directed 2026-08-09): it used to be a reveal
//     twin cross-faded against a hide twin inside the navigator, and the pair rode the collapse
//     slide. One button now hangs off the window root — see ``WindowSidebarToggle``.
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
        // to meet them. `SlopDeskClientApp.growTitlebarToBandHeight` now gives AppKit a titlebar of
        // the band's own height and lets IT centre the lights (user-directed 2026-08-09), so the
        // band has ONE row and plain centring finds it.
        ZStack {
            // Left: the tabs the hidden sidebar took with it — collapsed-only. The sidebar toggle
            // itself is NOT here (``WindowSidebarToggle`` owns it at window level); the strip only
            // leaves its slot free.
            HStack(spacing: Slate.Metric.space2) {
                if !rows.isEmpty {
                    WorkspaceTabStrip(store: store, rows: rows, onSelect: onSelectPane)
                        // The TABS arrive: they wait one control to the leading side and slide into
                        // place as the column finishes leaving, so they read as the list coming
                        // across with the column rather than as a layer switching on. The toggle
                        // beside them stays perfectly still through all of it — that is the point of
                        // its move to the window root.
                        .offset(x: sidebarVisible ? -Slate.Metric.heightControl : 0)
                }
            }
            .opacity(sidebarVisible ? 0 : 1)
            .allowsHitTesting(!sidebarVisible)
            // The toggle's own slot (plate + gap) plus the lights' lead — the strip begins exactly
            // where it did when the reveal twin still stood in that space.
            .padding(.leading, Slate.Metric.windowControlsLead + Slate.Metric.plate + Slate.Metric.space2)
            // Reserve the trailing plate's slot so a long run of tabs scrolls instead of sliding
            // under the right-panel reopen button.
            .padding(.trailing, Slate.Metric.plate + 2 * Slate.Metric.space3)
            // Never RIDE the collapse slide (the column edge travels x 80→300): the strip lands as
            // the column finishes, so the delay tracks `columnSlideDuration` rather than a literal.
            // Leaving is the mirror and must CLEAR first — no delay, and quick, so the arriving
            // column never catches the strip still on screen.
            .animation(
                sidebarVisible
                    ? Slate.Anim.fadeOut
                    : Slate.Anim.columnSlide.delay(Slate.Anim.columnSlideDuration * 0.55),
                value: sidebarVisible,
            )
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
                    // Same contract as the leading cluster: land as the column finishes leaving,
                    // clear immediately when it comes back.
                    .animation(
                        codeSidebarVisible
                            ? Slate.Anim.fadeOut
                            : Slate.Anim.columnSlide.delay(Slate.Anim.columnSlideDuration * 0.55),
                        value: codeSidebarVisible,
                    )
                    .animation(Slate.Anim.smallFade, value: topHover)
                    .help("Show the right panel")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            // THE HIDE TWIN'S OWN x. The panel's strip pays `space2` at both ends
            // (``CodeSidebarColumn.strip``), so a reopen at the same inset appears exactly where the
            // hide button that closed the panel stood — the same "one button that stays put" the
            // navigator's toggle now has. It also stands on GROUND at last: the island's top starts
            // at the band's bottom in every state (``slateIsland()``, user-directed 2026-08-09), so
            // this plate no longer straddles the island's 26pt corner half-sunk in the glass, which
            // is what made it unreadable (user-reported 2026-08-09).
            .padding(.trailing, Slate.Metric.space2)
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
