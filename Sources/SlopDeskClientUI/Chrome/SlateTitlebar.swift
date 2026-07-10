// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — sidebar REOPEN, only while the sidebar is collapsed (expanded toggle lives inside the
//     sidebar traffic-light strip). Fixed lead 80 clears the system lights.
//   • centre— the active tab's title as a `⋯` menu (working dir / split / move / find / close pane)
//   • right — connection cluster ONLY while the sidebar is collapsed (resting home is the sidebar FOOTER;
//     trailing titlebar has room — never jammed next to the traffic lights).
// The reopen button flips the shared `WorkspaceChromeState` flag that the split representable reads
// to collapse the matching `NSSplitViewItem` — same machinery the old toolbar drove.

#if canImport(SwiftUI)
import Foundation
import SFSafeSymbols
import SlopDeskWorkspaceCore
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
        // Same source as the sidebar rail row (`RailRowsBuilder.rowTitle`) and the macOS window title
        // (`WorkspaceRootView.windowTitle`): the focused pane's cwd FOLDER NAME (an explicit rename wins,
        // a cwd-less pane falls back to its foreground program), NOT the raw shell title — so the centre
        // chip TRACKS the active pane instead of showing a static "Terminal". A `cd` / pane switch re-titles
        // it reactively (both read observed `tree` state).
        let title = RailRowsBuilder.rowTitle(
            kind: spec?.kind ?? .terminal, spec: spec, processLabel: store.paneForegroundProcess[id],
        )
        return title.isEmpty ? "~" : title
    }

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }

    /// The title pip's tint — the STATUS colour of the most-urgent waiting pane (the head of the
    /// urgency-sorted ``WorkspaceStore/unseenAttentionPanes``), matching the sidebar badge dots: red for
    /// a blocked agent / failed command, BLUE (the agent palette's done 🔵) for unread finishes, green
    /// only during the brief clean-finish flash. Secondary when nothing waits (the pip is hidden then
    /// anyway — this is just its resting value).
    private var attentionTint: Color {
        switch store.unseenAttentionPanes.first?.badge {
        case .awaitingInput,
             .error: Slate.Status.err
        case .completed: Slate.Status.ok
        case .finished: Slate.Status.info
        default: Slate.Text.secondary
        }
    }

    var body: some View {
        // Aligns the controls to the TRAFFIC-LIGHT row: top-anchored at `rowTop` so a 24pt plate's icon
        // centres at y≈15 (the row the red/yellow/green buttons sit on), NOT the vertical centre of the 40pt
        // strip.
        let rowTop: CGFloat = 3
        return ZStack(alignment: .top) {
            // Left: sidebar REOPEN only while collapsed (expanded toggle sits in the sidebar strip). Fixed
            // lead 80 clears traffic lights. Fade in after collapse settles; hide instantly on expand so it
            // doesn't ride the slide (x 80→300).
            PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                .opacity(sidebarVisible ? 0 : 1)
                .allowsHitTesting(!sidebarVisible)
                .padding(.leading, 80)
                .animation(sidebarVisible ? nil : Slate.Anim.standard.delay(0.15), value: sidebarVisible)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, rowTop)

            // Centre: the active title as a menu, on the traffic-light row.
            TitleMenuButton(
                title: activeTitle, showDot: store.hasUnseenAttention, dotTint: attentionTint,
                store: store, activePane: activePane,
            )
            .padding(.top, rowTop)

            // Right: connection cluster — collapsed-sidebar fallback only (footer is the resting home).
            // Trailing titlebar has room for host + metrics; never next to the traffic lights.
            if let connection, !sidebarVisible {
                ConnectionCluster(
                    connection: connection,
                    pingMS: ConnectionTelemetry.pingMS(store),
                    fps: ConnectionTelemetry.fps(store),
                    kbps: ConnectionTelemetry.kbps(store),
                    onConnect: onConnect,
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, Slate.Metric.space3)
                .padding(.top, rowTop)
            }
        }
        .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
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
/// split / move / find / close pane). Wired to the live store.
///
/// `showDot` is the bell-style unseen-attention indicator (``WorkspaceStore/hasUnseenAttention``): a tiny
/// SUPERSCRIPT pip riding the title's top-trailing corner — the notification-badge position, not an inline
/// bullet — tinted `dotTint` (the most-urgent waiting pane's STATUS colour, same map as the sidebar
/// badges). It appears while some OTHER pane is blocked / finished unread and vanishes when everything is
/// seen (MERIDIAN zero-ornament at rest). Rendered as an OVERLAY, so it never affects layout — the centred
/// title cannot shift when it comes and goes.
private struct TitleMenuButton: View {
    let title: String
    let showDot: Bool
    let dotTint: Color
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
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(dotTint)
                            .frame(width: 4, height: 4)
                            .offset(x: 5, y: -1.5)
                            .opacity(showDot ? 1 : 0)
                    }
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
        .animation(Slate.Anim.smallFade, value: showDot)
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
///
/// NEEDS ATTENTION (top, only while non-empty): the titlebar dot's per-pane breakdown
/// (``WorkspaceStore/unseenAttentionPanes`` — blocked first, then failures, then unread finishes).
/// Clicking a row FOCUSES that pane (session/tab switch included) — the dot points here, this answers
/// it. The section vanishes with the dot, so the at-rest menu is unchanged (zero ornament at rest).
struct TitlePaneMenu: View {
    let store: WorkspaceStore
    let activePane: PaneID?
    var dismiss: () -> Void = {}

    private var cwd: String? {
        guard let id = activePane else { return nil }
        return store.tree.activeSession?.specs[id]?.lastKnownCwd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let waiting = store.unseenAttentionPanes
            if !waiting.isEmpty {
                SlatePopoverSection("NEEDS ATTENTION")
                ForEach(waiting, id: \.pane) { entry in
                    // The leading glyph IS the sidebar's badge view — one status vocabulary, rail ≡ menu
                    // (the red orbit for blocked, the triangle for a failure, the dots for finishes).
                    SlatePopoverRow(waitingTitle(entry.pane), leading: TabBadgeView(kind: entry.badge)) {
                        jump(to: entry.pane)
                    }
                }
                SlatePopoverDivider()
            }
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

    /// The display title for a WAITING pane row — the same cwd-folder/rename/process chain the sidebar rail
    /// and the centre title speak (``RailRowsBuilder/rowTitle(kind:spec:processLabel:)``), resolved across
    /// ALL sessions (the list is global; the entry's pane may live outside the active session).
    private func waitingTitle(_ id: PaneID) -> String {
        let spec = store.tree.sessions.lazy.compactMap { $0.specs[id] }.first
        let title = RailRowsBuilder.rowTitle(
            kind: spec?.kind ?? .terminal, spec: spec, processLabel: store.paneForegroundProcess[id],
        )
        return title.isEmpty ? "~" : title
    }

    /// Focus a waiting pane from its NEEDS-ATTENTION row (switches session + tab as needed). Deferred one
    /// runloop tick so dismissing the popover doesn't race the focus reconcile — same idiom as `split`.
    private func jump(to id: PaneID) {
        dismiss()
        DispatchQueue.main.async { store.focusPaneTree(id) }
    }

    private func split(_ axis: SplitAxis) {
        dismiss()
        // A split MINTS a pane → create an in-pane CHOOSER pane (Terminal / Remote window), focused. Defer one
        // runloop tick so dismissing THIS menu's popover doesn't race the split's reconcile + focus.
        DispatchQueue.main.async { store.openChooserPane(.split(axis: axis)) }
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
