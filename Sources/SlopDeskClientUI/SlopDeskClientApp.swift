// SlopDeskClientApp — the native-SwiftUI app scene, rendering the native 3-pane IDE shell
// (`WorkspaceRootView` → `NSSplitViewController` on macOS / `NavigationSplitView` on iOS).
//
// It owns ONE `WorkspaceStore` + ONE `AppConnection` (docs/22 §7 / logic-api-surface §8), builds them
// once in `init()` with the production `liveMakeSession` factory over the shared mux registry, honors
// the AUTOCONNECT env seams (auto-connect + front-on-autoconnect), and renders `WorkspaceRootView`.

#if canImport(SwiftUI)
import SlopDeskTransport // ConnectionRegistry + LiveMuxConnectionFactory (the per-host shared mux pool)
import SlopDeskVideoProtocol // EnvConfig — the behaviour-preserving config resolver (env → overlay → default)
import SlopDeskWorkspaceCore
import SwiftUI
import SwiftUIIntrospect // reach THIS scene's NSWindow from the SwiftUI WindowGroup (no NSApplication.windows hack)
#if os(iOS)
import UIKit // UIDevice.current.userInterfaceIdiom — the per-device live-video cap signal at init
#endif
#if os(macOS)
import AppKit // NSApplication — AUTOMATION-ONLY window-front so an autoconnect launch goes live in one shot
import ObjectiveC // objc_setAssociatedObject — retain the window-close delegate for the window's life
import SlopDeskTerminal // TerminalCellMetrics + TerminalViewportSnapshotting (live cell advance, macOS window-size glue)
import UserNotifications // explicit OSC 9/777 child notifications → local UNUserNotification
#endif

public struct SlopDeskClientApp: App {
    #if os(macOS)
    /// Retains the notification click-router (the `UNUserNotificationCenter` delegate is held weakly).
    @MainActor static var notificationRouter: PaneNotificationRouter?

    /// QUIT-DRAIN (orphaned-session leak): the app delegate that parks ⌘Q behind a BOUNDED
    /// ``WorkspaceStore/quiesce()`` so in-flight pane teardowns (the bye/channelClose of a just-closed
    /// busy pane) reach the wire before the process dies — see ``SlopDeskAppTerminationDelegate``.
    /// The store is threaded via the delegate's static seam in `init()` (SwiftUI instantiates the
    /// adaptor delegate itself, so the property-wrapper instance is not reachable there).
    @NSApplicationDelegateAdaptor(SlopDeskAppTerminationDelegate.self) private var terminationDelegate
    #endif

    @State private var store: WorkspaceStore
    @State private var connection: AppConnection
    @State private var dialogMonitor: SystemDialogMonitor
    #if os(macOS)
    @State private var clipboardMonitor: ClipboardMonitor
    /// The macOS Dock progress/error-tint controller (`NSApp.dockTile`). macOS-only — there is no
    /// iOS Dock. Fed the store's resolved ``WorkspaceStore/dockTileModel`` on each progress/completion edge;
    /// the Dock bounce rides ``CommandCompletionNotifier/bounceDock``.
    @State private var dockProgress: DockProgressController
    #endif
    @State private var appLaunchMonitor: AppLaunchMonitor
    @State private var preferences: PreferencesStore
    /// The Agents settings-card model (install / uninstall / status of the Claude Code host hooks).
    /// Owned here so it outlives the separate `Settings` scene; its async seams resolve the active
    /// connection's first connected pane ``MetadataClient`` lazily at call time (a connection comes and goes).
    @State private var agentHooks: AgentHooksController
    /// The single overlay coordinator — command palette (⌘⇧P), keyboard cheat sheet (⌘/), the
    /// toast stack, and the Connect-to-Host / remote-window-picker modals. Built once in `init()` after the
    /// store + app connection, injected into the scene env (`\.overlayCoordinator`) and handed to
    /// ``WorkspaceRootView``. The macOS ``WorkspaceKeyDispatcher`` threads its palette/cheat toggles so the
    /// SAME NSEvent monitor that owns every chord drives the overlays; the store's background-event sinks
    /// ALSO push an in-app toast through it.
    @State private var overlayCoordinator: OverlayCoordinator
    /// The app-owned, client-side Folders frecency store — the backing of the Open-Quickly
    /// **Folders** pill (⌘Z). Owned HERE so it outlives the ``OverlayCoordinator``'s WEAK `folders` reference
    /// (attached, like `store`, in `init()`); ``WorkspaceStore/onCwdVisited`` records each cwd change into it
    /// (`record(cwd:)` validates-then-stores). On iOS the picker reads it too (the pill bar is shared ClientUI).
    @State private var folderFrecency: FolderFrecencyStore
    #if os(macOS)
    /// WS-B / B3: the live keybinding dispatcher. ONE app-level `NSEvent` `.keyDown` local monitor (the
    /// re-scope of DECISIONS.md's "no NSEvent monitor" rule — a multi-key prefix can't be a `.commands`
    /// menu item and the menu can't swallow a sequence's follow-up before the terminal first responder).
    /// Installed once at launch in a scene `.task`.
    @State private var keyDispatcher: WorkspaceKeyDispatcher
    /// The CLIENT-side control socket server (`AF_UNIX` NDJSON), the runtime surface the
    /// `slopdesk` CLI drives the running GUI through (windows/tabs/panes, jump/config/theme/keybind, pane
    /// capture/send-keys, agent status). Built once here over a ``WorkspaceControlBackend`` adapter and bound
    /// in a launch `.task`; compiled-only + never unit-tested (hang-safety, mirroring the host's
    /// `AgentControlListener`). macOS-only — the CLI install + OS integration are `#if os(macOS)`.
    @State private var clientControlServer: ClientControlServer
    #endif
    /// The chrome flags (sidebar collapse + window PIN) the toolbar / menu / palette
    /// drive. OWNED HERE (not view-local `@State` inside ``WorkspaceRootView``) so the macOS scene's blessed
    /// `.introspect(.window)` closure + the `.onChange(of: chrome.pinned)` actuator read the SAME flag the
    /// titlebar / menu flip — ONE `NSWindow.level` source of truth, never `NSApplication.windows`. Passed into
    /// ``WorkspaceRootView`` (both platforms); iOS reads only the two collapse flags (pin is an inert no-op).
    @State private var chrome: WorkspaceChromeState
    #if os(macOS)
    /// The host-windows feed (docs/45): the ONE `@Observable` store behind the RIGHT rail + Open
    /// Quickly's host-window rows. App-owned so its renewal loop outlives column mounts; the loop
    /// itself runs in a scene `.task` and self-gates on chrome/OQ/connection.
    @State private var hostWindowFeed: HostWindowFeed
    /// A WEAK handle to THIS scene's `NSWindow`, captured in the blessed `.introspect(.window)`
    /// closure so the `.onChange(of: chrome.pinned)` pin actuator can re-level the live window WITHOUT the
    /// forbidden `NSApplication.windows` scan (and without depending on the introspect closure re-firing on a
    /// pure flag change). A plain holder, not `@Observable` — mutating its `window` must not re-render.
    @State private var windowBox: WeakWindowBox
    /// The detach-pane satellite windows (one plain-AppKit `NSWindowController` per
    /// ``WorkspaceStore/detachedPanes`` entry) — pure AppKit, never a second `WindowGroup`, so the
    /// single-workspace-window machinery (`windowBox` / chord dispatcher / close gate) is untouched.
    @State private var satelliteWindows = SatelliteWindowsCoordinator()
    /// The cross-container pane-drag rendezvous: the sidebar rows, the canvas, and every satellite
    /// window live in SEPARATE hosting views, so the free pane drag (move across tabs / break to a new
    /// tab / tear off to a window / merge back) meets here. App-owned like `chrome`; its `store` weak
    /// ref is bound in `init`.
    @State private var paneDrag = PaneDragCoordinator()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycleTask: Task<Void, Never>?
    /// The PURE first-launch gating model (which steps for this platform, present-once).
    /// Built once; the guided sheet presents when ``FirstLaunchModel/shouldPresent(hasCompleted:automationActive:)``
    /// (a fresh install, no automation) — resolved in a launch `.task` into ``presentFirstLaunch``. Both
    /// platforms (iOS keeps the cross-platform steps; the macOS-only steps drop out of `model.steps`).
    @State private var firstLaunchModel = FirstLaunchModel()
    /// Whether the first-launch sheet is up — set true once at launch when ``FirstLaunchModel/shouldPresent``.
    @State private var presentFirstLaunch = false

