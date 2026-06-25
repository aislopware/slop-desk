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

        let restoredTree = persistence?.loadTree() // nil in automation ⇒ bootstrap replaces it anyway
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

        #if os(macOS)
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router
        store.onPaneNotification = { paneID, paneTitle, title, body in
            guard SettingsKey.oscNotificationsEnabled else { return }
            explicitNotifier.notifyExplicit(
                paneIDKey: paneID.raw.uuidString, paneTitle: paneTitle, title: title, body: body,
            )
        }
        store.onLongCommandNotify = { paneIDKey, paneTitle, exitCode, durationMS in
            explicitNotifier.notifyIfLong(
                paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS, paneIDKey: paneIDKey,
            )
        }
        store.onAgentAttention = { paneIDKey, name, needsInput, detail in
            guard SettingsKey.oscNotificationsEnabled else { return }
            let headline = needsInput ? "needs your input" : "finished"
            let body: String = {
                guard let detail, !detail.isEmpty else { return headline }
                return "\(headline) — \(detail)"
            }()
            explicitNotifier.notifyExplicit(
                paneIDKey: paneIDKey, paneTitle: name, title: name, body: body,
            )
        }
        #endif

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
        // resolved from `WorkspaceBindingRegistry.activeOverrides`. The constructor also accepts the E2
        // overlay toggles (`toggleFind`/`togglePeekReply`, alongside the existing palette/cheat); E2 threads
        // them to the root view's `@State` from THIS mount point. They are nil in E1 (those overlays don't
        // exist yet) → the corresponding actions stay graceful no-ops via `route`, never dead chords.
        _keyDispatcher = State(initialValue: WorkspaceKeyDispatcher(store: store))
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
            installDetailsToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleDetailsPanel(toggle) },
            installSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleSidebar(toggle) },
        )
        #else
        WorkspaceRootView(store: store, connection: connection)
        #endif
    }

    public var body: some Scene {
        WindowGroup {
            workspaceRootView
                // L4: hand the single live PreferencesStore to deep views (the agent footer's W4
                // notification dismissal/enable persistence reads it via `\.preferencesStore`).
                .preferencesStore(preferences)
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
        // shortcut would double-fire / swallow a prefix tail. The overlay toggles are nil in E1 (those
        // overlays land in later epics) → those actions stay graceful no-ops via `route`, never dead items.
        .commands { WorkspaceCommands(store: store) }
        #endif

        // D4: the GUI Settings surface (⌘,). A STOCK SwiftUI `Settings` scene — the main window is
        // `.hiddenTitleBar` and the otty overlay host (`OverlayCoordinator`) is not yet mounted, so a
        // separate system-chromed window is the non-clashing home for now (it relocates into an in-window
        // otty panel once the coordinator lands). Binds the SAME single live `PreferencesStore`. macOS-only:
        // `Settings` is unavailable on iOS (the iOS settings surface lands as an in-app sheet later).
        #if os(macOS)
        AislopdeskSettingsScene(store: preferences)
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
#endif
