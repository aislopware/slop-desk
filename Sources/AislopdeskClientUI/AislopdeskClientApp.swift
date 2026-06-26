// AislopdeskClientApp — the native-SwiftUI rewrite (REBUILD-V2) app scene, L1.
//
// The old Warp-clone view tree + the custom `AislopdeskDesignSystem` token target were DELETED in L0.
// L1 restores the REAL app-init logic (recovered verbatim from the pre-L0 scene) and renders the new
// native 3-pane IDE shell (`WorkspaceRootView` → `NSSplitViewController` on macOS / `NavigationSplitView`
// on iOS). Versus the old scene this differs ONLY by: no DesignSystem import / `Fonts.register()` /
// `.theme(...)` (native uses system colours + fonts), and no `.windowStyle(.hiddenTitleBar)` (we want the
// system titlebar so the unified toolbar + sidebar toggle land in a later layer). Everything else — the
// `WorkspaceStore` + `AppConnection` construction, the autoconnect/auto-reconnect/monitor wiring, the
// notification router, the scene-phase lifecycle — is PRESERVED.
//
// It owns ONE `WorkspaceStore` + ONE `AppConnection` (docs/22 §7 / logic-api-surface §8), builds them
// once in `init()` with the production `liveMakeSession` factory over the shared mux registry, honors
// the AUTOCONNECT env seams (auto-connect + front-on-autoconnect — W9), and renders `WorkspaceRootView`.

#if canImport(SwiftUI)
import AislopdeskTransport // ConnectionRegistry + LiveMuxConnectionFactory (the per-host shared mux pool)
import AislopdeskVideoProtocol // W12: EnvConfig — the behaviour-preserving config resolver (env → overlay → default)
import AislopdeskWorkspaceCore
import SwiftUI
import SwiftUIIntrospect // reach THIS scene's NSWindow from the SwiftUI WindowGroup (no NSApplication.windows hack)
#if os(iOS)
import UIKit // UIDevice.current.userInterfaceIdiom — the per-device live-video cap signal at init
#endif
#if os(macOS)
import AppKit // NSApplication — AUTOMATION-ONLY window-front so an autoconnect launch goes live in one shot
import ObjectiveC // objc_setAssociatedObject — retain the E3 WI-4 window-close delegate for the window's life
import UserNotifications // explicit OSC 9/777 child notifications → local UNUserNotification
#endif

public struct AislopdeskClientApp: App {
    #if os(macOS)
    /// Retains the notification click-router (the `UNUserNotificationCenter` delegate is held weakly).
    @MainActor static var notificationRouter: PaneNotificationRouter?
    #endif

    @State private var store: WorkspaceStore
    @State private var connection: AppConnection
    @State private var dialogMonitor: SystemDialogMonitor
    #if os(macOS)
    @State private var clipboardMonitor: ClipboardMonitor
    #endif
    @State private var appLaunchMonitor: AppLaunchMonitor
    @State private var preferences: PreferencesStore
    /// E2/WI-1: the single overlay coordinator — command palette (⌘⇧P), keyboard cheat sheet (⌘/), the
    /// toast stack, and the Connect-to-Host / remote-window-picker modals. Built once in `init()` after the
    /// store + app connection, injected into the scene env (`\.overlayCoordinator`) and handed to
    /// ``WorkspaceRootView``. The macOS ``WorkspaceKeyDispatcher`` threads its palette/cheat toggles so the
    /// SAME NSEvent monitor that owns every chord drives the overlays; the store's background-event sinks
    /// ALSO push an in-app toast through it. The panel views + the host mount land in WI-2…WI-5.
    @State private var overlayCoordinator: OverlayCoordinator
    #if os(macOS)
    /// WS-B / B3: the live keybinding dispatcher. ONE app-level `NSEvent` `.keyDown` local monitor (the
    /// re-scope of DECISIONS.md's "no NSEvent monitor" rule — a multi-key prefix can't be a `.commands`
    /// menu item and the menu can't swallow a sequence's follow-up before the terminal first responder).
    /// Installed once at launch in a scene `.task`.
    @State private var keyDispatcher: WorkspaceKeyDispatcher
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycleTask: Task<Void, Never>?

