// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — sidebar REOPEN, only while the sidebar is collapsed (expanded toggle lives inside the
//     sidebar traffic-light strip). Fixed lead 80 clears the system lights.
//   • centre— the active tab's title as a `⋯` menu (working dir / split / move / find / close pane)
//   • right — the Host Windows rail REOPEN, only while the rail is collapsed (its expanded toggle
//     lives inside the rail strip — the mirror of the left arrangement), plus the connection cluster
//     ONLY while the LEFT sidebar is collapsed (resting home is the sidebar FOOTER; trailing titlebar
//     has room — never jammed next to the traffic lights).
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
        let kind = spec?.kind ?? .terminal
        // Same source as the sidebar rail row (`RailRowsBuilder.rowTitle`) and the macOS window title
        // (`WorkspaceRootView.windowTitle`): the focused pane's cwd FOLDER NAME (an explicit rename wins,
        // a cwd-less pane falls back to its foreground program), NOT the raw shell title — so the centre
        // chip TRACKS the active pane instead of showing a static "Terminal". A `cd` / pane switch re-titles
        // it reactively (both read observed `tree` state).
        //
        // The `paneForegroundProcess` read is GUARDED (perf audit 2026-07-11) by the SAME
        // `RailStructureKey.titledByProcess` escape-order check the sidebar's structural fingerprint uses:
        // this titlebar is ALWAYS mounted, so an unconditional read made its body a dependent of the WHOLE
        // process dict — a background pane's 1Hz process tick re-ran it even though only a cwd-less,
        // non-renamed pane's title ever depends on that dict.
        let titledByProcess = RailStructureKey.titledByProcess(kind: kind, spec: spec)
        let title = RailRowsBuilder.rowTitle(
            kind: kind, spec: spec, processLabel: titledByProcess ? store.paneForegroundProcess[id] : nil,
        )
        return title.isEmpty ? "~" : title
    }

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }
    private var hostRailVisible: Bool { !chrome.hostRailCollapsed }

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

            // Centre: the active title as a menu, on the traffic-light row. The unseen-attention dot's
            // visibility + tint are computed INSIDE `TitleMenuButton` (perf audit 2026-07-11), not read
            // here: `store.unseenAttentionPanes` is a full DFS over every session/tab/pane touching a wide
            // net of volatile dicts (agent status / completion / busy / process / progress / gates) + a
            // sort, and this titlebar body is ALWAYS mounted — reading it here made the WHOLE body (the
            // sidebar-toggle plate, the connection cluster, the slide animation) a dependent of every one
            // of those dicts, so ANY pane's 1Hz tick anywhere re-ran all of it. Scoping the read to the
            // leaf button means a tick re-renders only that small button — mirrors `RailRowsMemo`'s
            // leaf-scoping shape for the sidebar rail.
            TitleMenuButton(title: activeTitle, store: store, activePane: activePane)
                .padding(.top, rowTop)

            // Right: the Host Windows rail REOPEN (only while the rail is collapsed — the expanded
            // toggle lives inside the rail's strip, exactly the left sidebar's split of duties), with
            // the connection cluster beside it (collapsed-LEFT-sidebar fallback only; footer is the
            // resting home). The reopen slot is ALWAYS reserved (hidden ⇒ transparent, not absent) so
            // the cluster never shifts when the rail toggles — the zero-shift rule.
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
                // Fade in after the collapse settles; hide instantly on expand so it doesn't ride
                // the slide — the same choreography as the left reopen button.
                PlateIconButton(symbol: .sidebarRight) { chrome.toggleHostWindows() }
                    .opacity(hostRailVisible ? 0 : 1)
                    .allowsHitTesting(!hostRailVisible)
                    .animation(
                        hostRailVisible ? nil : Slate.Anim.standard.delay(0.15),
                        value: hostRailVisible,
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Slate.Metric.space3)
            .padding(.top, rowTop)
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
/// The trailing dot is the unseen-attention indicator (``WorkspaceStore/hasUnseenAttention``): the SAME
/// static status dot the sidebar tab rows wear (one vocabulary — the user reads red/blue identically in
/// both places), tinted by the most-urgent waiting pane (``WorkspaceStore/unseenAttentionPanes``'s head).
/// Computed HERE, not by the parent ``SlateTitlebar`` (perf audit 2026-07-11): `unseenAttentionPanes` is a
/// full DFS over every session/tab/pane touching a wide net of volatile store dicts + a sort, and
/// `SlateTitlebar` is an ALWAYS-MOUNTED overlay — reading the walk there made its WHOLE body (plate button
/// + connection cluster + slide animation) a dependent of all those dicts. Scoping the read to this small
/// leaf means a pane's status tick elsewhere re-renders only this button. The walk is also SINGLE-BOUND
/// (`let waiting = …` below, mirroring ``TitlePaneMenu``'s own bind) — the old shape read
/// `store.unseenAttentionPanes` twice (once for the dot, once for the tint), redoing the DFS twice per eval.
///
/// It lives in the trailing COMPLICATION SLOT the hover `⋯` already reserves — the one-trailing-complication
/// anatomy every Slate row speaks (``SlateTabRow``/``SlatePopoverRow``) — so the centred title NEVER shifts,
/// and at rest the titlebar reads `title ●` exactly like a tab row. On hover/press the dot yields to the
/// `⋯` (you are about to open the menu, whose NEEDS-ATTENTION section is the dot's answer). Vanishes when
/// everything is seen (MERIDIAN zero-ornament at rest). Superscript-pip and leading-bullet variants were
/// tried and rejected (2026-07-10): a badge riding TEXT reads as dirt — badges belong on icons or in the
/// row's trailing slot.
private struct TitleMenuButton: View {
    let title: String
    let store: WorkspaceStore
    let activePane: PaneID?

