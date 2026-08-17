// SlopDeskClientApp — the SwiftUI app SCENE, rendering the 3-pane IDE shell (`WorkspaceRootView` →
// `NSSplitViewController` on macOS / `NavigationSplitView` on iOS).
//
// What the app IS — the ONE `WorkspaceStore`, the ONE `AppConnection`, the preferences, the overlay
// coordinator, the Folders frecency, the Agents card, the chrome flags, and every closure seam between
// them — is built by ``ClientComposition`` in `SlopDeskClientCore` (docs/56 §2). None of that wiring
// draws, and once the UI splits per platform it would otherwise have had to be written twice.
//
// So what is left here is scene-shaped and nothing else: hold the composition, mount the root view,
// run the launch tasks, and install the macOS-only actuators the composition leaves as open sinks (the
// `UNUserNotification` banners, the Dock tile, the sound cue) plus the AppKit surfaces that have no
// phone counterpart at all (the NSEvent chord monitor, the satellite windows, the window-close gate).

#if canImport(SwiftUI)
import Defaults // fire-time reads of the Code Agent sound toggles in the attention sink
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import SwiftUIIntrospect // reach THIS scene's NSWindow from the SwiftUI WindowGroup (no NSApplication.windows hack)
#if os(iOS)
import UIKit // UIDevice.current.userInterfaceIdiom — the per-device live-video cap signal at init
#endif
#if os(macOS)
import AppKit // NSApplication — AUTOMATION-ONLY window-front so an autoconnect launch goes live in one shot
import Combine // AnyCancellable — the `.remember` frame-save observers, retained on the window
import ObjectiveC // objc_setAssociatedObject — retain the window-close delegate for the window's life
import SlopDeskTerminal // TerminalCellMetrics + TerminalViewportSnapshotting (live cell advance, macOS window-size glue)
import UserNotifications // explicit OSC 9/777 child notifications → local UNUserNotification
#endif

public struct SlopDeskClientApp: App {
    #if os(macOS)
    /// Retains the notification click-router (the `UNUserNotificationCenter` delegate is held weakly).
    @MainActor static var notificationRouter: PaneNotificationRouter?

    // The disable is a REGION, not a `:next`: `:next` between a doc comment and its declaration
    // orphans the doc comment, and from above the doc comment it silences a `///` line instead.
    // swiftlint:disable unused_declaration
    /// QUIT-DRAIN (orphaned-session leak): the app delegate that parks ⌘Q behind a BOUNDED
    /// ``WorkspaceStore/quiesce()`` so in-flight pane teardowns (the bye/channelClose of a just-closed
    /// busy pane) reach the wire before the process dies — see ``SlopDeskAppTerminationDelegate``.
    /// The store is threaded via the delegate's static seam in `init()` (SwiftUI instantiates the
    /// adaptor delegate itself, so the property-wrapper instance is not reachable there).
    /// The property wrapper INSTALLS the delegate; the instance is unreachable by design (SwiftUI
    /// builds it), so there is nothing here to reference.
    @NSApplicationDelegateAdaptor(SlopDeskAppTerminationDelegate.self) private var terminationDelegate
    // swiftlint:enable unused_declaration
    #endif

