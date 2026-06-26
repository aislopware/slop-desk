// WorkspaceRootView — the native 3-column IDE shell (REBUILD-V2, L1 + L4a toolbar/inspector).
//
// macOS: an `NSViewControllerRepresentable` (`WorkspaceSplitRepresentable`) owning an
// `AislopdeskSplitViewController` (an `NSSplitViewController` with sidebar | content | inspector items,
// each an `NSHostingController` over a SwiftUI column). Modelled on CodeEdit's split shell. The window runs
// `.windowStyle(.hiddenTitleBar)` — there is NO system unified toolbar; otty's own hover-reveal titlebar
// (`OttyTitlebar`, hosted as a top overlay inside `ContentColumn`) IS the chrome (sidebar/Details toggles,
// "New Tab", the centred title menu). iOS: a stock `NavigationSplitView` over the same three columns + its
// own toolbar.
//
// NO custom design-system / token target (deleted in L0): SYSTEM semantic colours + fonts + SF Symbols.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

public struct WorkspaceRootView: View {
    let store: WorkspaceStore
    let connection: AppConnection
    /// The single ``OverlayCoordinator`` (command palette / cheat sheet / toasts / connect / remote-window
    /// picker), built once at app `init` and injected into the scene env. WI-1 threads it so the iOS
    /// connection pill (and any macOS status surface) can open the Connect-to-Host overlay via
    /// ``OverlayCoordinator/openConnect()``; the `OverlayHostView` mount that renders the panels lands in WI-5.
    let overlay: OverlayCoordinator
    /// The two split-collapse flags the toolbar toggles drive (owned here, read by the representable).
    @State private var chrome = WorkspaceChromeState()
    /// The shared Details-panel tab selection (E9/WI-7). Owned here so BOTH inspector mounts (the macOS split
    /// item via the representable, the iOS detail column) read ONE selection, and the four `Details: *` jump
    /// commands can write it through the `selectDetailsTab` closure installed in `wireChromeToggles()`.
    @State private var details = DetailsPanelState()
    #if os(iOS)
    /// Whether the iOS settings sheet (WI-5) is presented — flipped by the toolbar gear, read by the `.sheet`.
    @State private var showSettings = false
    /// The single live preferences store, injected once at the WindowGroup root (`\.preferencesStore`) and
    /// handed to the iOS ``SettingsSheet``. `nil` (no scene injection / a preview) → the gear presents nothing.
    @Environment(\.preferencesStore) private var preferencesStore
    #endif
    /// Installs the Details-panel toggle on the app-level keybinding dispatcher. The dispatcher is built at
    /// app `init` (before this view's `chrome` exists), so on appear the root view hands it
    /// `chrome.toggleInspector` and ⌘⇧R (otty's Toggle Details Panel) routes through the SAME NSEvent monitor
    /// that owns every other chord. `nil` (the default / iOS / tests) leaves the chord a graceful no-op. A
    /// plain closure keeps `WorkspaceKeyDispatcher` internal (no public-API widening).
    private let installDetailsToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the sidebar / Tabs-panel toggle on the app-level keybinding dispatcher (same late-wiring story
    /// as `installDetailsToggle`): on appear the root view hands it `chrome.toggleSidebar` so ⌘⇧L (otty's
    /// Toggle Tabs Panel) flips the LIVE `chrome.sidebarCollapsed` the native split reads — not the legacy
    /// `store.sidebarCollapsed` (which nothing reads on macOS). `nil` (the default / iOS / tests) is a no-op.
    private let installSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the four `Details: *` jump commands' tab-selector on the app-level keybinding dispatcher
    /// (same late-wiring story as `installDetailsToggle`): on appear the root view hands it a closure that
    /// sets `details.selected` AND reveals the panel (`chrome.inspectorCollapsed = false`), so a routed
    /// `selectDetailsTab(_:)` action switches the Details tab through the SAME NSEvent monitor / menu that
    /// owns every command. `nil` (the default / iOS / tests) leaves the four commands graceful no-ops.
    private let installSelectDetailsTab: ((@escaping (DetailsPanelTab) -> Void) -> Void)?

    public init(
        store: WorkspaceStore,
        connection: AppConnection,
        overlay: OverlayCoordinator,
        installDetailsToggle: ((@escaping () -> Void) -> Void)? = nil,
        installSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installSelectDetailsTab: ((@escaping (DetailsPanelTab) -> Void) -> Void)? = nil,
    ) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        self.installDetailsToggle = installDetailsToggle
        self.installSidebarToggle = installSidebarToggle
        self.installSelectDetailsTab = installSelectDetailsTab
    }

