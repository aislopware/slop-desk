// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — the ``WorkspaceTabStrip``, collapsed-only: the tab list the hidden sidebar took with
//     it, laid horizontally on the project beds it already had. It starts at
//     ``RailStatusRollupMount/collapsedTrailingEdge`` — past the sidebar toggle's slot AND past the
//     agent rollup that parks beside it while the column is hidden. Neither of those is mounted
//     here (both hang off the window root: ``WindowSidebarToggle``, user-directed 2026-08-09 — it
//     used to be a reveal twin cross-faded against a hide twin inside the navigator, and the pair
//     rode the collapse slide — and ``RailStatusRollupMount``, 2026-08-11). The strip only leaves
//     their room.
//   • right — the CONNECTION ISLAND, collapsed-only, anchored to the strip's trailing corner
//     (user-directed 2026-08-09). It is the SAME island that stands at the navigator's foot while
//     the tabs are vertical: the status follows the tab list's axis, so with the list laid across
//     the band the island lays down beside it, one line on the same bed. The panel's reopen does NOT
//     live here — the collapsed panel leaves a RAIL carrying its own toggle instead (``PanelRail``,
//     user-directed 2026-08-09), which is a control that is always there and always in the same
//     place, and never has to stand on the island's corner.
// The CENTRE IS EMPTY (user-directed 2026-08-08): the pane title and its `⋯` menu are gone. With the
// terminal lifted as an island, the band above it is the island's top moat — a strip of bare ground —
// and a label floating in it read as chrome the layout no longer has room for. Nothing was lost: split
// / move / close all carry chords, and the cwd readout with its Copy Path row lives in the command
// palette's DIRECTORY section. The window title itself is unaffected (`.navigationTitle` still feeds
// Mission Control, the window menu and screenshots).
//
// The CENTRE stays empty even now that the trailing corner is occupied: the strip's two ends belong
// to the two things the collapse displaced (the tabs, and the status that stood under them), and the
// middle is still the island's top moat.

// `os(macOS)` on the WHOLE file, not just on the AppKit import. This is window-titlebar chrome —
// it stands on the traffic lights' line and hangs off `.hiddenTitleBar`, neither of which iOS has —
// and its only mount, `ContentColumn`, is already inside `#if os(macOS)`. The type itself was not,
// so it still COMPILED for the iOS triple, where its body reaches for `RailStatusRollupMount`, a
// macOS-only view. That has been a hard error on iOS since the rollup moved into the band
// (2026-08-11) and nothing reported it: `swift build` compiles the macOS slice only, and
// `scripts/check-ios.sh` — which exists for exactly this — was reachable from no make target.
// It is `make check-ios` now.
#if canImport(SwiftUI) && os(macOS)
import AppKit // NSPasteboard for "Copy Path"
import Foundation
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct SlateTitlebar: View {
    let store: WorkspaceStore
    let chrome: WorkspaceChromeState
    /// The memoized structural rows the collapsed-state tab strip renders — handed down from the
    /// content column so the strip and the sidebar share ONE rows build. Empty (previews / iOS /
    /// tests) simply mounts no strip.
    var rows: [RailRow] = []
    /// Focus a pane from the strip. No-op default keeps the titlebar standalone-mountable.
    var onSelectPane: (PaneID) -> Void = { _ in }
    /// The app-global connection — the trailing island's model. `nil` (previews / tests) omits it.
    var connection: AppConnection?
    /// Opens the Connect-to-Host editor from that island.
    var onConnect: () -> Void = {}

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }
    private var codeSidebarVisible: Bool { !chrome.codeSidebarCollapsed }

    var body: some View {
        // Everything in the band hangs from ``Slate/Metric/bandControlInset``, which is the inset
        // that puts a control's CENTRE on the traffic lights' centre (user-directed 2026-08-09 — the
        // plates read low beside the discs when both hung from the island's line instead). The
        // lights meet that centre from the other side: `SlopDeskClientApp.lowerTrafficLightsToTheTopLine`
        // declares the titlebar height AppKit parks them by.
        ZStack(alignment: .top) {
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
                if let connection {
                    // The strip above is a horizontal ScrollView and takes whatever width is left,
                    // so this island needs no spacer to be pushed to the trailing edge — and a long
                    // tab run scrolls under it rather than shoving it off the band.
                    ConnectionStatusMount(
                        store: store, connection: connection, onConnect: onConnect, layout: .inline,
                    )
                    // The mirror of the tabs' arrival: it waits one control OUT on the trailing side
                    // and lands as the column finishes leaving, so the two halves of the band fill
                    // in from their own edges instead of both sliding the same way.
                    .offset(x: sidebarVisible ? Slate.Metric.heightControl : 0)
                }
            }
            .opacity(sidebarVisible ? 0 : 1)
            .allowsHitTesting(!sidebarVisible)
            // ⚠️ The strip begins after EVERYTHING already standing on that band's leading side —
            // the lights, the toggle's slot, and (since 2026-08-11) the agent rollup that parks
            // beside the toggle when the column is gone. It used to stop at the toggle, and the
            // marks landed on top of the first tab (user-reported). One sum, owned by
            // ``RailStatusRollupMount``, so the two can never drift apart again.
            .padding(.leading, RailStatusRollupMount.collapsedTrailingEdge)
            // Reserve the trailing slot so a long run of tabs scrolls instead of sliding under the
            // panel's rail (or, with the panel open, off the column's own trailing edge).
            .padding(
                .trailing,
                codeSidebarVisible ? Slate.Metric.space2 : Slate.Metric.panelRailWidth,
            )
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
            .padding(.top, Slate.Metric.bandControlInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
        .animation(Slate.Anim.standard, value: sidebarVisible)
    }

    // NOTE: the titlebar carries NO hidden SwiftUI `.keyboardShortcut` for the chrome chords. ⌘⇧L
    // "Toggle Tabs Panel" (sidebar) is owned by the app-level
    // `WorkspaceKeyDispatcher` NSEvent monitor (registry action `.toggleSidebar`,
    // wired to `chrome.toggleSidebar` in `WorkspaceRootView`). A SwiftUI shortcut
    // here would be DEAD — the monitor swallows the chord before the responder chain sees it — so we keep a
    // SINGLE owner per chord. The visible plate buttons (the window's sidebar toggle and the panel
    // rail's) still drive the same `chrome` flags on click.
}

#endif