    public init() {
        // Promote `AISLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        Self.applyLaunchArgumentEnvironment()

        // D3: register the runtime-theme hook BEFORE building `PreferencesStore` so its init-time
        // `applyAppearance` repoints `ThemeStore.shared` (and the persisted theme is live from the first
        // frame). `WorkspaceCore` owns the `AppearanceApplier` seam but cannot import this SwiftUI layer, so
        // the closure lives here — it maps the persisted `ThemeChoice` onto `ThemeStore.shared`, which posts
        // the cross-`NSHostingController` repaint notification the split controller re-pins on.
        AppearanceApplier.apply = { choice in
            ThemeStore.shared.apply(choice)
        }
        // The terminal CELLS adopt the active theme's flat background/foreground (otty flat design): this
        // hook reads the already-resolved `ThemeStore.active` (so `.system` is concrete) and hands its
        // libghostty 6-hex colours to `PreferencesStore` when it (re)builds the terminal config.
        AppearanceApplier.resolveTerminalColors = {
            let theme = ThemeStore.shared.active
            return (theme.terminalBackgroundHex, theme.terminalForegroundHex)
        }

        // Build the GUI Settings store FIRST so its apply paths run before the video pipeline / any
        // `static let` env flag is forced (folds persisted prefs into `EnvConfig.overlay`).
        let preferences = PreferencesStore()
        // E1/WI-6 + WI-2: fold the otty-style `~/.config/aislopdesk/config.toml` keybind lines into the live
        // keybindings so ES-E1-6 is reachable end-to-end — setting `keybindings` republishes the merged model
        // to `WorkspaceBindingRegistry.activeOverrides` via the store's `didSet`, which the dispatcher reads
        // BEFORE the action table. The `text:` / `csi:` / `esc:` / `unbind:` directives need no registry and
        // fold inside the loader; the NAMED / parameterized directives (`cmd+t:new_tab`, `cmd+1:goto_tab:1`)
        // are resolved HERE via the production `resolveNamedBinding` hook — the loader lives in
        // `AislopdeskVideoProtocol` (which must not import the registry), so the app layer (which imports
        // `AislopdeskWorkspaceCore`) supplies the action-name → bindingID table. An unknown / out-of-range
        // name resolves to `nil` and the line is dropped (validate-then-drop, no trap). A missing/broken file
        // is a no-op, so a fresh install is behaviour-identical.
        if let configURL = KeybindConfigLoader.defaultConfigURL() {
            let merged = KeybindConfigLoader.loadFile(
                at: configURL,
                into: preferences.keybindings,
                resolveNamedBinding: { named in
                    guard let bindingID = WorkspaceBindingRegistry.bindingID(
                        forConfigName: named.id, arg: named.arg,
                    ) else { return nil }
                    return (bindingID: bindingID, chord: named.chord)
                },
            )
            if merged != preferences.keybindings { preferences.keybindings = merged }
        }
        _preferences = State(initialValue: preferences)

        // Automation runs against the real Application Support dir; build the bootstrap store WITHOUT a
        // persistence handle under automation so the throwaway autoconnect shape can never overwrite the
        // developer's real workspace.json. A normal launch keeps the one persistence handle.
        let isAutomation = Self.hasAutomationEnvironment()
        let persistence: WorkspacePersistence? = isAutomation ? nil : WorkspacePersistence()

        // Per-device live-video ceiling (resolved ONCE at launch, per-device).
        #if os(macOS)
        let liveVideoCap = VideoCapPolicy.cap(for: .mac)
        #elseif os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let liveVideoCap = VideoCapPolicy.cap(for: isPad ? .pad : .phone)
        #else
        let liveVideoCap = VideoCapPolicy.cap(for: .phone)
        #endif

        // Per-host shared-connection pool (TCP-mux): EVERY pane rides one shared `MuxNWConnection` per
        // host, each as a logical channel.
        let muxRegistry = ConnectionRegistry(makeConnection: LiveMuxConnectionFactory.makeConnection)

        // O1: honour the otty `On Launch` general setting (General → On Launch). `.restoreLastSession` (the
        // default) restores the persisted tree; `.newWindow` seeds a fresh single-pane session instead
        // (`launchTree` returns nil ⇒ the store uses `TreeWorkspace.defaultWorkspace()`), so the picker is a
        // live control, not a dead accessor. nil in automation ⇒ bootstrap replaces it anyway.
        let restoredTree = WorkspacePersistence.launchTree(
            behavior: SettingsKey.onLaunch, persistence: persistence,
        )
        let env = WorkspaceStore.automationInputs()
        let seedTarget: ConnectionTarget = isAutomation
            ? (WorkspaceStore.videoTarget(from: env)?.0 ?? WorkspaceStore.terminalTarget(from: env) ?? .default)
            : (restoredTree?.activeSession?.connection ?? .default)
        let appConnection = AppConnection(registry: muxRegistry, seed: seedTarget)
        let store = WorkspaceStore(
            restoringTree: restoredTree,
            liveModel: .tree,
            makeSession: WorkspaceStore.liveMakeSession(
                makeInspector: WorkspaceStore.liveMakeInspector,
                muxRegistry: muxRegistry,
                target: { appConnection.target },
            ),
            liveVideoCap: liveVideoCap,
            persistence: persistence,
            // Hold a closed `.remoteGUI` pane's cap slot briefly past `teardown()` so the dismantle
            // releases the stack before a same-tick sibling is admitted (avoids a transient cap+1).
            videoTeardownSettle: .milliseconds(250),
        )

        // Automation seams: only when the env vars are present do we let the bootstrap REPLACE the
        // restored workspace with the autoconnect/video shape (a normal launch restores untouched).
        if isAutomation {
            store.bootstrapFromEnvironment()
        }
        // Persist a committed target into the tree (so the Connect-to-Host editor prefills the last host
        // next launch).
        appConnection.onTargetCommitted = { [weak store] target in store?.commitConnectionTarget(target) }
        // Gate the scene-level "Reconnect Pane" command on the app being connected.
        store.isAppConnected = { [weak appConnection] in
            if case .connected = appConnection?.status { return true }
            return false
        }

        // E2/WI-1: the single overlay coordinator. Built HERE — after the store + app connection exist — so
        // the macOS dispatcher (below) can thread its ⌘⇧P / ⌘/ toggles into the SAME NSEvent monitor that
        // owns every chord, and the store's background-event sinks can ALSO surface an in-app toast.
        // `connectionTarget` lets the remote-window-picker modal query the live host. Retained for the scene
        // lifetime by `_overlayCoordinator` below.
        let overlay = OverlayCoordinator(store: store)
        overlay.connectionTarget = { [weak appConnection] in appConnection?.target ?? .default }

        #if os(macOS)
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router
        #endif

        // E2/WI-1 (ES-E2-5): surface the SAME background events as IN-APP toasts on BOTH platforms. A toast
        // is in-app UI, INDEPENDENT of the OS-notification setting — push it unconditionally; the macOS
        // `UNUserNotification` stays gated on `SettingsKey.oscNotificationsEnabled` exactly as before. Each
        // toast carries a stable `pane.<key>` id so a newer event for the same pane REPLACES the old one (the
        // coordinator's de-dupe), and a flavour that matches the event class.
        store.onPaneNotification = { [weak overlay] paneID, paneTitle, title, body in
            overlay?.pushToast(Toast(
                id: "pane.\(paneID.raw.uuidString)", flavor: .default, title: title, body: body,
            ))
            #if os(macOS)
            guard SettingsKey.oscNotificationsEnabled else { return }
            explicitNotifier.notifyExplicit(
                paneIDKey: paneID.raw.uuidString, paneTitle: paneTitle, title: title, body: body,
            )
            #endif
        }
        store.onLongCommandNotify = { [weak overlay] paneIDKey, paneTitle, exitCode, durationMS in
            // The store fires this ONLY for an unfocused, genuinely-long command (its own gate), so a toast
            // here is the background "your build finished" cue. A clean exit is `.success`; a non-zero exit is
            // `.error` (a green checkmark on a failed build would mislead).
            let secs = Int((Double(durationMS) / 1000).rounded())
            let cleanExit = (exitCode ?? 0) == 0
            overlay?.pushToast(Toast(
                id: "pane.\(paneIDKey)",
                flavor: cleanExit ? .success : .error,
                title: paneTitle.isEmpty ? "Command finished" : paneTitle,
                body: "command finished (exit \(exitCode.map(String.init) ?? "?"), \(secs)s)",
            ))
            #if os(macOS)
            explicitNotifier.notifyIfLong(
                paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS, paneIDKey: paneIDKey,
            )
            #endif
        }
        store.onAgentAttention = { [weak overlay] paneIDKey, name, needsInput, detail in
            let headline = needsInput ? "needs your input" : "finished"
            let body: String = {
                guard let detail, !detail.isEmpty else { return headline }
                return "\(headline) — \(detail)"
            }()
            // Agent-needs-input is the highest-signal background event → `.attention`; a finish is `.success`.
            overlay?.pushToast(Toast(
                id: "pane.\(paneIDKey)",
                flavor: needsInput ? .attention : .success,
                title: name, body: body,
            ))
            #if os(macOS)
            guard SettingsKey.oscNotificationsEnabled else { return }
            explicitNotifier.notifyExplicit(
                paneIDKey: paneIDKey, paneTitle: name, title: name, body: body,
            )
            #endif
        }

        // The system-dialog monitor + app-launch monitor: poll the host while connected.
        let monitor = SystemDialogMonitor(
            store: store,
            isConnected: { [weak appConnection] in
                if case .connected = appConnection?.status { return true }
                return false
            },
            target: { [weak appConnection] in appConnection?.target ?? .default },
        )
        let launchMonitor = AppLaunchMonitor(
            store: store,
            isConnected: { [weak appConnection] in
                if case .connected = appConnection?.status { return true }
                return false
            },
            target: { [weak appConnection] in appConnection?.target ?? .default },
        )
        _store = State(initialValue: store)
        _connection = State(initialValue: appConnection)
        _overlayCoordinator = State(initialValue: overlay)
        _dialogMonitor = State(initialValue: monitor)
        _appLaunchMonitor = State(initialValue: launchMonitor)
        #if os(macOS)
        _clipboardMonitor = State(initialValue: ClipboardMonitor(store: store))
        // WS-B / B3: build the live keybinding dispatcher over the single store. A new-pane action (split /
        // new-tab / new-session / floating) mints an in-pane `.chooser` pane via the store's routing, focused,
        // so the user picks Terminal / Remote window INSIDE the new pane; ⌘T stays a direct-terminal escape
        // hatch (it routes via `.newPane(.terminal)`, never `.newTab`). The default prefix is ⌃A (tmux-like).
        //
        // E1/WI-7: the dispatcher's `textBinding`/`unbind` resolution is LIVE here regardless of E2 — a user
        // `text:`/`csi:`/`esc:` config binding injects via `sendBytes` and an `unbind:` passes through, both
        // resolved from `WorkspaceBindingRegistry.activeOverrides`. E2/WI-1 threads the palette (⌘⇧P) +
        // cheat-sheet (⌘/) toggles into THIS monitor so the overlay layer is driven by the SAME single chord
        // owner (never a competing `.keyboardShortcut`). `toggleFind`/`togglePeekReply` stay nil — their
        // `route` arms already fall back to the tree-path behaviour (`requestFindInActivePane()` /
        // `jumpToOldestAttentionPane()`); the Find BAR view lands in E5.
        // E5/WI-4: thread the ⇧⌘F Global Search toggle into the SAME NSEvent monitor that owns every chord, so
        // the cross-tab results surface opens from the keyboard (and the View ▸ Global Search… menu item below).
        _keyDispatcher = State(initialValue: WorkspaceKeyDispatcher(
            store: store,
            togglePalette: { [overlay] in overlay.togglePalette() },
            toggleCheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            toggleGlobalSearch: { [overlay] in overlay.toggleGlobalSearch() },
        ))
        #endif
    }