    public init() {
        // Promote `SLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        Self.applyLaunchArgumentEnvironment()

        // Register the runtime-theme hook BEFORE building `PreferencesStore` so its init-time
        // `applyAppearance` repoints `ThemeStore.shared` (and the persisted theme is live from the first
        // frame). `WorkspaceCore` owns the `AppearanceApplier` seam but cannot import this SwiftUI layer, so
        // the closure lives here, taking the WHOLE `AppearancePreferences` so
        // `ThemeStore` resolves the dual-slot / custom-slug / follow-OS selection and posts the
        // cross-`NSHostingController` repaint notification the split controller re-pins on.
        AppearanceApplier.apply = { appearance in
            ThemeStore.shared.apply(appearance: appearance)
        }
        // The terminal CELLS adopt the active theme's flat palette: this hook reads the
        // already-resolved `ThemeStore.active` (so the dual-slot / `.system` selection is concrete) and hands
        // its libghostty 6-hex background/foreground plus the 16-entry ANSI palette + selection
        // colour to `PreferencesStore` when it (re)builds the terminal config.
        AppearanceApplier.resolveTerminalColors = {
            let theme = ThemeStore.shared.active
            return ResolvedTerminalTheme(
                background: theme.terminalBackgroundHex,
                foreground: theme.terminalForegroundHex,
                palette: theme.ansiPalette,
                selectionBackground: theme.selectionBackgroundHex,
            )
        }
        // The per-scope (Light/Dark-theme) font override reaches the live terminal. The active
        // slot's resolved theme slug (`ThemeStore.active.id` — dual-slot / `.system` already concrete) keys
        // `appearance.themeFonts`, which `PreferencesStore.applyTerminal` looks up via `FontScopeResolver`.
        AppearanceApplier.resolveActiveThemeSlug = { ThemeStore.shared.active.id }
        // Start the macOS OS-appearance observer so a dual-slot / `.system` user follows the system
        // colour scheme LIVE (a no-op on iOS).
        ThemeStore.shared.observeOSAppearanceChanges()

        // Build the GUI Settings store FIRST so its apply paths run before the video pipeline / any
        // `static let` env flag is forced (folds persisted prefs into `EnvConfig.overlay`).
        let preferences = PreferencesStore()
        // Fold the `~/.config/slopdesk/config.toml` keybind lines into the live keybindings.
        // Setting `keybindings` republishes the merged model to `WorkspaceBindingRegistry.activeOverrides` via
        // the store's `didSet`, which the dispatcher reads BEFORE the action table. The `text:` / `csi:` /
        // `esc:` / `unbind:` directives need no registry and fold inside the loader; the NAMED / parameterized
        // directives (`cmd+t:new_tab`, `cmd+1:goto_tab:1`) resolve HERE via `resolveNamedBinding` — the loader
        // lives in `SlopDeskVideoProtocol` (which must not import the registry), so the app layer supplies the
        // action-name → bindingID table. An unknown / out-of-range name resolves to `nil` and the line is
        // dropped (validate-then-drop, no trap). A missing/broken file is a no-op, so a fresh install is
        // behaviour-identical.
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

        // Per-device live-video ceiling, resolved ONCE at launch.
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

        // Honour the `On Launch` general setting (General → On Launch). `.restoreLastSession` (the
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
        // When the app-global connection (re)establishes, re-dial every pane channel stuck
        // disconnected/failed/unreachable — the leaf's connect-on-appear `.task` never re-fires under
        // keep-all-mounted, so without this fan-out a restored pane that gave up while the host was down stays
        // a dead, blank terminal behind a green pill until a manual per-pane Reconnect.
        appConnection.onConnectionEstablished = { [weak store] in store?.redialDisconnectedPanes() }
        // Host identity: the titlebar speaks the host's NAME even when the user connected by
        // IP. The resolver asks the host itself over the metadata RPC (verb 14) through whichever pane
        // carries a live channel — resolved at call time like the Agents card, so the fetcher survives
        // pane churn/reconnects.
        appConnection.hostInfoFetcher = { [weak store] in
            guard let store, let client = Self.firstConnectedMetadataClient(store) else { return nil }
            return await client.hostInfo()
        }
        // Gate the scene-level "Reconnect Pane" command on the app being connected.
        store.isAppConnected = { [weak appConnection] in
            if case .connected = appConnection?.status { return true }
            return false
        }
        // ⌘+/⌘-/⌘0 zoom the terminal via the SINGLE source of truth (`terminal.fontSize`) so the
        // Settings "Size" stepper stays in sync (the zoom rebuilds the libghostty config + reflows the PTY grid
        // — a font-SIZE change is correctly NOT grid-preserving). Wired to the live `PreferencesStore`.
        store.onFontSizeStep = { [weak preferences] step in
            switch step {
            case .increase: preferences?.increaseFontSize()
            case .decrease: preferences?.decreaseFontSize()
            case .reset: preferences?.resetFontSize()
            }
        }

        // Build the client-side Folders frecency store (backing the Open-Quickly Folders pill,
        // ⌘Z). Retained by `_folderFrecency` below; the coordinator holds it WEAKLY (like `store`). Under
        // automation, point it at a THROWAWAY temp sidecar so an autoconnect run never pollutes the
        // developer's real `folders-frecency.json` (mirroring the nil-persistence guard that protects
        // `workspace.json`).
        let folderFrecency: FolderFrecencyStore = isAutomation
            ? FolderFrecencyStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("slopdesk-automation-folders-frecency.json"))
            : FolderFrecencyStore()
        // Record a pane's cwd change into the frecency store. The store fires
        // `onCwdVisited` ONLY when the known cwd actually changes (its own guard); the client owns the
        // recording so `WorkspaceStore` stays store/SwiftUI-agnostic (a closure, not a direct dependency), and
        // `record(cwd:)` validates-then-stores (drops an empty / over-long path). Held weakly — the app retains
        // the store via `_folderFrecency`.
        store.onCwdVisited = { [weak folderFrecency] cwd in folderFrecency?.record(cwd: cwd) }

        // Build the single overlay coordinator HERE — after the store + app connection exist — so
        // the macOS dispatcher (below) can thread its ⌘⇧P / ⌘/ toggles into the SAME NSEvent monitor that
        // owns every chord, and the store's background-event sinks can ALSO surface an in-app toast.
        // `connectionTarget` lets the remote-window-picker modal query the live host. The Folders frecency
        // store is attached here (held weakly). Retained for the scene lifetime by `_overlayCoordinator` /
        // `_folderFrecency` below.
        let overlay = OverlayCoordinator(store: store, folders: folderFrecency)
        overlay.connectionTarget = { [weak appConnection] in appConnection?.target ?? .default }
        // The palette's "Switch Theme" verb is a LOCAL client action over the
        // live ``PreferencesStore`` (the SAME `appearance` slot Settings → Appearance edits) — it advances the
        // primary slot through the built-in themes (chrome retint + terminal cells repaint live).
        overlay.switchTheme = { [weak preferences] in
            guard let preferences else { return }
            var appearance = preferences.appearance
            appearance.theme = Self.nextBuiltinTheme(after: appearance.theme)
            preferences.appearance = appearance
        }

        #if os(macOS)
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router

        // The macOS Dock progress/error-tint controller. The Dock bounce is driven from the notifier
        // (a DELIVERED banner, NOT the bell): the "Bounce Dock Icon" toggle gates it HERE at the actuation seam
        // so the pure `CommandCompletionNotifier` stays toggle-agnostic. Returning to the app while the Dock is
        // red jumps to the next failing tab + clears the tint (the closest-faithful stand-in for the dock-click
        // hook SwiftUI owns — see docs/DECISIONS.md). Retained for the scene lifetime by `_dockProgress` below.
        let dockProgress = DockProgressController()
        explicitNotifier.bounceDock = { [weak dockProgress] in
            guard SettingsKey.bounceDockIconEnabled else { return }
            dockProgress?.bounce()
        }
        dockProgress.onActivatedWhileErrored = { [weak store] in store?.revealNextErrorPane() }
        #endif

