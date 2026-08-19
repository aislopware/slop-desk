// WorkspaceRootView — the iOS/iPadOS shell: a stock `NavigationSplitView` over the same two columns
// the Mac splits, plus its own toolbar (connection cluster, agent glyph, palette, New Tab, gear).
//
// It used to be BOTH shells: one body with a `#if os(macOS)` down the middle, an AppKit
// `NSViewControllerRepresentable` on one side and this split on the other. The Mac's half now lives
// in `MacWorkspaceRootView` (`SlopDeskMacUI`) and the two share no view ancestor (docs/56 §3). What
// they share they share BELOW the view layer: ``WorkspaceChromePolicy`` (the auto-hide decision and
// the window title), the ``OverlayCoordinator`` and the store.
//
// The whole-file `#if os(iOS)` is the one platform gate docs/56 allows: `swift build` compiles every
// SwiftPM target on the host triple, so this is how a phone-only view declares itself to a macOS
// build. It goes away with the target's rename to `SlopDeskPhoneUI`.

#if os(iOS)
import Defaults
import SFSafeSymbols
import SlopDeskAgentDetect
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

public struct WorkspaceRootView: View {
    let store: WorkspaceStore
    let connection: AppConnection
    /// The single ``OverlayCoordinator`` (command palette / cheat sheet / toasts / connect / remote-window
    /// picker), built once by ``ClientComposition`` and injected into the scene env. Threaded so the
    /// connection pill can open Connect-to-Host via ``OverlayCoordinator/openConnect()``.
    let overlay: OverlayCoordinator
    /// The two split-collapse flags + the window-pin flag, owned by the composition. The leading column's
    /// visibility is a two-way mapping onto `sidebarCollapsed` (see ``sidebarColumnVisibility``).
    let chrome: WorkspaceChromeState
    /// The single live preferences store, injected once at the WindowGroup root (`\.preferencesStore`). Used
    /// by the ``SettingsSheet`` (the gear). `nil` (no scene injection / a preview) → the gear presents
    /// nothing.
    @Environment(\.preferencesStore) private var preferencesStore
    /// The live `auto-hide-tabs-panel` mode. Read via `@Default` (NOT the plain
    /// ``SettingsKey/autoHideTabsPanel`` accessor) so SwiftUI re-evaluates the body — re-firing the
    /// `.onChange(of: autoHideTabsPanel)` observer below — when the user flips the Settings picker. Drives
    /// the TABS panel auto-hide together with the active session's tab count.
    @Default(.autoHideTabsPanel) private var autoHideTabsPanel
    /// Whether the settings sheet is presented — flipped by the toolbar gear, read by the `.sheet`.
    @State private var showSettings = false
    /// THE RIGHT PANEL'S THREE MODELS, held here because they must outlive the presentation the way the
    /// Mac's outlive its surface tree: a panel dismissed and re-opened would otherwise re-list every
    /// device and re-boot every stream, and the parking rules already assume an owner above the
    /// surfaces (``PhonePanelModels``).
    @State private var panelModels = PhonePanelModels()

