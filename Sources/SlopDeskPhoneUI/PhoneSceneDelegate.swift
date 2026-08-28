// PhoneSceneDelegate — one window, the workspace root, and the lifecycle a phone has that a Mac
// does not.
//
// The half of `SlopDeskPhoneApp: App` that genuinely IS per-scene (docs/62 stage A). What used to be
// a `WindowGroup` body plus `@Environment(\.scenePhase)` is a window, a root controller and the four
// callbacks the system was collapsing into one `ScenePhase` value — which is the trade the whole
// campaign is about: `scenePhase` reported `.inactive` and `.background` through one `onChange` that
// then had to say which of them it was looking at, and UIKit hands each edge its own entry point.
//
// The root is a `UIHostingController` for exactly as long as stage D takes: the workspace root is
// still SwiftUI, and mounting it from a UIKit parent is ONE implementation reached from a UIKit
// shell, not two (docs/62 §6, the carve-out). Stage D replaces this line with a real controller and
// deletes what it hosted in the same change; the hosting-controller count is a stage exit condition
// and it only falls.
//
// WHAT IS NOT HERE, on purpose: the composition, the notification sinks, the clipboard loops and the
// responder chain's tail are all ``PhoneAppDelegate``'s. They belong to the PROCESS, and putting
// them here is what made an iPad's second window run a second clipboard poller against one
// pasteboard.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI // UIHostingController — the stage-A mount of the still-SwiftUI workspace root
import UIKit

/// The window scene: one window, the workspace root, and the foreground/background fan-out.
@preconcurrency
@MainActor
public final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    /// Serialises the scene-phase fan-outs: a background→active flip must not run its resume against
    /// a pause that has not finished, so each phase awaits the previous one's task.
    ///
    /// UIKit has no equivalent — the four callbacks are delivered in order but each returns before
    /// its own async work is done — so this is carried over from the `App` verbatim. It is what makes
    /// `beginBackgroundTask` → `saveImmediately` → `pauseAll` → `connection.pause` →
    /// `endBackgroundTask` atomic against a fast background/foreground flap.
    private var lifecycleTask: Task<Void, Never>?

    /// The app object, which owns everything this scene reads. Force-unwrapped through a computed
    /// property rather than stored: the delegate exists for the whole process and a scene that could
    /// not reach it has no workspace to show.
    private var app: PhoneAppDelegate? {
        UIApplication.shared.delegate as? PhoneAppDelegate
    }

    public func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) {
        guard let windowScene = scene as? UIWindowScene, let app else { return }
        let root = WorkspaceRootView(
            store: app.store, connection: app.connection, overlay: app.overlayCoordinator,
            chrome: app.chrome,
        )
        // Hand the single live PreferencesStore to deep views (the agent footer's notification
        // dismissal/enable persistence reads it via `\.preferencesStore`), and the single overlay
        // coordinator, so deep views reach it via `\.overlayCoordinator`. Both entries die in stage B,
        // where every consumer takes the value as an `init` parameter instead.
        let host = UIHostingController(
            rootView: root
                .preferencesStore(app.preferences)
                .overlayCoordinator(app.overlayCoordinator),
        )
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()
    }

    public func sceneDidDisconnect(_: UIScene) {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        window = nil
    }

    // MARK: The foreground/background fan-out

    // `scenePhase` genuinely tracked foreground/background here (there is no separate
    // window-occlusion signal to prefer), so the four callbacks below stay the source of truth for
    // `isAppActive` — the opposite of macOS, where the same value tracks window VISIBILITY and the
    // AppKit activation notifications are the truthful signal.

    public func sceneDidBecomeActive(_: UIScene) {
        app?.store.isAppActive = true
        serialise { app in
            // Coming back to the foreground is the moment a file dropped into the app's Documents
            // directory (the one place a sandbox lets a config file in) becomes readable. A no-op when
            // the file has not moved — see ``ConfigFile/reload(_:)``.
            ConfigFile.reload(app.preferences)
            await app.connection.resume()
            await app.store.resumeAll()
        }
    }

    /// The phase `scenePhase` spelled `.inactive`: a scene that is on screen but not taking input.
    /// It flips the flag and nothing else — the flush belongs to backgrounding, and running it on
    /// every control-centre pull would pause the connection for a swipe.
    public func sceneWillResignActive(_: UIScene) {
        app?.store.isAppActive = false
    }

    /// Backgrounding does the whole flush INSIDE a `beginBackgroundTask` window: save the tree, pause
    /// every pane, pause the connection.
    public func sceneDidEnterBackground(_: UIScene) {
        app?.store.isAppActive = false
        serialise { app in
            let task = UIApplication.shared.beginBackgroundTask(withName: "slopdesk.background-flush")
            app.store.saveImmediately()
            await app.store.pauseAll()
            await app.connection.pause()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// Runs `body` after whatever the last phase started has finished.
    private func serialise(_ body: @escaping @MainActor (PhoneAppDelegate) async -> Void) {
        let previous = lifecycleTask
        lifecycleTask = Task { [weak self] in
            await previous?.value
            guard let app = self?.app else { return }
            await body(app)
        }
    }
}
#endif
