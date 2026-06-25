// OttyTitlebar — otty's full-width hover-reveal titlebar (`TitlebarHoverView` + chrome controls), ported from
// /Volumes/Lacie/Workspace/oss/otty-reversed (`OttyReplica.titlebar` + `TitleMenuButton`). It floats as a top
// overlay over the content area (the window runs `.hiddenTitleBar`, so there is NO system unified toolbar —
// this IS the chrome). A click-through hover catcher reveals the controls (fade-in 0.15s; on exit, dwell
// 0.40s + fade-out 0.20s) so the resting window is clean otty:
//   • left  — the sidebar toggle (hover-revealed; stays visible while the sidebar is collapsed)
//   • centre— the active tab's title as a `⋯` menu (working dir / split / move / find / close pane)
//   • right — the Details (inspector) toggle (stays visible while Details is open)
// The sidebar/Details toggles flip the shared `WorkspaceChromeState` flags that the split representable reads
// to collapse the matching `NSSplitViewItem` — same machinery the old toolbar drove.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation
import SFSafeSymbols
import SwiftUI
#if os(macOS)
import AppKit // NSPasteboard for "Copy Path"
#endif

struct OttyTitlebar: View {
    let store: WorkspaceStore
    let chrome: WorkspaceChromeState

    @State private var chromeShown = false
    @State private var hideWork: DispatchWorkItem?

    /// The active tab's active pane id — drives the centre title + the menu's pane actions.
    private var activePane: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    private var activeTitle: String {
        guard let id = activePane else { return "~" }
        let spec = store.tree.activeSession?.specs[id]
        let title = spec?.lastKnownTitle ?? spec?.title ?? ""
        return title.isEmpty ? "~" : title
    }

    private var sidebarVisible: Bool { !chrome.sidebarCollapsed }
    private var detailsVisible: Bool { !chrome.inspectorCollapsed }

    var body: some View {
        // otty aligns the controls to the TRAFFIC-LIGHT row: top-anchored at `rowTop` so a 24pt plate's icon
        // centres at y≈15 (the row the red/yellow/green buttons sit on), NOT the vertical centre of the 40pt
        // strip.
        let rowTop: CGFloat = 3
        return ZStack(alignment: .top) {
            #if os(macOS)
            TitlebarHoverCatcher { setHover($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif

            // Left: the sidebar toggle, on the traffic-light row (aligned with the Details toggle on the
            // right). The toggle lives in the CONTENT overlay, whose origin is the DIVIDER when the sidebar is
            // expanded but the WINDOW's left edge when collapsed. A single button with a state-dependent lead
            // therefore either DARTED right on collapse (the lead grew a frame before the content slid) or sat
            // too far in (a constant lead). So render TWO cross-fading instances, each at a FIXED lead, gated
            // by opacity + hit-testing so only one is live:
            //   • EXPANDED → tucked just past the divider (lead 12), hover-revealed.
            //   • COLLAPSED → clear of the traffic lights (lead 80), always visible; it fades in only AFTER the
            //     collapse settles (delay), so it never flashes at the wide-content position.
            ZStack(alignment: .topLeading) {
                PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                    .opacity(sidebarVisible && chromeShown ? 1 : 0)
                    .allowsHitTesting(sidebarVisible && chromeShown)
                    .padding(.leading, 12)
                PlateIconButton(symbol: .sidebarLeft) { chrome.toggleSidebar() }
                    .opacity(sidebarVisible ? 0 : 1)
                    .allowsHitTesting(!sidebarVisible)
                    .padding(.leading, 80)
                    .animation(Otty.Anim.standard.delay(sidebarVisible ? 0 : 0.15), value: sidebarVisible)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, rowTop)

            // Centre: the active title as a menu, on the traffic-light row.
            TitleMenuButton(title: activeTitle, store: store, activePane: activePane)
                .padding(.top, rowTop)

            // Right: Details toggle (stays visible while Details is open).
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PlateIconButton(symbol: detailsVisible ? .sidebarTrailing : .sidebarRight) {
                    chrome.toggleInspector()
                }
                .opacity(chromeShown || detailsVisible ? 1 : 0)
                .allowsHitTesting(chromeShown || detailsVisible)
            }
            .padding(.trailing, 10)
            .padding(.top, rowTop)
        }
        .frame(height: Otty.Metric.titlebarHeight, alignment: .top)
        .animation(Otty.Anim.standard, value: sidebarVisible)
        .animation(Otty.Anim.standard, value: detailsVisible)
    }

    // NOTE: the titlebar carries NO hidden SwiftUI `.keyboardShortcut` for the chrome chords. Both ⌘⇧L
    // "Toggle Tabs Panel" (sidebar) and ⌘⇧R "Toggle Details Panel" are owned by the app-level
    // `WorkspaceKeyDispatcher` NSEvent monitor (registry actions `.toggleSidebar` / `.toggleDetailsPanel`,
    // wired to `chrome.toggleSidebar` / `chrome.toggleInspector` in `WorkspaceRootView`). A SwiftUI shortcut
    // here would be DEAD — the monitor swallows the chord before the responder chain sees it — so we keep a
    // SINGLE owner per chord. The visible plate buttons (the Details toggle above, the sidebar toggle on the
    // left row) still drive the same `chrome` flags on click.

    /// otty's reveal timing: fade-in 0.15s on enter; on exit, dwell 0.40s then fade-out 0.20s (keeps the
    /// controls clickable while the pointer travels to them).
    private func setHover(_ over: Bool) {
        hideWork?.cancel()
        if over {
            withAnimation(Otty.Anim.reveal) { chromeShown = true }
            return
        }
        let work = DispatchWorkItem {
            withAnimation(.timingCurve(0.42, 0, 1, 1, duration: Otty.Anim.titlebarFadeOut)) { chromeShown = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Otty.Anim.titlebarDwell, execute: work)
    }
}

// MARK: - Title menu (centre)

/// The centred active-title button. Hover shows a `⋯` + plate; click opens the pane menu (working dir /
/// split / move / find / close pane). Ported from otty's `TitleMenuButton`, wired to the live store.
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
                    .font(.system(size: Otty.Typeface.body, weight: .medium))
                    .foregroundStyle(hover || show ? Otty.Text.primary : Otty.Text.secondary)
                    .lineLimit(1)
                Image(systemSymbol: .ellipsis)
                    .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(Otty.Text.icon)
                    .opacity(hover || show ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hover || show ? Otty.State.hover : .clear, in: .rect(cornerRadius: Otty.Metric.radiusControl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Otty.Anim.smallFade, value: hover)
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

// MARK: - Title-menu row chrome (ported from otty's TMRow/TMSection/TMDivider)

private struct TitleMenuSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: Otty.Typeface.small, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Otty.State.header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }
}

private struct TitleMenuDivider: View {
    var body: some View {
        Rectangle().fill(Otty.Line.divider).frame(height: 1)
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
                    Image(systemName: icon).font(.system(size: Otty.Typeface.base)).foregroundStyle(Otty.Text.icon)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: Otty.Typeface.base))
                    .foregroundStyle(dim ? Otty.Text.secondary : Otty.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.system(size: Otty.Typeface.footnote)).foregroundStyle(Otty.Text.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(hovering ? Otty.State.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
