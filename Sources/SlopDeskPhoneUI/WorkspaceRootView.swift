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
import SFSafeSymbols
import SlopDeskAgentDetect
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol // ConfigRevision — what makes the config-backed reads below live
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
    /// The single live preferences store, injected once at the WindowGroup root (`\.preferencesStore`) and
    /// RE-injected below, because a sheet does not inherit its presenter's custom environment values and
    /// ``PhonePanelSheet`` reads this key. `nil` in a preview / pre-scene state.
    @Environment(\.preferencesStore) private var preferencesStore
    /// The live `auto-hide-tabs-panel` mode. COMPUTED, and it reads ``ConfigRevision/generation``
    /// first: `AppConfig` is a plain locked global, so the bare ``SettingsKey/autoHideTabsPanel``
    /// accessor registers no dependency and the body would never re-evaluate. Reading the revision
    /// here is what re-fires the `.onChange(of: autoHideTabsPanel)` observer below when the user saves
    /// their config file. Drives the vertical TABS panel auto-hide with the active session's tab count.
    private var autoHideTabsPanel: AutoHideTabsPanelMode {
        _ = ConfigRevision.shared.generation
        return SettingsKey.autoHideTabsPanel
    }

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

    // `package`, not `public`: constructed only by `PhoneSceneDelegate`, and `chrome` is the package-level
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
            NavigatorColumn(store: store)
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
        // THE CLIPBOARD QUESTIONS — an unsafe paste, an OSC-52 read, an OSC-52 write — put to the user,
        // where the Mac puts them in an `NSAlert` (``SlopDeskMacUI/PasteProtectionSheet``). TOPMOST on
        // purpose: it is raised by a remote PROGRAM rather than summoned, so it may not be covered by a
        // card the user opened, and it is an in-window layer rather than a `.sheet` for the same reason
        // — the system's modal stack declines a second presentation, and a declined presentation here
        // would leave libghostty holding the request forever. It renders nothing while the mailbox is
        // empty, which is almost always. See ``ClipboardConfirmCard``.
        .overlay {
            ClipboardConfirmCard()
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
        // NO settings action, and that is the whole policy: settings are a config FILE with defaults
        // good enough that nobody has to open it. macOS's palette row opens that file in an editor;
        // a phone has neither the editor nor the file, so the row is a graceful no-op there rather
        // than a control that raises a surface which no longer exists.
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
        ToolbarItem(placement: .primaryAction) { panelButton }
        ToolbarItem(placement: .primaryAction) {
            // The `+` mints a focused terminal pane directly (the kind chooser is retired).
            Button { store.newTerminalPane(.newTab) } label: { Image(systemSymbol: .plus) }
                .help("New Tab")
        }
    }

    /// THE RIGHT PANEL's entry point, and the phone's answer to the Mac's rail.
    ///
    /// macOS has ⌥⌘B and, while the panel is collapsed, a RAIL — four named plates down the window's
    /// edge, any of which opens the panel ON that surface in one click (`SlopDeskMacUI/MacPanelRail`).
    /// The phone had a bare toggle: it reopened on whatever surface was last selected, so reaching
    /// Emulators from a closed panel was two taps with nothing on screen naming the second one. A rail
    /// cannot be copied here — a phone has no window edge to spare and the panel is a full-screen cover
    /// rather than a column — but the CAPABILITY is "open on a named surface, in one gesture", and that
    /// is a menu on this platform.
    ///
    /// A `Menu` with a `primaryAction`, so the cheap gesture keeps its cheap meaning: a TAP is still
    /// the toggle it always was, and a PRESS offers the four by name. The rows carry the same words
    /// and the same order the panel's own strip draws (``PanelTabs/all``) — the rail's whole point is
    /// that it names the same four things the strip does — and each one selects AND reveals, because a
    /// row that only selected would leave the reader on a closed panel wondering what it did.
    ///
    /// The check is the menu's own affordance for the chosen row, as it is on the consoles' level
    /// menu; drawing the selection any other way would give one control two vocabularies.
    private var panelButton: some View {
        Menu {
            ForEach(PanelTabs.all, id: \.surface) { tab in
                Button {
                    chrome.panelSurface = tab.surface
                    chrome.revealCodeSidebar()
                } label: {
                    if chrome.panelSurface == tab.surface, !chrome.codeSidebarCollapsed {
                        Label(tab.label, systemSymbol: .checkmark)
                    } else {
                        Text(tab.label)
                    }
                }
                .accessibilityHint(tab.accessibilityHint)
            }
        } label: {
            // The glyph is the Mac strip's hide toggle read the other way round — same control, same
            // corner of the same panel, mirrored because here it opens rather than closes.
            Image(systemSymbol: .sidebarRight)
        } primaryAction: {
            chrome.toggleCodeSidebar()
        }
        .accessibilityLabel("Panel")
    }

    /// Opens the Connect-to-Host flow via the injected coordinator (sets `overlay.connectVisible`). A give-up
    /// state still runs Retry inside the pill itself.
    private func openConnect() {
        overlay.openConnect()
    }
}
#endif