    /// The root IDE shell. On macOS it hands the root view installers that wire ⌘⇧R (otty Toggle Details
    /// Panel) and ⌘⇧L (otty Toggle Tabs Panel / sidebar) to the view's `WorkspaceChromeState` toggles ON THE
    /// app-level `keyDispatcher`, so each chord routes through the SAME NSEvent monitor that owns every other
    /// chord (the legacy `store.sidebarCollapsed` is not read on macOS); iOS has no dispatcher.
    @ViewBuilder
    private var workspaceRootView: some View {
        #if os(macOS)
        WorkspaceRootView(
            store: store,
            connection: connection,
            overlay: overlayCoordinator,
            installDetailsToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleDetailsPanel(toggle) },
            installSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleSidebar(toggle) },
            // E9/WI-7: hand the dispatcher the four `Details: *` jump commands' tab selector (sets the shared
            // `DetailsPanelState` + reveals the panel), so a user-bound chord / palette row switches the Details
            // tab through the SAME NSEvent monitor that owns every other command.
            installSelectDetailsTab: { [keyDispatcher] select in keyDispatcher.setSelectDetailsTab(select) },
        )
        #else
        WorkspaceRootView(store: store, connection: connection, overlay: overlayCoordinator)
        #endif
    }

    public var body: some Scene {
        WindowGroup {
            workspaceRootView
                // L4: hand the single live PreferencesStore to deep views (the agent footer's W4
                // notification dismissal/enable persistence reads it via `\.preferencesStore`).
                .preferencesStore(preferences)
                // E2/WI-1: inject the single overlay coordinator so deep views (the agent footer's "open
                // settings" hook, future toast emitters) reach it via `\.overlayCoordinator`. The host view
                // that renders the palette / cheat sheet / toasts lands in WI-5.
                .overlayCoordinator(overlayCoordinator)
                // L6: the otty chrome is a PINNED palette (default Monokai Pro Classic — flat dark filter).
                // Pin the window's colour scheme to the active theme so every system semantic colour we don't
                // tokenize resolves with the right contrast, and route the global tint to the otty accent so
                // stock controls/selection adopt it.
                .tint(Otty.State.accent)
                .preferredColorScheme(Otty.colorScheme)
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
                // System-dialog monitor poll loop, scoped to the scene. Skipped under automation / when
                // AISLOPDESK_SYSTEM_DIALOG_PANES=0; inert anyway with no discovery seam registered.
                .task {
                    // W12: resolve through `EnvConfig` (ProcessInfo env → settings overlay → nil) so a
                    // GUI toggle can drive it; an EMPTY overlay is byte-identical to the raw read. This is
                    // the 3-state flag (unset / "0" / "force"), so route the lookup through `EnvConfig.string`
                    // and keep the 3-state branch VERBATIM — no polarity helper collapses the "force" arm.
                    let flag = EnvConfig.string("AISLOPDESK_SYSTEM_DIALOG_PANES")
                    guard flag != "0" else { return }
                    if flag != "force", !SettingsKey.systemDialogPanesEnabled { return }
                    guard !Self.hasAutomationEnvironment() || flag == "force" else { return }
                    await dialogMonitor.run()
                }
            #if os(macOS)
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await clipboardMonitor.run()
                }
                // WS-B / B3: install the app-level keybinding dispatcher's `.keyDown` local monitor once the
                // scene is up. It runs under automation too (the keybinding path is part of what HW E2E
                // drives); the monitor swallows ONLY the prefix + armed follow-ups + bound chords and passes
                // every bare key through, so it never interferes with autoconnect typing.
                .task { keyDispatcher.install() }
            #endif
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await appLaunchMonitor.run()
                }
                // AUTOMATION ONLY (env-gated): auto-connect so an autoconnect launch goes live without a
                // manual click (W9). A normal launch silently re-connects the saved host (see the
                // auto-reconnect task) or, on a fresh install, waits for the user to open the
                // Connect-to-Host editor (the top-bar status pill / "Connect to Host…" palette action).
                .task {
                    guard Self.hasAutomationEnvironment() else { return }
                    let env = WorkspaceStore.automationInputs()
                    if env["AISLOPDESK_AUTOCONNECT_HOST"]?.isEmpty == false {
                        await connection.connect()
                    } else {
                        // Video-only automation (the video host serves UDP only, no TCP listener): mark
                        // connected so the workspace mounts and the .remoteGUI pane opens its UDP flow.
                        connection.markConnectedForAutomation()
                    }
                }
                // AUTO-RECONNECT (Goal B): normal launch silently re-connects to the MRU host. No-op under
                // any AUTOCONNECT env (automation keeps precedence); AISLOPDESK_SKIP_AUTO_RECONNECT=1 off.
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await connection.connectIfSavedTarget()
                }
            #if os(macOS)
                // AUTOMATION ONLY (W9): bring the window to front + make it key at launch so the content
                // subtree appears and connect-on-appear fires WITHOUT a manual front/Open click. We reach
                // THIS scene's window via SwiftUIIntrospect rather than the fragile `NSApplication.shared
                // .windows.first` (wrong once a second window exists). The closure fires exactly when the
                // NSWindow is real, and `.introspect(.window)` is the sanctioned hook for any future
                // WindowGroup-level config. `!isKeyWindow` makes the repeat-firing callback idempotent.
                .introspect(.window, on: .macOS(.v14, .v15, .v26)) { window in
                    // E3 WI-4: install the window-close confirmation gate (independent of automation). The
                    // store owns the policy decision (`requestCloseWindow()` → `pendingWindowClose`); the
                    // delegate routes through `WindowCloseGate` and presents a synchronous confirmation so a
                    // parked close always resolves (the window is never stranded).
                    Self.installWindowCloseGate(on: window, store: store)
                    guard Self.hasAutomationEnvironment(), !window.isKeyWindow else { return }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                }
            #endif
        }
        #if os(macOS)
        // otty has NO system unified toolbar: hide the titlebar (the window keeps traffic lights + a
        // full-size content view) so otty's own hover-reveal titlebar (`OttyTitlebar`) is the only chrome.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        // G1: open at the odiff reference geometry (1280×800) so a fresh window matches the reference.
        .defaultSize(width: 1280, height: 800)
        // E1/N6 (OPTIONAL): the discoverability-only menu bar over the SAME binding registry the dispatcher
        // reads. Each item routes through `WorkspaceBindingRegistry.route` with NO `.keyboardShortcut` — the
        // `NSEvent` monitor (`keyDispatcher`) owns chord dispatch (incl. the multi-key prefix), so a menu
        // shortcut would double-fire / swallow a prefix tail. E2/WI-1 threads the palette + cheat-sheet
        // toggles (capturing the SAME coordinator the NSEvent dispatcher drives) so the menu items toggle the
        // identical overlays — cheap parity. `toggleFind`/`togglePeekReply` stay nil (tree-path route arms).
        .commands {
            WorkspaceCommands(
                store: store,
                togglePalette: { [overlayCoordinator] in overlayCoordinator.togglePalette() },
                toggleCheatSheet: { [overlayCoordinator] in overlayCoordinator.toggleCheatSheet() },
                toggleGlobalSearch: { [overlayCoordinator] in overlayCoordinator.toggleGlobalSearch() },
                // E9/WI-7 (ES-E9-5): the four View ▸ Details: * menu rows route through the SAME injected
                // coordinator closure the palette rows + the user-bindable chord drive (installed by
                // `WorkspaceRootView.wireChromeToggles` → sets `DetailsPanelState.selected` + reveals the
                // panel). Without this the menu rows were inert (`selectDetailsTab` was nil).
                selectDetailsTab: { [overlayCoordinator] tab in overlayCoordinator.selectDetailsTab(tab) },
            )
            // E7 WI-4: File ▸ Export/Import Workspace (optional parity). Shortcut-LESS — the NSEvent
            // dispatcher owns chords (DECISIONS N6); a hostile import is a no-op + toast, never a crash.
            WorkspaceFileCommands(store: store, overlay: overlayCoordinator)
        }
        #endif

        // D4: the GUI Settings surface (⌘,). A STOCK SwiftUI `Settings` scene — the main window is
        // `.hiddenTitleBar` and the otty overlay host (`OverlayCoordinator`) is not yet mounted, so a
        // separate system-chromed window is the non-clashing home for now (it relocates into an in-window
        // otty panel once the coordinator lands). Binds the SAME single live `PreferencesStore`. macOS-only:
        // `Settings` is unavailable on iOS (the iOS settings surface lands as an in-app sheet later).
        #if os(macOS)
        // Thread the live `WorkspaceStore` into the Settings scene so the Advanced → Workspace rows (E7
        // WI-4) can export/import (the Settings scene is separate from the WindowGroup above).
        AislopdeskSettingsScene(store: preferences, workspaceStore: store)
        #endif
    }

    /// Promotes every `AISLOPDESK_<KEY>=<VALUE>` launch argument into the process environment via `setenv`.
    private static func applyLaunchArgumentEnvironment() {
        for arg in CommandLine.arguments.dropFirst() {
            guard arg.hasPrefix("AISLOPDESK_"), let eq = arg.firstIndex(of: "=") else { continue }
            let key = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            setenv(key, value, 1)
        }
    }

    /// Whether any AUTOCONNECT env var is set (gates the bootstrap + the front-on-autoconnect path).
    private static func hasAutomationEnvironment(_ env: [String: String] = WorkspaceStore
        .automationInputs()) -> Bool
    {
        let keys = ["AISLOPDESK_AUTOCONNECT_HOST", "AISLOPDESK_VIDEO_AUTOCONNECT_HOST"]
        return keys.contains { (env[$0]?.isEmpty == false) }
    }

    #if os(macOS)
    /// Associated-object key under which a window retains its ``WindowCloseConfirmationDelegate`` (the
    /// delegate is referenced WEAKLY by `NSWindow.delegate`, so it needs an explicit owner for the window's
    /// lifetime). Only its ADDRESS is used (as the associated-object key), never its value — `nonisolated`
    /// (unsafe) because an address-only key carries no shared mutable state to race on.
    private nonisolated(unsafe) static var windowCloseDelegateKey: UInt8 = 0

    /// Installs the E3 WI-4 window-close confirmation gate on `window` exactly once. SwiftUI installs its own
    /// `NSWindowDelegate`; a transparent shim (``WindowCloseConfirmationDelegate``) wraps it — implementing
    /// only `windowShouldClose(_:)` and forwarding every other selector to SwiftUI's delegate — so SwiftUI's
    /// window bookkeeping is preserved while the close attempt routes through the store. The `.introspect`
    /// closure can re-fire, so it no-ops when our shim already owns the delegate (and self-heals if SwiftUI
    /// re-installs a delegate, by wrapping the new one).
    @MainActor
    private static func installWindowCloseGate(on window: NSWindow, store: WorkspaceStore) {
        guard !(window.delegate is WindowCloseConfirmationDelegate) else { return }
        let shim = WindowCloseConfirmationDelegate(store: store, next: window.delegate)
        window.delegate = shim
        objc_setAssociatedObject(window, &windowCloseDelegateKey, shim, .OBJC_ASSOCIATION_RETAIN)
    }
    #endif

    private func handleScenePhase(_ phase: ScenePhase) {
        store.isAppActive = (phase == .active)
        #if os(iOS)
        let prev = lifecycleTask
        lifecycleTask = Task {
            await prev?.value
            switch phase {
            case .background:
                let bgTask = UIApplication.shared.beginBackgroundTask(withName: "aislopdesk.background-flush")
                store.saveImmediately()
                await store.pauseAll()
                await connection.pause()
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            case .active:
                await connection.resume()
                await store.resumeAll()
            default:
                break
            }
        }
        #elseif os(macOS)
        if phase == .background { store.saveImmediately() }
        #endif
    }
}