    @State private var hover = false
    @State private var show = false

    var body: some View {
        let waiting = store.unseenAttentionPanes
        let showDot = !waiting.isEmpty
        let dotTint = Self.tint(for: waiting.first?.badge)
        return Button { show.toggle() } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: .medium))
                    .foregroundStyle(hover || show ? Slate.Text.primary : Slate.Text.secondary)
                    .lineLimit(1)
                // The ONE trailing complication slot (always reserved): the attention dot at rest, the
                // `⋯` menu hint on hover/press. A ZStack so the swap is a cross-fade in place.
                ZStack {
                    Image(systemSymbol: .ellipsis)
                        .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                        .foregroundStyle(Slate.Text.icon)
                        .opacity(hover || show ? 1 : 0)
                    SlateStatusDot(color: dotTint, size: 7)
                        .opacity(showDot && !hover && !show ? 1 : 0)
                }
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

    /// The title pip's tint — the STATUS colour of the most-urgent waiting pane (the head of the
    /// urgency-sorted ``WorkspaceStore/unseenAttentionPanes``), matching the sidebar badge dots: red for
    /// a blocked agent / failed command, BLUE (the agent palette's done 🔵) for unread finishes, green
    /// only during the brief clean-finish flash. Secondary when nothing waits (the pip is hidden then
    /// anyway — this is just its resting value).
    private static func tint(for badge: TabBadgeKind?) -> Color {
        switch badge {
        case .awaitingInput,
             .error: Slate.Status.err
        case .completed: Slate.Status.ok
        case .finished: Slate.Status.info
        default: Slate.Text.secondary
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
                    // The leading glyph IS the sidebar's badge view — one status vocabulary, rail ≡ menu.
                    // Line 2 = the host agent label (the actual blocking question / last assistant line)
                    // when the wire carried one, else the badge's caption; trailing = how long it has
                    // been waiting (the shortcut slot doubles as the age readout — one trailing
                    // complication, same anatomy).
                    SlatePopoverRow(
                        waitingTitle(entry.pane),
                        leading: TabBadgeView(kind: entry.badge),
                        subtitle: entry.label ?? Self.waitingCaption(entry.badge),
                        shortcut: Self.relativeAge(of: entry.since),
                    ) {
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

    /// The fallback second line for a waiting pane whose host sent no agent label — what the badge MEANS,
    /// in words. The non-attention kinds never reach the list; empty keeps them harmless if one ever does.
    static func waitingCaption(_ badge: TabBadgeKind) -> String {
        switch badge {
        case .awaitingInput: "Needs your input"
        case .error: "Failed"
        case .completed,
             .finished: "Finished"
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: ""
        }
    }

    /// A compact "how long has this been waiting" readout — `42s` / `5m` / `2h` / `3d`, or `nil` when the
    /// instant is unknown (no age shown) or in the future (clock skew — show nothing, never `-3s`). Pure +
    /// static so the bucketing is unit-pinned.
    static func relativeAge(of date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
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
