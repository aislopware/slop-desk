#if canImport(SwiftUI)
import AislopdeskClient
import AislopdeskInspector
import AislopdeskTransport
import SwiftUI
#if os(iOS)
import UIKit // UIDevice.current.userInterfaceIdiom — the per-device live-video cap signal at init
#endif
#if os(macOS)
import AppKit // NSApplication — AUTOMATION-ONLY window-front so an autoconnect launch goes live in one shot
import UserNotifications // explicit OSC 9/777 child notifications → local UNUserNotification
#endif

/// The Aislopdesk client app scene, shared by both Xcode app targets (ClientApp-macOS,
/// ClientApp-iOS). The app targets reference this as their `@main` entry — see the
/// `project.yml`s under `Apps/`.
///
/// It owns ONE ``WorkspaceStore`` (docs/22 §7 app-shell): the single `@MainActor @Observable`
/// source of truth for the whole workspace (the tree of intent + the table of liveness), built with
/// the production `makeSession` factory (``LivePaneSession/make(_:makeClient:makeInspector:)`` via
/// ``WorkspaceStore/liveMakeSession(makeClient:makeInspector:)``). `body` is just
/// ``WorkspaceRootView``.
///
/// Platform chrome is branched with `#if os(macOS)` / `#if os(iOS)`:
/// - macOS: a resizable `WindowGroup`; scene phase is informational only.
/// - iOS: scene phase drives the AWAITED `pause()`/`resume()` fan-out over EVERY session
///   (`store.pauseAll()` / `store.resumeAll()`) so no socket is stranded across background.
///
/// The terminal renderer + video factories are the gated seams, registered once in
/// `Apps/Shared/AppMain.swift` (UNCHANGED) — this shell never imports `CGhostty`/`AislopdeskVideoClient`.
public struct AislopdeskClientApp: App {
    #if os(macOS)
    /// Retains the notification click-router (the `UNUserNotificationCenter` delegate is held weakly).
    /// Static because the App value type is recreated by SwiftUI; the router's lifetime is the process.
    @MainActor static var notificationRouter: PaneNotificationRouter?
    #endif

    /// The single workspace store. Built ONCE in ``init()`` (no `@State` double-init: we construct the
    /// store eagerly and seed the `@State` backing with it, never reassigning).
    @State private var store: WorkspaceStore
    /// The ONE app-global connection (docs/31): owns the single endpoint + status, fronted by the
    /// connect-gate. Built once beside the store + the shared mux registry.
    @State private var connection: AppConnection
    /// Drives the "show system popups in their own pane" feature: while connected it polls the host for
    /// open system dialogs (SecurityAgent password prompts etc.) and auto-spawns/closes ephemeral panes.
    /// Built once beside the store + connection; its poll loop is owned by a scene `.task`.
    @State private var dialogMonitor: SystemDialogMonitor
    #if os(macOS)
    /// Polls the pasteboard into the store's clipboard ring (the "Paste Recent" feature).
    @State private var clipboardMonitor: ClipboardMonitor
    #endif
    /// Polls the host window list to auto-switch a layout when its trigger app launches.
    @State private var appLaunchMonitor: AppLaunchMonitor
    @Environment(\.scenePhase) private var scenePhase
    /// Serializes the iOS background/foreground lifecycle transitions so the LAST phase observed is the
    /// LAST applied: each `handleScenePhase` chains its work behind the previous transition's, so a
    /// rapid background→foreground flip applies `pauseAll` then `resumeAll` IN ORDER (the app ends
    /// resumed while visible) and the save can't race the resume. `@State`'s setter is nonmutating, so
    /// the handler need not become `mutating`.
    @State private var lifecycleTask: Task<Void, Never>?

