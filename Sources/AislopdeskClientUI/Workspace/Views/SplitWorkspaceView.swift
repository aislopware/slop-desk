// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit // NSApplication fullscreen notifications — the title-bar drag region only shows when windowed.
#endif

// MARK: - SplitWorkspaceView (the IDE shell root — W5, Muxy MainWindow skeleton)

/// The coding-IDE shell that replaces `CanvasView` as the live workspace content (docs/41 §3.4,
/// docs/42 W5), REWRITTEN to Muxy's hand-built `MainWindow` layout (no `NavigationSplitView`): a
/// **sessions sidebar** (``SessionSidebarView``) in a left nav column whose top reserves a window-drag
/// title-bar strip, a draggable divider (``PanelResizeHandle``), and a **main column** stacking the
/// window-title-bar tab strip (``TabBarView`` with `isWindowTitleBar: true`) over the recursive split
/// content (``SplitTreeView``) over the bottom status bar (``PaneStatusBar``). Binds the LIVE
/// ``WorkspaceStore/tree``.
///
/// The whole shell paints itself in the terminal's dark theme (`AislopdeskTheme.bg`) and draws to the
/// window edge under the hidden title bar (`ignoresSafeArea(.container, edges: .top)` +
/// ``WindowConfigurator``), so the traffic lights float over the sessions sidebar's reserved drag strip.
///
/// TODO(iOS tree carousel — deferred, see DECISIONS #8): there is no compact/iPhone per-tab tree
/// projection yet; this regular shell is the only tree projection (the iPhone per-tab carousel is
/// deliberately DEFERRED and is blocked by pre-existing iOS UIKit rot). Do not treat its absence as an
/// accident. The window-drag / traffic-light reservation is macOS-only; off macOS the strip collapses.
struct SplitWorkspaceView: View {
    @Bindable var store: WorkspaceStore

    /// The sessions-sidebar width, user-draggable via the inter-column ``PanelResizeHandle`` and clamped
    /// to the expanded min/max (Muxy keeps the rail resizable, not a fixed `NavigationSplitView` column).
    @State private var sidebarWidth: CGFloat = 240

    /// Whether the window is full-screen — when true the reserved title-bar drag strip is hidden (no
    /// traffic lights to clear in full-screen). Defaults `false`; tracked from the custom
    /// `.aislopdeskWindowFullScreenDidChange` notification (posted by `WindowConfigurator.Coordinator`
    /// with `object: window` and `userInfo["isFullScreen"]: Bool`) filtered to this view's OWN window,
    /// so Settings sheets, command palettes, or a second workspace window going full-screen cannot
    /// wrongly flip this state.
    @State private var isFullScreen = false

    #if os(macOS)
    /// This view's own `NSWindow`, captured lazily via ``WindowAnchorView`` once the view is on screen.
    /// Used to filter `.aislopdeskWindowFullScreenDidChange` to only notifications from our window.
    @State private var ownWindow: NSWindow?
    #endif

    /// Keep-alive set: tab IDs that have been SHOWN at least once this run. A tab mounts (its libghostty
    /// surfaces are created + channels opened) the FIRST time it becomes active, then STAYS mounted — so
    /// switching BACK is a pure teardown-free visibility flip (the no-prompt-loss property) while a
    /// never-visited tab costs nothing. The first cut of the prompt-loss fix mounted EVERY tab of every
    /// session up-front, which created all surfaces + opened all channels at launch — a thundering herd
    /// that made switching slow (HW-found "render rất chậm"). Bounding the live set to visited tabs keeps
    /// the fix and removes the storm.
    @State private var visitedTabIDs: Set<TabID> = []

    /// P5 disappearing-chrome: hide the bottom ``PaneStatusBar`` so the shell recedes toward pure terminal
    /// output. Default OFF (the strip shows). `@AppStorage` so a Settings flip applies on the next render.
    @AppStorage(SettingsKey.hideStatusBar) private var hideStatusBar = false

