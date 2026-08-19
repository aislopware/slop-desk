// SlopDeskMacApp — the macOS app SCENE: one workspace window, the stock Settings scene, and the
// AppKit obligations that hang off them.
//
// It is the macOS half of what used to be `SlopDeskClientApp`, a single scene serving two products
// through seventeen `#if os(...)` branches. There is not one platform gate left in this file, because
// the file is the platform (docs/56 §3).
//
// WHAT THE APP IS lives in ``ClientComposition`` (`SlopDeskClientCore`): the store, the connection, the
// preferences, the overlay coordinator, the Folders frecency, the Agents card, the chrome flags and
// every seam between them. This scene holds one of those and adds what only a Mac has:
//
//   * the three OS-notification sinks the composition leaves open — the `UNUserNotification` banner
//     for a background pane event, the one for a finished long command, and the agent edge's
//     `NSSound` cue plus banner;
//   * the Dock tile (progress, error tint, bounce) and the quit drain behind ⌘Q;
//   * ONE `NSEvent` `.keyDown` monitor (``WorkspaceKeyDispatcher``) that owns every chord, including
//     the multi-key prefix a `.commands` menu item cannot express;
//   * the workspace `NSWindow` itself — its close gate, its remembered/grid geometry, its traffic
//     lights, and the satellite windows a detached pane opens;
//   * the client control socket the `slopdesk` CLI drives this running GUI through;
//   * the clipboard monitor + host sync, and the discoverability-only menu bar.

import AppKit
import Combine // AnyCancellable — the `.remember` frame-save observers, retained on the window
import Defaults // fire-time reads of the Code Agent sound toggles in the attention sink
import ObjectiveC // objc_setAssociatedObject — retain the window-close delegate for the window's life
import SlopDeskClientCore
import SlopDeskClientUI // the SwiftUI mounts stage D has not lifted yet
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskTerminal // TerminalCellMetrics + TerminalViewportSnapshotting (live cell advance)
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import SwiftUIIntrospect // reach THIS scene's NSWindow from the WindowGroup (no NSApplication.windows hack)
import UserNotifications // explicit OSC 9/777 child notifications → local UNUserNotification

public struct SlopDeskMacApp: App {
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