    /// The active tab's active pane's live session, if materialized — the source of the active pane's ping
    /// + agent status surfaced in the toolbar (and the inspector's Session section).
    private var activeLive: LivePaneSession? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The active pane's smoothed RTT (ms) — ping lives on the per-pane channel (`ConnectionViewModel`).
    private var activePingMS: Double? { activeLive?.connection?.latencyMS }

    /// The active pane's agent status (`.none` when no agent / no live pane).
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

    public var body: some View {
        #if os(macOS)
        // No system unified toolbar / header — the window runs `.hiddenTitleBar` and otty's hover-reveal
        // titlebar (`OttyTitlebar`, hosted inside `ContentColumn`) IS the chrome.
        WorkspaceSplitRepresentable(
            store: store, connection: connection, chrome: chrome, details: details, overlay: overlay,
        )
        .ignoresSafeArea()
        // The floating-overlay layer (palette / cheat sheet / connect / remote-window picker / toasts)
        // floats above the AppKit split — SwiftUI overlays compose over an `NSViewControllerRepresentable`.
        // `toggledState` is built from the LIVE chrome so the palette's ✓ gutter tracks the real
        // sidebar/inspector visibility.
        .overlay {
            OverlayHostView(
                store: store,
                connection: connection,
                coordinator: overlay,
                toggledState: OverlayHostView.toggledState(for: chrome),
            )
        }
        // Wire ⌘⇧R (Toggle Details) + ⌘⇧L (Toggle Tabs Panel / sidebar) to the live chrome once it
        // exists. The dispatcher is built at app `init` (before `chrome`), so we hand it the toggles here
        // — `[chrome]` captures the same @Observable instance the representable + titlebar read, so the
        // NSEvent chord and the titlebar button drive ONE flag.
        .onAppear { wireChromeToggles() }
        #else
        NavigationSplitView {
            NavigatorColumn(store: store)
        } content: {
            ContentColumn(store: store, connection: connection, chrome: chrome)
        } detail: {
            InspectorColumn(store: store, connection: connection, details: details, onConnect: openConnect)
        }
        .toolbar { iosToolbar }
        // The floating-overlay layer mounts on iOS too (palette / connect / remote-window picker / toasts read
        // as a ZStack overlay on both platforms). No chrome-driven ✓ gutter yet on iOS, so the toggled-state
        // predicate is the no-op default.
        .overlay {
            OverlayHostView(store: store, connection: connection, coordinator: overlay)
        }
        // ES-E9-5: wire the four `Details: *` palette commands to the live `chrome`/`details` on iOS too (the
        // palette is cross-platform; iOS has no NSEvent dispatcher, so the palette + this closure ARE the
        // surface). The macOS path wires the same closure in `wireChromeToggles()`.
        .onAppear { wireOverlaySelectDetailsTab() }
        // WI-5: the toolbar gear presents the in-app settings sheet (iOS has no `Settings` scene). The sheet
        // hosts the same cross-platform section structs as the macOS strip. The live `WorkspaceStore` rides
        // the `\.workspaceStore` slot so Advanced → Workspace export/import works on iOS too.
        .sheet(isPresented: $showSettings) {
            if let preferencesStore {
                SettingsSheet(store: preferencesStore)
                    .workspaceStore(store)
            }
        }
        #endif
    }

    #if os(macOS)
    /// Hand the app-level dispatcher the chrome toggles (Details ⌘⇧R + sidebar ⌘⇧L), each bound to THIS
    /// view's live `chrome`. Called on appear (the dispatcher predates `chrome`, so the closures are installed
    /// late). `[chrome]` captures the same `@Observable` instance the representable + titlebar read, so each
    /// NSEvent chord and the matching titlebar button flip ONE flag.
    private func wireChromeToggles() {
        installDetailsToggle? { [chrome] in chrome.toggleInspector() }
        installSidebarToggle? { [chrome] in chrome.toggleSidebar() }
        // The four `Details: *` jump commands (ES-E9-5): set the shared tab selection AND reveal the panel
        // (otty opens a hidden Details panel on a tab jump). `[chrome, details]` captures the SAME instances
        // the representable + the hosted `InspectorColumn` read, so a routed `selectDetailsTab(_:)` switches
        // the visible tab and un-collapses the inspector split item in one shot.
        installSelectDetailsTab? { [chrome, details] tab in
            details.selected = tab
            chrome.inspectorCollapsed = false
        }
        // Route the palette's chrome-toggle rows through the SAME live `chrome` the chords + titlebar drive,
        // so "Toggle Tabs Panel"/"Toggle Details Panel" from the palette flip the flag the split + the ✓ read
        // (not the dead `store.sidebarCollapsed`). Bound here because `chrome` predates the app-built overlay.
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        overlay.toggleInspector = { [chrome] in chrome.toggleInspector() }
        wireOverlaySelectDetailsTab()
    }
    #endif