    var body: some View {
        HStack(spacing: 0) {
            // ⌘B collapses the rail AND its divider, leaving the main column full-width.
            if !store.sidebarCollapsed {
                leftNavColumn
                    .frame(width: sidebarWidth)
                    // Elevation: the sidebar is the RAISED level (one step above `bg`) so the reserved
                    // title-bar drag strip + sessions rail read as a distinct chrome surface.
                    .background(AislopdeskTheme.bgRaised)
                // P3a T-JUNCTION FIX: the sidebar's OWN trailing 1pt `border` overlay was REMOVED. The
                // `PanelResizeHandle` below is itself a full-height 1pt `Rectangle` filled with the SAME
                // `AislopdeskTheme.border` (ResizeHandle.body) sitting immediately to the sidebar's right,
                // so the old overlay produced TWO adjacent identical vertical hairlines (sidebar-right border
                // + handle line) — the real doubled-seam artifact. Dropping the sidebar overlay leaves the
                // resize handle as the SINGLE element that owns the full-height vertical run at the
                // sidebar↔mainColumn boundary. The tabstrip-bottom horizontal border (mainColumn) then butts
                // cleanly into that one vertical at a true L-join — no doubled vertical, no inset notch.
                //
                // The inter-column divider — drag to resize the sessions rail (clamped to the expanded
                // bounds). It now ALSO owns the column-boundary vertical hairline (its resting `border` fill).
                PanelResizeHandle(
                    axis: .horizontal,
                    edge: .trailing,
                    current: { sidebarWidth },
                    apply: { sidebarWidth = Self.clampSidebar($0) },
                )
            }
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AislopdeskTheme.bg)
        // Muxy paints itself in the terminal's (dark) theme regardless of the macOS appearance, so the whole
        // window — titlebar, scrollbars, menus — reads as one dark surface with the chrome + terminal panes
        // instead of a half-light stock shell.
        .preferredColorScheme(.dark)
        // Draw under the hidden title bar so the chrome reaches the window's top edge (the traffic lights
        // float over the sessions rail's reserved drag strip).
        .ignoresSafeArea(.container, edges: .top)
        // The borderless / custom-title-bar window foundation (hides the stock titlebar, drops the window
        // background to one solid theme color, repositions + keeps the traffic lights aligned).
        .background(WindowConfigurator())
        #if os(macOS)
            // Capture this view's own NSWindow so we can filter the full-screen notification below.
            .background(WindowAnchorView(window: $ownWindow))
            // Track full-screen so the reserved title-bar drag strip (which only exists to clear the
            // traffic lights) collapses in full-screen, where there are no traffic lights.
            //
            // We subscribe to the CUSTOM `.aislopdeskWindowFullScreenDidChange` notification (posted by
            // `WindowConfigurator.Coordinator` with `object: window` and `userInfo["isFullScreen"]: Bool`)
            // rather than the bare `NSWindow.didEnter/ExitFullScreenNotification`. The bare notifications
            // carry NO object filter in SwiftUI's `.onReceive`, so any OTHER window going full-screen
            // (Settings sheet, command palette, a second workspace window) would wrongly flip this view's
            // `isFullScreen` state and toggle the 78pt drag-strip reservation on the wrong window.
            .onReceive(
                NotificationCenter.default.publisher(for: .aislopdeskWindowFullScreenDidChange),
            ) { notification in
                // Filter to our own window so other windows don't affect this view's layout.
                guard let window = notification.object as? NSWindow,
                      window === ownWindow,
                      let value = notification.userInfo?["isFullScreen"] as? Bool
                else { return }
                isFullScreen = value
            }
        #endif
    }

    // MARK: Left nav column (sessions sidebar under a reserved title-bar drag strip)