    /// THE COMPOSITION ROOT — what the app IS, built and wired once in `SlopDeskClientCore` so this
    /// shell and the phone's can never grow two copies of it (docs/56 §2).
    @State private var app: ClientComposition
    @State private var clipboardMonitor: ClipboardMonitor
    /// Bidirectional clipboard sync with the host (copy here → paste there, and back) over the
    /// metadata RPC; its push/pull seams resolve the first connected pane's ``MetadataClient`` lazily at
    /// call time (panes churn, the engine outlives them).
    @State private var clipboardSync: ClipboardSyncEngine
    /// The Dock progress/error-tint controller (`NSApp.dockTile`). Fed the store's resolved
    /// ``WorkspaceStore/dockTileModel`` on each progress/completion edge; the bounce rides
    /// ``CommandCompletionNotifier/bounceDock``.
    @State private var dockProgress: DockProgressController
    /// The live keybinding dispatcher. ONE app-level `NSEvent` `.keyDown` local monitor (the re-scope of
    /// DECISIONS.md's "no NSEvent monitor" rule — a multi-key prefix can't be a `.commands` menu item and
    /// the menu can't swallow a sequence's follow-up before the terminal first responder). Installed once
    /// at launch in a scene `.task`.
    @State private var keyDispatcher: WorkspaceKeyDispatcher
    /// The CLIENT-side control socket server (`AF_UNIX` NDJSON), the runtime surface the `slopdesk` CLI
    /// drives the running GUI through (windows/tabs/panes, jump/config/theme/keybind, pane capture/
    /// send-keys, agent status). Built once here over a ``WorkspaceControlBackend`` adapter and bound in a
    /// launch `.task`; compiled-only + never unit-tested (hang-safety, mirroring the host's
    /// `AgentControlListener`).
    @State private var clientControlServer: ClientControlServer
    /// The host-windows feed behind Open Quickly's host-window rows. App-owned so its renewal loop
    /// outlives column mounts; the loop runs in a scene `.task` and self-gates on OQ/connection.
    @State private var hostWindowFeed: HostWindowFeed
    /// A WEAK handle to THIS scene's `NSWindow`, captured in the blessed `.introspect(.window)` closure
    /// so the ⌘⇧W / menu / palette `performClose` actuators reach the live window WITHOUT the forbidden
    /// `NSApplication.windows` scan. A plain holder, not `@Observable` — mutating it must not re-render.
    @State private var windowBox: WeakWindowBox
    /// The detach-pane satellite windows (one plain-AppKit `NSWindowController` per
    /// ``WorkspaceStore/detachedPanes`` entry) — never a second `WindowGroup`, so the single-window
    /// machinery (`windowBox` / chord dispatcher / close gate) is untouched.
    @State private var satelliteWindows = SatelliteWindowsCoordinator()
    /// The summoned cards that are WINDOWS of their own (docs/56 stage D) — one `NSPanel` over the
    /// workspace window per overlay the Mac has taken out of the shared SwiftUI host.
    @State private var overlayPanels = MacOverlayPanels()
    /// The cross-container pane-drag rendezvous: the sidebar rows, the canvas, and every satellite window
    /// live in SEPARATE hosting views, so the free pane drag (move across tabs / break to a new tab / tear
    /// off to a window / merge back) meets here. Its `store` weak ref is bound in a launch `.task`.
    /// The chip — the card that follows the cursor — is INJECTED rather than owned, because it is an
    /// `NSHostingView` over a SwiftUI card and the coordinator is a floor below it. `chip:` defaults to
    /// `nil`, so a caller that forgets this compiles and silently draws no chip; this is the one caller.
    @State private var paneDrag = PaneDragCoordinator(chip: PaneDragChipPanel())
    /// The Settings WINDOW (docs/56 stage D). Not a `Settings` scene: that scene is a SwiftUI construct
    /// that supplies its own ⌘, item, and the page it hosted is now drawn in AppKit from the layout
    /// table. Built once at launch, opened on demand, and it holds its own window.
    @State private var settingsWindow: MacSettingsWindowController
    @Environment(\.scenePhase) private var scenePhase
    /// The guided first-launch checklist, as a real sheet on the workspace window. Held here rather
    /// than presented by a `.sheet` modifier so the checklist is an AppKit sheet like every other
    /// summoned surface the Mac shell has taken (docs/56 stage D).
    @State private var firstLaunchSheet: MacFirstLaunchSheet

    // MARK: The composition's parts, read straight through

    private var store: WorkspaceStore { app.store }
    private var connection: AppConnection { app.connection }
    private var preferences: PreferencesStore { app.preferences }
    private var overlayCoordinator: OverlayCoordinator { app.overlay }
    private var agentHooks: AgentHooksController { app.agentHooks }
    private var chrome: WorkspaceChromeState { app.chrome }

