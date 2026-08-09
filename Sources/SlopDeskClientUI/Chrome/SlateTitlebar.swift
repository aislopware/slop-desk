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

    /// The chrome's ambient polarity, kept for the one control that may leave the ground: the
    /// panel's reopen plate stands ON the island whenever the navigator is showing.
    @Environment(\.colorScheme) private var chromeScheme

    /// How far the panel's reopen plate keeps off the window's trailing edge — far enough that its
    /// whole 24pt square lands on the island's STRAIGHT top edge instead of on the corner curve. See
    /// the note at the plate itself.
    private static var reopenTrailing: CGFloat {
        Slate.Metric.islandInset + Slate.Metric.islandRadius + Slate.Metric.space1
    }

    var body: some View {
        // Everything in the band hangs from its TOP LINE (``Slate/Metric/bandInset``), never centred
        // in the band (user-directed 2026-08-09): the line is the island's top edge, and a control
        // centred in the band sits above it. The traffic lights meet the same line from the other
        // side — `SlopDeskClientApp.lowerTrafficLightsToTheTopLine` declares the titlebar height that
        // makes AppKit park them there.
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
            }
            .opacity(sidebarVisible ? 0 : 1)
            .allowsHitTesting(!sidebarVisible)
            // The toggle's own slot (plate + gap) plus the lights' lead — the strip begins exactly
            // where it did when the reveal twin still stood in that space.
            .padding(.leading, Slate.Metric.windowControlsLead + Slate.Metric.plate + Slate.Metric.space2)
            // Reserve the trailing plate's slot so a long run of tabs scrolls instead of sliding
            // under the right-panel reopen button.
            .padding(.trailing, Self.reopenTrailing + Slate.Metric.plate + Slate.Metric.space2)
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
            .padding(.top, Slate.Metric.bandInset)
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
                    // ON THE GLASS, so it reads in the glass's polarity. While the navigator is
                    // showing, the island's top edge is the band's own line and this plate — the one
                    // band control the island can reach — stands on it rather than on ground. With
                    // the navigator hidden the island drops below the whole band and the plate is
                    // back on cream, so the polarity follows the surface instead of the state.
                    .environment(\.colorScheme, chrome.sidebarCollapsed ? chromeScheme : Slate.glassColorScheme)
                    .help("Show the right panel")
            }
            .padding(.top, Slate.Metric.bandInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
            // CLEAR OF THE CORNER, not flush with the window's edge. The plate used to pay the same
            // `space2` the panel's own hide button pays (``CodeSidebarColumn.strip``) so that reopen
            // and hide stood at one x — but on the band's line that inset puts the plate's top-right
            // exactly where the island's 26pt corner curves away, half on glass and half on cream,
            // which is what made it unreadable (user-reported 2026-08-09). Past `islandInset +
            // islandRadius` the island's top edge is straight, so the plate sits wholly on it; the
            // extra `space1` keeps it off the tangent point.
            .padding(.trailing, Self.reopenTrailing)
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
