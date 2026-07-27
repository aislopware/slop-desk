// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — sidebar REOPEN (`sidebar.left`), only while the sidebar is collapsed (expanded toggle
//     lives inside the sidebar traffic-light strip). Fixed lead 80 clears the system lights.
//   • centre— the active tab's title as a `⋯` menu (working dir / split / move / find / close pane)
//   • right — the Host Windows rail REOPEN (`macwindow.on.rectangle` — the rail lists the host's
//     WINDOWS, so its toggle wears the window glyph, deliberately distinct from the left `sidebar.left`),
//     only while the rail is collapsed, plus the connection cluster ONLY while
//     the LEFT sidebar is collapsed (resting home is the sidebar FOOTER).
// Both reopen buttons are HOVER-REVEALED (the otty behavior): hidden at rest,
// faded in while the pointer is inside the top strip (`HoverSensor` — hit-test-transparent, so the
// strip stays draggable/clickable). The centre title + connection cluster stay always-visible: they are
// STATUS, not controls. The reopen button flips the shared `WorkspaceChromeState` flag that the split
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

    /// The active tab's active pane id — drives the centre title + the menu's pane actions.
    private var activePane: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    private var activeTitle: String {
        guard let id = activePane else { return "~" }
        let spec = store.tree.activeSession?.specs[id]
        let kind = spec?.kind ?? .terminal
        // Same source as the sidebar rail row (`RailRowsBuilder.rowTitle`) and the macOS window title
        // (`WorkspaceRootView.windowTitle`): the focused pane's cwd FOLDER NAME (an explicit rename wins,
        // a cwd-less pane falls back to its foreground program), NOT the raw shell title — so the centre
        // chip TRACKS the active pane instead of showing a static "Terminal". A `cd` / pane switch re-titles
        // it reactively (both read observed `tree` state).
        //
        // The `paneForegroundProcess` read is GUARDED by the SAME
        // `RailStructureKey.titledByProcess` escape-order check the sidebar's structural fingerprint uses:
        // this titlebar is ALWAYS mounted, so an unconditional read made its body a dependent of the WHOLE
        // process dict — a background pane's 1Hz process tick re-ran it even though only a cwd-less,
        // non-renamed pane's title ever depends on that dict.
        let cwd = store.paneCwd(for: id)
        let titledByProcess = RailStructureKey.titledByProcess(kind: kind, spec: spec, cwd: cwd)
        let title = RailRowsBuilder.rowTitle(
            kind: kind, spec: spec, cwd: cwd, liveTitle: store.liveProgramTitle(for: id),
            processLabel: titledByProcess ? store.paneForegroundProcess[id] : nil,
        )
        return title.isEmpty ? "~" : title
    }

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }

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

            // Centre: the active title as a menu, on the traffic-light row.
            TitleMenuButton(title: activeTitle, store: store, activePane: activePane)
                .padding(.top, rowTop)

            // Right: the connection cluster (collapsed-LEFT-sidebar fallback only; the sidebar footer
            // is its resting home).
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

// MARK: - Title menu (centre)

/// The centred active-title button. Hover shows a `⋯` + plate; click opens the pane menu (working dir /
/// split / move / find / close pane). Wired to the live store. The trailing slot holds only the hover
/// `⋯` menu hint — attention never rides the titlebar (the sidebar's ring marks are the one attention
/// surface), so at rest the centred title is bare (MERIDIAN zero-ornament at rest).
private struct TitleMenuButton: View {
    let title: String
    let store: WorkspaceStore
    let activePane: PaneID?

    @State private var hover = false
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: .medium))
                    .foregroundStyle(hover || show ? Slate.Text.primary : Slate.Text.secondary)
                    .lineLimit(1)
                Image(systemSymbol: .ellipsis)
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(Slate.Text.icon)
                    .opacity(hover || show ? 1 : 0)
            }
            .padding(.horizontal, Slate.Metric.space2)
            .frame(height: Slate.Metric.heightControl)
            .background(hover || show ? Slate.State.hover : .clear, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Slate.Anim.smallFade, value: hover)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            TitlePaneMenu(store: store, activePane: activePane, dismiss: { show = false })
        }
    }
}

/// The centre title's pane menu — the `.popover` content of ``TitleMenuButton``. Internal (not nested
/// private) so the L10 snapshot harness (`SlateSnapshotRender`) can render the REAL menu headlessly; a
/// popover never opens under `ImageRenderer`. `dismiss` closes the presenting popover before an action runs.
///
/// The menu speaks the shared ``SlatePopoverSection``/``SlatePopoverRow``/``SlatePopoverDivider``
/// vocabulary (MERIDIAN C3) — one menu chrome across the app, no per-popover drift.
struct TitlePaneMenu: View {
    let store: WorkspaceStore
    let activePane: PaneID?
    var dismiss: () -> Void = {}

    private var cwd: String? {
        guard let id = activePane else { return nil }
        return store.paneCwd(for: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlatePopoverSection("WORKING DIRECTORY")
            SlatePopoverRow(cwd ?? "~", icon: "folder", dim: true) {}
            SlatePopoverRow("Copy Path") { copyPath() }
            SlatePopoverDivider()
            SlatePopoverRow("Split Right", shortcut: "⌘D") { split(.horizontal) }
            SlatePopoverRow("Split Down", shortcut: "⌘⇧D") { split(.vertical) }
            SlatePopoverRow("Move Pane Left", shortcut: "⌥⌘←") { move(.left) }
            SlatePopoverRow("Move Pane Right", shortcut: "⌥⌘→") { move(.right) }
            SlatePopoverDivider()
            SlatePopoverRow("Close Pane", shortcut: "⌘W") { close() }
        }
        .padding(.vertical, 6)
        .frame(width: 260)
    }

    private func split(_ axis: SplitAxis) {
        dismiss()
        // A split MINTS a pane → create an in-pane CHOOSER pane (Terminal / Remote window), focused. Defer one
        // runloop tick so dismissing THIS menu's popover doesn't race the split's reconcile + focus.
        DispatchQueue.main.async { store.newTerminalPane(.split(axis: axis)) }
    }

    private func move(_ direction: FocusDirection) {
        dismiss()
        store.swapActivePaneInDirection(direction)
    }

    private func close() {
        guard let id = activePane else { return }
        dismiss()
        store.requestClosePaneTree(id)
    }

    private func copyPath() {
        dismiss()
        #if os(macOS)
        guard let path = cwd else { return }
        ClientPasteboard.write(path)
        #endif
    }
}

#endif
