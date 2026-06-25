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
    /// The two split-collapse flags the toolbar toggles drive (owned here, read by the representable).
    @State private var chrome = WorkspaceChromeState()
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

    public init(
        store: WorkspaceStore,
        connection: AppConnection,
        installDetailsToggle: ((@escaping () -> Void) -> Void)? = nil,
        installSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
    ) {
        self.store = store
        self.connection = connection
        self.installDetailsToggle = installDetailsToggle
        self.installSidebarToggle = installSidebarToggle
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
        WorkspaceSplitRepresentable(store: store, connection: connection, chrome: chrome)
            .ignoresSafeArea()
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
            InspectorColumn(store: store, connection: connection)
        }
        .toolbar { iosToolbar }
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
    }
    #endif

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
    }
    #endif

    /// Opens the connect-host flow. No connect overlay exists in the native rebuild yet (the old gate was
    /// deleted in L0); a give-up state still runs Retry inside the pill. TODO(L4b): open connect overlay.
    private func openConnect() {
        // TODO(L4b): open the Connect-to-Host overlay (host/port editor). No-op until L4b adds it.
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

    func makeNSViewController(context _: Context) -> AislopdeskSplitViewController {
        AislopdeskSplitViewController(store: store, connection: connection, chrome: chrome)
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
