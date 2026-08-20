// SlopDeskPhoneApp — the iOS app SCENE: one window, the workspace root, and the lifecycle a phone has
// that a Mac does not.
//
// It is the iOS half of what used to be `SlopDeskClientApp`, a single scene serving two products
// through seventeen `#if os(...)` branches. The whole FILE is guarded — that is the one platform gate
// docs/56 §3 allows, because `swift build` compiles every SwiftPM target on the host triple and this
// target has nothing to say there — and inside the guard there is not a second one.
//
// WHAT THE APP IS lives in ``ClientComposition`` (`SlopDeskClientCore`): the store, the connection, the
// preferences, the overlay coordinator, the Folders frecency, the Agents card, the chrome flags and
// every seam between them, identical to the Mac's. What this scene adds is only what a phone has:
//
//   * the per-idiom live-video ceiling (a phone gets one live stream, an iPad two);
//   * the real foreground/background lifecycle — a backgrounded app must flush the tree, pause every
//     pane and pause the connection INSIDE a `beginBackgroundTask` window, then resume on return.
//     macOS `scenePhase` tracks window visibility instead, so it cannot be the same code;
//   * the settings SHEET, because `Settings` (⌘,) is a macOS scene and there is no menu bar here.
//
// It DOES install all three of the composition's OS-notification sinks, over the same
// `CommandCompletionNotifier` / `PaneNotificationRouter` the Mac installs — `UserNotifications` is one
// framework with one API, so a long build finishing, a non-zero exit and an agent awaiting input reach
// the phone as real local notifications rather than dying at a nil closure while Settings renders the
// whole Notification group. The two apps differ in LAYOUT; they do not differ in which events exist.
// What genuinely has no phone answer is the Dock bounce, and that is already an injected closure this
// file simply leaves at its `{}` default.

#if os(iOS)
import Defaults // fire-time reads of the Code Agent sound toggles in the attention sink
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI
import UIKit
import UserNotifications // explicit OSC 9/777 + long-command + agent edges → local notifications

public struct SlopDeskPhoneApp: App {
    /// Retains the notification click-router (`UNUserNotificationCenter` holds its delegate weakly, so
    /// nothing else in this process would). Static for the same reason the Mac's is: it is set from
    /// `init()`, before any `@State` box is read, and there is exactly one app.
    @MainActor static var notificationRouter: PaneNotificationRouter?

    /// THE COMPOSITION ROOT — what the app IS, built and wired once in `SlopDeskClientCore` so this
    /// shell and the Mac's can never grow two copies of it (docs/56 §2).
    @State private var app: ClientComposition
    @Environment(\.scenePhase) private var scenePhase
    /// Serialises the scene-phase fan-outs: a background→active flip must not run its resume against a
    /// pause that has not finished, so each phase awaits the previous one's task.
    @State private var lifecycleTask: Task<Void, Never>?
    /// Whether the first-launch sheet is up — set true once at launch when ``FirstLaunchModel/shouldPresent``.
    @State private var presentFirstLaunch = false
    /// The clipboard-history poller, the same type the Mac shell runs. On this platform it consumes the
    /// board's `changeCount` and records nothing: iOS refuses an unattended CONTENT read, so the ring is
    /// filled by ``WorkspaceStore/currentLocalClipboard()`` on the paths the user asked to paste on.
    /// Running it anyway is what keeps the seen count honest across the session.
    @State private var clipboardMonitor: ClipboardMonitor
    /// Cross-device clipboard sync, the same engine the Mac shell runs. The PULL half is whole here —
    /// a copy on the host lands on the phone's pasteboard within a tick, which needs no permission —
    /// and the push half is gated by the same iOS rule the monitor states.
    @State private var clipboardSync: ClipboardSyncEngine

    // MARK: The composition's parts, read straight through

    private var store: WorkspaceStore { app.store }
    private var connection: AppConnection { app.connection }
    private var preferences: PreferencesStore { app.preferences }
    private var overlayCoordinator: OverlayCoordinator { app.overlay }
    private var agentHooks: AgentHooksController { app.agentHooks }
    private var chrome: WorkspaceChromeState { app.chrome }