    public init() {
        // Build the store exactly once with the production session factory. `makeInspector` is now the
        // live builder (`WorkspaceStore.liveMakeInspector`): a `.claudeCode` pane's read-only inspector
        // second channel (NWConnection #2) is an `NWByteChannel` → `InspectorClient` over the
        // terminal-port+1 convention (docs/16, docs/20, docs/22 §7), connected LAZILY on appear. The
        // GUARDRAIL holds: the host does not yet serve an inspector port, so the channel simply never
        // completes its handshake against today's `aislopdesk-hostd` and the terminal is unaffected — the
        // FOLD is what is wired + unit-tested (via `LoopbackByteChannel`), and real-network inspector
        // serving is a hardware followup. We pass it explicitly (rather than relying on the default) so
        // the wiring is auditable here at the one app-glue site.
        // Automation runs against the real, un-isolated Application Support dir (check-macos.sh /
        // check-video.sh launch the bundle binary directly). Build the bootstrap store WITHOUT a
        // persistence handle so the throwaway autoconnect/video shape can never overwrite the
        // developer's real workspace.json. A normal launch keeps the one persistence handle that both
        // loads the restored tree AND backs the debounced save-on-mutation (docs/22 §6) — the same
        // default file URL on both sides so a debounced write and the next launch's load agree.
        let isAutomation = Self.hasAutomationEnvironment()
        let persistence: WorkspacePersistence? = isAutomation ? nil : WorkspacePersistence()
        // Per-device live-video ceiling (docs/22 §7, ITEM #5): the safe concurrent `.remoteGUI` count
        // scales with the host's decode/compositing headroom. RESOLVED ONCE here at launch (per-device,
        // not live-resizing): `WorkspaceStore.liveVideoCap` is an immutable `let`, so nothing re-tightens
        // it after init. macOS → the mac tier; iOS resolves the pad-vs-phone tier from the idiom. The
        // horizontal size class is not known yet at init, so an iPad keeps its launch (pad) cap even if
        // it later enters compact slide-over — the documented design: the cap is the per-device resource
        // ceiling, and the per-pane activation gate (`activateVideo`) is what actually bites at runtime.
        #if os(macOS)
        let liveVideoCap = VideoCapPolicy.cap(for: .mac)
        #elseif os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let liveVideoCap = VideoCapPolicy.cap(for: isPad ? .pad : .phone)
        #else
        let liveVideoCap = VideoCapPolicy.cap(for: .phone)
        #endif
        // Per-host shared-connection pool (TCP-mux): EVERY pane rides one shared `MuxNWConnection`
        // per host, each as a logical channel. The wire is mux preamble + envelope framing — the
        // only terminal wire.
        let muxRegistry = ConnectionRegistry(makeConnection: LiveMuxConnectionFactory.makeConnection)
        // The ONE app-global connection (docs/31). Seed its target from the env in automation (so
        // check-macos.sh/check-video.sh keep working), else from the persisted `Workspace.connection`,
        // else the default. Every pane reads `connection.target` for its host/ports.
        let restored = persistence?.load() // nil in automation ⇒ bootstrap replaces it anyway
        let env = ProcessInfo.processInfo.environment
        let seedTarget: ConnectionTarget = isAutomation
            ? (WorkspaceStore.videoTarget(from: env)?.0 ?? WorkspaceStore.terminalTarget(from: env) ?? .default)
            : (restored?.connection ?? .default)
        let appConnection = AppConnection(registry: muxRegistry, seed: seedTarget)
        let store = WorkspaceStore(
            restoring: restored,
            makeSession: WorkspaceStore.liveMakeSession(
                makeInspector: WorkspaceStore.liveMakeInspector,
                muxRegistry: muxRegistry,
                target: { appConnection.target },
            ),
            liveVideoCap: liveVideoCap,
            persistence: persistence,
            // FIX #4: hold a closed `.remoteGUI` pane's cap slot briefly past `teardown()` so the
            // SwiftUI dismantle → VideoWindowPipeline.deactivate() → detached session.stop() (which
            // closes the 2 UDP NWConnections + VTDecompressionSession + display link) actually
            // releases the stack before a same-tick sibling is admitted (avoids a transient cap+1).
            videoTeardownSettle: .milliseconds(250),
        )
        // Automation seams (docs/22 §7): only when the env vars are present do we let the bootstrap
        // REPLACE the restored workspace with the autoconnect/video shape (a normal launch restores the
        // persisted tree untouched). With nil persistence above, the bootstrap reconcile's
        // scheduleSave() is a no-op, so no disk write occurs for the ephemeral automation run. The
        // env-var names are unchanged so `check-macos.sh` / `check-video.sh` keep working; the actual
        // connect / autotype / video-open TRIGGER stays in the view layer (WF5).
        if isAutomation {
            store.bootstrapFromEnvironment()
        }
        // Persist a committed target into the tree (so the gate prefills the last host next launch).
        appConnection.onTargetCommitted = { [weak store] target in store?.commitConnectionTarget(target) }
        // Gate the scene-level "Reconnect Pane" command on the app being connected, so ⇧⌘R before the
        // first connect can't build the shared mux behind the connect-gate.
        store.isAppConnected = { [weak appConnection] in
            if case .connected = appConnection?.status { return true }
            return false
        }
        #if os(macOS)
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777): post a child-requested notification as a local
        // macOS notification (gated by the user's @AppStorage toggle), tagged with the pane id; a
        // click reveals (focus + centre) that pane. The router is installed as the UN delegate so the
        // click routes back here. Headless / iOS: this whole block is absent, so the store hook stays
        // nil and the notification is simply dropped.
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router // retain it for the app's lifetime
        store.onPaneNotification = { paneID, paneTitle, title, body in
            // Respect the user's toggle (default ON); read at fire-time so a settings change applies live.
            guard SettingsKey.oscNotificationsEnabled else { return }
            explicitNotifier.notifyExplicit(
                paneIDKey: paneID.raw.uuidString, paneTitle: paneTitle, title: title, body: body,
            )
        }
        #endif
        // The system-dialog monitor (the "system popups in their own pane" feature): polls the host while
        // connected and auto-manages ephemeral dialog panes. `isConnected` reads the app connection status;
        // `target` reads the live host/ports. Started by a scene `.task` (so its lifetime is the scene's).
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
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                // The system-dialog monitor's poll loop, scoped to the scene's lifetime. Skipped under
                // automation (deterministic check-* runs) and when AISLOPDESK_SYSTEM_DIALOG_PANES=0. Inert
                // anyway with no discovery seam registered.
                .task {
                    let flag = ProcessInfo.processInfo.environment["AISLOPDESK_SYSTEM_DIALOG_PANES"]
                    guard flag != "0" else { return } // env override: explicitly disabled
                    // The user-facing toggle (Settings ▸ Advanced, default ON) gates it now; the env var
                    // remains a test override (`0` off / `force` on). `force` bypasses both the toggle and
                    // the automation skip below.
                    if flag != "force", !SettingsKey.systemDialogPanesEnabled { return }
                    // Skipped during automation (deterministic check-* runs) UNLESS forced for an E2E test.
                    guard !Self.hasAutomationEnvironment() || flag == "force" else { return }
                    await dialogMonitor.run()
                }
            #if os(macOS)
                // The clipboard-ring poller, scoped to the scene. Skipped under automation (no need to
                // capture the test rig's clipboard).
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await clipboardMonitor.run()
                }
            #endif
                // The layout auto-switch poller (host app launch → preset). Inert unless a preset has a
                // trigger and the feature is on. Skipped under automation.
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await appLaunchMonitor.run()
                }
                // AUTOMATION ONLY (env-gated): auto-connect the app connection so an autoconnect launch
                // goes live without a manual gate click (check-macos.sh/check-video.sh). A normal launch
                // shows the gate prefilled and waits for the user's Connect.
                .task {
                    guard Self.hasAutomationEnvironment() else { return }
                    let env = ProcessInfo.processInfo.environment
                    if env["AISLOPDESK_AUTOCONNECT_HOST"]?.isEmpty == false {
                        await connection.connect() // terminal automation: pin the TCP mux
                    } else {
                        // Video-only automation (check-video.sh): the video host serves UDP only and runs
                        // no TCP listener, so there is no mux to pin. Mark connected so the gate dismisses
                        // and the canvas (+ the .remoteGUI pane) mounts and opens its UDP flow.
                        connection.markConnectedForAutomation()
                    }
                }
            #if os(macOS)
                // AUTOMATION ONLY (env-gated): bring the window to front + make it key at launch so the
                // NavigationSplitView detail subtree appears and the .remoteGUI pane's connect-on-appear
                // trigger fires WITHOUT a manual front/Open click — so an autoconnect run (check-video.sh
                // or an ssh-launched bundle) goes LIVE in one shot. A normal user launch has no
                // AISLOPDESK_*_AUTOCONNECT_* env, so this never steals focus or alters the manual flow.
                .task {
                    guard Self.hasAutomationEnvironment() else { return }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                }
                // R7 #5 (CRITICAL data-loss): macOS scene phase delivers no reliable flush on ⌘Q, so the
                // 600 ms-debounced workspace save silently ABANDONS the most recent layout edits (split /
                // close / rename / divider-drag made within ~600 ms of quitting) on every quit. Flush
                // synchronously on app termination: `saveImmediately()` cancels the pending debounce and
                // does a generation-bumped atomic write, and `willTerminate` observers run synchronously
                // BEFORE the process exits, so the latest tree is durably persisted.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                }
            #endif
        }
        // The native command surface (docs/22 §5): a Pane + Tab menu on macOS, the hardware-keyboard
        // ⌘-hold HUD on iPadOS — both driven by the SAME ⌘/⌥-prefixed shortcuts as
        // `CommandInterpreter.defaultBindings`, so plain keys + Ctrl-letters still flow to the focused
        // terminal (the §5 conflict rule). Each item resolves the key scene's store via
        // `@FocusedValue(\.workspaceStore)`, which `WorkspaceRootView` publishes. The ⌘K command
        // palette is a window-level affordance owned inside `WorkspaceRootView` (it needs view-tree
        // state + an overlay), so it is wired there, not here.
        .commands { WorkspaceCommands() }
        #if os(macOS)
            .windowResizability(.contentSize)
        #endif

        #if os(macOS)
        // The Settings scene (⌘,): canvas / notification / advanced prefs that retire the env-var gates
        // into real, discoverable @AppStorage settings (SettingsKey is the shared source of truth).
        Settings { SettingsView() }
        #endif
    }

    /// Whether any of the automation env vars (`AISLOPDESK_AUTOCONNECT_*` / `AISLOPDESK_VIDEO_AUTOCONNECT_*`)
    /// are set. Gates the bootstrap so a normal launch restores the persisted workspace untouched.
    private static func hasAutomationEnvironment(_ env: [String: String] = ProcessInfo.processInfo
        .environment) -> Bool
    {
        let keys = [
            "AISLOPDESK_AUTOCONNECT_HOST",
            "AISLOPDESK_VIDEO_AUTOCONNECT_HOST",
        ]
        return keys.contains { (env[$0]?.isEmpty == false) }
    }

    /// Drives the iOS lifecycle seam over EVERY session (docs/22 §4 the single, AWAITED fan-out):
    /// background → `pauseAll()` (each connection's host retains the tail; each inspector channel is
    /// closed), then persist the tree; foreground → `resumeAll()` (byte-exact + inspector re-tail).
    /// On macOS scene phase is informational only.
    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        // Chain behind the previous transition so a queued resume can't start until the preceding pause
        // has fully completed (and vice-versa). The new Task is @MainActor-isolated (inherits from this
        // @MainActor handler) exactly like the two it replaces, capturing the same non-Sendable
        // @MainActor store — so it stays Swift 6 strict-concurrency clean. `default: break` lives INSIDE
        // the chained task so even a no-op phase flushes the chain ordering.
        let prev = lifecycleTask
        lifecycleTask = Task {
            await prev?.value
            switch phase {
            case .background:
                // R15 #4: hold a background-execution assertion so the OS grants time to finish the
                // durable save + clean bye instead of suspending the process mid-flight. Bare SwiftUI
                // scenePhase returns immediately after kicking off this Task, so without an assertion
                // the OS can suspend before the awaited `pauseAll()` fan-out (each pane flushes its ack,
                // sends a clean `bye`, tears its socket down) — or the save — completes. docs/17/18 §2.5
                // prescribe exactly this UIKit `beginBackgroundTask` window (~30s) over bare scenePhase.
                let bgTask = UIApplication.shared.beginBackgroundTask(withName: "aislopdesk.background-flush")
                // R15 #8: flush the durable layout tree FIRST. `saveImmediately()` is synchronous and
                // cheap (cancel the debounce + one atomic file write); sequencing it AFTER the whole
                // N-pane network teardown made the user-visible persistence the first casualty of a
                // truncated background window if a pane's `sendBye` stalled on a flaky NetBird path.
                // Save, THEN pause. (docs/22 §6 save-on-background; pause/resume ordering is preserved
                // by the outer `await prev?.value` chaining.)
                store.saveImmediately()
                await store.pauseAll()
                // Unpin the shared mux LAST (after channels pause) so the OS doesn't kill the app for a
                // stranded background socket; `resume()` re-pins it.
                await connection.pause()
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            case .active:
                // Re-establish the shared mux FIRST, then re-open the per-pane channels on it.
                await connection.resume()
                await store.resumeAll()
            default:
                break
            }
        }
        #elseif os(macOS)
        // macOS delivers `.background` when the app is hidden / the last window closes. Flush the tree
        // then too (R7 #5) — a complement to the `willTerminate` flush above — so a layout edit is not
        // lost if the window closes without a full ⌘Q. `saveImmediately()` cancels the debounce + writes
        // synchronously, so there is no race with a subsequent re-activate.
        if phase == .background { store.saveImmediately() }
        #endif
    }
}
#endif