    public init() {
        // Promote `SLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        ClientComposition.applyLaunchArgumentEnvironment()

        // Pin the whole app to the LIGHT appearance — the ground is cream, so semantic chrome ink must
        // resolve light or the navigator draws white-on-cream under an OS in dark mode. Armed here and
        // re-fired at didFinishLaunching, because `NSApp` does not exist yet inside `App.init`.
        SlateAppearancePin.install()
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

        let app = ClientComposition(deviceClass: .mac)
        _app = State(initialValue: app)
        let store = app.store
        let overlay = app.overlay

        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        Self.notificationRouter = router

        // The Dock progress/error-tint controller. The bounce is driven from the notifier (a DELIVERED
        // banner, NOT the bell): the "Bounce Dock Icon" toggle gates it HERE at the actuation seam so the
        // pure `CommandCompletionNotifier` stays toggle-agnostic. Returning to the app while the Dock is
        // red jumps to the next failing tab + clears the tint (the closest-faithful stand-in for the
        // dock-click hook SwiftUI owns — see docs/DECISIONS.md).
        let dockProgress = DockProgressController()
        explicitNotifier.bounceDock = { [weak dockProgress] in
            guard SettingsKey.bounceDockIconEnabled else { return }
            dockProgress?.bounce()
        }
        dockProgress.onActivatedWhileErrored = { [weak store] in store?.revealNextErrorPane() }
        _dockProgress = State(initialValue: dockProgress)

        // The three OS-notification sinks the composition leaves open. The phone installs NONE of them —
        // which is the honest statement that the in-app toast is its only notification surface. The toast
        // half of each fan-out already fired inside the composition, on both platforms.
        app.backgroundNoticeSink = { notice in
            explicitNotifier.notifyExplicit(
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
        // gates on OQ visibility + connection — no OQ up costs the host exactly 0 Hz.
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
        // Held in a local so the dispatcher's `isWorkspaceWindowKey` closure below captures the SAME
        // `WeakWindowBox` the `.introspect(.window)` hook fills.
        let windowBox = WeakWindowBox()
        _windowBox = State(initialValue: windowBox)
        _firstLaunchSheet = State(initialValue: MacFirstLaunchSheet(
            model: app.firstLaunch, agentHooks: app.agentHooks,
        ))
        // The Settings window controller, built with the SAME single live store the workspace binds —
        // one `PreferencesStore`, one window, raised rather than re-made on the second ⌘,.
        _settingsWindow = State(initialValue: MacSettingsWindowController(
            store: app.preferences, agentHooks: app.agentHooks, workspace: store,
        ))
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
        // Build the live keybinding dispatcher over the single store. A new-pane action (split / new-tab
        // / new-session) mints a terminal pane directly via the store's routing, focused, so the user
        // picks Terminal / Remote window INSIDE the new pane; ⌘T stays a direct-terminal escape hatch
        // (it routes via `.newPane(.terminal)`, never `.newTab`).
        //
        // The dispatcher's `textBinding`/`unbind` resolution is LIVE here regardless of the overlay
        // layer — a user `text:`/`csi:`/`esc:` config binding injects via `sendBytes` and an `unbind:`
        // passes through, both resolved from `WorkspaceBindingRegistry.activeOverrides`. The palette
        // (⌘⇧P) + cheat-sheet (⌘/) toggles thread into THIS monitor so the overlay layer is driven by the
        // SAME single chord owner (never a competing `.keyboardShortcut`). `toggleFind` stays nil — its
        // `route` arm falls back to the tree-path `requestFindInActivePane()`.
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
    }

    /// The root IDE shell, handed the installers that wire ⌘⇧L (Toggle Tabs Panel), ⌘⇧R (Toggle Code
    /// Panel), ⌥⌘R (focus the code panel) and the chord-less Pin Window action to the view's live state
    /// ON the app-level `keyDispatcher`, so each routes through the SAME NSEvent monitor that owns every
    /// other chord (the legacy `store.sidebarCollapsed` is not read here).
    private var workspaceRootView: some View {
        MacWorkspaceRootView(
            store: store,
            connection: connection,
            overlay: overlayCoordinator,
            chrome: chrome,
            installSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleSidebar(toggle) },
            installCodeSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleCodeSidebar(toggle) },
            installFocusCodePanel: { [keyDispatcher] focus in keyDispatcher.setFocusCodePanel(focus) },
            // The (chord-less by default) Pin Window toggle, so a user-bound chord for `.pinWindow`
            // flips the SAME `chrome.pinned` the menu Button + the `NSWindow.level` glue read.
            installPinToggle: { [keyDispatcher] toggle in keyDispatcher.setTogglePinWindow(toggle) },
            paneDrag: paneDrag,
        )
        // Bind the coordinator's `openSettingsAction` to the SwiftUI `openSettings` environment action so
        // the palette "Open Settings" row + the agent footer hook open the stock Settings scene — without
        // this the row is a dead control, since nothing observes a `settingsVisible` flag.
        .modifier(SettingsOpenerInstaller(overlay: overlayCoordinator))
    }