    public init() {
        // Promote `SLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read.
        ClientComposition.applyLaunchArgumentEnvironment()

        // The terminal CELLS adopt the app palette's flat colours: this hook hands the libghostty 6-hex
        // background/foreground plus the 16-entry ANSI palette + selection colour to `PreferencesStore`
        // when it (re)builds the terminal config. `WorkspaceCore` owns the `AppearanceApplier` seam but
        // cannot import the view layer, so the closure lives on this side of the fence.
        AppearanceApplier.resolveTerminalColors = {
            let theme = SlateTheme.app
            return ResolvedTerminalTheme(
                background: theme.terminalBackgroundHex,
                foreground: theme.terminalForegroundHex,
                palette: theme.ansiPalette,
                selectionBackground: theme.selectionBackgroundHex,
            )
        }

        // The concurrent live-video ceiling, resolved ONCE at launch from the device idiom: an iPad in a
        // regular projection can hold two live streams, a phone one.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let app = ClientComposition(deviceClass: isPad ? .pad : .phone)
        _app = State(initialValue: app)
        _clipboardMonitor = State(initialValue: ClipboardMonitor(store: app.store))
        // CLIPBOARD SYNC, wired exactly as `SlopDeskMacApp` wires it: routed through whichever pane
        // carries a live channel, resolved at call time (the same idiom as the Agents card / hostInfo
        // fetcher). A phone differs from the Mac in LAYOUT, not in which features exist — docs/56 §3 —
        // and this one is a phone's best case: copy on the host, paste on the device in your hand.
        _clipboardSync = State(initialValue: ClipboardSyncEngine(
            push: { [weak store = app.store] clip in
                guard let store, let client = store.firstConnectedMetadataClient else { return false }
                return await client.setClipboard(clip)
            },
            pull: { [weak store = app.store] lastSeen in
                guard let store, let client = store.firstConnectedMetadataClient else { return nil }
                return await client.readClipboard(lastSeenChangeCount: lastSeen)
            },
        ))
        Self.installNotificationSinks(app)
    }