#if os(macOS)
/// E3 WI-4 — the PURE window-close gate the macOS `windowShouldClose` consults. Factored out of the AppKit
/// delegate so the close decision is unit-testable WITHOUT an `NSWindow` (the hang-safety rule), and so the
/// gate can never strand the window: a parked close ALWAYS resolves here — it never returns the old bare
/// `false` with no path to close (the E3 regression this replaces).
@MainActor
enum WindowCloseGate {
    /// Resolves a window-close attempt against `store` and returns whether the `NSWindow` may close NOW.
    ///
    /// Parks the confirmation per the active session's ``CloseConfirmationPolicy``
    /// (``WorkspaceStore/requestCloseWindow()``). When NO confirmation is required it returns `true`
    /// immediately (byte-identical to the pre-E3 default close, the persisted layout preserved). When one IS
    /// required it invokes `confirm` (the synchronous prompt) EXACTLY once and routes the user's choice:
    ///   - confirmed ⇒ ``WorkspaceStore/confirmPendingWindowClose()`` (close the active session — otty window
    ///     → ``Session`` — which tears down its panes / stops any running processes) and return `true` so the
    ///     NSWindow then closes (the red-traffic-light intent);
    ///   - cancelled ⇒ ``WorkspaceStore/cancelPendingWindowClose()`` and return `false` (keep the window).
    ///
    /// Pure of AppKit (the only AppKit is inside the injected `confirm`), so a test drives every branch with a
    /// stub prompt and asserts the window can ALWAYS close once the user confirms.
    static func resolve(store: WorkspaceStore, confirm: () -> Bool) -> Bool {
        store.requestCloseWindow()
        guard store.pendingWindowClose != nil else {
            return true // no confirmation needed → close normally
        }
        if confirm() {
            store.confirmPendingWindowClose()
            return true
        }
        store.cancelPendingWindowClose()
        return false
    }
}