    public var body: some Scene {
        WindowGroup {
            workspaceRootView
                // Hand the single live PreferencesStore to deep views (the agent footer's notification
                // dismissal/enable persistence reads it via `\.preferencesStore`).
                .preferencesStore(preferences)
                // The Agents install-hooks controller (the `Settings` scene injects it on its own side).
                .agentHooksController(agentHooks)
                // The single overlay coordinator, so deep views reach it via `\.overlayCoordinator`.
                .overlayCoordinator(overlayCoordinator)
                // The guided first-launch checklist — On-Launch / Default-Terminal / Install-CLI /
                // Install-Claude-hooks. Presents once on a fresh install (the `hasCompletedFirstLaunch`
                // Defaults flag) and never under automation (it would steal the autoconnect focus).
                // Dismissing by ANY path persists the flag (the sheet's completion handler).
                .task {
                    guard FirstLaunchModel.shouldPresent(
                        hasCompleted: SettingsKey.hasCompletedFirstLaunchEnabled,
                        automationActive: app.isAutomation,
                    ) else { return }
                    // A sheet needs the window it hangs from, and the window arrives when the
                    // `.introspect(.window)` hook fires — which is after this task starts. Yield until
                    // it lands, bounded, so a build where the hook never fires shows no checklist
                    // rather than spinning: the flag stays unset, so the next launch offers it again.
                    for _ in 0..<100 where windowBox.window == nil {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    guard let window = windowBox.window else { return }
                    firstLaunchSheet.present(over: window)
                }
                // The chrome follows the OS appearance (semantic tokens resolve per-appearance at draw
                // time — user-directed 2026-08-07), so NO colour scheme is forced anywhere.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.saveImmediately() }
                }
                .task {
                    guard !app.isAutomation else { return }
                    await clipboardMonitor.run()
                }
                // Clipboard-sync poll loop (push local copies to the host, pull host copies back).
                // Skipped under automation like the monitor: an E2E run must not mirror the developer's
                // real pasteboard onto the test host (or vice versa).
                .task {
                    guard !app.isAutomation else { return }
                    await clipboardSync.run()
                }
                // Install the keybinding dispatcher's `.keyDown` local monitor once the scene is up. It
                // runs under automation too (the keybinding path is part of what HW E2E drives); the
                // monitor swallows ONLY the prefix + armed follow-ups + bound chords and passes every
                // bare key through, so it never interferes with autoconnect typing.
                .task { keyDispatcher.install() }
                // Host-windows FEED renewal loop (docs/45). Self-gating: a collapsed rail with Open
                // Quickly hidden (or a disconnected app) idles with ZERO wire traffic.
                .task { await hostWindowFeed.run() }
                // Bind the client control socket so the `slopdesk` CLI can drive this running GUI. The
                // bind/listen is a couple of syscalls + a detached accept thread (the per-connection read
                // loops stay OFF the cooperative pool — hang-safety, mirroring the host ctl socket). A
                // bind failure (stale path the OS won't reclaim, etc.) is swallowed: the CLI control
                // plane is a convenience, never load-bearing, and must never crash the app.
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
                // Drive the Dock tile from the store's resolved aggregate. `dockTileModel` reads
                // `paneProgress` + `panePendingCompletion` (@Observable), so a progress/completion edge
                // re-renders here and re-applies the tile; a last-session-end edge resolves to `.inert` →
                // the controller CLEARS (no stuck red tile). The initial `.task` applies any restored
                // state once (onChange fires only on a change).
                .onChange(of: store.dockTileModel) { _, model in dockProgress.apply(model) }
                .task { dockProgress.apply(store.dockTileModel) }
                // AUTOMATION ONLY (env-gated): auto-connect so an autoconnect launch goes live without a
                // manual click. A normal launch silently re-connects the saved host (the auto-reconnect
                // task below) or, on a fresh install, waits for the user to open the Connect-to-Host
                // editor (the top-bar status pill / "Connect to Host…" palette action).
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
                // AUTO-RECONNECT (Goal B): a normal launch silently re-connects to the MRU host. No-op
                // under any AUTOCONNECT env (automation keeps precedence); SLOPDESK_SKIP_AUTO_RECONNECT=1
                // turns it off.
                .task {
                    guard !app.isAutomation else { return }
                    await connection.connectIfSavedTarget()
                }
                // AUTOMATION ONLY: bring the window to front + make it key at launch so the content
                // subtree appears and connect-on-appear fires WITHOUT a manual front/Open click. We reach
                // THIS scene's window via SwiftUIIntrospect rather than the fragile
                // `NSApplication.shared.windows.first` (wrong once a second window exists). The closure
                // fires exactly when the NSWindow is real, and `.introspect(.window)` is the sanctioned
                // hook for any WindowGroup-level config.
                .introspect(.window, on: .macOS(.v14, .v15, .v26)) { window in
                    // Install the window-close confirmation gate (independent of automation). The store
                    // owns the policy decision (`requestCloseWindow()` → `pendingWindowClose`); the
                    // delegate routes through `WindowCloseGate` and presents a synchronous confirmation
                    // so a parked close always resolves (the window is never stranded).
                    Self.installWindowCloseGate(on: window, store: store)
                    // Install the ⌘⇧W "Close Window" actuator on the SAME NSEvent monitor that owns every
                    // chord. It calls `performClose(nil)` on the captured window (via the weak
                    // `windowBox`), firing `windowShouldClose` → the gate just installed — so the chord
                    // ACTUATES a close instead of parking a flag nothing reads. Re-assigning on a re-fire
                    // is an idempotent closure swap (it always reads the latest `windowBox.window`).
                    keyDispatcher.setCloseWindow { [windowBox] in windowBox.window?.performClose(nil) }
                    // The palette "Close Window" row routes through the SAME `performClose(nil)` actuator
                    // → the close-confirmation gate, so it actuates a real close instead of the dead
                    // `requestCloseWindow()` park. Re-assigning on a re-fire is idempotent.
                    overlayCoordinator.closeWindow = { [windowBox] in windowBox.window?.performClose(nil) }
                    // Capture the window weakly for the ⌘⇧W / menu / palette `performClose` actuators,
                    // and apply the configured initial size EXACTLY ONCE per window open (so a later
                    // manual resize is never fought). All NSWindow reach stays inside THIS blessed hook.
                    // (The window PIN level is a native `.windowLevel(chrome.pinned…)` scene modifier.)
                    // This closure fires only for the window hosting the WORKSPACE root (the Settings
                    // scene never mounts this modifier), and File ▸ New Window is removed
                    // (`CommandGroup(replacing: .newItem)`), so exactly ONE window can ever land here.
                    windowBox.window = window
                    // Pass the LIVE chrome (for the grid `chromeOverhead` — the revealed sidebar) + the
                    // configured terminal font size (the font-derived fallback cell used only before the
                    // terminal surface lays out). The grid sizing DEFERS its once-per-open commit until
                    // real cell metrics exist, so it recomputes to the exact cols×rows.
                    Self.applyInitialWindowSize(
                        to: window, store: store, chrome: chrome,
                        fontPointSize: CGFloat(preferences.terminal.fontSize),
                    )
                    // AUTOMATION ONLY: bring the window to front + make it key ONCE per open (see helper).
                    Self.automationBringToFrontOnce(window)
                    // Bring the traffic lights DOWN onto the band's top line, where the island's top edge
                    // and every other control in the band start (see helper).
                    Self.lowerTrafficLightsToTheTopLine(on: window)
                }
                // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination.
                // (Fires AFTER ``SlopDeskAppTerminationDelegate`` has drained the in-flight pane
                // teardowns and replied — termination proceeds only then — so this stays the LAST-word
                // save; the delegate also saves up front in case the drain window is interrupted.)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.saveImmediately()
                    // `.remember` window-size: capture the final frame at quit — the end-of-gesture
                    // observers (`applyRememberedFrame`) cover resize/move, but a plain ⌘Q after a zoom
                    // (no live-resize gesture) would otherwise miss the last frame. Automation quits never
                    // save (they run at the odiff reference geometry, not the user's).
                    if SettingsKey.windowSize == .remember, !app.isAutomation,
                       let window = windowBox.window
                    {
                        SettingsKey.savedWindowFrame = window.frameDescriptor
                    }
                    // Reset the process-global Dock tile on teardown so a quit never leaves a stuck
                    // progress/red tile behind for the next app to inherit.
                    dockProgress.clear()
                }
                // `scenePhase` tracks WINDOW VISIBILITY here, not app activation — it stays `.active`
                // while the window sits visible-but-backgrounded behind another app, which would keep
                // `isAppActive` permanently true and silently suppress every command/error/agent UN
                // banner (default `notifyWhileForeground == .off`). Drive it from the real AppKit
                // activation signal instead — the same one DockProgressController /
                // SecureKeyboardEntryController already use.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.isAppActive = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    store.isAppActive = false
                }
                .task {
                    store.isAppActive = NSApplication.shared.isActive
                }
                // SATELLITE WINDOWS (Detach Pane into Window): diff one plain-AppKit window per detached
                // pane. Driven HERE off the `@Observable` detached list — the store stays headless; only
                // this app layer touches NSWindow. The launch restore re-docks satellites (v1: they don't
                // persist as windows), so the initial sync is normally a no-op — kept for the
                // automation/replay paths that could restore a mid-detach state.
                .onChange(of: store.detachedPanes) { _, panes in
                    satelliteWindows.sync(panes, store: store, paneDrag: paneDrag, decorate: decorateSatelliteRoot)
                }
                // THE ⌘/ CHEAT SHEET is the Mac's own AppKit panel (docs/56 stage D) — driven from
                // HERE for the same reason the satellites are: `windowBox` holds the one workspace
                // window, captured in the blessed `.introspect(.window)` closure, and a card is a
                // child window of it. The coordinator's flag stays the single truth; the panel
                // follows this edge, and every dismissal inside it flips the flag back rather than
                // tearing itself down.
                .onChange(of: overlayCoordinator.cheatSheetVisible) { _, visible in
                    overlayPanels.setCheatSheet(
                        visible, host: windowBox.window, store: store, coordinator: overlayCoordinator,
                    )
                }
                // THE ⌘⇧P PALETTE is the Mac's own AppKit panel (docs/56 stage D) — the first MODAL
                // surface across, and the one that settles the palette family's shape: a pre-focused
                // field, a ranked list steered THROUGH that field's editing commands, and a card that
                // measures itself against its own results. `toggledState` is built from the LIVE
                // chrome, so the ✓ gutter tracks real visibility and a ⌘↩ that keeps the card up flips
                // its own row.
                .onChange(of: overlayCoordinator.paletteVisible) { _, visible in
                    overlayPanels.setPalette(
                        visible, host: windowBox.window, store: store, coordinator: overlayCoordinator,
                        toggledState: PalettePresentation.toggledState(chrome: chrome, store: store),
                    )
                }
                // THE ⌘⌥J PEEK CARD is the Mac's own AppKit panel (docs/56 stage D) — the second
                // MODAL surface across, and the first whose CONTENT moves under it: a reply advances
                // the queue, and the card is re-cut for the next blocked pane without the panel ever
                // going away. It takes no `toggledState`-style injection because everything it shows
                // is the store's and the coordinator's already.
                .onChange(of: overlayCoordinator.peekReplyVisible) { _, visible in
                    overlayPanels.setPeekReply(
                        visible, host: windowBox.window, store: store, coordinator: overlayCoordinator,
                    )
                }
                // THE ⌘⇧O / ⌘J PICKER is the Mac's own AppKit panel (docs/56 stage D), and the LAST
                // card to move: with it gone, `OverlayHostView` draws no card on macOS at all.
                .onChange(of: overlayCoordinator.openQuicklyVisible) { _, visible in
                    overlayPanels.setOpenQuickly(
                        visible, host: windowBox.window, store: store, coordinator: overlayCoordinator,
                    )
                }
                // THE ⇧⌘F RESULTS PANEL is the Mac's own AppKit panel (docs/56 stage D). It is the
                // one of the three that is FIXED-SIZE: the query re-runs on every keystroke, and a
                // panel that resized with the match count would move under the pointer — which on
                // that surface is the selection itself.
                .onChange(of: overlayCoordinator.globalSearchVisible) { _, visible in
                    overlayPanels.setGlobalSearch(
                        visible, host: windowBox.window, store: store, coordinator: overlayCoordinator,
                    )
                }
                // CONNECT-TO-HOST is the Mac's own AppKit SHEET (docs/56 stage D) — the last surface
                // over the workspace to leave the shared SwiftUI floor, and the one that was never a
                // card: a form you fill in and commit is what the platform's own modal is for, so it
                // is a real `beginSheet` rather than a borderless panel. Same discipline as the cards
                // regardless — Cancel, Esc and a successful connect flip the coordinator's flag, and
                // this edge is what opens and closes the window.
                .onChange(of: overlayCoordinator.connectVisible) { _, visible in
                    overlayPanels.setConnect(
                        visible, host: windowBox.window, connection: connection,
                        coordinator: overlayCoordinator,
                    )
                }
                // THE CLOSE CONFIRMATION is the Mac's own `NSAlert` sheet (docs/56 stage D), and with
                // it the window root mounts no SwiftUI above the split at all. Driven off the store's
                // two parks rather than a flag — a park IS the state — and both buttons resolve the
                // park, so the store and the sheet cannot disagree. `initial: true` covers a launch
                // that restores straight into a parked close.
                .onChange(of: CloseConfirmationCopy.request(store: store), initial: true) { _, _ in
                    overlayPanels.syncCloseConfirmation(store: store, host: windowBox.window)
                }
                // THE NOTIFICATION CORNER is the Mac's own AppKit panel too (docs/56 stage D), and it
                // is what took the last ALWAYS-MOUNTED `NSHostingView` off the window root: the toast
                // host used to be a full-bleed SwiftUI layer over the whole workspace, toggling
                // `allowsHitTesting` so the split beneath stayed clickable. The panel is sized to the
                // column instead, so the only region that takes hits is the cards themselves. Driven
                // off the list rather than off a flag, because an ambient surface has no flag — its
                // content IS its state.
                .onChange(of: overlayCoordinator.toasts) { _, stack in
                    overlayPanels.syncToasts(
                        stack, host: windowBox.window, store: store, coordinator: overlayCoordinator,
                    )
                }
                // THE ⌃⇥ READOUT, the last ambient tenant of the shared host and now an `NSPanel` that
                // ignores the mouse outright. Driven off the store's gesture rather than a coordinator
                // flag, because the gesture IS the state — the dispatcher owns open/step/commit/cancel
                // and this only draws what it decided.
                .onChange(of: store.paneSwitcher) { _, gesture in
                    overlayPanels.syncPaneSwitcher(gesture, host: windowBox.window, store: store)
                }
                .task {
                    // Late-bind the drag coordinator's weak store (chip labels + destination gating) —
                    // `@State` objects cannot reference each other at property-init time.
                    paneDrag.store = store
                    satelliteWindows.sync(
                        store.detachedPanes, store: store, paneDrag: paneDrag, decorate: decorateSatelliteRoot,
                    )
                    // The store stays AppKit-free, so a reveal calls back into this coordinator through
                    // the injected seam instead of minting a second live stream.
                    store.revealSatelliteWindow = { paneID in satelliteWindows.reveal(paneID) }
                }
        }
        // The app has NO system unified toolbar: hide the titlebar (the window keeps traffic lights + a
        // full-size content view) so its own titlebar band (`MacTitlebarBand`) is the only chrome.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        // `.remember` seeds the CREATION geometry from the saved frame so the window never paints a
        // wrong-size first frame (the introspect `setFrame(from:)` fires post-first-paint — alone it
        // restores correctly but with a visible default-size flash). Fallback = the odiff reference
        // geometry (1280×800, fresh install / other modes / automation).
        .defaultSize(
            width: Self.rememberedFrameSeed?.frame.width ?? 1280,
            height: Self.rememberedFrameSeed?.frame.height ?? 800,
        )
        .defaultPosition(Self.rememberedFrameSeed.map { seed in
            let unit = WindowSizeMath.unitPosition(frame: seed.frame, screen: seed.screen)
            return UnitPoint(x: unit.x, y: unit.y)
        } ?? .center)
        // Pin Window (chord-less; menu/palette flips `chrome.pinned`) maps to the WINDOW LEVEL. Reading
        // the live `chrome.pinned` @Observable in the scene body re-applies this on every flip — a native
        // scene modifier rather than an `.introspect(.window)` pin-apply + `.onChange(of:)` actuator
        // reaching `NSWindow.level` directly. The single-window model (File ▸ New Window is removed)
        // means this group-wide level only ever touches the one workspace window.
        .windowLevel(chrome.pinned ? .floating : .normal)
        // The discoverability-only menu bar over the SAME binding registry the dispatcher reads. Each
        // item routes through `WorkspaceBindingRegistry.route` with NO `.keyboardShortcut` — the
        // `NSEvent` monitor (`keyDispatcher`) owns chord dispatch (incl. the multi-key prefix), so a menu
        // shortcut would double-fire / swallow a prefix tail. The palette + cheat-sheet toggles thread
        // through (capturing the SAME coordinator the NSEvent dispatcher drives) so the menu items toggle
        // the identical overlays — cheap parity.
        .commands {
            // The product is a documented SINGLE-workspace-window model (one WindowGroup window + the
            // stock Settings scene) — the whole app wiring (`store` / `keyDispatcher` / `windowBox` / the
            // close gate) is app-wide singleton state, so the stock File ▸ New Window item would mint a
            // SECOND workspace window over the SAME store whose introspect hook then overwrites
            // `windowBox`: chords would intermittently die in the window being typed in and the ⌃B prefix
            // would leak into remote-GUI panes. `.newItem` carries ONLY the New-Window item for a plain
            // WindowGroup (no document types are declared), so replacing it with nothing removes the
            // affordance without touching the rest of the File menu.
            CommandGroup(replacing: .newItem) {}
            // ⌘, is the one shortcut declared here rather than routed through the binding registry: it
            // is the app menu's, not the workspace's, and the `Settings` scene that used to supply it
            // went with the SwiftUI settings surface. `.appSettings` is the group AppKit reserves for
            // it, so the item lands where every Mac user looks for it.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { settingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            WorkspaceCommands(
                store: store,
                togglePalette: { [overlayCoordinator] in overlayCoordinator.togglePalette() },
                toggleCheatSheet: { [overlayCoordinator] in overlayCoordinator.toggleCheatSheet() },
                // The View ▸ Peek & Reply menu row opens the SAME overlay the ⌘⌥J chord drives (the menu
                // mirrors the chord; the NSEvent dispatcher owns the chord itself).
                togglePeekReply: { [overlayCoordinator] in overlayCoordinator.togglePeekReply() },
                // The View ▸ Toggle Code Panel row flips the SAME live `chrome.codeSidebarCollapsed` the
                // ⌘⇧R chord + the palette row drive — directly off the app-owned chrome.
                toggleCodeSidebar: { [chrome] in chrome.toggleCodeSidebar() },
                toggleGlobalSearch: { [overlayCoordinator] in overlayCoordinator.toggleGlobalSearch() },
                // The View ▸ Jump To… menu item opens the folded-in Jump-To (the Open-Quickly picker at
                // the `.current` pill), the SAME overlay the ⌘J chord drives.
                toggleJumpTo: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .current) },
                // The View ▸ Open Quickly… menu row opens the picker at the merged `.all` pill.
                openQuickly: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .all) },
                // Pin Window is CHORD-LESS (no default keybinding), so the menu item is its primary
                // entry. Flip the SAME live `chrome.pinned` the scene modifier above actuates to
                // `NSWindow.level` — directly off the app-owned chrome (no overlay round-trip needed).
                togglePinWindow: { [chrome] in chrome.togglePin() },
                // Feed the live pinned state so the View ▸ Pin Window row renders its ✓ (a checkable
                // toggle). Reading `chrome.pinned` here re-evaluates `.commands` when the pin flips.
                pinWindowOn: chrome.pinned,
                // The Window ▸ Close Window menu row ACTUATES a real close on the window the user is
                // LOOKING AT: a key SATELLITE closes itself (its delegate reattaches the pane — never the
                // hidden main window, which would be the surprise target of the once-captured
                // `windowBox`); otherwise `performClose(nil)` on the captured workspace `NSWindow` fires
                // the native `windowShouldClose` → the existing `WindowCloseConfirmationDelegate` gate
                // (preserving the close-confirmation policy), rather than routing to
                // `store.requestCloseWindow()`, which only parks a flag nothing observes.
                closeWindow: { [windowBox] in
                    if let satellite = NSApp.keyWindow as? SatellitePaneWindow {
                        satellite.performClose(nil)
                    } else {
                        windowBox.window?.performClose(nil)
                    }
                },
            )
        }
    }

    /// Wraps a satellite window's SwiftUI root with the scene-level environment. An `NSHostingView` root
    /// inherits NOTHING from the main scene (the known hosting-root env trap), so the injected stores
    /// must be re-applied here or the satellite's deep views resolve nil coordinators. No colour scheme
    /// is forced — the chrome follows the OS appearance like every other window.
    private func decorateSatelliteRoot(_ root: AnyView) -> AnyView {
        AnyView(
            root
                .preferencesStore(preferences)
                .agentHooksController(agentHooks)
                .overlayCoordinator(overlayCoordinator),
        )
    }
}