    /// Installs the composition's three OS-notification sinks over ONE ``CommandCompletionNotifier`` and
    /// ONE ``PaneNotificationRouter`` — the same pair the Mac shell installs, because they are the same
    /// type: `UserNotifications` is cross-platform and the poster stopped being `#if os(macOS)` when the
    /// phone stopped being a client that only whispers to itself.
    ///
    /// The toast half of each of these three fan-outs already fired inside the composition, on both
    /// platforms; what is added here is the OS surface. `bounceDock` is deliberately left at its `{}`
    /// default — there is no Dock tile on a phone, and that is the one asymmetry, expressed as an
    /// unbound seam rather than as a gate.
    ///
    /// Authorization is LAZY inside the poster: the first event that survives the toggles prompts, so a
    /// phone that never sees one never asks. Local notifications need no entitlement and no Info.plist
    /// key — the grant IS the capability.
    @MainActor
    private static func installNotificationSinks(_ app: ClientComposition) {
        let notifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store = app.store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        notificationRouter = router

        app.backgroundNoticeSink = { notice in
            notifier.notifyExplicit(
                event: notice.event,
                paneIDKey: notice.paneIDKey, paneTitle: notice.paneTitle,
                title: notice.title, body: notice.body,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }
        // Notify on Finish (clean exit, default OFF) / Notify on Error Exit (non-zero, default ON) + the
        // Notify-While-Foreground gate — the duration threshold is the notifier's own.
        app.longCommandSink = { notice in
            notifier.notifyIfLong(
                paneTitle: notice.paneTitle, exitCode: notice.exitCode, durationMS: notice.durationMS,
                paneIDKey: notice.paneIDKey,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }
        app.agentAttentionSink = { notice in
            // ONE decision, TWO presenters: ``AgentSoundPolicy`` — which does NOT gate on focus (the
            // TOAST is suppressed for a focused pane, the cue still rings) — says ring or stay silent,
            // and the phone hands that verdict to the BANNER instead of opening a second audio path.
            // Agent edges ride their OWN per-event toggles (awaiting-input vs task-complete), NOT the
            // shell-app master switch, then the Notify-While-Foreground gate.
            notifier.notifyExplicit(
                event: notice.needsInput ? .agentAwaitInput : .agentTaskComplete,
                paneIDKey: notice.paneIDKey, paneTitle: notice.name,
                title: notice.name, body: notice.body,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
                sound: AgentSoundPolicy.sound(
                    needsInput: notice.needsInput,
                    sourcePaneFocused: notice.sourcePaneFocused,
                    soundTaskComplete: Defaults[.agentSoundTaskComplete],
                    soundAwaitInput: Defaults[.agentSoundAwaitInput],
                ),
            )
        }
    }

    public var body: some Scene {
        WindowGroup {
            WorkspaceRootView(
                store: store, connection: connection, overlay: overlayCoordinator, chrome: chrome,
            )
            // Hand the single live PreferencesStore to deep views (the agent footer's notification
            // dismissal/enable persistence reads it via `\.preferencesStore`).
            .preferencesStore(preferences)
            // The Agents install-hooks controller — the root view hands it to the settings SHEET, which
            // is this platform's settings surface. Without the injection the Agents card is permanently
            // `.disconnected` and the whole Agent-Behaviour toggle block is greyed out.
            .agentHooksController(agentHooks)
            // The single overlay coordinator, so deep views reach it via `\.overlayCoordinator`.
            .overlayCoordinator(overlayCoordinator)
            // The guided first-launch sheet — the cross-platform steps (the macOS-only ones drop out of
            // `model.steps` on their own). Presents once on a fresh install and never under automation.
            .sheet(isPresented: $presentFirstLaunch) {
                FirstLaunchView(model: app.firstLaunch, store: preferences)
                    .agentHooksController(agentHooks)
            }
            .task {
                presentFirstLaunch = FirstLaunchModel.shouldPresent(
                    hasCompleted: SettingsKey.hasCompletedFirstLaunchEnabled,
                    automationActive: app.isAutomation,
                )
            }
            .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
            // Clipboard-history poll. Skipped under automation like the Mac's: an E2E run must not
            // mirror the developer's real pasteboard onto the test host (or vice versa).
            .task {
                guard !app.isAutomation else { return }
                await clipboardMonitor.run()
            }
            // Clipboard-sync poll loop (pull host copies onto this device; push what iOS lets us read).
            .task {
                guard !app.isAutomation else { return }
                await clipboardSync.run()
            }
            // AUTOMATION ONLY (env-gated): auto-connect so an autoconnect launch goes live without a
            // manual tap.
            .task {
                guard app.isAutomation else { return }
                let env = WorkspaceStore.automationInputs()
                if env["SLOPDESK_AUTOCONNECT_HOST"]?.isEmpty == false {
                    await connection.connect()
                } else {
                    // Video-only automation (the video host serves UDP only, no TCP listener): mark
                    // connected so the workspace mounts and the video pane opens its UDP flow.
                    connection.markConnectedForAutomation()
                }
            }
            // AUTO-RECONNECT (Goal B): a normal launch silently re-connects to the MRU host. No-op under
            // any AUTOCONNECT env (automation keeps precedence); SLOPDESK_SKIP_AUTO_RECONNECT=1 off.
            .task {
                guard !app.isAutomation else { return }
                await connection.connectIfSavedTarget()
            }
        }
    }

    /// The foreground/background fan-out.
    ///
    /// `scenePhase` genuinely tracks foreground/background here (there is no separate window-occlusion
    /// signal to prefer), so it stays the source of truth for `isAppActive` — the opposite of macOS,
    /// where the same value tracks window VISIBILITY and the AppKit activation notifications are the
    /// truthful signal.
    ///
    /// Backgrounding does the whole flush INSIDE a `beginBackgroundTask` window: save the tree, pause
    /// every pane, pause the connection. Each phase awaits the previous phase's task, so a fast
    /// background→foreground flip can never run its resume against a half-finished pause.
    private func handleScenePhase(_ phase: ScenePhase) {
        store.isAppActive = (phase == .active)
        let prev = lifecycleTask
        lifecycleTask = Task {
            await prev?.value
            switch phase {
            case .background:
                let bgTask = UIApplication.shared.beginBackgroundTask(withName: "slopdesk.background-flush")
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
    }
}
#endif