    /// THE COMPOSITION ROOT — the store, the connection, the preferences, the overlay coordinator, the
    /// Folders frecency, the Agents card model and the chrome flags, built and wired once in
    /// ``ClientComposition`` (docs/56 §2). None of that wiring draws, so none of it lives here: the two UI
    /// targets each hold a scene like this one and share exactly one definition of what the app IS.
    ///
    /// The `store` / `connection` / … accessors below read straight through, so a body that touches an
    /// `@Observable` field of one of them still registers its dependency normally.
    @State private var app: ClientComposition
    #if os(macOS)
    @State private var clipboardMonitor: ClipboardMonitor
    /// Bidirectional clipboard sync with the host (copy here → paste there, and back) over the
    /// metadata RPC. macOS-only, like the monitor; its push/pull seams resolve the first connected
    /// pane's ``MetadataClient`` lazily at call time (panes churn, the engine outlives them).
    @State private var clipboardSync: ClipboardSyncEngine
    /// The macOS Dock progress/error-tint controller (`NSApp.dockTile`). macOS-only — there is no
    /// iOS Dock. Fed the store's resolved ``WorkspaceStore/dockTileModel`` on each progress/completion edge;
    /// the Dock bounce rides ``CommandCompletionNotifier/bounceDock``.
    @State private var dockProgress: DockProgressController
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
    /// The host-windows feed: the `@Observable` store behind Open Quickly's host-window rows. (The
    /// RIGHT rail it was also built for was retired with the host-windows rail in `6a015eab` — the
    /// feed outlived it, see the `init` note.)
    /// App-owned so its renewal loop outlives column mounts; the loop itself runs in a scene `.task`
    /// and self-gates on chrome/OQ/connection.
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
    /// Whether the first-launch sheet is up — set true once at launch when ``FirstLaunchModel/shouldPresent``.
    @State private var presentFirstLaunch = false

    // MARK: The composition's parts, read straight through

    /// The ONE workspace store (docs/22 §7).
    private var store: WorkspaceStore { app.store }
    /// The ONE app-global connection.
    private var connection: AppConnection { app.connection }
    /// The ONE live settings store, handed to deep views via `\.preferencesStore`.
    private var preferences: PreferencesStore { app.preferences }
    /// The single overlay coordinator — palette (⌘⇧P), cheat sheet (⌘/), Open Quickly, Global Search,
    /// Peek & Reply, the toast stack and the modals.
    private var overlayCoordinator: OverlayCoordinator { app.overlay }
    /// The Agents settings-card model, read by the `Settings` scene and the iOS settings sheet.
    private var agentHooks: AgentHooksController { app.agentHooks }
    /// The chrome flags (sidebar collapse + window PIN) the toolbar / menu / palette drive — ONE
    /// `NSWindow.level` source of truth, never `NSApplication.windows`.
    private var chrome: WorkspaceChromeState { app.chrome }
    /// The PURE first-launch gating model (which steps for this platform, present-once).
    private var firstLaunchModel: FirstLaunchModel { app.firstLaunch }

