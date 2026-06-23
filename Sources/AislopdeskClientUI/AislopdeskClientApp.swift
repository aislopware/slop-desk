// AislopdeskClientApp — the rebuilt client app scene (L2 of the Warp-clone UI rewrite). Shared by both
// Xcode app targets (ClientApp-macOS, ClientApp-iOS) as their `@main` body; the seam registrations live
// in `Apps/Shared/AppMain.swift`.
//
// It owns ONE `WorkspaceStore` + ONE `AppConnection` (docs/22 §7 / logic-api-surface §8), builds them
// once in `init()` with the production `liveMakeSession` factory over the shared mux registry, honors
// the AUTOCONNECT env seams (auto-connect + front-on-autoconnect — W9), registers the bundled fonts at
// launch, and renders `WorkspaceRootView` with the Warp Dark theme injected via `\.theme`.

#if canImport(SwiftUI)
import AislopdeskClient
import AislopdeskDesignSystem
import AislopdeskInspector
import AislopdeskTransport
import AislopdeskWorkspaceCore
import SwiftUI
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycleTask: Task<Void, Never>?

    public init() {
        // Promote `AISLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        Self.applyLaunchArgumentEnvironment()

        // F2: register the bundled Hack + Roboto faces with CoreText so SwiftUI + ImageRenderer resolve
        // them by family name (graceful no-op if a face is missing). Done first so the theme's text
        // renders in the bundled families from the first frame.
        Fonts.register()

        // Build the GUI Settings store FIRST so its apply paths run before the video pipeline / any
        // `static let` env flag is forced (folds persisted prefs into `EnvConfig.overlay`).
        let preferences = PreferencesStore()
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
        #endif
    }

    public var body: some Scene {
        WindowGroup {
            WorkspaceRootView(store: store, connection: connection)
                .theme(DesignTokens.warpDark)
                // L4: hand the single live PreferencesStore to deep views (the agent footer's W4
                // notification dismissal/enable persistence reads it via `\.preferencesStore`).
                .preferencesStore(preferences)
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
                // System-dialog monitor poll loop, scoped to the scene. Skipped under automation / when
                // AISLOPDESK_SYSTEM_DIALOG_PANES=0; inert anyway with no discovery seam registered.
                .task {
                    let flag = ProcessInfo.processInfo.environment["AISLOPDESK_SYSTEM_DIALOG_PANES"]
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
                // subtree appears and connect-on-appear fires WITHOUT a manual front/Open click.
                .task {
                    guard Self.hasAutomationEnvironment() else { return }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                }
                // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        // G1: open at the odiff reference geometry (1280×800) so a fresh window matches the Warp ref.
        .defaultSize(width: 1280, height: 800)
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
