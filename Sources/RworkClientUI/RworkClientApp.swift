#if canImport(SwiftUI)
import SwiftUI
import RworkClient
import RworkInspector
#if os(iOS)
import UIKit   // UIDevice.current.userInterfaceIdiom — the per-device live-video cap signal at init
#endif
#if os(macOS)
import AppKit  // NSApplication — AUTOMATION-ONLY window-front so an autoconnect launch goes live in one shot
#endif

/// The Rwork client app scene, shared by both Xcode app targets (ClientApp-macOS,
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
/// `Apps/Shared/AppMain.swift` (UNCHANGED) — this shell never imports `CGhostty`/`RworkVideoClient`.
public struct RworkClientApp: App {
    /// The single workspace store. Built ONCE in ``init()`` (no `@State` double-init: we construct the
    /// store eagerly and seed the `@State` backing with it, never reassigning).
    @State private var store: WorkspaceStore
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
        // completes its handshake against today's `rwork-hostd` and the terminal is unaffected — the
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
        let store = WorkspaceStore(
            restoring: persistence?.load(),   // nil in automation ⇒ bootstrap replaces it anyway
            makeSession: WorkspaceStore.liveMakeSession(
                makeClient: { RworkClient() },
                makeInspector: WorkspaceStore.liveMakeInspector
            ),
            liveVideoCap: liveVideoCap,
            persistence: persistence
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
        _store = State(initialValue: store)
    }

    public var body: some Scene {
        WindowGroup {
            WorkspaceRootView(store: store)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                #if os(macOS)
                // AUTOMATION ONLY (env-gated): bring the window to front + make it key at launch so the
                // NavigationSplitView detail subtree appears and the .remoteGUI pane's connect-on-appear
                // trigger fires WITHOUT a manual front/Open click — so an autoconnect run (check-video.sh
                // or an ssh-launched bundle) goes LIVE in one shot. A normal user launch has no
                // RWORK_*_AUTOCONNECT_* env, so this never steals focus or alters the manual flow.
                .task {
                    guard Self.hasAutomationEnvironment() else { return }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
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
    }

    /// Whether any of the automation env vars (`RWORK_AUTOCONNECT_*` / `RWORK_VIDEO_AUTOCONNECT_*`)
    /// are set. Gates the bootstrap so a normal launch restores the persisted workspace untouched.
    private static func hasAutomationEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let keys = [
            "RWORK_AUTOCONNECT_HOST",
            "RWORK_VIDEO_AUTOCONNECT_HOST",
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
                await store.pauseAll()
                // Flush the tree NOW (cancelling any in-flight debounced save) through the store's
                // configured persistence — docs/22 §6 save-on-background. Inside the serialized pause
                // step, so the save can't race a resume.
                store.saveImmediately()
            case .active:
                await store.resumeAll()
            default:
                break
            }
        }
        #endif
    }
}
#endif