    /// The sessions sidebar, with a reserved title-bar-height strip at the top (windowed only) that is a
    /// window-drag region so empty space beside the traffic lights drags the window — Muxy's MainWindow
    /// left column.
    private var leftNavColumn: some View {
        VStack(spacing: 0) {
            if !isFullScreen {
                Color.clear
                    .frame(height: UIMetrics.titleBarHeight)
                    .frame(maxWidth: .infinity)
                    .background(WindowDragRepresentable())
                Rectangle().fill(AislopdeskTheme.border).frame(height: 1)
            }
            SessionSidebarView(store: store)
        }
    }

    // MARK: Main column (window-title-bar tab strip over recursive split content over status bar)

    @ViewBuilder
    private var mainColumn: some View {
        if let session = store.tree.activeSession, let activeTab = session.activeTab {
            VStack(spacing: 0) {
                // The tab strip doubles as the window's custom title bar (empty space drags the window).
                HStack(spacing: 0) {
                    #if os(macOS)
                    // With the sidebar collapsed the strip slides to x=0; reserve a leading drag strip
                    // so the first tab clears the floating traffic lights instead of tucking under them.
                    // (In full-screen there are no traffic lights, so no reservation.)
                    if store.sidebarCollapsed, !isFullScreen {
                        Color.clear
                            .frame(width: Self.trafficLightInset)
                            .background(WindowDragRepresentable())
                    }
                    #endif
                    TabBarView(store: store, session: session, isWindowTitleBar: true)
                }
                // P3a: the strip-height container mirrors the strip's OWN additive height stack — the cell
                // row is `DSSpace.tabHeight` (30) and the 2pt top inset is ADDITIVE on top, so the net is
                // 30 + 2 = 32 (≈ legacy titlebar height, and aligned with the sidebar drag strip's
                // `UIMetrics.titleBarHeight` 32). If this container were pinned to a bare `DSSpace.tabHeight`
                // (30) while the strip is 32, the 2pt inset band would be CLIPPED here (the tab-height-token-
                // split risk). The strip applies its own `.frame(height:) + .dsSpace(.top, 2)` internally; we
                // only need the container tall enough not to clip it — `.fixedSize(vertical:)` lets the
                // strip's intrinsic 32pt drive the row so the two cannot disagree.
                .fixedSize(horizontal: false, vertical: true)
                .background(AislopdeskTheme.bg)
                // P3a T-JUNCTION FIX: the tabstrip-bottom hairline butts FLUSH at mainColumn x=0 (NO leading
                // inset). With the redundant sidebar-right border removed above, mainColumn x=0 sits exactly
                // at the right edge of the single `PanelResizeHandle` vertical run, so the horizontal border
                // forms a clean perpendicular L-join with that one vertical — there is no second vertical to
                // double against, and no inset notch to open. (The earlier 1pt leading inset was WRONG: the
                // resize handle — not the sidebar border — is the element interposed at mainColumn's leading
                // edge, so an inset only clipped 1pt off the horizontal line over the handle rather than
                // closing any doubling.) The strip border reaches the window edge whether the sidebar is
                // shown or collapsed.
                Rectangle()
                    .fill(AislopdeskTheme.border)
                    .frame(height: 1)
                panesHost(activeTabID: activeTab.id)
                    // Outer half-gap so panes at the window edge float by the same amount as
                    // panes that are interior siblings — the tab strip / status bar / sidebar
                    // seam shows the SUNKEN gutter rather than a flush butt joint.
                    .padding(AislopdeskTheme.Space.paneGap / 2)
                    // Back the half-gap outer padding with the same sunken gutter SplitTreeView paints,
                    // so the window-edge gutter matches the inter-pane seam (one continuous sunken floor).
                    .background(AislopdeskTheme.bgSunken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // P5 disappearing-chrome: the status strip is hidden on demand so a confident dev tool
                // recedes to pure terminal output. The focused pane's RTT / agent state stays in the tab +
                // sidebar, so nothing is lost — only the always-on bottom chrome.
                if !hideStatusBar {
                    PaneStatusBar(store: store)
                }
            }
            .background(AislopdeskTheme.bg)
            // Mark the now-visible tab visited (keep-alive) and prune ids whose tab was closed so the set
            // can't grow without bound. `initial: true` seeds the launch tab. The active tab is mounted
            // unconditionally below regardless of this set, so there is no first-frame race.
            .onChange(of: activeTab.id, initial: true) { _, id in
                guard !visitedTabIDs.contains(id) else { return }
                let liveIDs = Set(store.tree.sessions.flatMap { $0.tabs.map(\.id) })
                visitedTabIDs = visitedTabIDs.intersection(liveIDs).union([id])
            }
        } else {
            // A live tree is never empty (the ops re-seed a default), so this is only a transient
            // pre-materialize state.
            emptyState
        }
    }

    /// Mounts the active tab plus every PREVIOUSLY-VISITED tab (at `opacity 0`, hit-testing off — the same
    /// no-teardown trick `SplitTreeView` uses for zoom, here extended across tabs/sessions), showing only
    /// the active one. Keeping a visited tab mounted means its libghostty surfaces are NEVER torn down +
    /// recreated on a switch back. That recreate — surface rebuilt at a possibly-different backing scale,
    /// byte ring replayed, grid reflowed — is exactly what dropped a segment of the prompt on switch
    /// (HW-found). Switching back is now a pure visibility flip. A never-visited tab is NOT mounted, so the
    /// app doesn't create every surface + open every channel at launch (the slow-switch storm).
    private func panesHost(activeTabID: TabID) -> some View {
        ZStack {
            ForEach(hostedTabs(activeTabID: activeTabID), id: \.tab.id) { hosted in
                let active = hosted.tab.id == activeTabID
                SplitTreeView(store: store, session: hosted.session, tab: hosted.tab, isActive: active)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .zIndex(active ? 1 : 0)
            }
        }
    }

    /// The (session, tab) pairs to keep mounted: the active tab (always) ∪ every visited tab (keep-alive).
    /// `TabID` is globally unique, so the `ForEach` identity is stable → a visited tab never remounts on a
    /// switch. The active tab is always included even before `visitedTabIDs` records it, so the first frame
    /// of a freshly-selected tab never races the keep-alive bookkeeping.
    private func hostedTabs(activeTabID: TabID) -> [(session: Session, tab: Tab)] {
        store.tree.sessions.flatMap { session in
            session.tabs.compactMap { tab in
                tab.id == activeTabID || visitedTabIDs.contains(tab.id) ? (session: session, tab: tab) : nil
            }
        }
    }

    /// Horizontal space the macOS traffic-light cluster occupies at the window's leading edge (close +
    /// minimize + zoom + standard gutter). Reserved on the tab strip when the sidebar is collapsed so the
    /// first tab is not clipped under the lights. Native AppKit buttons are fixed-size, so this is not scaled.
    private static let trafficLightInset: CGFloat = 78

    /// Clamp the sidebar width to the expanded min/max with ordered comparisons (no bare `</>` ternary —
    /// SwiftLint's NaN-faithful min/max convention; a width is never NaN but the rule applies uniformly).
    private static func clampSidebar(_ width: CGFloat) -> CGFloat {
        let lo = UIMetrics.sidebarExpandedMinWidth
        let hi = UIMetrics.sidebarExpandedMaxWidth
        if width < lo { return lo }
        if width > hi { return hi }
        return width
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Session", systemImage: "rectangle.split.3x1")
        } description: {
            Text("Create a session to get started.")
        } actions: {
            Button("New Session") {
                store.newSession(name: "Local", kind: SettingsKey.defaultPaneKind)
            }
        }
    }
}

// MARK: - WindowAnchorView

#if os(macOS)
/// A zero-size `NSViewRepresentable` that writes the view's `NSWindow` into a binding once the view
/// is on screen. Used by `SplitWorkspaceView` to capture its own window so the
/// `.aislopdeskWindowFullScreenDidChange` notification can be filtered by object identity (preventing
/// another window's full-screen transition from flipping this view's `isFullScreen` state).
private struct WindowAnchorView: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.frame = .zero
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
#endif

#endif