        // Surface the SAME background events as IN-APP toasts on BOTH platforms. A toast
        // is in-app UI, INDEPENDENT of the OS-notification setting — push it unconditionally; the macOS
        // `UNUserNotification` is gated by the pure ``NotificationPolicy`` (the per-event toggle +
        // the Notify-While-Foreground tri-state), applied inside the notifier with the store-supplied
        // appActive + sourcePaneFocused. Each toast carries a stable `pane.<key>` id so a newer event for the
        // same pane REPLACES the old one (the coordinator's de-dupe), and a flavour matching the event class.
        store.onPaneNotification = { [weak overlay, weak store] paneID, paneTitle, title, body in
            // An `slopdesk watch` finish carries the private WatchNotificationMarker sentinel in its
            // title — route it to `.watchFinish` (gated by Notify on Watch Finish) with the marker STRIPPED;
            // every other explicit notification stays `.explicitOSC` (the master switch).
            let (event, displayTitle) = NotificationEvent.classifyExplicit(title: title, body: body)
            // SECURITY: the toast is in-app UI and — on iOS — the ONLY notification surface, so the secret
            // redaction the macOS banner (`CommandCompletionNotifier`) and the pane title
            // (`PanePresentation`) apply must ALSO run here, or an OSC 9/777 title/body carrying a token is
            // shown verbatim. Done once at the construction site (`Toast.explicitOSC`) so both platforms benefit.
            overlay?.pushToast(Toast.explicitOSC(paneIDRaw: paneID.raw, title: displayTitle, body: body))
            #if os(macOS)
            // The OS banner goes through the pure NotificationPolicy (the per-event toggle resolved
            // above + the Notify-While-Foreground tri-state) — the store supplies appActive + whether the SOURCE
            // pane is the focused one. The in-app toast above stays unconditional.
            guard let store else { return }
            explicitNotifier.notifyExplicit(
                event: event,
                paneIDKey: paneID.raw.uuidString, paneTitle: paneTitle, title: displayTitle, body: body,
                appActive: store.isAppActive,
                sourcePaneFocused: store.isSourcePaneFocused(paneID),
                settings: SettingsKey.notificationSettings,
            )
            #endif
        }
        // After an UNEXPECTED reconnect, surface WHICH kind it was as a transient toast —
        // `.resumedSession` reattached the same live shell (scrollback intact); `.freshShell` spawned a fresh
        // shell (the previous session ended). Otherwise a fresh shell silently drops the user's context with
        // no signal. Pushed unconditionally (in-app UI, independent of OS-notification settings); the stable
        // `pane.<key>` id de-dupes with the pane's other toasts.
        store.onSessionResumeOutcome = { [weak overlay] paneID, outcome in
            guard let toast = Toast.sessionResume(paneIDKey: paneID.raw.uuidString, outcome: outcome) else { return }
            overlay?.pushToast(toast)
        }
        // A NON-pane-scoped copy (palette "Copy Path", rail "Copy Window Title") lights the coordinator's
        // window-level `COPIED · N` chip — the pane-less twin of `TerminalViewModel.copyReceipt`.
        store.onLocalCopy = { [weak overlay] text in
            overlay?.noteCopy(text)
        }
        // Closing a tab is the workspace's most destructive ROUTINE action, and the ⇧⌘T reopen has no
        // visible affordance at the moment it matters. The store fires this only when a REOPENABLE tab
        // just landed on the LIFO, so the chip never promises an undo it can't deliver.
        store.onTabCloseRecorded = { [weak overlay] in
            overlay?.noteNotice(label: "TAB CLOSED", detail: "⇧⌘T REOPENS")
        }
        // A teleport jump (⌘⇧U walk, palette / Open Quickly, a Global Search hit, a notification /
        // connection-alert click) swaps the whole viewport in one frame. The store fires this ONLY when
        // the landing crossed a tab/session boundary — the breadcrumb chip says where you are now.
        // SECURITY: the breadcrumb embeds OSC/PTY-settable titles → mask at the display site.
        store.onCrossTabJump = { [weak overlay] breadcrumb in
            overlay?.noteNotice(
                label: "JUMPED", detail: Toast.redactSecretsIfEnabled(breadcrumb), dwell: .seconds(2.5),
            )
        }
        store.onLongCommandNotify = { [weak overlay, weak store] paneIDKey, paneTitle, exitCode, durationMS in
            // The store fires this ONLY for an unfocused, genuinely-long command (its own gate), so a toast
            // here is the background "your build finished" cue. SECURITY: `paneTitle` is the live OSC 0/2 pane
            // title — remote/PTY-settable text (often the running command line such as `mysql -pSECRET`), and
            // the toast is the ONLY notification surface on iOS, so the title is masked at the single
            // construction site (`Toast.longCommand`) for parity with the macOS banner + the OSC toast.
            overlay?.pushToast(Toast.longCommand(
                paneIDKey: paneIDKey, paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS,
            ))
            #if os(macOS)
            // Route the OS banner through NotificationPolicy — Notify on Finish (clean exit, default
            // OFF) / Notify on Error Exit (non-zero, default ON) + the Notify-While-Foreground gate.
            guard let store else { return }
            explicitNotifier.notifyIfLong(
                paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS, paneIDKey: paneIDKey,
                appActive: store.isAppActive,
                sourcePaneFocused: store.isSourcePaneFocused(byIDString: paneIDKey),
                settings: SettingsKey.notificationSettings,
            )
            #endif
        }
        store.onAgentAttention = { [weak overlay, weak store] paneIDKey, name, needsInput, detail in
            let headline = needsInput ? "needs your input" : "finished"
            let body: String = {
                guard let detail, !detail.isEmpty else { return headline }
                return "\(headline) — \(detail)"
            }()
            // Agent-needs-input is the highest-signal background event → `.attention`; a finish is `.success`.
            // The agent `detail` is host-provided (Claude label); mask any secret in it (and the name) for
            // the same reason as the OSC toast above — the toast is the only iOS notification surface.
            overlay?.pushToast(Toast(
                id: "pane.\(paneIDKey)",
                flavor: needsInput ? .attention : .success,
                title: Toast.redactSecretsIfEnabled(name), body: Toast.redactSecretsIfEnabled(body),
            ))
            #if os(macOS)
            // Agent edges (Claude-only, reusing AttentionSupervision) ride their OWN per-event
            // toggles — awaiting-input vs task-complete — NOT the shell-app master switch, then the
            // Notify-While-Foreground gate.
            guard let store else { return }
            explicitNotifier.notifyExplicit(
                event: needsInput ? .agentAwaitInput : .agentTaskComplete,
                paneIDKey: paneIDKey, paneTitle: name, title: name, body: body,
                appActive: store.isAppActive,
                sourcePaneFocused: store.isSourcePaneFocused(byIDString: paneIDKey),
                settings: SettingsKey.notificationSettings,
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
        // The Agents settings-card model. Its seams resolve the active session's FIRST connected
        // pane metadata façade at CALL time (not at construction — no pane is connected yet) and route the
        // install/uninstall/status verb through it. The card is host-global but `MetadataClient` is one-per-
        // pane, so any live channel suffices; with no connected pane the status seam returns `nil` and the
        // card lands on `.disconnected` ("Connect a session to manage hooks"), never a dead button.
        let agentHooks = AgentHooksController(
            install: { [weak store] in
                guard let store, let client = Self.firstConnectedMetadataClient(store) else { return false }
                return await client.installAgentHooks()
            },
            uninstall: { [weak store] in
                guard let store, let client = Self.firstConnectedMetadataClient(store) else { return false }
                return await client.uninstallAgentHooks()
            },
            refreshStatus: { [weak store] in
                guard let store, let client = Self.firstConnectedMetadataClient(store) else { return nil }
                return await client.agentHookStatus()
            },
        )

        _store = State(initialValue: store)
        _connection = State(initialValue: appConnection)
        _agentHooks = State(initialValue: agentHooks)
        _overlayCoordinator = State(initialValue: overlay)
        _folderFrecency = State(initialValue: folderFrecency)
        _dialogMonitor = State(initialValue: monitor)
        _appLaunchMonitor = State(initialValue: launchMonitor)
        // The app owns the chrome flags (incl. window PIN) so the macOS scene's blessed
        // `.introspect(.window)` closure reads the SAME `chrome.pinned` the titlebar / menu flip.
        let chromeState = WorkspaceChromeState()
        _chrome = State(initialValue: chromeState)
        #if os(macOS)
        // Host-windows FEED: the ONE app-owned store Open Quickly's Host rows render (the dedicated
        // rail is retired — full-desktop pivot). Its renewal loop (a scene `.task` below) gates on OQ
        // visibility + connection — no OQ up costs the host exactly 0 Hz. Strong capture of the
        // app-lifetime overlay local; the connection is weak like `overlay.connectionTarget`.
        let feed = HostWindowFeed(
            isActive: { overlay.openQuicklyVisible },
            isConnected: { [weak appConnection] in appConnection?.status == .connected },
            target: { [weak appConnection] in appConnection?.target ?? .default },
        )
        _hostWindowFeed = State(initialValue: feed)
        // Open Quickly's Host rows read the live feed (weak — @State owns it).
        overlay.hostWindowFeed = feed
        // While the feed is live its snapshot answers the app-launch monitor's
        // poll for free (one poller replaces two); a dormant feed falls back to the wire query.
        launchMonitor.hostWindowFeed = feed
        // QUIT-DRAIN: hand the termination delegate the single live store (weak — the App's `@State`
        // owns it) so `applicationShouldTerminate` can drain the in-flight pane teardowns via
        // `quiesce()` before the process dies. Set here, before any window exists, so the seam is live
        // for the very first ⌘Q.
        SlopDeskAppTerminationDelegate.store = store
        // Held in a local so the keybinding dispatcher's `isWorkspaceWindowKey` closure below captures the SAME
        // `WeakWindowBox` the `.introspect(.window)` hook fills — mirroring the `overlay` local pattern.
        let windowBox = WeakWindowBox()
        _windowBox = State(initialValue: windowBox)
        _clipboardMonitor = State(initialValue: ClipboardMonitor(store: store))
        // PASTE AS KEYSTROKES: the LIVE local-clipboard reader for the ⌥⌘V chord + the remote-GUI pane's
        // paste menu. Reads the CURRENT pasteboard (not the up-to-1s-stale ring head), so it works even when
        // clipboard-history recording is off. Main-actor only (route()/currentLocalClipboard() are @MainActor).
        store.clipboardTextProvider = { ClientPasteboard.pasteboard.string(forType: .string) }
        _dockProgress = State(initialValue: dockProgress)
        // Build the live keybinding dispatcher over the single store. A new-pane action (split /
        // new-tab / new-session) mints a terminal pane directly via the store's routing, focused,
        // so the user picks Terminal / Remote window INSIDE the new pane; ⌘T stays a direct-terminal escape
        // hatch (it routes via `.newPane(.terminal)`, never `.newTab`).
        //
        // The dispatcher's `textBinding`/`unbind` resolution is LIVE here regardless of the overlay layer —
        // a user `text:`/`csi:`/`esc:` config binding injects via `sendBytes` and an `unbind:` passes through, both
        // resolved from `WorkspaceBindingRegistry.activeOverrides`. The palette (⌘⇧P) +
        // cheat-sheet (⌘/) toggles thread into THIS monitor so the overlay layer is driven by the SAME single chord
        // owner (never a competing `.keyboardShortcut`). `toggleFind` stays nil — its `route` arm falls back
        // to the tree-path `requestFindInActivePane()`. `togglePeekReply` IS wired here: ⌘⌥J
        // opens the Peek & Reply overlay rather than falling back to `jumpToOldestAttentionPane()`.
        // The ⇧⌘F Global Search toggle threads into the SAME NSEvent monitor that owns every chord, so
        // the cross-tab results surface opens from the keyboard (and the View ▸ Global Search… menu item below).
        let keyDispatcher = WorkspaceKeyDispatcher(
            store: store,
            togglePalette: { [overlay] in overlay.togglePalette() },
            toggleCheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            // ⌘⌥J opens the Peek & Reply card over the oldest pane needing attention through
            // the SAME NSEvent monitor that owns every chord. The coordinator's `togglePeekReply()` HONESTLY
            // no-ops when nothing needs attention (so the chord does nothing rather than flashing an empty
            // card), instead of falling back to `jumpToOldestAttentionPane()` in `route`. ⌘⇧J stays the
            // Hint-to-Open chord (not repurposed for peek-reply).
            togglePeekReply: { [overlay] in overlay.togglePeekReply() },
            toggleGlobalSearch: { [overlay] in overlay.toggleGlobalSearch() },
            // ⌘J opens the folded-in Jump-To — the Open-Quickly picker at the
            // `.current` pill — through the SAME NSEvent monitor that owns every chord.
            toggleJumpTo: { [overlay] in overlay.toggleOpenQuickly(filter: .current) },
            // ⌘⇧O opens the Open-Quickly picker at the merged `.all` pill. ⌘⇧O + ⌘J are the ONLY
            // GLOBAL Open-Quickly chords; the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL (handled by
            // `OpenQuicklyView.onKeyPress`, never registered in `WorkspaceBindingRegistry`).
            toggleOpenQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            // While the Open-Quickly picker is presented the dispatcher yields the whole
            // keyboard to it like a modal sheet (the picker's `.onKeyPress` owns ⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J + ⌘1–9 +
            // ⌘K). Without this the app monitor — which PREEMPTS the responder chain — resolves the GLOBAL
            // chord behind the picker, so ⌘1–9 switched the background tab (not quick-pick) and ⌘W destroyed
            // the focused pane. Esc / a scrim-tap still close it; ⌘⇧O / ⌘J stay global only while it is hidden.
            // The Peek & Reply card YIELDS the same way — its reply field must receive normal
            // typing + the bare-1–9 quick-answer (which a global ⌘-less chord can't steal, but a yield keeps
            // any modeled chord from firing behind the focused card). Esc / a scrim-tap close it.
            isOverlayCapturingKeys: { [overlay] in overlay.capturesKeyboardWhileVisible },
            // Gate the app-wide NSEvent monitor
            // on the WORKSPACE window being key, so the stock Settings scene (⌘,) + attached sheets receive
            // their own keystrokes instead of a bound chord (⌘W/⌘T/⌘1–9/…) resolving against the hidden
            // workspace tree behind them. The window is captured weakly in `windowBox` by the
            // `.introspect(.window)` hook below; the predicate is a pure IDENTITY check against
            // `NSApp.keyWindow` (`workspaceWindowIsKey`), so a nil capture — pre-introspect, or the weak box
            // going stale after the window closes — NEVER claims the keyboard. A `?? true` default would let a
            // stale/empty box swallow chords while Settings was frontmost. Every key then passes through
            // until the workspace window is truly key again.
            isWorkspaceWindowKey: { [windowBox] in
                Self.workspaceWindowIsKey(captured: windowBox.window, keyWindow: NSApp.keyWindow)
            },
        )
        _keyDispatcher = State(initialValue: keyDispatcher)
        // The client control socket server over a ``WorkspaceControlBackend`` adapter on the SAME
        // live stores the GUI uses (the backend holds them WEAKLY — the app retains the originals). Built
        // here so it outlives the scene; BOUND in a launch `.task` (the bind/listen is deferred off init).
        // The socket path is `SLOPDESK_CLIENT_SOCKET` env > the Application Support default.
        _clientControlServer = State(initialValue: ClientControlServer(
            backend: WorkspaceControlBackend(
                store: store, preferences: preferences, folders: folderFrecency,
            ),
        ))
        #endif
    }

    /// The root IDE shell. On macOS it hands the root view installers that wire ⌘⇧L (Toggle Tabs Panel /
    /// sidebar) and the chord-less Pin Window action to the view's live state ON THE
    /// app-level `keyDispatcher`, so each chord routes through the SAME NSEvent monitor that owns every other
    /// chord (the legacy `store.sidebarCollapsed` is not read on macOS); iOS has no dispatcher.
    @ViewBuilder
    private var workspaceRootView: some View {
        #if os(macOS)
        WorkspaceRootView(
            store: store,
            connection: connection,
            overlay: overlayCoordinator,
            chrome: chrome,
            installSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleSidebar(toggle) },
            // Hand the dispatcher the (chord-less by default) Pin Window toggle, so a user-bound
            // chord for `.pinWindow` flips the SAME `chrome.pinned` the menu Button + the `NSWindow.level` glue
            // read, through the one NSEvent monitor that owns every chord.
            installPinToggle: { [keyDispatcher] toggle in keyDispatcher.setTogglePinWindow(toggle) },
            paneDrag: paneDrag,
        )
        // Bind the coordinator's `openSettingsAction` to the SwiftUI `openSettings`
        // environment action so the palette "Open Settings" row + the agent footer hook open the stock
        // Settings scene — without this the row is a dead control, since nothing observes a `settingsVisible` flag.
        .modifier(SettingsOpenerInstaller(overlay: overlayCoordinator))
        #else
        WorkspaceRootView(store: store, connection: connection, overlay: overlayCoordinator, chrome: chrome)
        #endif
    }