    /// Maps the shared `chrome.sidebarCollapsed` flag (driven by the auto-hide policy, read by the Mac's
    /// split too) onto the `NavigationSplitView`'s `columnVisibility`, so the TABS panel hides/reveals on
    /// iPad. Getter derives visibility via ``SidebarColumnVisibility/visibility(sidebarCollapsed:)``; setter
    /// routes a user swipe through ``SidebarColumnVisibility/apply(_:chrome:)``, which writes the flag back
    /// AND records `manualSidebarOverride` on a genuine collapse/reveal — so the auto-hide policy honors an
    /// iPad swipe like ⌘⇧L. The SECOND manual entry point besides `toggleSidebar()`.
    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { SidebarColumnVisibility.visibility(sidebarCollapsed: chrome.sidebarCollapsed) },
            set: { SidebarColumnVisibility.apply($0, chrome: chrome) },
        )
    }

    /// The app-owned Agents install-hooks controller, injected once at the WindowGroup root
    /// (`\.agentHooksController`) and handed to the ``SettingsSheet`` so the Agents card + Agent-Behaviour
    /// toggles are LIVE here (macOS's `Settings` scene injects it on its own side). `nil` (no scene
    /// injection / a preview) → the card renders the disabled "Connect a session" state.
    @Environment(\.agentHooksController) private var agentHooksController

    // `package`, not `public`: constructed only by `SlopDeskPhoneApp`, and `chrome` is the package-level
    // `WorkspaceChromeState`.
    package init(
        store: WorkspaceStore,
        connection: AppConnection,
        overlay: OverlayCoordinator,
        chrome: WorkspaceChromeState,
    ) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        self.chrome = chrome
    }

    /// The active tab's active pane's live session, if materialized — the source of the active pane's ping
    /// + agent status surfaced in the toolbar.
    private var activeLive: LivePaneSession? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The active pane's agent status (`.none` when no agent / no live pane).
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

    /// The active session's tab count — the auto-hide policy's input. `nil` (no active session yet) reads as
    /// `0`, which collapses under `.auto` (nothing to switch between). The `.onChange(of: activeTabCount)`
    /// observer fires the policy on a tab open/close TRANSITION, not every render — so a manual reveal/hide
    /// is never fought.
    private var activeTabCount: Int { store.tree.activeSession?.tabs.count ?? 0 }

    public var body: some View {
        NavigationSplitView(
            columnVisibility: sidebarColumnVisibility,
        ) {
            NavigatorColumn(
                store: store, preferences: preferencesStore,
            )
        } detail: {
            ContentColumn(store: store, connection: connection, chrome: chrome)
        }
        // The columns read the reducer from the environment (the island's chip stack does, and macOS's
        // split host injects it per hosting controller for the same reason) — one tree here, so
        // one injection at the root covers both columns.
        .overlayCoordinator(overlay)
        .toolbar { iosToolbar }
        // The floating-overlay layer (palette / connect / remote-window picker / toasts — a ZStack overlay on
        // both platforms). The ✓ gutter tracks the live chrome + the active pane's read-only / secure-entry
        // state — the SAME predicate the macOS host uses.
        .overlay {
            OverlayHostView(
                store: store,
                connection: connection,
                coordinator: overlay,
                toggledState: PalettePresentation.toggledState(chrome: chrome, store: store),
            )
        }
        // THE NOTIFICATION CORNER is the phone's own presentation (docs/56 stage D): an overlay on
        // this root, where the Mac's is an `NSPanel` sized to the column. ALWAYS MOUNTED — it renders
        // nothing when the stack is empty — so an arriving card animates in without a re-mount, and
        // it takes hits only while there is a card to take them. The two halves meet at
        // ``ToastPresentation``: the headline, the spine budget, the mark and the dwell.
        .overlay {
            ToastStackView(coordinator: overlay, onJump: store.jumpToPaneNamedByNotification)
                .allowsHitTesting(!overlay.toasts.isEmpty)
        }
        // Wire the palette's cwd resolver + the per-pane hardware-keyboard interceptor's overlay toggles
        // (iPad has no app-level NSEvent monitor, so a focused terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J would
        // otherwise die at a nil toggle).
        .onAppear {
            wireOverlayCwdResolver()
            wireOverlayKeyToggles()
            wireChromeActions()
        }
        // Drive the TABS panel auto-hide — the SAME shared policy macOS runs. On a tab-count TRANSITION or a
        // Settings mode flip, apply `SidebarAutoHidePolicy` to `chrome.sidebarCollapsed` (mapped to the
        // split's `columnVisibility` via `sidebarColumnVisibility`), only when the policy has an opinion
        // (`.auto`) and the 1↔>1 regime crossed — so a manual reveal/hide is never fought by an unrelated tab
        // open/close. `initial: true` applies ONCE at launch too (SwiftUI `.onChange` skips first
        // appearance), so a single-tab `.auto` session opens with the TABS panel already hidden.
        .onChange(of: activeTabCount, initial: true) { applyAutoHidePolicy() }
        .onChange(of: autoHideTabsPanel) { applyAutoHidePolicy() }
        // THE ⌘/ CHEAT SHEET is the phone's own presentation (docs/56 stage D): a native sheet, not the
        // in-window paper card the other overlays take. It left the shared ``OverlayHostView`` when the
        // Mac's half became an `NSPanel`, and the two now meet only at ``CheatSheetContent`` — the rows,
        // the glyphs and the column deal — which is the layer docs/56 says a divergent surface shares.
        // `cheatSheetVisible` is `private(set)`, so the binding is one-way by construction: any system
        // dismissal (the swipe, Esc on a hardware keyboard) routes back through `closeCheatSheet()`.
        .sheet(isPresented: cheatSheetBinding) {
            KeyboardCheatSheetView(coordinator: overlay)
        }
        // THE RIGHT PANEL, as a phone can have one: the Mac hangs its four surfaces in a third split
        // column, and a phone has room for exactly one such thing at a time, so they arrive as a
        // full-screen cover (``PhonePanelSheet`` — docs/56 stage D). Driven by the SAME
        // `codeSidebarCollapsed` flag the Mac's split item reads, which is what makes
        // `revealCodeSidebar()` — the open-this-file-in-the-workbench actuation — work here for free.
        // A cover does not inherit the presenter's custom environment, so the two values the surfaces
        // read are threaded back in explicitly.
        .fullScreenCover(isPresented: codePanelBinding) {
            PhonePanelSheet(
                store: store, connection: connection, chrome: chrome, models: panelModels,
                overlay: overlay, onClose: { chrome.collapseCodeSidebar() },
            )
            .preferencesStore(preferencesStore)
        }
        // The toolbar gear presents the in-app settings sheet (iOS has no `Settings` scene). The sheet hosts
        // the same cross-platform section structs as the macOS strip.
        .sheet(isPresented: $showSettings) {
            if let preferencesStore {
                // Thread the app-owned controller into the sheet so the Agents card / behaviour toggles are
                // live (a sheet does not inherit the presenter's custom environment values).
                SettingsSheet(store: preferencesStore, agentHooks: agentHooksController, workspace: store)
            }
        }
    }

    /// Presentation binding for the right panel. Reads the shared chrome flag inverted — a panel that
    /// is not collapsed is a panel that is up — and every dismissal (the close plate, a swipe down)
    /// routes through ``WorkspaceChromeState/collapseCodeSidebar()``, so the workstyle choice persists
    /// exactly as the Mac's hide toggle writes it. `set(true)` never happens: a cover does not present
    /// itself, and the toolbar's panel button flips the flag rather than this binding.
    private var codePanelBinding: Binding<Bool> {
        Binding(
            get: { !chrome.codeSidebarCollapsed },
            set: { if !$0 { chrome.collapseCodeSidebar() } },
        )
    }

    /// Presentation binding for the cheat sheet. `set(false)` — the swipe, a hardware Esc, any system
    /// dismissal — routes to `closeCheatSheet()` so the coordinator stays the single owner of the flag;
    /// `set(true)` never happens (a sheet does not present itself) and is deliberately not modelled.
    private var cheatSheetBinding: Binding<Bool> {
        Binding(
            get: { overlay.cheatSheetVisible },
            set: { if !$0 { overlay.closeCheatSheet() } },
        )
    }

    /// Bind the overlay coordinator's `resolveActiveCwd` to the focused pane's live ``MetadataClient`` so
    /// opening the command palette EAGERLY resolves its working directory (host `cwd()` RPC) and mirrors it
    /// into `pane/cwd` — which the WORKING DIRECTORY header's cwd pill (and the titlebar / rail)
    /// read reactively. Without this the pill stayed blank on a freshly-connected pane at a prompt: the only
    /// other `pane/cwd` writer (a command completing via OSC 133;D) had not fired. Reuses the EXACT
    /// live-metadata path Open-Quickly uses (`store.handle(for:) as? LivePaneSession → activeMetadataClient`),
    /// so it spends NO new wire message. `[store]` captures the live store; a disconnected pane / nil client /
    /// empty cwd is a silent no-op (validate-then-drop). The Mac binds the same seam from its own root.
    private func wireOverlayCwdResolver() {
        overlay.resolveActiveCwd = { [store] in
            guard let id = store.tree.activeSession?.activeTab?.activePane,
                  let client = (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient
            else { return }
            Task { @MainActor in
                guard let cwd = await client.cwd(), !cwd.isEmpty else { return }
                store.setLastKnownCwd(cwd, for: id)
            }
        }
    }

    /// Hand the live store the overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor``
    /// threads into `route` (``WorkspaceStore/overlayKeyToggles``), each pointed at the injected
    /// ``OverlayCoordinator``. iPad has no app-level NSEvent monitor, so without these a focused terminal's
    /// ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J resolved to a `nil` toggle and did nothing.
    private func wireOverlayKeyToggles() {
        store.overlayKeyToggles = WorkspaceOverlayKeyToggles(
            palette: { [overlay] in overlay.togglePalette() },
            cheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            globalSearch: { [overlay] in overlay.toggleGlobalSearch() },
            jumpTo: { [overlay] in overlay.toggleOpenQuickly(filter: .current) },
            openQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            peekReply: { [overlay] in overlay.togglePeekReply() },
            // The two PANELS, on the same road for the same reason: ⌘⇧L and ⌘⇧R reach the focused
            // terminal surface first here, and both name a panel that exists on this platform.
            sidebar: { [chrome] in chrome.toggleSidebar() },
            codeSidebar: { [chrome] in chrome.toggleCodeSidebar() },
            focusCodePanel: { [chrome] in chrome.revealCodeSidebar() },
        )
    }

    /// Point the coordinator's chrome actuators at the LIVE ``WorkspaceChromeState`` — the phone's half of
    /// what `MacWorkspaceRootView.wireChromeToggles()` does, and what makes the command palette's View and
    /// Settings rows do something here rather than nothing.
    ///
    /// Three of the four rows were dead on this platform because the coordinator's closures default to
    /// empty and only the Mac's root ever bound them: "Toggle Tabs Panel", "Toggle Code Panel" and "Focus
    /// Code Panel" all resolved to `{}`. Pin Window stays unbound on purpose — a phone has one window and
    /// no window level, which the palette row itself records.
    ///
    /// FOCUS CODE PANEL IS A REVEAL HERE, not a toggle of the keyboard's owner. The Mac's version asks the
    /// webview pool which way to move first responder; there is no responder duel on iOS, so the honest
    /// reading of "focus the code panel" on a device that shows one surface at a time is "put it up".
    private func wireChromeActions() {
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        overlay.toggleCodeSidebar = { [chrome] in chrome.toggleCodeSidebar() }
        overlay.focusCodePanel = { [chrome] in chrome.revealCodeSidebar() }
        // The palette's Settings row. macOS opens its `Settings` scene through the SwiftUI environment
        // action; the phone has no such scene, so the row raises the same sheet the toolbar gear does.
        overlay.openSettingsAction = { showSettings = true }
    }

    /// Thin view-side glue over ``WorkspaceChromePolicy/applyAutoHide(mode:tabCount:chrome:)`` — read the
    /// live inputs (the `@Default` mode + the active session's tab count) and actuate. Called from the
    /// `.onChange` observers so the tested unit stays the policy.
    private func applyAutoHidePolicy() {
        WorkspaceChromePolicy.applyAutoHide(
            mode: autoHideTabsPanel, tabCount: activeTabCount, chrome: chrome,
        )
    }

    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        // The column-visibility chrome is `NavigationSplitView`'s own; surface the connection pill (the
        // phone's cut of the Mac's island — one connection READING per app, two layouts; see
        // ``ConnectionPill``) + the agent indicator + a New-Tab affordance.
        ToolbarItem(placement: .principal) {
            ConnectionPill(
                connection: connection,
                pingMS: ConnectionTelemetry.pingMS(store),
                fps: ConnectionTelemetry.fps(store),
                kbps: ConnectionTelemetry.kbps(store),
                onConnect: openConnect,
            )
        }
        ToolbarItem(placement: .primaryAction) {
            if let reading = StatusPresentation.agentReading(activeAgentStatus) {
                StatusGlyph(reading: reading, tint: StatusPresentation.agentTint(activeAgentStatus))
                    .accessibilityLabel("Agent \(StatusPresentation.agentLabel(activeAgentStatus))")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // The command palette (⌘⇧P) — iOS has no app-level NSEvent monitor (macOS's
            // `WorkspaceKeyDispatcher` owns that chord), so without this button the palette had NO entry point
            // on iPad. The hardware-keyboard chord is also routed (see `wireOverlayKeyToggles()`); this is the
            // touch affordance.
            Button { overlay.togglePalette() } label: { Image(systemSymbol: .command) }
                .help("Command Palette")
        }
        ToolbarItem(placement: .primaryAction) {
            // THE RIGHT PANEL's entry point. macOS has ⌥⌘B and a rail to click; the phone has neither,
            // so the four surfaces need a button of their own or they are unreachable. The glyph is the
            // Mac strip's hide toggle read the other way round — same control, same corner of the same
            // panel, mirrored because here it opens rather than closes.
            Button { chrome.toggleCodeSidebar() } label: { Image(systemSymbol: .sidebarRight) }
                .help("Panel")
        }
        ToolbarItem(placement: .primaryAction) {
            // The `+` mints a focused terminal pane directly (the kind chooser is retired).
            Button { store.newTerminalPane(.newTab) } label: { Image(systemSymbol: .plus) }
                .help("New Tab")
        }
        ToolbarItem(placement: .primaryAction) {
            // The settings gear — iOS has no `Settings` scene (⌘, is macOS-only), so settings present as an
            // in-app sheet. Disabled until the preferences store is injected (so the gear never opens an empty
            // sheet in a preview / pre-scene state).
            Button { showSettings = true } label: { Image(systemSymbol: .gearshape) }
                .help("Settings")
                .disabled(preferencesStore == nil)
        }
    }

    /// Opens the Connect-to-Host flow via the injected coordinator (sets `overlay.connectVisible`). A give-up
    /// state still runs Retry inside the pill itself.
    private func openConnect() {
        overlay.openConnect()
    }
}
#endif
