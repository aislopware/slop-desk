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
// What it deliberately does NOT install are the composition's three OS-notification sinks: the in-app
// toast, pushed by the composition on both platforms, is this platform's only notification surface.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskClientUI
import SlopDeskWorkspaceCore
import SwiftUI
import UIKit

public struct SlopDeskPhoneApp: App {
    /// THE COMPOSITION ROOT — what the app IS, built and wired once in `SlopDeskClientCore` so this
    /// shell and the Mac's can never grow two copies of it (docs/56 §2).
    @State private var app: ClientComposition
    @Environment(\.scenePhase) private var scenePhase
    /// Serialises the scene-phase fan-outs: a background→active flip must not run its resume against a
    /// pause that has not finished, so each phase awaits the previous one's task.
    @State private var lifecycleTask: Task<Void, Never>?
    /// Whether the first-launch sheet is up — set true once at launch when ``FirstLaunchModel/shouldPresent``.
    @State private var presentFirstLaunch = false

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
        _app = State(initialValue: ClientComposition(deviceClass: isPad ? .pad : .phone))
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