    /// Cross-platform (ES-E9-5): bind the overlay coordinator's `selectDetailsTab` to THIS view's live
    /// `chrome`/`details` so the command palette's four `Details: *` rows — and, on macOS, the View ▸
    /// Details: * menu rows routed through the same coordinator closure (threaded in `AislopdeskClientApp`) —
    /// set the shared `DetailsPanelState.selected` AND reveal the panel. The palette is cross-platform, so the
    /// four commands run on iOS too (where there is no NSEvent dispatcher). `[chrome, details]` captures the
    /// SAME instances both inspector mounts read, so the visible tab switches in one shot.
    private func wireOverlaySelectDetailsTab() {
        overlay.selectDetailsTab = { [chrome, details] tab in
            details.selected = tab
            chrome.inspectorCollapsed = false
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        // iOS uses NavigationSplitView's own column-visibility chrome; surface the connection pill + the
        // agent indicator + a New-Tab affordance. (Sidebar/inspector toggles are the system idiom there.)
        ToolbarItem(placement: .principal) {
            ConnectionStatusPill(connection: connection, pingMS: activePingMS, onTap: openConnect)
        }
        ToolbarItem(placement: .primaryAction) {
            if let symbol = StatusPresentation.agentSymbol(activeAgentStatus) {
                Image(systemName: symbol)
                    .foregroundStyle(StatusPresentation.agentTint(activeAgentStatus))
                    .accessibilityLabel("Agent \(StatusPresentation.agentLabel(activeAgentStatus))")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // The `+` opens a focused `.chooser` pane (the in-pane chooser UX — same as macOS's titlebar),
            // which renders `InPaneChooserView` for the Terminal/Remote pick. (The old centred
            // `PaneChooserModel` popover was removed in the in-pane-chooser refactor.)
            Button { store.openChooserPane(.newTab) } label: { Image(systemSymbol: .plus) }
                .help("New Tab")
        }
        ToolbarItem(placement: .primaryAction) {
            // WI-5: the settings gear — iOS has no `Settings` scene (⌘, is macOS-only), so settings present
            // as an in-app sheet. Disabled until the preferences store is injected (so the gear never opens
            // an empty sheet in a preview / pre-scene state).
            Button { showSettings = true } label: { Image(systemSymbol: .gearshape) }
                .help("Settings")
                .disabled(preferencesStore == nil)
        }
    }
    #endif

    /// Opens the Connect-to-Host flow via the injected coordinator (sets `overlay.connectVisible`). The
    /// `ConnectHostView` the flag drives lands in WI-5; WI-1 only routes the affordance here. A give-up
    /// state still runs Retry inside the pill itself.
    private func openConnect() {
        overlay.openConnect()
    }
}

#if os(macOS)
/// Bridges the AppKit `AislopdeskSplitViewController` into SwiftUI. The controller (and the three SwiftUI
/// columns it hosts) owns the long-lived shell; SwiftUI just mounts it. Keeping the shell in AppKit (not a
/// SwiftUI `HSplitView`) is the load-bearing no-teardown choice for the libghostty panes. `updateNSView…`
/// pushes the chrome collapse flags into the split items each update (the toolbar toggles flip them).
struct WorkspaceSplitRepresentable: NSViewControllerRepresentable {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// The shared Details-tab selection (E9/WI-7) — forwarded into the controller so the hosted
    /// `InspectorColumn` reads the SAME selection the root view's `selectDetailsTab` closure writes.
    let details: DetailsPanelState
    /// The overlay reducer — threaded so the controller can wire the inspector's Status row to
    /// `openConnect()` (ES-E2-6, the macOS connect affordance). Captured once in `makeNSViewController`.
    let overlay: OverlayCoordinator

    func makeNSViewController(context _: Context) -> AislopdeskSplitViewController {
        AislopdeskSplitViewController(
            store: store, connection: connection, chrome: chrome, details: details,
            onConnect: { [overlay] in overlay.openConnect() },
        )
    }

    func updateNSViewController(_ controller: AislopdeskSplitViewController, context _: Context) {
        // Reading the @Observable flags here ties this update to their changes; apply them to the items.
        controller.applyCollapse(
            sidebarCollapsed: chrome.sidebarCollapsed,
            inspectorCollapsed: chrome.inspectorCollapsed,
        )
    }
}
#endif
#endif