    public var body: some Scene {
        WindowGroup {
            workspaceRootView
                // Hand the single live PreferencesStore to deep views (the agent footer's
                // notification dismissal/enable persistence reads it via `\.preferencesStore`).
                .preferencesStore(preferences)
                // Inject the app-owned Agents install-hooks controller so
                // the iOS `WorkspaceRootView` can hand it to the settings `SettingsSheet` (the macOS `Settings`
                // scene injects it separately). Harmless on macOS (the main window does not host the Agents
                // card). Without this the iOS Agents card is permanently `.disconnected` and the whole
                // Agent-Behaviour toggle block greyed out (the controller's `@Environment` resolves nil).
                .agentHooksController(agentHooks)
                // Inject the single overlay coordinator so deep views (the agent footer's "open
                // settings" hook, future toast emitters) reach it via `\.overlayCoordinator`.
                .overlayCoordinator(overlayCoordinator)
                // The guided first-launch sheet — composes On-Launch / Default-Terminal /
                // Install-CLI / Theme / Install-Claude-hooks. Presents once on a fresh install (the
                // `hasCompletedFirstLaunch` Defaults flag) and never under automation (it would steal the
                // autoconnect focus). Dismissing by ANY path persists the flag (FirstLaunchView's
                // `.onDisappear → model.finish()`), so it never re-presents. The sheet inherits the injected
                // `agentHooksController` (re-injected here defensively) for the Claude-hooks step.
                .sheet(isPresented: $presentFirstLaunch) {
                    FirstLaunchView(model: firstLaunchModel, store: preferences)
                        .agentHooksController(agentHooks)
                        // Native sheet → SYSTEM accent (reset the inherited theme tint) so its stock controls read
                        // as native macOS controls; appearance still follows the theme via `preferredColorScheme`.
                        .tint(nil)
                        // Adopt the active theme's light/dark like every other surface (issue 1) — without it
                        // the sheet inherited the OS appearance and could render light over a dark workspace.
                        .preferredColorScheme(Slate.colorScheme)
                }
                .task {
                    presentFirstLaunch = FirstLaunchModel.shouldPresent(
                        hasCompleted: SettingsKey.hasCompletedFirstLaunchEnabled,
                        automationActive: Self.hasAutomationEnvironment(),
                    )
                }
                // The app chrome is a PINNED palette (default Monokai Pro Classic — flat dark filter).
                // Pin the window's colour scheme to the active theme so every system semantic colour we don't
                // tokenize resolves with the right contrast, and route the global tint to the theme's accent
                // colour so stock controls/selection adopt it.
                .tint(Slate.State.accent)
                .preferredColorScheme(Slate.colorScheme)
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
                // System-dialog monitor poll loop, scoped to the scene. Skipped under automation / when
                // SLOPDESK_SYSTEM_DIALOG_PANES=0; inert anyway with no discovery seam registered.
                .task {
                    // Resolve through `EnvConfig` (ProcessInfo env → settings overlay → nil) so a
                    // GUI toggle can drive it; an EMPTY overlay is byte-identical to the raw read. This is
                    // the 3-state flag (unset / "0" / "force"), so route the lookup through `EnvConfig.string`
                    // and keep the 3-state branch VERBATIM — no polarity helper collapses the "force" arm.
                    let flag = EnvConfig.string("SLOPDESK_SYSTEM_DIALOG_PANES")
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
                // Install the app-level keybinding dispatcher's `.keyDown` local monitor once the
                // scene is up. It runs under automation too (the keybinding path is part of what HW E2E
                // drives); the monitor swallows ONLY the prefix + armed follow-ups + bound chords and passes
                // every bare key through, so it never interferes with autoconnect typing.
                .task { keyDispatcher.install() }
                // Host-windows FEED renewal loop (docs/45), scoped to the scene like the dialog
                // monitor. Self-gating: a collapsed rail with Open Quickly hidden (or a disconnected
                // app) idles with ZERO wire traffic, so running it unconditionally costs nothing.
                .task { await hostWindowFeed.run() }
                // Bind the client control socket so the `slopdesk` CLI can drive this running
                // GUI. The bind/listen is a couple of syscalls + a detached accept thread (the per-connection
                // read loops stay OFF the cooperative pool — hang-safety, mirroring the host ctl socket). A
                // bind failure (stale path the OS won't reclaim, etc.) is swallowed: the CLI control plane is
                // a convenience, never load-bearing, and must never crash the app. Runs under automation too
                // (HW E2E drives the CLI against a live app).
                .task {
                    do {
                        try clientControlServer.start()
                    } catch {
                        // Best-effort: log + continue; the GUI is fully usable without the CLI socket.
                        FileHandle.standardError.write(Data(
                            "client-control: socket bind failed: \(error)\n".utf8,
                        ))
                    }
                }
                // Drive the macOS Dock tile from the store's resolved aggregate. `dockTileModel`
                // reads `paneProgress` + `panePendingCompletion` (@Observable), so a progress/completion edge
                // re-renders here and re-applies the tile; a last-session-end edge resolves to `.inert` → the
                // controller CLEARS (no stuck red tile). The initial `.task` applies any restored state once
                // (onChange fires only on a change).
                .onChange(of: store.dockTileModel) { _, model in dockProgress.apply(model) }
                .task { dockProgress.apply(store.dockTileModel) }
            #endif
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await appLaunchMonitor.run()
                }
                // AUTOMATION ONLY (env-gated): auto-connect so an autoconnect launch goes live without a
                // manual click. A normal launch silently re-connects the saved host (see the
                // auto-reconnect task) or, on a fresh install, waits for the user to open the
                // Connect-to-Host editor (the top-bar status pill / "Connect to Host…" palette action).
                .task {
                    guard Self.hasAutomationEnvironment() else { return }
                    let env = WorkspaceStore.automationInputs()
                    if env["SLOPDESK_AUTOCONNECT_HOST"]?.isEmpty == false {
                        await connection.connect()
                    } else {
                        // Video-only automation (the video host serves UDP only, no TCP listener): mark
                        // connected so the workspace mounts and the .remoteGUI pane opens its UDP flow.
                        connection.markConnectedForAutomation()
                    }
                }
                // AUTO-RECONNECT (Goal B): normal launch silently re-connects to the MRU host. No-op under
                // any AUTOCONNECT env (automation keeps precedence); SLOPDESK_SKIP_AUTO_RECONNECT=1 off.
                .task {
                    guard !Self.hasAutomationEnvironment() else { return }
                    await connection.connectIfSavedTarget()
                }
            #if os(macOS)
                // AUTOMATION ONLY: bring the window to front + make it key at launch so the content
                // subtree appears and connect-on-appear fires WITHOUT a manual front/Open click. We reach
                // THIS scene's window via SwiftUIIntrospect rather than the fragile `NSApplication.shared
                // .windows.first` (wrong once a second window exists). The closure fires exactly when the
                // NSWindow is real, and `.introspect(.window)` is the sanctioned hook for any future
                // WindowGroup-level config. `!isKeyWindow` makes the repeat-firing callback idempotent.
                .introspect(.window, on: .macOS(.v14, .v15, .v26)) { window in
                    // Install the window-close confirmation gate (independent of automation). The
                    // store owns the policy decision (`requestCloseWindow()` → `pendingWindowClose`); the
                    // delegate routes through `WindowCloseGate` and presents a synchronous confirmation so a
                    // parked close always resolves (the window is never stranded).
                    Self.installWindowCloseGate(on: window, store: store)
                    // Install the ⌘⇧W "Close Window" actuator on the SAME NSEvent monitor
                    // that owns every chord. It calls `performClose(nil)` on the captured window (via the
                    // weak `windowBox`), firing `windowShouldClose` → the gate just installed — so the chord
                    // ACTUATES a close instead of parking a flag nothing reads. Re-assigning on a re-fire is an
                    // idempotent closure swap (it always reads the latest `windowBox.window`).
                    keyDispatcher.setCloseWindow { [windowBox] in windowBox.window?.performClose(nil) }
                    // The palette "Close Window" row routes through the SAME
                    // `performClose(nil)` actuator → the close-confirmation gate, so it actuates a real close
                    // instead of the dead `requestCloseWindow()` park. Re-assigning on a re-fire is idempotent.
                    overlayCoordinator.closeWindow = { [windowBox] in windowBox.window?.performClose(nil) }
                    // Capture the window weakly for the ⌘⇧W / menu / palette `performClose` actuators,
                    // and apply the configured initial size EXACTLY ONCE per window open (so a later manual
                    // resize is never fought). All NSWindow reach stays inside THIS blessed hook. (The window
                    // PIN level is a native `.windowLevel(chrome.pinned…)` scene modifier, not applied here.)
                    // This closure fires only for the window
                    // hosting the WORKSPACE root (the Settings scene never mounts this modifier), and File ▸ New
                    // Window is removed (`CommandGroup(replacing: .newItem)`), so exactly ONE window can ever land
                    // here — the box is never overwritten by a second workspace window's re-render.
                    windowBox.window = window
                    // Pass the LIVE chrome (for the grid `chromeOverhead` — the revealed
                    // sidebar) + the configured terminal font size (the font-derived fallback cell used
                    // only before the terminal surface lays out). The grid sizing DEFERS its once-per-open
                    // commit until real cell metrics exist, so it recomputes to the exact cols×rows.
                    Self.applyInitialWindowSize(
                        to: window, store: store, chrome: chrome,
                        fontPointSize: CGFloat(preferences.terminal.fontSize),
                    )
                    // AUTOMATION ONLY: bring the window to front + make it key ONCE per window open (see helper).
                    Self.automationBringToFrontOnce(window)
                }
                // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination.
                // (Fires AFTER ``SlopDeskAppTerminationDelegate`` has drained the in-flight pane
                // teardowns and replied — termination proceeds only then — so this stays the LAST-word
                // save; the delegate also saves up front in case the drain window is interrupted.)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                    // Reset the process-global Dock tile on teardown so a quit never leaves a
                    // stuck progress/red tile behind for the next app to inherit.
                    dockProgress.clear()
                }
                // On macOS `scenePhase` tracks WINDOW VISIBILITY, not app
                // activation — it stays `.active` while the window sits visible-but-backgrounded behind
                // another app, which would keep `isAppActive` permanently true and silently suppress every
                // command/error/agent UN banner (default `notifyWhileForeground == .off`). Drive it from
                // the real AppKit activation signal instead — the same one DockProgressController /
                // SecureKeyboardEntryController already use — so backgrounding the app (window still
                // visible) correctly flips the foreground gate.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.isAppActive = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    store.isAppActive = false
                }
                .task {
                    store.isAppActive = NSApplication.shared.isActive
                }
                // SATELLITE WINDOWS (Detach Pane into Window): diff one plain-AppKit window per
                // detached pane. Driven HERE off the `@Observable` detached list — the store stays
                // headless; only this app layer touches NSWindow. The launch restore re-docks satellites
                // (v1: they don't persist as windows), so the initial sync is normally a no-op — kept for
                // the automation/replay paths that could restore a mid-detach state.
                .onChange(of: store.detachedPanes) { _, panes in
                    satelliteWindows.sync(panes, store: store, paneDrag: paneDrag, decorate: decorateSatelliteRoot)
                }
                .task {
                    // Late-bind the drag coordinator's weak store (chip labels + destination gating) —
                    // `@State` objects cannot reference each other at property-init time.
                    paneDrag.store = store
                    satelliteWindows.sync(
                        store.detachedPanes, store: store, paneDrag: paneDrag, decorate: decorateSatelliteRoot,
                    )
                    // `openRemoteWindow` re-opening an already-detached host window reveals the satellite
                    // instead of minting a second live stream — the store stays AppKit-free, so it calls
                    // back into this coordinator through the injected seam.
                    store.revealSatelliteWindow = { paneID in satelliteWindows.reveal(paneID) }
                }
            #endif
        }
        #if os(macOS)
        // The app has NO system unified toolbar: hide the titlebar (the window keeps traffic lights + a
        // full-size content view) so its own hover-reveal titlebar (`SlateTitlebar`) is the only chrome.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        // Open at the odiff reference geometry (1280×800) so a fresh window matches the reference.
        .defaultSize(width: 1280, height: 800)
        // Pin Window (chord-less; menu/palette flips `chrome.pinned`) maps to the WINDOW LEVEL.
        // Reading the live `chrome.pinned` @Observable in the scene body re-applies this on every flip — a
        // native scene modifier is used rather than an `.introspect(.window)` pin-apply + `.onChange(of:)`
        // actuator reaching `NSWindow.level` directly. `WindowLevel` is macOS 15+; the single-window model (File ▸ New
        // Window is removed) means this group-wide level only ever touches the one workspace window.
        .windowLevel(chrome.pinned ? .floating : .normal)
        // The discoverability-only menu bar over the SAME binding registry the dispatcher
        // reads. Each item routes through `WorkspaceBindingRegistry.route` with NO `.keyboardShortcut` — the
        // `NSEvent` monitor (`keyDispatcher`) owns chord dispatch (incl. the multi-key prefix), so a menu
        // shortcut would double-fire / swallow a prefix tail. The palette + cheat-sheet
        // toggles thread through (capturing the SAME coordinator the NSEvent dispatcher drives) so the menu items toggle the
        // identical overlays — cheap parity. `toggleFind` stays nil (tree-path route arm); `togglePeekReply`
        // is wired so the View ▸ Peek & Reply menu row drives the same ⌘⌥J overlay.
        .commands {
            // The product is a documented SINGLE-workspace-window model (one
            // WindowGroup window + the stock Settings scene) — the whole app wiring (`store` /
            // `keyDispatcher` / `windowBox` / the close gate) is app-wide singleton state, so the stock
            // File ▸ New Window item would mint a SECOND workspace window over the SAME store whose introspect
            // hook then overwrites `windowBox`: chords would intermittently die in the window being typed in and
            // the ⌃B prefix would leak into remote-GUI panes. `.newItem` carries ONLY the New-Window item for a
            // plain WindowGroup (no document types are declared), so replacing it with nothing removes the
            // affordance without touching the rest of the File menu.
            CommandGroup(replacing: .newItem) {}
            WorkspaceCommands(
                store: store,
                togglePalette: { [overlayCoordinator] in overlayCoordinator.togglePalette() },
                toggleCheatSheet: { [overlayCoordinator] in overlayCoordinator.toggleCheatSheet() },
                // The View ▸ Peek & Reply menu row opens the SAME overlay the ⌘⌥J chord
                // drives (the menu mirrors the chord; the NSEvent dispatcher owns the chord itself).
                togglePeekReply: { [overlayCoordinator] in overlayCoordinator.togglePeekReply() },
                toggleGlobalSearch: { [overlayCoordinator] in overlayCoordinator.toggleGlobalSearch() },
                // The View ▸ Jump To… menu item opens the folded-in Jump-To (the
                // Open-Quickly picker at the `.current` pill), the SAME overlay the ⌘J chord drives.
                toggleJumpTo: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .current) },
                // The View ▸ Open Quickly… menu row opens the picker at the merged `.all` pill —
                // the SAME overlay the ⌘⇧O chord drives (the menu mirrors the chord; the dispatcher owns it).
                openQuickly: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .all) },
                // Pin Window is CHORD-LESS (no default keybinding), so the menu item is its primary
                // entry. Flip the SAME live `chrome.pinned` the `.onChange(of:)` above actuates to `NSWindow
                // .level` — directly off the app-owned chrome (no overlay round-trip needed).
                togglePinWindow: { [chrome] in chrome.togglePin() },
                // Feed the live pinned state so the View ▸ Pin Window row renders its ✓ (a checkable
                // toggle). Reading `chrome.pinned` here re-evaluates `.commands` when the pin flips.
                pinWindowOn: chrome.pinned,
                // The Window ▸ Close Window menu row ACTUATES a real close on the window the user is
                // LOOKING AT: a key SATELLITE closes itself (its delegate reattaches the pane — never the
                // hidden main window, which would be the surprise target of the once-captured `windowBox`);
                // otherwise `performClose(nil)` on the captured workspace `NSWindow` fires the native
                // `windowShouldClose` → the existing `WindowCloseConfirmationDelegate` gate (preserving the
                // close-confirmation policy), rather than routing to `store.requestCloseWindow()`, which
                // only parks a flag nothing observes and would leave the menu item unable to close.
                closeWindow: { [windowBox] in
                    if let satellite = NSApp.keyWindow as? SatellitePaneWindow {
                        satellite.performClose(nil)
                    } else {
                        windowBox.window?.performClose(nil)
                    }
                },
            )
        }
        #endif

        // The GUI Settings surface (⌘,). A STOCK SwiftUI `Settings` scene — the main window is
        // `.hiddenTitleBar` and the in-app overlay host is not yet mounted, so a separate system-chromed
        // window is the non-clashing home. Binds the SAME single live `PreferencesStore`. macOS-only:
        // `Settings` is unavailable on iOS (the iOS settings surface is an in-app sheet).
        #if os(macOS)
        SlopDeskSettingsScene(store: preferences, agentHooks: agentHooks)
        #endif
    }

    /// The FIRST connected pane's metadata façade in the active session, or `nil` when no pane
    /// carries a live channel. The Agents settings card (install/uninstall/status) is host-global but
    /// `MetadataClient` is one-per-pane, so it routes through whichever pane is connected; a `nil` here lets
    /// the card show "Connect a session to manage hooks" instead of a dead button. Resolved at CALL time so a
    /// reconnect transparently re-points the seam.
    @MainActor
    private static func firstConnectedMetadataClient(_ store: WorkspaceStore) -> MetadataClient? {
        for id in store.tree.activeSession?.allPaneIDs() ?? [] {
            if let client = (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient {
                return client
            }
        }
        return nil
    }

    /// The next built-in theme after `current` for the palette "Switch Theme"
    /// verb — advances the primary slot through the shipped built-ins (Settings → Appearance order), wrapping. A
    /// `nil` / `.system` / custom-slug current resolves to the compile-time default (Monokai Pro Classic) and
    /// advances from there, so the FIRST "Switch Theme" is always a visible change rather than a no-op. PURE (no
    /// GUI dependency) — mirrors ``ThemeCatalog/builtinThemes`` order via the matching ``ThemeChoice`` cases.
    private static func nextBuiltinTheme(after current: ThemeChoice?) -> ThemeChoice {
        let order: [ThemeChoice] = [
            .monokaiProClassic, .monokaiProClassicLight, .monokaiProOctagon, .monokaiProMachine,
            .monokaiProRistretto, .monokaiProSpectrum, .paper, .dark,
        ]
        let resolved = current.flatMap { order.contains($0) ? $0 : nil } ?? .monokaiProClassic
        let idx = order.firstIndex(of: resolved) ?? 0
        return order[(idx + 1) % order.count]
    }

    /// Promotes every `SLOPDESK_<KEY>=<VALUE>` launch argument into the process environment via `setenv`.
    private static func applyLaunchArgumentEnvironment() {
        for arg in CommandLine.arguments.dropFirst() {
            guard arg.hasPrefix("SLOPDESK_"), let eq = arg.firstIndex(of: "=") else { continue }
            let key = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            setenv(key, value, 1)
        }
    }

    /// Whether any AUTOCONNECT env var is set (gates the bootstrap + the front-on-autoconnect path).
    private static func hasAutomationEnvironment(_ env: [String: String] = WorkspaceStore
        .automationInputs()) -> Bool
    {
        let keys = ["SLOPDESK_AUTOCONNECT_HOST", "SLOPDESK_VIDEO_AUTOCONNECT_HOST"]
        return keys.contains { (env[$0]?.isEmpty == false) }
    }

    #if os(macOS)
    /// Wraps a satellite window's SwiftUI root with the scene-level environment. An `NSHostingView`
    /// root inherits NOTHING from the main scene (the known hosting-root env trap), so the theme
    /// tint/scheme + the injected stores must be re-applied here or the satellite renders unthemed and
    /// its deep views resolve nil coordinators.
    private func decorateSatelliteRoot(_ root: AnyView) -> AnyView {
        AnyView(
            root
                .preferencesStore(preferences)
                .agentHooksController(agentHooks)
                .overlayCoordinator(overlayCoordinator)
                .tint(Slate.State.accent)
                .preferredColorScheme(Slate.colorScheme),
        )
    }

    /// The keybinding dispatcher's key-window gate, as a PURE identity predicate so it is unit-pinnable
    /// without an `NSWindow` (`AnyObject` — tests inject plain fakes): the workspace owns the keyboard ONLY
    /// when the window captured by the `.introspect(.window)` hook IS the application's current key window.
    /// A `nil` capture (pre-introspect, or the weak ``WeakWindowBox`` going stale after the workspace window
    /// closed) NEVER claims the keyboard — a `window.map(\.isKeyWindow) ?? true` form would default a nil
    /// capture to "workspace is key", letting a stale box swallow chords while the Settings window (or any
    /// other window) is frontmost. Identity against `NSApp.keyWindow` also stays truthful if the box ever
    /// held a non-workspace window: that window being key is exactly the state where yielding is wrong only
    /// for the REAL workspace window — and only the ONE workspace window can land in the box: File ▸ New
    /// Window is removed, and the detach-pane satellites (``SatellitePaneWindow``) are plain-AppKit windows
    /// that never mount the `.introspect` hook. A key SATELLITE therefore correctly yields the chord
    /// keyboard (workspace chords act on the main window; satellites take plain first-responder input).
    static func workspaceWindowIsKey(captured: AnyObject?, keyWindow: AnyObject?) -> Bool {
        guard let captured else { return false }
        return captured === keyWindow
    }

    /// Associated-object key under which a window retains its ``WindowCloseConfirmationDelegate`` (the
    /// delegate is referenced WEAKLY by `NSWindow.delegate`, so it needs an explicit owner for the window's
    /// lifetime). Only its ADDRESS is used (as the associated-object key), never its value — `nonisolated`
    /// (unsafe) because an address-only key carries no shared mutable state to race on.
    private nonisolated(unsafe) static var windowCloseDelegateKey: UInt8 = 0

    /// Installs the window-close confirmation gate on `window` exactly once. SwiftUI installs its own
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

    /// Associated-object key marking a window whose once-per-open initial size has been applied (so
    /// a later manual resize is never re-fought by the re-firing introspect callback). Only its ADDRESS is
    /// used as the key, never its value — `nonisolated(unsafe)` like ``windowCloseDelegateKey``.
    private nonisolated(unsafe) static var windowSizeAppliedKey: UInt8 = 0
    /// One-shot gate for the automation bring-to-front (see the `.introspect(.window)` closure): the
    /// introspect callback re-fires on every scene re-render, so the activate must run at most once per
    /// window or it steals focus back whenever the user switches to another app.
    private nonisolated(unsafe) static var windowActivatedKey: UInt8 = 0

    /// AUTOMATION ONLY: bring the workspace window to front + make it key ONCE per window open, so an
    /// autoconnect launch goes live without a manual click. Gated by the same associated-object one-shot as
    /// `applyInitialWindowSize` — the `.introspect(.window)` closure RE-FIRES on every scene re-render
    /// (terminal/video output mutates @Observable state continuously), and an un-gated re-activate would yank
    /// focus straight back the moment the user switched to another app. A non-automation launch is a no-op.
    @MainActor
    private static func automationBringToFrontOnce(_ window: NSWindow) {
        guard hasAutomationEnvironment(),
              objc_getAssociatedObject(window, &windowActivatedKey) == nil else { return }
        objc_setAssociatedObject(window, &windowActivatedKey, true, .OBJC_ASSOCIATION_RETAIN)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Apply the configured initial window size at most once per window open (guarded by an
    /// associated object, mirroring the close-gate retain idiom), so a later manual resize always stands:
    ///   * ``WindowSizeMode/remember`` → `setFrameAutosaveName` and commit (let the autosaved frame restore);
    ///   * ``WindowSizeMode/grid`` / ``WindowSizeMode/frame`` → resolve a CONTENT size via the pure
    ///     ``WindowSizeMath/resolvedContentSize(mode:cols:rows:widthPx:heightPx:cell:visible:chromeInsets:chromeOverhead:)``
    ///     and `setContentSize`.
    ///
    /// Two correctness points the pure math + this glue enforce:
    ///   1. The grid sizes the TERMINAL, not the whole content view — `chromeOverhead` adds the revealed
    ///      sidebar (TABS) width (the SAME constant the split item adopts) so an
    ///      80-col grid yields an 80-col TERMINAL, not 80 cols minus the sidebar. The hover-reveal titlebar is
    ///      an OVERLAY (no layout height) and there is no horizontal tab bar, so the vertical overhead is 0.
    ///   2. Real cell metrics: `grid` uses the LIVE per-cell advance of the active terminal surface; before it
    ///      lays out we use a font-DERIVED fallback (`WindowSizeMath.fallbackCell`) instead of a wrong hard
    ///      8×16, and DEFER the once-per-open commit until real metrics exist — so the window recomputes to the
    ///      exact cols×rows once libghostty reports its true cell advance (a later introspect fire), rather than
    ///      permanently committing the approximation.
    /// All numeric inputs are clamped inside ``WindowSizeMath`` (never 0×0 / off-screen-gigantic).
    @MainActor
    private static func applyInitialWindowSize(
        to window: NSWindow,
        store: WorkspaceStore,
        chrome: WorkspaceChromeState,
        fontPointSize: CGFloat,
    ) {
        guard objc_getAssociatedObject(window, &windowSizeAppliedKey) == nil else { return }

        let mode = SettingsKey.windowSize
        if mode == .remember {
            window.setFrameAutosaveName("SlopDeskMainWindow")
            objc_setAssociatedObject(window, &windowSizeAppliedKey, true, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        // Live per-cell advance of the active terminal pane, or a font-derived fallback before the first
        // surface lays out (NOT a hard 8×16, which is wrong for any non-default font).
        let liveCell = Self.activeCellMetrics(store: store)
        let cell = liveCell ?? WindowSizeMath.fallbackCell(fontPointSize: fontPointSize)
        let visible = window.screen?.visibleFrame ?? .zero
        // Chrome insets = full window frame minus the content layout rect (title bar + borders). Separate
        // subtraction per axis (no fma) — `WindowSizeMath` keeps the same float discipline.
        let chromeInsets = CGSize(
            width: window.frame.size.width - window.contentLayoutRect.size.width,
            height: window.frame.size.height - window.contentLayoutRect.size.height,
        )
        // In-window non-terminal overhead for `grid` mode: the revealed sidebar width
        // (the titlebar is an overlay → no vertical cost; vertical-tabs-only → no horizontal tab bar).
        let overheadWidth =
            chrome.sidebarCollapsed ? 0 : SlopDeskSplitViewController.defaultSidebarWidth
        let chromeOverhead = CGSize(width: overheadWidth, height: 0)
        guard let size = WindowSizeMath.resolvedContentSize(
            mode: mode,
            cols: SettingsKey.windowCols,
            rows: SettingsKey.windowRows,
            widthPx: SettingsKey.windowWidthPx,
            heightPx: SettingsKey.windowHeightPx,
            cell: cell,
            visible: visible,
            chromeInsets: chromeInsets,
            chromeOverhead: chromeOverhead,
        ) else { return }
        window.setContentSize(size)

        // Commit the once-per-open guard EXCEPT for a `grid` window still on the font-derived fallback (no real
        // metrics yet): leave it UNSET so a later introspect fire recomputes to the exact cols×rows once the
        // terminal surface has laid out. `.frame` (no cell dependency) and grid-with-real-metrics commit now.
        if mode == .frame || liveCell != nil {
            objc_setAssociatedObject(window, &windowSizeAppliedKey, true, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// The live per-cell advance of the active terminal pane, or `nil` when the active pane is not
    /// a laid-out terminal surface (a remote-GUI pane, or before the first layout) — the grid math then falls
    /// back to a sane default. Reaches the surface ONLY through the public ``WorkspaceStore/handle(for:)``
    /// chain (no private store reach-around), and only READS geometry (hang-safe: no surface instantiation).
    @MainActor
    private static func activeCellMetrics(store: WorkspaceStore) -> TerminalCellMetrics? {
        guard let id = store.tree.activeSession?.activeTab?.activePane,
              let live = store.handle(for: id) as? LivePaneSession,
              let snapshot = live.terminalModel?.surface as? TerminalViewportSnapshotting
        else { return nil }
        return snapshot.cellMetrics()
    }
    #endif

    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        // iOS scenePhase genuinely tracks foreground/background (there's no separate window-occlusion
        // signal to prefer), so it stays the source of truth for `isAppActive` there.
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
        #elseif os(macOS)
        if phase == .background { store.saveImmediately() }
        #endif
    }
}

#if os(macOS)
/// Binds ``OverlayCoordinator/openSettingsAction`` to the SwiftUI `openSettings`
/// environment action so the palette "Open Settings" row + the agent footer's settings hook actually open the
/// stock `Settings` scene (⌘, is otherwise the ONLY way in). `openSettings` is only readable from inside a
/// View's environment, so this zero-effect modifier is where the app captures it; wired once on appear.
private struct SettingsOpenerInstaller: ViewModifier {
    let overlay: OverlayCoordinator
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { overlay.openSettingsAction = { openSettings() } }
    }
}

/// QUIT-DRAIN (orphaned-session leak — the clean-quit twin of the wifi-flap host detach/reattach fix): closing a
/// busy pane (⌘W) drops it from the tree + registry SYNCHRONOUSLY, but the actual host disconnect
/// (bye/channelClose) runs in a non-awaited background teardown task. A ⌘Q within that window kills the
/// process before the bye reaches the wire: the host soft-detaches the just-closed session into
/// `DetachedSessionStore` (default TTL: NEVER) while the client's persisted workspace no longer
/// references it — a permanently orphaned session whose agent keeps running with no owner.
/// ``WorkspaceStore/quiesce()`` exists exactly for this drain, wired here at its call site.
///
/// `applicationShouldTerminate` parks the quit (`.terminateLater`), saves the tree immediately (the
/// termination is async — the existing `willTerminateNotification` flush still runs after the reply
/// and stays the last word), drains via ``TerminationDrain`` (bounded — quit must NEVER hang on a wedged
/// teardown), then replies so AppKit finishes terminating.
///
/// The store rides a static seam because SwiftUI's `@NSApplicationDelegateAdaptor` instantiates the
/// delegate itself (`SlopDeskClientApp.init` cannot hand it instance state); weak — the App's `@State`
/// owns the store. With no store (never happens in production) the quit proceeds untouched.
@MainActor
final class SlopDeskAppTerminationDelegate: NSObject, NSApplicationDelegate {
    /// The single live store, injected by `SlopDeskClientApp.init()`.
    weak static var store: WorkspaceStore?
    /// The teardown-drain budget: generous for the in-flight bye/channelClose round trips, short enough
    /// that quit never feels hung (the losing quiesce keeps draining until the process exits anyway).
    static let drainTimeout: Duration = .seconds(2)
    /// One-shot: a second ⌘Q while the drain is pending must not spawn a second drain (each
    /// `.terminateLater` expects exactly one `reply`; the in-flight drain resolves the first request).
    private var draining = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store else { return .terminateNow }
        guard !draining else { return .terminateCancel } // drain in flight — its reply resolves the quit
        // QUIT-CONFIRM: guards against a stray ⌘Q reaching the app while the user is working the Host
        // Windows rail — `performKeyEquivalent: → terminate:` can fire with no real intent (a vanished
        // window reads as a CRASH; rcmd/XKey event-tap leaks are prime suspects). With any
        // tab open, an interactive quit asks first. Apple-Event quits (osascript, logout/shutdown)
        // skip the dialog — blocking automation or logout is worse than a stray quit.
        if QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: store.tree.sessions.contains { !$0.tabs.isEmpty },
            isAppleEventQuit: NSAppleEventManager.shared().currentAppleEvent != nil,
            envValue: ProcessInfo.processInfo.environment["SLOPDESK_QUIT_CONFIRM"],
        ), !Self.confirmQuit() {
            return .terminateCancel
        }
        draining = true
        // Persist BEFORE the async drain so even an interrupted drain window keeps the layout; the
        // willTerminate flush re-saves after the reply (idempotent, and the authoritative last word).
        store.saveImmediately()
        Task { @MainActor in
            await TerminationDrain.drain(timeout: Self.drainTimeout) { await store.quiesce() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The confirm dialog itself (GUI — the decision lives in ``QuitConfirmPolicy``). Return = Quit,
    /// Esc = Cancel: an intentional quit costs one keystroke; a stray one becomes a visible dialog
    /// instead of a vanished window.
    private static func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit SlopDesk?"
        alert.informativeText = "Host sessions keep running; your workspace reattaches on the next launch."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// PURE quit-confirmation decision (unit-pinned in `QuitConfirmPolicyTests`): interactive quits with
/// any open tab confirm; Apple-Event quits (automation, logout) and an explicit
/// `SLOPDESK_QUIT_CONFIRM=0` never do. An empty workspace quits silently — there is nothing to lose.
enum QuitConfirmPolicy {
    static func requiresConfirmation(
        hasOpenTabs: Bool, isAppleEventQuit: Bool, envValue: String?,
    ) -> Bool {
        guard envValue != "0" else { return false } // default-ON idiom (CLAUDE.md env table)
        return hasOpenTabs && !isAppleEventQuit
    }
}

/// QUIT-DRAIN: races an async drain `operation` against a bounded `timeout` and returns when EITHER
/// finishes — a clean teardown replies immediately, a wedged one never hangs the quit. Kept pure of
/// AppKit so the bound is unit-pinned headlessly (`TerminationDrainTests`); the delegate passes
/// `store.quiesce()`.
///
/// Shape: a continuation resumed exactly once by two racing `@MainActor` sibling tasks — deliberately
/// NOT a task group (the Swift-6 `@MainActor`-capture-in-`addTask` sendability trap). The losing side
/// runs to completion in the background: a timed-out quiesce keeps draining until the process dies
/// (harmless, and strictly better than not trying); a won race leaves only a finite sleep behind.
@MainActor
enum TerminationDrain {
    static func drain(timeout: Duration, operation: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task { @MainActor in
                await operation()
                gate.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume()
            }
        }
    }

    /// Resumes the wrapped continuation at most once — `@MainActor`, so the two racing tasks serialize
    /// through it and a double-resume (both sides landing) is structurally impossible.
    @MainActor
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}

/// A tiny WEAK holder for THIS scene's `NSWindow`, captured in the blessed `.introspect(.window)`
/// closure so the `.onChange(of: chrome.pinned)` pin actuator can re-level the live window without the
/// forbidden `NSApplication.windows` scan. Deliberately NOT `@Observable` — mutating `window` must not trigger
/// a re-render; it is a pure capture slot the scene's `@State` storage keeps alive for the window's lifetime.
@MainActor
final class WeakWindowBox {
    weak var window: NSWindow?
}

/// The PURE window-close gate the macOS `windowShouldClose` consults. Factored out of the AppKit
/// delegate so the close decision is unit-testable WITHOUT an `NSWindow` (the hang-safety rule), and so the
/// gate can never strand the window: a parked close ALWAYS resolves here, rather than returning a bare
/// `false` with no path to close.
@MainActor
enum WindowCloseGate {
    /// Resolves a window-close attempt against `store` and returns whether the `NSWindow` may close NOW.
    ///
    /// Parks the confirmation per the active session's ``CloseConfirmationPolicy``
    /// (``WorkspaceStore/requestCloseWindow()``). When NO confirmation is required it returns `true`
    /// immediately (byte-identical to an unguarded default close, the persisted layout preserved). When one IS
    /// required it invokes `confirm` (the synchronous prompt) EXACTLY once and routes the user's choice:
    ///   - confirmed ⇒ ``WorkspaceStore/confirmPendingWindowClose()`` (close the active session — the window
    ///     maps 1:1 to a ``Session`` — which tears down its panes / stops any running processes) and return `true` so the
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

/// A transparent `NSWindowDelegate` shim that adds the window-close confirmation gate WITHOUT
/// displacing SwiftUI's own window delegate. It implements ONLY `windowShouldClose(_:)` and forwards every
/// other selector to the delegate SwiftUI installed (`next`), so SwiftUI's window bookkeeping is untouched.
///
/// On a close attempt it routes through ``WindowCloseGate/resolve(store:confirm:)`` (the window → active
/// ``Session`` map). When the configured ``CloseConfirmationPolicy`` says confirm, it presents a SYNCHRONOUS
/// confirmation (`NSAlert`) so the attempt always resolves — the window can never be stranded with an
/// unresolved park. The decision is store-side + unit-tested; only this NSWindow
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