    public init() {
        // Promote `SLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        ClientComposition.applyLaunchArgumentEnvironment()

        // Pin the whole app to the LIGHT appearance — the ground is cream, so semantic chrome ink
        // must resolve light or the navigator draws white-on-cream under an OS in dark mode. Armed
        // here and re-fired at didFinishLaunching, because `NSApp` does not exist yet inside
        // `App.init`.
        SlateAppearancePin.install()
        // The terminal CELLS adopt the app palette's flat colours: this hook hands the libghostty
        // 6-hex background/foreground plus the 16-entry ANSI palette + selection colour to
        // `PreferencesStore` when it (re)builds the terminal config. `WorkspaceCore` owns the
        // `AppearanceApplier` seam but cannot import this SwiftUI layer, so the closure lives here.
        AppearanceApplier.resolveTerminalColors = {
            let theme = SlateTheme.app
            return ResolvedTerminalTheme(
                background: theme.terminalBackgroundHex,
                foreground: theme.terminalForegroundHex,
                palette: theme.ansiPalette,
                selectionBackground: theme.selectionBackgroundHex,
            )
        }

        // The composition root: the store, the connection, the preferences, the overlays, the Folders
        // frecency, the Agents card and the chrome flags — everything the app IS, built and wired once
        // in `SlopDeskClientCore` (docs/56 §2) so the AppKit and SwiftUI halves can never grow two
        // copies of it. The device class resolves the concurrent live-video ceiling; asking the
        // platform what it is running on is a UI-layer question, so it is answered here and passed in.
        #if os(macOS)
        let deviceClass = VideoDeviceClass.mac
        #elseif os(iOS)
        let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? VideoDeviceClass.pad : .phone
        #else
        let deviceClass = VideoDeviceClass.phone
        #endif
        let app = ClientComposition(deviceClass: deviceClass)
        _app = State(initialValue: app)

        #if os(macOS)
        let store = app.store
        let overlay = app.overlay

        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router

        // The macOS Dock progress/error-tint controller. The Dock bounce is driven from the notifier
        // (a DELIVERED banner, NOT the bell): the "Bounce Dock Icon" toggle gates it HERE at the
        // actuation seam so the pure `CommandCompletionNotifier` stays toggle-agnostic. Returning to the
        // app while the Dock is red jumps to the next failing tab + clears the tint (the closest-faithful
        // stand-in for the dock-click hook SwiftUI owns — see docs/DECISIONS.md).
        let dockProgress = DockProgressController()
        explicitNotifier.bounceDock = { [weak dockProgress] in
            guard SettingsKey.bounceDockIconEnabled else { return }
            dockProgress?.bounce()
        }
        dockProgress.onActivatedWhileErrored = { [weak store] in store?.revealNextErrorPane() }
        _dockProgress = State(initialValue: dockProgress)

        // The three OS-notification sinks the composition leaves open. iOS installs NONE of them —
        // which is the honest statement that the in-app toast is its only notification surface. The
        // toast half of each fan-out already fired inside the composition, on both platforms.
        app.backgroundNoticeSink = { notice in
            explicitNotifier.notifyExplicit(
                event: notice.event,
                paneIDKey: notice.paneIDKey, paneTitle: notice.paneTitle,
                title: notice.title, body: notice.body,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }
        // Notify on Finish (clean exit, default OFF) / Notify on Error Exit (non-zero, default ON) +
        // the Notify-While-Foreground gate — the duration threshold is the notifier's own.
        app.longCommandSink = { notice in
            explicitNotifier.notifyIfLong(
                paneTitle: notice.paneTitle, exitCode: notice.exitCode, durationMS: notice.durationMS,
                paneIDKey: notice.paneIDKey,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }
        app.agentAttentionSink = { notice in
            // The herdr-style sound cues (Submarine on a finish, Glass on awaiting-input), gated by the
            // pure ``AgentSoundPolicy`` — which does NOT gate on focus: the TOAST is suppressed for a
            // focused pane (a card over the event you are watching is spam), but the cue still rings,
            // because a focused pane is routinely one in a background window or on another display.
            // System sounds via `NSSound(named:)` — nothing bundled.
            if let sound = AgentSoundPolicy.sound(
                needsInput: notice.needsInput,
                sourcePaneFocused: notice.sourcePaneFocused,
                soundTaskComplete: Defaults[.agentSoundTaskComplete],
                soundAwaitInput: Defaults[.agentSoundAwaitInput],
            ) {
                NSSound(named: sound.rawValue)?.play()
            }
            // Agent edges (reusing AttentionSupervision) ride their OWN per-event toggles —
            // awaiting-input vs task-complete — NOT the shell-app master switch, then the
            // Notify-While-Foreground gate.
            explicitNotifier.notifyExplicit(
                event: notice.needsInput ? .agentAwaitInput : .agentTaskComplete,
                paneIDKey: notice.paneIDKey, paneTitle: notice.name,
                title: notice.name, body: notice.body,
                appActive: notice.appActive, sourcePaneVisible: notice.sourcePaneVisible,
                settings: SettingsKey.notificationSettings,
            )
        }

        // Host-windows FEED: Open Quickly's host-window rows. Its renewal loop (a scene `.task` below)
        // gates on OQ visibility + connection — no OQ up costs the host exactly 0 Hz. The connection is
        // weak, like the coordinator's own `connectionTarget`.
        _hostWindowFeed = State(initialValue: HostWindowFeed(
            isActive: { overlay.openQuicklyVisible },
            isConnected: { [weak app] in app?.connection.status == .connected },
            target: { [weak app] in app?.connection.target ?? .default },
        ))
        // QUIT-DRAIN: hand the termination delegate the single live store (weak — the composition owns
        // it) so `applicationShouldTerminate` can drain the in-flight pane teardowns via `quiesce()`
        // before the process dies. Set here, before any window exists, so the seam is live for the very
        // first ⌘Q.
        SlopDeskAppTerminationDelegate.store = store
        // Held in a local so the keybinding dispatcher's `isWorkspaceWindowKey` closure below captures
        // the SAME `WeakWindowBox` the `.introspect(.window)` hook fills.
        let windowBox = WeakWindowBox()
        _windowBox = State(initialValue: windowBox)
        _clipboardMonitor = State(initialValue: ClipboardMonitor(store: store))
        // CLIPBOARD SYNC: copy on this Mac → the HOST pasteboard mirrors it within a tick (so Claude
        // Code's Ctrl+V image paste and a plain ⌘V in a remote-desktop pane just work), and a host-side
        // copy flows back. Routed through whichever pane carries a live channel — the same
        // resolve-at-call-time idiom as the Agents card / hostInfo fetcher.
        _clipboardSync = State(initialValue: ClipboardSyncEngine(
            push: { [weak store] clip in
                guard let store, let client = store.firstConnectedMetadataClient else { return false }
                return await client.setClipboard(clip)
            },
            pull: { [weak store] lastSeen in
                guard let store, let client = store.firstConnectedMetadataClient else { return nil }
                return await client.readClipboard(lastSeenChangeCount: lastSeen)
            },
        ))
        // Build the live keybinding dispatcher over the single store. A new-pane action (split /
        // new-tab / new-session) mints a terminal pane directly via the store's routing, focused, so the
        // user picks Terminal / Remote window INSIDE the new pane; ⌘T stays a direct-terminal escape
        // hatch (it routes via `.newPane(.terminal)`, never `.newTab`).
        //
        // The dispatcher's `textBinding`/`unbind` resolution is LIVE here regardless of the overlay
        // layer — a user `text:`/`csi:`/`esc:` config binding injects via `sendBytes` and an `unbind:`
        // passes through, both resolved from `WorkspaceBindingRegistry.activeOverrides`. The palette
        // (⌘⇧P) + cheat-sheet (⌘/) toggles thread into THIS monitor so the overlay layer is driven by
        // the SAME single chord owner (never a competing `.keyboardShortcut`). `toggleFind` stays nil —
        // its `route` arm falls back to the tree-path `requestFindInActivePane()`.
        _keyDispatcher = State(initialValue: WorkspaceKeyDispatcher(
            store: store,
            togglePalette: { [overlay] in overlay.togglePalette() },
            toggleCheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            // ⌘⌥J opens the Peek & Reply card over the oldest pane needing attention through the SAME
            // NSEvent monitor that owns every chord. The coordinator's `togglePeekReply()` HONESTLY
            // no-ops when nothing needs attention (so the chord does nothing rather than flashing an
            // empty card). ⌘⇧J stays the Hint-to-Open chord (not repurposed for peek-reply).
            togglePeekReply: { [overlay] in overlay.togglePeekReply() },
            toggleGlobalSearch: { [overlay] in overlay.toggleGlobalSearch() },
            // ⌘J opens the folded-in Jump-To — the Open-Quickly picker at the `.current` pill.
            toggleJumpTo: { [overlay] in overlay.toggleOpenQuickly(filter: .current) },
            // ⌘⇧O opens the picker at the merged `.all` pill. ⌘⇧O + ⌘J are the ONLY GLOBAL Open-Quickly
            // chords; the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL (handled by
            // `OpenQuicklyView.onKeyPress`, never registered in `WorkspaceBindingRegistry`).
            toggleOpenQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            // While the Open-Quickly picker is presented the dispatcher yields the whole keyboard to it
            // like a modal sheet. Without this the app monitor — which PREEMPTS the responder chain —
            // resolves the GLOBAL chord behind the picker, so ⌘1–9 switched the background tab (not
            // quick-pick) and ⌘W destroyed the focused pane. The Peek & Reply card YIELDS the same way.
            isOverlayCapturingKeys: { [overlay] in overlay.capturesKeyboardWhileVisible },
            // Gate the app-wide NSEvent monitor on the WORKSPACE window being key, so the stock Settings
            // scene (⌘,) + attached sheets receive their own keystrokes instead of a bound chord
            // (⌘W/⌘T/⌘1–9/…) resolving against the hidden workspace tree behind them. The predicate is a
            // pure IDENTITY check against `NSApp.keyWindow` (`workspaceWindowIsKey`), so a nil capture
            // NEVER claims the keyboard.
            isWorkspaceWindowKey: { [windowBox] in
                Self.workspaceWindowIsKey(captured: windowBox.window, keyWindow: NSApp.keyWindow)
            },
        ))
        // Diagnostics tap for the keyboard-focus saga — inert unless SLOPDESK_FOCUS_DEBUG=1.
        FocusDebugProbe.installIfRequested()
        // The code panel's warm-swap focus restore needs the workspace's ACTIVE TAB (the pool cannot see
        // the store) — same late-wiring idiom as the dispatcher's closures above.
        CodeSidebarWebViewPool.activeTabID = { [store] in store.tree.activeSession?.activeTab?.id }
        // The client control socket server over a ``WorkspaceControlBackend`` adapter on the SAME live
        // stores the GUI uses (the backend holds them WEAKLY — the composition retains the originals).
        // Built here so it outlives the scene; BOUND in a launch `.task` (the bind/listen is deferred).
        _clientControlServer = State(initialValue: ClientControlServer(
            backend: WorkspaceControlBackend(
                store: store, preferences: app.preferences, folders: app.folders,
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
            // ⌘⇧R (Toggle Code Panel — the right sidebar's embedded VS Code) rides the same late-wiring.
            installCodeSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleCodeSidebar(toggle) },
            installFocusCodePanel: { [keyDispatcher] focus in keyDispatcher.setFocusCodePanel(focus) },
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
                }
                .task {
                    presentFirstLaunch = FirstLaunchModel.shouldPresent(
                        hasCompleted: SettingsKey.hasCompletedFirstLaunchEnabled,
                        automationActive: app.isAutomation,
                    )
                }
                // The chrome follows the OS appearance (semantic tokens resolve per-appearance at draw
                // time — user-directed 2026-08-07), so NO colour scheme is forced anywhere. Where the
                // BRAND accent is a deliberate signal (active tab, focus corner), the view says
                // `Slate.State.accent` itself.
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
            #if os(macOS)
                .task {
                    guard !app.isAutomation else { return }
                    await clipboardMonitor.run()
                }
                // Clipboard-sync poll loop (push local copies to the host, pull host copies back).
                // Skipped under automation like the monitor: an E2E run must not mirror the
                // developer's real pasteboard onto the test host (or vice versa).
                .task {
                    guard !app.isAutomation else { return }
                    await clipboardSync.run()
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
                // AUTOMATION ONLY (env-gated): auto-connect so an autoconnect launch goes live without a
                // manual click. A normal launch silently re-connects the saved host (see the
                // auto-reconnect task) or, on a fresh install, waits for the user to open the
                // Connect-to-Host editor (the top-bar status pill / "Connect to Host…" palette action).
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
                // AUTO-RECONNECT (Goal B): normal launch silently re-connects to the MRU host. No-op under
                // any AUTOCONNECT env (automation keeps precedence); SLOPDESK_SKIP_AUTO_RECONNECT=1 off.
                .task {
                    guard !app.isAutomation else { return }
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
                    // Bring the traffic lights DOWN onto the band's top line, where the island's top
                    // edge and every other control in the band start (see helper).
                    Self.lowerTrafficLightsToTheTopLine(on: window)
                }
                // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination.
                // (Fires AFTER ``SlopDeskAppTerminationDelegate`` has drained the in-flight pane
                // teardowns and replied — termination proceeds only then — so this stays the LAST-word
                // save; the delegate also saves up front in case the drain window is interrupted.)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                    // `.remember` window-size: capture the final frame at quit — the end-of-gesture
                    // observers (`applyRememberedFrame`) cover resize/move, but a plain ⌘Q after a
                    // zoom (no live-resize gesture) would otherwise miss the last frame. Automation
                    // quits never save (they run at the odiff reference geometry, not the user's).
                    if SettingsKey.windowSize == .remember, !app.isAutomation,
                       let window = windowBox.window
                    {
                        SettingsKey.savedWindowFrame = window.frameDescriptor
                    }
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
        // `.remember` seeds the CREATION geometry from the saved frame so the window never paints a
        // wrong-size first frame (the introspect `setFrame(from:)` fires post-first-paint — alone it
        // restores correctly but with a visible default-size flash). Fallback = the odiff reference
        // geometry (1280×800, fresh install / other modes / automation) so a fresh window still
        // matches the reference.
        .defaultSize(
            width: Self.rememberedFrameSeed?.frame.width ?? 1280,
            height: Self.rememberedFrameSeed?.frame.height ?? 800,
        )
        .defaultPosition(Self.rememberedFrameSeed.map { seed in
            let unit = WindowSizeMath.unitPosition(frame: seed.frame, screen: seed.screen)
            return UnitPoint(x: unit.x, y: unit.y)
        } ?? .center)
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
                // The View ▸ Toggle Code Panel row flips the SAME live `chrome.codeSidebarCollapsed`
                // the ⌘⇧R chord + the palette row drive — directly off the app-owned chrome.
                toggleCodeSidebar: { [chrome] in chrome.toggleCodeSidebar() },
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
        SlopDeskSettingsScene(store: preferences, agentHooks: agentHooks, workspace: store)
        #endif
    }

    #if os(macOS)
    /// Wraps a satellite window's SwiftUI root with the scene-level environment. An `NSHostingView`
    /// root inherits NOTHING from the main scene (the known hosting-root env trap), so the injected
    /// stores must be re-applied here or the satellite's deep views resolve nil coordinators. No
    /// colour scheme is forced — the chrome follows the OS appearance like every other window.
    private func decorateSatelliteRoot(_ root: AnyView) -> AnyView {
        AnyView(
            root
                .preferencesStore(preferences)
                .agentHooksController(agentHooks)
                .overlayCoordinator(overlayCoordinator),
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
        guard ClientComposition.hasAutomationEnvironment(),
              objc_getAssociatedObject(window, &windowActivatedKey) == nil else { return }
        objc_setAssociatedObject(window, &windowActivatedKey, true, .OBJC_ASSOCIATION_RETAIN)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Declare a taller system titlebar so AppKit itself parks the three window controls on the
    /// band's TOP LINE (``Slate/Metric/bandInset``) instead of at its own default 8pt corner inset,
    /// which left them a full grid step above the island's top edge and everything else in the band
    /// (user-directed 2026-08-09). MEASURED on the running app: `.unifiedCompact` yields a 40pt
    /// `AXToolbar` and lands the discs 13 from the top, 12 from the leading edge — one point under
    /// the line, which on a 16pt disc is nothing, and the ONLY tool the system offers is this
    /// height (the inset is not settable).
    ///
    /// ⚠️ THIS DOES NOT MOVE THE BUTTONS, AND THAT IS THE WHOLE POINT. The first cut nudged their
    /// frames directly and it FLICKERED: AppKit rebuilds the titlebar whenever `NSWindow.title`
    /// changes, which resets the cluster to the corner, and the correction then landed a frame later
    /// as a visible jump. The window title tracks the focused pane's cwd folder name, so switching
    /// panes inside one project usually kept the same string and looked clean while crossing to
    /// another project re-titled the window and jumped — the symptom read as a pane-switch bug and
    /// was a title-change bug. Owning the HEIGHT instead of the POSITION makes the placement
    /// AppKit's own layout, so every rebuild re-derives it and there is nothing left to correct.
    ///
    /// The toolbar is EMPTY and has no delegate — it is a height declaration, not a toolbar. With no
    /// items and customization off, AppKit adds no "Show Toolbar" / "Customize Toolbar…" to the View
    /// menu (checked: it still reads Show Tab Bar / Show All Tabs / Enter Full Screen), and the
    /// window's own `titlebarAppearsTransparent` keeps it from painting anything.
    @MainActor
    private static func lowerTrafficLightsToTheTopLine(on window: NSWindow) {
        // The introspect hook re-fires on every scene re-render; this must stay idempotent.
        guard window.toolbar == nil else { return }
        window.toolbar = NSToolbar(identifier: "SlopDeskBandHeight")
        window.toolbarStyle = .unifiedCompact
    }

    /// Apply the configured initial window size at most once per window open (guarded by an
    /// associated object, mirroring the close-gate retain idiom), so a later manual resize always stands:
    ///   * ``WindowSizeMode/remember`` → restore the app-persisted frame descriptor + install the
    ///     save-on-change observers (``applyRememberedFrame(to:)``) and commit;
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
    ///
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
            // Automation launches keep the deterministic odiff geometry: no restore, and no
            // observers — an automation run must never overwrite the user's saved frame either.
            if !ClientComposition.hasAutomationEnvironment() { applyRememberedFrame(to: window) }
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

    /// The scene-creation seed for ``WindowSizeMode/remember`` — the parsed saved frame, or `nil`
    /// (other modes / nothing saved / malformed descriptor / automation). Consumed by the scene's
    /// `.defaultSize` / `.defaultPosition` so the window is CREATED at the remembered geometry and the
    /// first paint is already right; ``applyRememberedFrame(to:)`` then reconciles exactly via
    /// `setFrame(from:)` (screen topology changes — `defaultPosition` is proportional, not absolute).
    /// Automation launches opt out (matching ``applyRememberedFrame(to:)``): the odiff reference
    /// geometry must stay the deterministic 1280×800.
    private static var rememberedFrameSeed: (frame: CGRect, screen: CGRect)? {
        guard SettingsKey.windowSize == .remember, !ClientComposition.hasAutomationEnvironment() else { return nil }
        return WindowSizeMath.parseFrameDescriptor(SettingsKey.savedWindowFrame)
    }

    /// Associated-object key retaining the `.remember`-mode frame-save subscription — tied to the
    /// window so the observer lives exactly as long as it does. Address-only key, `nonisolated(unsafe)`
    /// like ``windowCloseDelegateKey``.
    private nonisolated(unsafe) static var frameSaveObserversKey: UInt8 = 0

    /// ``WindowSizeMode/remember``: restore the frame persisted under the app's OWN Defaults key
    /// (``SettingsKey/savedWindowFrame``) and install the save-on-change observers.
    /// `setFrameAutosaveName` is deliberately NOT used — SwiftUI asserts its own type-derived autosave
    /// name on the scene window (containing a per-launch `(unknown context at $…)` address), so AppKit's
    /// autosave machinery saves under a key that changes every launch and can never restore. Both halves
    /// are owned here instead: `NSWindow.frameDescriptor` (screen-aware) is written at end-of-gesture
    /// granularity (`didEndLiveResize` / `didMove` — not per-tick `didResize`) plus the scene's
    /// `willTerminateNotification` save, and re-applied via `setFrame(from:)` — which itself constrains
    /// an off-screen / stale-display frame back onto a live screen — on the next window open.
    @MainActor
    private static func applyRememberedFrame(to window: NSWindow) {
        let saved = SettingsKey.savedWindowFrame
        if !saved.isEmpty { window.setFrame(from: saved) }
        // Combine publishers (not block-based `addObserver`) — both notifications post on the main
        // thread, so the MainActor-formed sink closure needs no Sendable dance to read the window.
        let cancellable = NotificationCenter.default
            .publisher(for: NSWindow.didEndLiveResizeNotification, object: window)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: window))
            .sink { [weak window] _ in
                guard let window else { return }
                SettingsKey.savedWindowFrame = window.frameDescriptor
            }
        objc_setAssociatedObject(window, &frameSaveObserversKey, cancellable, .OBJC_ASSOCIATION_RETAIN)
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
