// SlateTitlebar — the full-width titlebar chrome. It floats as a top overlay over the content area (the
// window runs `.hiddenTitleBar`, so there is NO system unified toolbar — this IS the chrome):
//   • left  — the sidebar REOPEN button, shown ONLY while the sidebar is collapsed. The expanded-state
//     toggle lives INSIDE the sidebar (`NavigatorColumn`'s traffic-light strip) — the button belongs to
//     the panel it hides; the titlebar hosts it only when that panel is gone.
//   • centre— the active tab's title as a `⋯` menu (working dir / split / move / find / close pane)
//   • right — the ALWAYS-visible connection-status cluster (`TitlebarConnectionCluster`): dot + host +
//     live ping/fps, tap → the Connect-to-Host editor. Ambient window state.
// The reopen button flips the shared `WorkspaceChromeState` flag that the split representable reads
// to collapse the matching `NSSplitViewItem` — same machinery the old toolbar drove.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation
import SFSafeSymbols
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

    /// The active pane's live session — resolves the per-pane connection telemetry the status cluster
    /// shows: ping (per-pane channel RTT) and, for a GUI/video pane, the host stream cadence (fps).
    private var activeLive: LivePaneSession? {
        guard let id = activePane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The RTT (ms) for the status cluster. Prefers the ACTIVE pane's per-channel `latencyMS`, falling back
    /// to ANY live pane's when the active pane has none — a `.remoteGUI` window pane has no terminal-channel
    /// ping (`connection == nil`), so without this the ping would VANISH the moment you focus a window. Every
    /// pane pings the SAME host, so a sibling terminal's RTT is representative; `.min()` keeps it
    /// deterministic across the unordered registry.
    private var activePingMS: Double? {
        if let active = activeLive?.connection?.latencyMS { return active }
        return store.allSessions
            .compactMap { ($0 as? LivePaneSession)?.connection?.latencyMS }
            .min()
    }

    /// The active VIDEO pane's host-announced stream cadence (fps); `nil` for a terminal pane / until the
    /// host's FPS governor announces a value.
    private var activeFps: Int? { activeLive?.remoteWindow?.streamFps }

    /// The active VIDEO pane's remote-window size (points); `nil` for a terminal pane / pre-handshake.
    private var activeWindowSize: CGSize? { activeLive?.remoteWindow?.windowPointSize }

    private var activeTitle: String {
        guard let id = activePane else { return "~" }
        let spec = store.tree.activeSession?.specs[id]
        let title = spec?.lastKnownTitle ?? spec?.title ?? ""
        return title.isEmpty ? "~" : title
    }

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }

    var body: some View {
        // Aligns the controls to the TRAFFIC-LIGHT row: top-anchored at `rowTop` so a 24pt plate's icon
        // centres at y≈15 (the row the red/yellow/green buttons sit on), NOT the vertical centre of the 40pt
        // strip.
        let rowTop: CGFloat = 3
        return ZStack(alignment: .top) {
            // Left: the sidebar REOPEN button, live only while the sidebar is collapsed (the expanded-state
            // toggle sits inside the sidebar itself — `NavigatorColumn`'s traffic-light strip). Fixed lead 80
            // clears the traffic lights. Each direction shows the button only in its SETTLED state: it fades
            // in only AFTER the collapse slide settles (delay), and on expand it hides INSTANTLY (`nil`
            // animation) the moment the flag flips — anchored to the sliding content, a fade-out would RIDE
            // the expand slide rightward (x 80→300) and read as a flash.
            PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                .opacity(sidebarVisible ? 0 : 1)
                .allowsHitTesting(!sidebarVisible)
                .padding(.leading, 80)
                .animation(sidebarVisible ? nil : Slate.Anim.standard.delay(0.15), value: sidebarVisible)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, rowTop)

            // Centre: the active title as a menu, on the traffic-light row.
            TitleMenuButton(title: activeTitle, store: store, activePane: activePane)
                .padding(.top, rowTop)

            // Right: the connection-status cluster, on the traffic-light row. ALWAYS visible (ambient
            // window state — the single home for host/status/telemetry now the sidebar footer is gone).
            if let connection {
                TitlebarConnectionCluster(
                    connection: connection,
                    pingMS: activePingMS,
                    fps: activeFps,
                    windowSize: activeWindowSize,
                    onConnect: onConnect,
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
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
        .popover(isPresented: $show, arrowEdge: .bottom) { menu }
    }

    private var cwd: String? {
        guard let id = activePane else { return nil }
        return store.tree.activeSession?.specs[id]?.lastKnownCwd
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            TitleMenuSection("WORKING DIRECTORY")
            TitleMenuRow(icon: "folder", title: cwd ?? "~", dim: true) {}
            TitleMenuRow(title: "Copy Path") { copyPath() }
            TitleMenuDivider()
            TitleMenuRow(title: "Split Right", shortcut: "⌘D") { split(.horizontal) }
            TitleMenuRow(title: "Split Down", shortcut: "⌘⇧D") { split(.vertical) }
            TitleMenuRow(title: "Move Pane Left", shortcut: "⌥⌘←") { move(.left) }
            TitleMenuRow(title: "Move Pane Right", shortcut: "⌥⌘→") { move(.right) }
            TitleMenuDivider()
            TitleMenuRow(title: "Close Pane", shortcut: "⌘W") { close() }
                .padding(.bottom, 6)
        }
        .frame(width: 260)
    }

    private func split(_ axis: SplitAxis) {
        show = false
        // A split MINTS a pane → create an in-pane CHOOSER pane (Terminal / Remote window), focused. Defer one
        // runloop tick so dismissing THIS menu's popover doesn't race the split's reconcile + focus.
        DispatchQueue.main.async { store.openChooserPane(.split(axis: axis)) }
    }

    private func move(_ direction: FocusDirection) {
        show = false
        store.swapActivePaneInDirection(direction)
    }

    private func close() {
        guard let id = activePane else { return }
        show = false
        store.requestClosePaneTree(id)
    }

    private func copyPath() {
        show = false
        #if os(macOS)
        guard let path = cwd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #endif
    }
}

// MARK: - Title-menu row chrome (TMRow/TMSection/TMDivider)

private struct TitleMenuSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        // MERIDIAN L2: caps micro-labels speak the INSTRUMENT voice — same register as `SlateSectionHeader`
        // and the sort popover's section label (one voice per role, no per-popover drift).
        Text(title)
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
            .tracking(Slate.Typeface.instrumentTracking)
            .foregroundStyle(Slate.State.header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Slate.Metric.space3).padding(.top, Slate.Metric.space2).padding(.bottom, 2)
    }
}

private struct TitleMenuDivider: View {
    var body: some View {
        Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            .padding(.vertical, 5).padding(.horizontal, 10)
    }
}

private struct TitleMenuRow: View {
    var icon: String?
    var title: String
    var shortcut: String?
    var dim = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: Slate.Typeface.base)).foregroundStyle(Slate.Text.icon)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(dim ? Slate.Text.secondary : Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.system(size: Slate.Typeface.footnote)).foregroundStyle(Slate.Text.secondary)
                }
            }
            .padding(.horizontal, Slate.Metric.space3).frame(height: Slate.Metric.heightBar)
            .background(hovering ? Slate.State.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