/// E3 WI-4 — a transparent `NSWindowDelegate` shim that adds the window-close confirmation gate WITHOUT
/// displacing SwiftUI's own window delegate. It implements ONLY `windowShouldClose(_:)` and forwards every
/// other selector to the delegate SwiftUI installed (`next`), so SwiftUI's window bookkeeping is untouched.
///
/// On a close attempt it routes through ``WindowCloseGate/resolve(store:confirm:)`` (the otty window → active
/// ``Session`` map). When the configured ``CloseConfirmationPolicy`` says confirm, it presents a SYNCHRONOUS
/// confirmation (`NSAlert`) so the attempt always resolves — the window can never be stranded with an
/// unresolved park (the regression this fixes). The decision is store-side + unit-tested; only this NSWindow
/// plumbing + the alert is here.
@MainActor
private final class WindowCloseConfirmationDelegate: NSObject, NSWindowDelegate {
    private let store: WorkspaceStore
    /// The delegate SwiftUI had installed; held strongly (NSWindow holds delegates weakly) so every
    /// non-`windowShouldClose` message keeps reaching SwiftUI's own delegate via forwarding. `nonisolated`
    /// so the `NSObject` runtime-forwarding overrides (themselves `nonisolated`) can read it — AppKit only
    /// touches a window delegate on the main thread, so the access is single-threaded in practice.
    private nonisolated(unsafe) let next: NSWindowDelegate?

    init(store: WorkspaceStore, next: NSWindowDelegate?) {
        self.store = store
        self.next = next
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        WindowCloseGate.resolve(store: store) { Self.confirmWindowClose() }
    }

    /// The synchronous close confirmation — an `NSAlert` whose "Close" button maps to `true`. Kept tiny +
    /// AppKit-only (the decision logic lives in ``WindowCloseGate``); presented app-modally (`runModal`) so
    /// `windowShouldClose` can return the user's choice inline — the window never closes until they answer.
    private static func confirmWindowClose() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        alert.informativeText = "Closing it ends the current session and stops any running processes."
        alert.addButton(withTitle: "Close") // first button ⇒ .alertFirstButtonReturn (the default action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Forward every selector this shim does not implement to SwiftUI's original delegate, so its window
    // bookkeeping (key/main/resize/restoration) is preserved.
    override nonisolated func responds(to aSelector: Selector?) -> Bool {
        if super.responds(to: aSelector) { return true }
        return next?.responds(to: aSelector) ?? false
    }

    override nonisolated func forwardingTarget(for aSelector: Selector?) -> Any? {
        if let next, next.responds(to: aSelector) { return next }
        return super.forwardingTarget(for: aSelector)
    }
}
#endif
#endif
