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
import AislopdeskTerminal // E19 WI-4: TerminalCellMetrics + TerminalViewportSnapshotting (live cell advance, macOS window-size glue)
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
    /// E14/K5/K8: the macOS Dock progress/error-tint controller (`NSApp.dockTile`). macOS-only — there is no
    /// iOS Dock. Fed the store's resolved ``WorkspaceStore/dockTileModel`` on each progress/completion edge;
    /// the K8 bounce rides ``CommandCompletionNotifier/bounceDock``.
    @State private var dockProgress: DockProgressController
    #endif
    @State private var appLaunchMonitor: AppLaunchMonitor
    @State private var preferences: PreferencesStore
    /// E13 WI-2: the Agents settings-card model (install / uninstall / status of the Claude Code host hooks).
    /// Owned here so it outlives the separate `Settings` scene; its async seams resolve the active
    /// connection's first connected pane ``MetadataClient`` lazily at call time (a connection comes and goes).
    @State private var agentHooks: AgentHooksController
    /// E2/WI-1: the single overlay coordinator — command palette (⌘⇧P), keyboard cheat sheet (⌘/), the
    /// toast stack, and the Connect-to-Host / remote-window-picker modals. Built once in `init()` after the
    /// store + app connection, injected into the scene env (`\.overlayCoordinator`) and handed to
    /// ``WorkspaceRootView``. The macOS ``WorkspaceKeyDispatcher`` threads its palette/cheat toggles so the
    /// SAME NSEvent monitor that owns every chord drives the overlays; the store's background-event sinks
    /// ALSO push an in-app toast through it. The panel views + the host mount land in WI-2…WI-5.
    @State private var overlayCoordinator: OverlayCoordinator
    /// E11 / WI-7: the app-owned, client-side Folders frecency store — the backing of the Open-Quickly
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
    /// E20 WI-3: the CLIENT-side control socket server (`AF_UNIX` NDJSON), the runtime surface the new
    /// `aislopdesk` CLI drives the running GUI through (windows/tabs/panes, jump/config/theme/keybind, pane
    /// capture/send-keys, agent status). Built once here over a ``WorkspaceControlBackend`` adapter and bound
    /// in a launch `.task`; compiled-only + never unit-tested (hang-safety, mirroring the host's
    /// `AgentControlListener`). macOS-only — the CLI install + OS integration are `#if os(macOS)`.
    @State private var clientControlServer: ClientControlServer
    #endif
    /// E19 WI-4: the chrome flags (sidebar / inspector collapse + window PIN) the toolbar / menu / palette
    /// drive. OWNED HERE (not view-local `@State` inside ``WorkspaceRootView``) so the macOS scene's blessed
    /// `.introspect(.window)` closure + the `.onChange(of: chrome.pinned)` actuator read the SAME flag the
    /// titlebar / menu flip — ONE `NSWindow.level` source of truth, never `NSApplication.windows`. Passed into
    /// ``WorkspaceRootView`` (both platforms); iOS reads only the two collapse flags (pin is an inert no-op).
    @State private var chrome: WorkspaceChromeState
    #if os(macOS)
    /// E19 WI-4: a WEAK handle to THIS scene's `NSWindow`, captured in the blessed `.introspect(.window)`
    /// closure so the `.onChange(of: chrome.pinned)` pin actuator can re-level the live window WITHOUT the
    /// forbidden `NSApplication.windows` scan (and without depending on the introspect closure re-firing on a
    /// pure flag change). A plain holder, not `@Observable` — mutating its `window` must not re-render.
    @State private var windowBox: WeakWindowBox
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycleTask: Task<Void, Never>?
    /// E16 WI-10: the File ▸ Recipe ▸ Save Snippet… editor presentation flag (macOS menu only — snippet CRUD
    /// is otherwise reached via Settings → Recipes). It has no store flag, so the app owns it; the recipe
    /// save / open / trust sheets ride the store's `recipes.pending*` flags instead (see ``recipeSheets``).
    @State private var snippetEditorPresented = false
    /// E20 WI-9 (ES-E20-4): the PURE first-launch gating model (which steps for this platform, present-once).
    /// Built once; the guided sheet presents when ``FirstLaunchModel/shouldPresent(hasCompleted:automationActive:)``
    /// (a fresh install, no automation) — resolved in a launch `.task` into ``presentFirstLaunch``. Both
    /// platforms (iOS keeps the cross-platform steps; the macOS-only steps drop out of `model.steps`).
    @State private var firstLaunchModel = FirstLaunchModel()
    /// Whether the first-launch sheet is up — set true once at launch when ``FirstLaunchModel/shouldPresent``.
    @State private var presentFirstLaunch = false

    public init() {
        // Promote `AISLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        Self.applyLaunchArgumentEnvironment()

        // D3: register the runtime-theme hook BEFORE building `PreferencesStore` so its init-time
        // `applyAppearance` repoints `ThemeStore.shared` (and the persisted theme is live from the first
        // frame). `WorkspaceCore` owns the `AppearanceApplier` seam but cannot import this SwiftUI layer, so
        // the closure lives here — E15 WI-3 widened it to take the WHOLE `AppearancePreferences`, so
        // `ThemeStore` resolves the dual-slot / custom-slug / follow-OS selection and posts the
        // cross-`NSHostingController` repaint notification the split controller re-pins on.
        AppearanceApplier.apply = { appearance in
            ThemeStore.shared.apply(appearance: appearance)
        }
        // The terminal CELLS adopt the active theme's flat palette (otty flat design): this hook reads the
        // already-resolved `ThemeStore.active` (so the dual-slot / `.system` selection is concrete) and hands
        // its libghostty 6-hex background/foreground PLUS (E15 WI-3) the 16-entry ANSI palette + selection
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
        // E15 ES-E15-4: the per-scope (Light/Dark-theme) font override reaches the live terminal. The active
        // slot's resolved theme slug (`ThemeStore.active.id` — dual-slot / `.system` already concrete) keys
        // `appearance.themeFonts`, which `PreferencesStore.applyTerminal` looks up via `FontScopeResolver`.
        AppearanceApplier.resolveActiveThemeSlug = { ThemeStore.shared.active.id }
        // E15 WI-6: build the custom-theme catalog (scan `~/.config/aislopdesk/themes/` — `[]` on iOS) and
        // wire it as the `ThemeStore` custom-resolution seam BEFORE the first `PreferencesStore` apply below, so
        // a persisted `.custom` light/dark slot resolves to its scanned `ThemeDocument` on the very first frame
        // (not the default fallback). A since-deleted / not-yet-scanned slug still falls back gracefully.
        ThemeCatalog.shared.reloadCustom()
        ThemeStore.shared.resolveCustomDocument = { slug in ThemeCatalog.shared.customDocument(slug: slug) }
        // E15 WI-3: start the macOS OS-appearance observer so a dual-slot / `.system` user follows the system
        // colour scheme LIVE (a no-op on iOS).
        ThemeStore.shared.observeOSAppearanceChanges()

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
        // E15 item 9: ⌘+/⌘-/⌘0 zoom the terminal via the SINGLE source of truth (`terminal.fontSize`) so the
        // Settings "Size" stepper stays in sync (the zoom rebuilds the libghostty config + reflows the PTY grid
        // — a font-SIZE change is correctly NOT grid-preserving). Wired to the live `PreferencesStore`.
        store.onFontSizeStep = { [weak preferences] step in
            switch step {
            case .increase: preferences?.increaseFontSize()
            case .decrease: preferences?.decreaseFontSize()
            case .reset: preferences?.resetFontSize()
            }
        }

        // E11 / WI-7: the app-owned, client-side Folders frecency store — the backing of the Open-Quickly
        // Folders pill (⌘Z). Owned here (retained by `_folderFrecency` below) and attached to the coordinator,
        // which holds it WEAKLY (like `store`). Under automation, point it at a THROWAWAY temp sidecar so an
        // autoconnect run never pollutes the developer's real `folders-frecency.json` (mirroring the
        // nil-persistence guard that protects `workspace.json`).
        let folderFrecency: FolderFrecencyStore = isAutomation
            ? FolderFrecencyStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("aislopdesk-automation-folders-frecency.json"))
            : FolderFrecencyStore()
        // E11 / WI-2 → WI-7: record a pane's cwd change into the frecency store. The store fires
        // `onCwdVisited` ONLY when the known cwd actually changes (its own guard); the client owns the
        // recording so `WorkspaceStore` stays store/SwiftUI-agnostic (a closure, not a direct dependency), and
        // `record(cwd:)` validates-then-stores (drops an empty / over-long path). Held weakly — the app retains
        // the store via `_folderFrecency`.
        store.onCwdVisited = { [weak folderFrecency] cwd in folderFrecency?.record(cwd: cwd) }

        // E16 WI-10: feed the snippet expander its reserved-var strings ({{clipboard}}/{{date}}/{{time}}) at
        // expand time. The store calls this from `runSnippet`; the read of the live pasteboard + clock stays
        // HERE (app side) so the pure `ReservedSnippetVars` resolver never touches `NSPasteboard`/`UIPasteboard`
        // /`Date` (the determinism + hang-safety split). `{{cursor}}` is resolved purely (no app input).
        store.snippetReservedValues = { Self.liveReservedSnippetValues() }

        // E2/WI-1: the single overlay coordinator. Built HERE — after the store + app connection exist — so
        // the macOS dispatcher (below) can thread its ⌘⇧P / ⌘/ toggles into the SAME NSEvent monitor that
        // owns every chord, and the store's background-event sinks can ALSO surface an in-app toast.
        // `connectionTarget` lets the remote-window-picker modal query the live host. The app-owned Folders
        // frecency store is attached here (the coordinator holds it weakly, backing the Open-Quickly Folders
        // pill). Retained for the scene lifetime by `_overlayCoordinator` / `_folderFrecency` below.
        let overlay = OverlayCoordinator(store: store, folders: folderFrecency)
        overlay.connectionTarget = { [weak appConnection] in appConnection?.target ?? .default }
        // E13 / WI-5 (ES-E13-5): the Send-to-Chat dialog reads the active pane's quote off the live store, and
        // its "Copy Message" writes the system pasteboard. Inject both so the coordinator stays store- and
        // clipboard-framework-agnostic (the headless / test defaults capture instead of touching AppKit).
        overlay.captureSendToChat = { [weak store] in store?.captureSendToChatContext() }
        overlay.copyToPasteboard = { text in
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #elseif canImport(UIKit)
            UIPasteboard.general.string = text
            #endif
        }

        #if os(macOS)
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router

        // E14/K5/K8: the macOS Dock progress/error-tint controller. The K8 bounce is driven from the notifier
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

        // E2/WI-1 (ES-E2-5): surface the SAME background events as IN-APP toasts on BOTH platforms. A toast
        // is in-app UI, INDEPENDENT of the OS-notification setting — push it unconditionally; the macOS
        // `UNUserNotification` is gated by the pure ``NotificationPolicy`` (E14/K9 — the per-event toggle +
        // the Notify-While-Foreground tri-state), applied inside the notifier with the store-supplied
        // appActive + sourcePaneFocused. Each toast carries a stable `pane.<key>` id so a newer event for the
        // same pane REPLACES the old one (the coordinator's de-dupe), and a flavour matching the event class.
        store.onPaneNotification = { [weak overlay, weak store] paneID, paneTitle, title, body in
            // E20/WI-7: an `aislopdesk watch` finish carries the private WatchNotificationMarker sentinel in its
            // title — route it to `.watchFinish` (gated by Notify on Watch Finish) with the marker STRIPPED;
            // every other explicit notification stays `.explicitOSC` (the master switch).
            let (event, displayTitle) = NotificationEvent.classifyExplicit(title: title, body: body)
            // SECURITY: the toast is in-app UI and — on iOS — the ONLY notification surface, so the secret
            // redaction the macOS banner (`CommandCompletionNotifier`) and the pane title
            // (`PanePresentation`) apply must ALSO run here, or an OSC 9/777 title/body carrying a token is
            // shown verbatim. Done once at the construction site (`Toast.explicitOSC`) so both platforms benefit.
            overlay?.pushToast(Toast.explicitOSC(paneIDRaw: paneID.raw, title: displayTitle, body: body))
            #if os(macOS)
            // E14/K9: the OS banner now goes through the pure NotificationPolicy (the per-event toggle resolved
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
            // E14/K9: route the OS banner through NotificationPolicy — Notify on Finish (clean exit, default
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
            // E14/K9: agent edges (Claude-only, reusing AttentionSupervision) ride their OWN per-event
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
        // E13 WI-2: the Agents settings-card model. Its seams resolve the active session's FIRST connected
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
        // E19 WI-4: the app owns the chrome flags (incl. window PIN) so the macOS scene's blessed
        // `.introspect(.window)` closure reads the SAME `chrome.pinned` the titlebar / menu flip.
        _chrome = State(initialValue: WorkspaceChromeState())
        #if os(macOS)
        _windowBox = State(initialValue: WeakWindowBox())
        _clipboardMonitor = State(initialValue: ClipboardMonitor(store: store))
        _dockProgress = State(initialValue: dockProgress)
        // WS-B / B3: build the live keybinding dispatcher over the single store. A new-pane action (split /
        // new-tab / new-session / floating) mints an in-pane `.chooser` pane via the store's routing, focused,
        // so the user picks Terminal / Remote window INSIDE the new pane; ⌘T stays a direct-terminal escape
        // hatch (it routes via `.newPane(.terminal)`, never `.newTab`). The default prefix is ⌃A (tmux-like).
        //
        // E1/WI-7: the dispatcher's `textBinding`/`unbind` resolution is LIVE here regardless of E2 — a user
        // `text:`/`csi:`/`esc:` config binding injects via `sendBytes` and an `unbind:` passes through, both
        // resolved from `WorkspaceBindingRegistry.activeOverrides`. E2/WI-1 threads the palette (⌘⇧P) +
        // cheat-sheet (⌘/) toggles into THIS monitor so the overlay layer is driven by the SAME single chord
        // owner (never a competing `.keyboardShortcut`). `toggleFind` stays nil — its `route` arm falls back
        // to the tree-path `requestFindInActivePane()`. `togglePeekReply` IS wired here (E13 / WI-8): ⌘⌥J now
        // opens the Peek & Reply overlay (replacing the old `jumpToOldestAttentionPane()` route fallback).
        // E5/WI-4: thread the ⇧⌘F Global Search toggle into the SAME NSEvent monitor that owns every chord, so
        // the cross-tab results surface opens from the keyboard (and the View ▸ Global Search… menu item below).
        _keyDispatcher = State(initialValue: WorkspaceKeyDispatcher(
            store: store,
            togglePalette: { [overlay] in overlay.togglePalette() },
            toggleCheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            // E13 / WI-8 (P4): ⌘⌥J opens the Peek & Reply card over the oldest pane needing attention through
            // the SAME NSEvent monitor that owns every chord. The coordinator's `togglePeekReply()` HONESTLY
            // no-ops when nothing needs attention (so the chord does nothing rather than flashing an empty
            // card) — replacing the prior `jumpToOldestAttentionPane()` fallback in `route`. ⌘⇧J stays E10's
            // Hint-to-Open (NOT restored to peek-reply).
            togglePeekReply: { [overlay] in overlay.togglePeekReply() },
            // E13 / WI-5 (ES-E13-5): ⌘⌃↩ opens the Send-to-Chat dialog over the active pane's captured quote
            // through the SAME NSEvent monitor that owns every chord. The coordinator HONESTLY no-ops when
            // there is nothing to quote (no selection + no command block), so the chord does nothing rather
            // than flashing an empty card.
            toggleSendToChat: { [overlay] in overlay.toggleSendToChat() },
            toggleGlobalSearch: { [overlay] in overlay.toggleGlobalSearch() },
            // E10 / WI-8 → E11 / WI-7: ⌘J now opens the folded-in Jump-To — the Open-Quickly picker at the
            // `.current` pill — through the SAME NSEvent monitor that owns every chord.
            toggleJumpTo: { [overlay] in overlay.toggleOpenQuickly(filter: .current) },
            // E11 / WI-7: ⌘⇧O opens the Open-Quickly picker at the merged `.all` pill. ⌘⇧O + ⌘J are the ONLY
            // GLOBAL Open-Quickly chords; the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL (handled by
            // `OpenQuicklyView.onKeyPress`, never registered in `WorkspaceBindingRegistry`).
            toggleOpenQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            // E11 review fix: while the Open-Quickly picker is presented the dispatcher yields the whole
            // keyboard to it like a modal sheet (the picker's `.onKeyPress` owns ⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J + ⌘1–9 +
            // ⌘K). Without this the app monitor — which PREEMPTS the responder chain — resolves the GLOBAL
            // chord behind the picker, so ⌘1–9 switched the background tab (not quick-pick) and ⌘W destroyed
            // the focused pane. Esc / a scrim-tap still close it; ⌘⇧O / ⌘J stay global only while it is hidden.
            // E13 / WI-8: the Peek & Reply card YIELDS the same way — its reply field must receive normal
            // typing + the bare-1–9 quick-answer (which a global ⌘-less chord can't steal, but a yield keeps
            // any modeled chord from firing behind the focused card). Esc / a scrim-tap close it.
            // E13 / WI-5: the Send-to-Chat dialog (its auto-focused comment field) folds into the SAME gate via
            // `capturesKeyboardWhileVisible` — without it a modeled ⌘W destroyed a background pane / ⌘1–9
            // switched a background tab behind the open dialog (the chord leaked past the focused field).
            isOverlayCapturingKeys: { [overlay] in overlay.capturesKeyboardWhileVisible },
        ))
        // E20 WI-3: the client control socket server over a ``WorkspaceControlBackend`` adapter on the SAME
        // live stores the GUI uses (the backend holds them WEAKLY — the app retains the originals). Built
        // here so it outlives the scene; BOUND in a launch `.task` (the bind/listen is deferred off init).
        // The socket path is `AISLOPDESK_CLIENT_SOCKET` env > the Application Support default.
        _clientControlServer = State(initialValue: ClientControlServer(
            backend: WorkspaceControlBackend(
                store: store, preferences: preferences, folders: folderFrecency,
            ),
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
            chrome: chrome,
            installDetailsToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleDetailsPanel(toggle) },
            installSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleSidebar(toggle) },
            // E9/WI-7: hand the dispatcher the four `Details: *` jump commands' tab selector (sets the shared
            // `DetailsPanelState` + reveals the panel), so a user-bound chord / palette row switches the Details
            // tab through the SAME NSEvent monitor that owns every other command.
            installSelectDetailsTab: { [keyDispatcher] select in keyDispatcher.setSelectDetailsTab(select) },
            // E19 WI-4: hand the dispatcher the (chord-less by default) Pin Window toggle, so a user-bound
            // chord for `.pinWindow` flips the SAME `chrome.pinned` the menu Button + the `NSWindow.level` glue
            // read, through the one NSEvent monitor that owns every chord.
            installPinToggle: { [keyDispatcher] toggle in keyDispatcher.setTogglePinWindow(toggle) },
        )
        #else
        WorkspaceRootView(store: store, connection: connection, overlay: overlayCoordinator, chrome: chrome)
        #endif
    }

    public var body: some Scene {
        WindowGroup {
            workspaceRootView
                // L4: hand the single live PreferencesStore to deep views (the agent footer's W4
                // notification dismissal/enable persistence reads it via `\.preferencesStore`).
                .preferencesStore(preferences)
                // E13 (ES-E13-1/ES-E13-2 iOS halves): inject the app-owned Agents install-hooks controller so
                // the iOS `WorkspaceRootView` can hand it to the settings `SettingsSheet` (the macOS `Settings`
                // scene injects it separately). Harmless on macOS (the main window does not host the Agents
                // card). Without this the iOS Agents card was permanently `.disconnected` and the whole
                // Agent-Behaviour toggle block greyed out (the controller's `@Environment` resolved nil).
                .agentHooksController(agentHooks)
                // E2/WI-1: inject the single overlay coordinator so deep views (the agent footer's "open
                // settings" hook, future toast emitters) reach it via `\.overlayCoordinator`. The host view
                // that renders the palette / cheat sheet / toasts lands in WI-5.
                .overlayCoordinator(overlayCoordinator)
                // E16 WI-10: host the recipe save / open / trust modals off the store's `recipes.pending*`
                // flags (⌘S / File ▸ Recipe routes flip them via `WorkspaceBindingRouting`), plus the
                // Save-Snippet editor off the app-owned `snippetEditorPresented`. Cross-platform — the same
                // sheets ride the iOS shell.
                .recipeSheets(store: store, snippetEditor: $snippetEditorPresented)
                // E20 WI-9 (ES-E20-4): the guided first-launch sheet — composes On-Launch / Default-Terminal /
                // Install-CLI / Theme / Install-Claude-hooks. Presents once on a fresh install (the
                // `hasCompletedFirstLaunch` Defaults flag) and never under automation (it would steal the
                // autoconnect focus). Dismissing by ANY path persists the flag (FirstLaunchView's
                // `.onDisappear → model.finish()`), so it never re-presents. The sheet inherits the injected
                // `agentHooksController` (re-injected here defensively) for the Claude-hooks step.
                .sheet(isPresented: $presentFirstLaunch) {
                    FirstLaunchView(model: firstLaunchModel, store: preferences)
                        .agentHooksController(agentHooks)
                        .tint(Otty.State.accent)
                }
                .task {
                    presentFirstLaunch = FirstLaunchModel.shouldPresent(
                        hasCompleted: SettingsKey.hasCompletedFirstLaunchEnabled,
                        automationActive: Self.hasAutomationEnvironment(),
                    )
                }
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
                // E20 WI-3: bind the client control socket so the `aislopdesk` CLI can drive this running
                // GUI. The bind/listen is a couple of syscalls + a detached accept thread (the per-connection
                // read loops stay OFF the cooperative pool — hang-safety, mirroring the host ctl socket). A
                // bind failure (stale path the OS won't reclaim, etc.) is swallowed: the CLI control plane is
                // a convenience, never load-bearing, and must never crash the app. Runs under automation too
                // (Phase-3 HW E2E drives the CLI against a live app).
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
                // E14/K5/K8: drive the macOS Dock tile from the store's resolved aggregate. `dockTileModel`
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
                    // E3 WI-4 (audit fix): install the ⌘⇧W "Close Window" actuator on the SAME NSEvent monitor
                    // that owns every chord. It calls `performClose(nil)` on the captured window (via the
                    // weak `windowBox`), firing `windowShouldClose` → the gate just installed — so the chord
                    // ACTUATES a close instead of parking a flag nothing reads. Re-assigning on a re-fire is an
                    // idempotent closure swap (it always reads the latest `windowBox.window`).
                    keyDispatcher.setCloseWindow { [windowBox] in windowBox.window?.performClose(nil) }
                    // Audit fix (palette parity): the palette "Close Window" row routes through the SAME
                    // `performClose(nil)` actuator → the close-confirmation gate, so it actuates a real close
                    // instead of the dead `requestCloseWindow()` park. Re-assigning on a re-fire is idempotent.
                    overlayCoordinator.closeWindow = { [windowBox] in windowBox.window?.performClose(nil) }
                    // E19 WI-4: capture the window weakly for the `.onChange(of: chrome.pinned)` pin actuator,
                    // apply the current pin level (idempotent — the callback can re-fire), and apply the
                    // configured initial size EXACTLY ONCE per window open (so a later manual resize is never
                    // fought). All NSWindow reach stays inside THIS blessed hook.
                    windowBox.window = window
                    Self.applyPinLevel(to: window, pinned: chrome.pinned)
                    // E19 WI-4 (A29): pass the LIVE chrome (for the grid `chromeOverhead` — revealed sidebar /
                    // shown inspector) + the configured terminal font size (the font-derived fallback cell used
                    // only before the terminal surface lays out). The grid sizing DEFERS its once-per-open
                    // commit until real cell metrics exist, so it recomputes to the exact cols×rows.
                    Self.applyInitialWindowSize(
                        to: window, store: store, chrome: chrome,
                        fontPointSize: CGFloat(preferences.terminal.fontSize),
                    )
                    guard Self.hasAutomationEnvironment(), !window.isKeyWindow else { return }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                // E19 WI-4: the Pin Window toggle flips `chrome.pinned`; re-level the captured window here so
                // the toggle is LIVE even if SwiftUIIntrospect's closure does not re-fire on a pure flag
                // change. Reading `chrome.pinned` registers the observation that re-runs this onChange.
                .onChange(of: chrome.pinned) { _, pinned in
                    if let window = windowBox.window { Self.applyPinLevel(to: window, pinned: pinned) }
                }
                // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                    // E14/K5/K8: reset the process-global Dock tile on teardown so a quit never leaves a
                    // stuck progress/red tile behind for the next app to inherit.
                    dockProgress.clear()
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
        // identical overlays — cheap parity. `toggleFind` stays nil (tree-path route arm); `togglePeekReply`
        // is wired (E13 / WI-8) so the View ▸ Peek & Reply menu row drives the same ⌘⌥J overlay.
        .commands {
            WorkspaceCommands(
                store: store,
                togglePalette: { [overlayCoordinator] in overlayCoordinator.togglePalette() },
                toggleCheatSheet: { [overlayCoordinator] in overlayCoordinator.toggleCheatSheet() },
                // E13 / WI-8 (P4): the View ▸ Peek & Reply menu row opens the SAME overlay the ⌘⌥J chord
                // drives (the menu mirrors the chord; the NSEvent dispatcher owns the chord itself).
                togglePeekReply: { [overlayCoordinator] in overlayCoordinator.togglePeekReply() },
                // E13 / WI-5 (ES-E13-5): the Agents ▸ Send to Chat menu row opens the SAME ⌘⌃↩ dialog the
                // chord drives (the menu mirrors the chord; the NSEvent dispatcher owns the chord itself).
                toggleSendToChat: { [overlayCoordinator] in overlayCoordinator.toggleSendToChat() },
                toggleGlobalSearch: { [overlayCoordinator] in overlayCoordinator.toggleGlobalSearch() },
                // E10 / WI-8 → E11 / WI-7: the View ▸ Jump To… menu item opens the folded-in Jump-To (the
                // Open-Quickly picker at the `.current` pill), the SAME overlay the ⌘J chord drives.
                toggleJumpTo: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .current) },
                // E11 / WI-7: the View ▸ Open Quickly… menu row opens the picker at the merged `.all` pill —
                // the SAME overlay the ⌘⇧O chord drives (the menu mirrors the chord; the dispatcher owns it).
                openQuickly: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .all) },
                // E9/WI-7 (ES-E9-5): the four View ▸ Details: * menu rows route through the SAME injected
                // coordinator closure the palette rows + the user-bindable chord drive (installed by
                // `WorkspaceRootView.wireChromeToggles` → sets `DetailsPanelState.selected` + reveals the
                // panel). Without this the menu rows were inert (`selectDetailsTab` was nil).
                selectDetailsTab: { [overlayCoordinator] tab in overlayCoordinator.selectDetailsTab(tab) },
                // E19 WI-4: Pin Window is CHORD-LESS (otty ships no chord), so the menu item is its primary
                // entry. Flip the SAME live `chrome.pinned` the `.onChange(of:)` above actuates to `NSWindow
                // .level` — directly off the app-owned chrome (no overlay round-trip needed).
                togglePinWindow: { [chrome] in chrome.togglePin() },
                // E19 WI-4: feed the live pinned state so the View ▸ Pin Window row renders its ✓ (a checkable
                // toggle). Reading `chrome.pinned` here re-evaluates `.commands` when the pin flips.
                pinWindowOn: chrome.pinned,
                // E3 WI-4 (audit fix): the Window ▸ Close Window menu row ACTUATES a real close —
                // `performClose(nil)` on THIS scene's captured `NSWindow` fires the native `windowShouldClose`
                // → the existing `WindowCloseConfirmationDelegate` gate (preserving the close-confirmation
                // policy). Without this the row routed to `store.requestCloseWindow()`, which only parked a flag
                // nothing observed — the menu item never closed the window.
                closeWindow: { [windowBox] in windowBox.window?.performClose(nil) },
                // E16 WI-10: light up the File ▸ Recipe ▸ Save Snippet… row — flips the app-owned
                // `snippetEditorPresented` the `recipeSheets` modifier presents the editor off. `nil` would
                // HIDE the row (no dead button); wiring it makes the menu entry live.
                openSnippetEditor: { snippetEditorPresented = true },
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
        AislopdeskSettingsScene(store: preferences, workspaceStore: store, agentHooks: agentHooks)
        #endif
    }

    /// E13 WI-2: the FIRST connected pane's metadata façade in the active session, or `nil` when no pane
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

    /// E16 WI-10 — the live reserved-snippet-var strings handed to ``WorkspaceStore/snippetReservedValues``
    /// (read by `runSnippet`): `{{clipboard}}` from the system pasteboard (`NSPasteboard` on macOS,
    /// `UIPasteboard` via ``SnippetPasteboardiOS`` on iOS), and `{{date}}` / `{{time}}` in the spec's fixed
    /// formats (`YYYY-MM-DD` / 24-hour `HH:mm`) built from local calendar components (locale-independent — no
    /// `DateFormatter` region surprises). `{{cursor}}` is resolved purely by ``ReservedSnippetVars`` and needs
    /// no value here.
    @MainActor
    private static func liveReservedSnippetValues() -> ReservedSnippetValues {
        let clipboard: String
        #if os(macOS)
        clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        #elseif os(iOS)
        clipboard = SnippetPasteboardiOS.clipboardString()
        #else
        clipboard = ""
        #endif
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        func pad2(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let date = "\(parts.year ?? 0)-\(pad2(parts.month ?? 0))-\(pad2(parts.day ?? 0))"
        let time = "\(pad2(parts.hour ?? 0)):\(pad2(parts.minute ?? 0))"
        return ReservedSnippetValues(clipboard: clipboard, date: date, time: time)
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

    /// E19 WI-4 — associated-object key marking a window whose once-per-open initial size has been applied (so
    /// a later manual resize is never re-fought by the re-firing introspect callback). Only its ADDRESS is
    /// used as the key, never its value — `nonisolated(unsafe)` like ``windowCloseDelegateKey``.
    private nonisolated(unsafe) static var windowSizeAppliedKey: UInt8 = 0

    /// E19 WI-4 (A30) — map the pin flag to `NSWindow.level` IDEMPOTENTLY. `.floating` keeps the window above
    /// other apps (otty Pin Window); `.normal` restores it. The guard means the re-firing introspect callback
    /// + a redundant `.onChange` never thrash the level.
    @MainActor
    private static func applyPinLevel(to window: NSWindow, pinned: Bool) {
        let level: NSWindow.Level = pinned ? .floating : .normal
        if window.level != level { window.level = level }
    }

    /// E19 WI-4 (A29) — apply the configured initial window size at most once per window open (guarded by an
    /// associated object, mirroring the close-gate retain idiom), so a later manual resize always stands:
    ///   * ``WindowSizeMode/remember`` → `setFrameAutosaveName` and commit (let the autosaved frame restore);
    ///   * ``WindowSizeMode/grid`` / ``WindowSizeMode/frame`` → resolve a CONTENT size via the pure
    ///     ``WindowSizeMath/resolvedContentSize(mode:cols:rows:widthPx:heightPx:cell:visible:chromeInsets:chromeOverhead:)``
    ///     and `setContentSize`.
    ///
    /// Two correctness points the pure math + this glue enforce:
    ///   1. The grid sizes the TERMINAL, not the whole content view — `chromeOverhead` adds the revealed
    ///      sidebar (TABS) + shown inspector (Details) widths (the SAME constants the split items adopt) so an
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
            window.setFrameAutosaveName("AislopdeskMainWindow")
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
        // In-window non-terminal overhead for `grid` mode: the revealed sidebar + shown inspector widths
        // (the titlebar is an overlay → no vertical cost; vertical-tabs-only → no horizontal tab bar).
        let overheadWidth =
            (chrome.sidebarCollapsed ? 0 : AislopdeskSplitViewController.defaultSidebarWidth)
                + (chrome.inspectorCollapsed ? 0 : AislopdeskSplitViewController.defaultInspectorWidth)
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

    /// E19 WI-4 — the live per-cell advance of the active terminal pane, or `nil` when the active pane is not
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
/// E19 WI-4 — a tiny WEAK holder for THIS scene's `NSWindow`, captured in the blessed `.introspect(.window)`
/// closure so the `.onChange(of: chrome.pinned)` pin actuator can re-level the live window without the
/// forbidden `NSApplication.windows` scan. Deliberately NOT `@Observable` — mutating `window` must not trigger
/// a re-render; it is a pure capture slot the scene's `@State` storage keeps alive for the window's lifetime.
@MainActor
final class WeakWindowBox {
    weak var window: NSWindow?
}

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
