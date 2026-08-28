// SlopDeskMacApp — the macOS app DELEGATE: one workspace window and the AppKit obligations that hang
// off it.
//
// It is the macOS half of what used to be `SlopDeskClientApp`, a single scene serving two products
// through seventeen `#if os(...)` branches. There is not one platform gate left in this file, because
// the file is the platform (docs/56 §3).
//
// WHAT THE APP IS lives in ``ClientComposition`` (`SlopDeskClientCore`): the store, the connection, the
// preferences, the overlay coordinator, the Folders frecency, the hook enforcer, the chrome flags and
// every seam between them. This delegate holds one of those and adds what only a Mac has:
//
//   * the three OS-notification sinks the composition leaves open — the `UNUserNotification` banner
//     for a background pane event, the one for a finished long command, and the agent edge's
//     `NSSound` cue plus banner;
//   * the Dock tile (progress, error tint, bounce) and the quit drain behind ⌘Q;
//   * ONE `NSEvent` `.keyDown` monitor (``WorkspaceKeyDispatcher``) that owns every chord, including
//     the multi-key prefix a menu item cannot express;
//   * the workspace `NSWindow` itself — its close gate, its remembered/grid geometry, its traffic
//     lights, and the satellite windows a detached pane opens;
//   * the client control socket the `slopdesk` CLI drives this running GUI through;
//   * the clipboard monitor + host sync, and the discoverability-only menu bar.
//
// ⚠️ IT WAS A SwiftUI `App` UNTIL THE DE-SWIFTUI PASS, AND THREE CONSTRUCTS DIED WITH THE SCENE
// RATHER THAN CROSSING WITH IT. Each existed ONLY to buy back something a declarative scene had
// taken away, so each is a deletion, not a port:
//
//   1. **`SwiftUIIntrospect`.** A `WindowGroup` creates its `NSWindow` and hides it; `.introspect(
//      .window, on: .macOS(…))` was the sanctioned way to get it back — and because that closure
//      RE-FIRES on every scene re-render (terminal and video output mutate `@Observable` state
//      continuously) every actuator it called had to carry an `objc_setAssociatedObject` one-shot.
//      An `NSWindowController` HAS its window: it is created here, by name, once. The dependency is
//      gone from `Package.swift` and half of `SlopDeskMacApp+Window.swift`'s idempotence machinery
//      went with it.
//   2. **`@NSApplicationDelegateAdaptor`.** A SwiftUI `App` is a value type and cannot BE the
//      application delegate, so the quit drain lived in a SECOND object (`SlopDeskAppTerminationDelegate`)
//      that SwiftUI instantiated itself — which is why the store reached it through a `static` seam
//      set in `init()` rather than through an initialiser. This class IS the delegate, so
//      ``applicationShouldTerminate(_:)`` below reads the store it already owns, the second object is
//      deleted, and the static seam with it.
//   3. **The disable region for SwiftLint's `unused_declaration`** around that adaptor property. The
//      property wrapper INSTALLED a delegate whose instance was unreachable by design, so the
//      declaration looked dead to the linter and had to be silenced. Nothing is silenced here.
//      (Written in prose rather than as the literal directive on purpose: SwiftLint scans COMMENTS
//      for its own commands, so naming the region the way it was spelled makes this header a real
//      blanket disable — seven of them, one per word after it.)
//
// The menu bar came back the same way. A SwiftUI `App` supplies the standard App/Edit/Window menus
// for free and `.commands` only amends them; an `NSApplication` launched without a MainMenu.nib (this
// bundle declares no `NSMainNibFile`, and no `NSPrincipalClass`) starts with NO menu bar at all — so
// ``WorkspaceCommands`` builds the whole tree now, including the Edit menu whose key equivalents are
// what make ⌘C/⌘V work in every text field in the app.

import AppKit
import Defaults // fire-time reads of the Code Agent sound toggles in the attention sink
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskVideoProtocol // `EnvConfig` — the env → settings-overlay resolver the quit gate reads through
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UserNotifications // explicit OSC 9/777 child notifications → local UNUserNotification

@preconcurrency
@MainActor
public final class SlopDeskMacApp: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    // MARK: The process entry point

    /// The one strong reference to the delegate. `NSApplication.delegate` is `weak`, and nothing else
    /// in the process owns this object — it IS the process's root.
    ///
    /// ⚠️ `nonisolated(unsafe)` because ``main()`` has to touch it from the entry thread before the
    /// main actor has anything scheduled on it; every other access is main-actor-isolated, and there
    /// is exactly one write, in ``main()``, before `run()` returns to anybody.
    private nonisolated(unsafe) static var retained: SlopDeskMacApp?

    /// THE ENTRY POINT, kept at this exact spelling so `Apps/ClientApp-macOS/AppMain.swift` does not
    /// change: it ends in `SlopDeskMacApp.main()`, the way the phone's shell ends in
    /// `PhoneAppDelegate.main()`. `App.main()` was `nonisolated` and synchronous, and the call site is
    /// a plain `static func main()` on the `@main` type, so this one has to be too —
    /// `MainActor.assumeIsolated` is the honest spelling of "the process entry thread IS the main
    /// thread", which is the same assumption `NSApplicationMain` makes and does not state.
    ///
    /// There is no `NSApplicationMain`, no MainMenu.nib and no `NSPrincipalClass` in the bundle's
    /// `Info.plist`, so the three things that machinery would have done are done here by hand: install
    /// the delegate, build the menu bar (in ``applicationDidFinishLaunching(_:)``), and run.
    public nonisolated static func main() {
        MainActor.assumeIsolated {
            let delegate = SlopDeskMacApp()
            Self.retained = delegate
            let application = NSApplication.shared
            application.delegate = delegate
            application.run()
        }
    }

    // MARK: What the app is

    /// THE COMPOSITION ROOT — what the app IS, built and wired once in `SlopDeskClientCore` so this
    /// shell and the phone's can never grow two copies of it (docs/56 §2).
    private let app: ClientComposition
    private let clipboardMonitor: ClipboardMonitor
    /// Bidirectional clipboard sync with the host (copy here → paste there, and back) over the
    /// metadata RPC; its push/pull seams resolve the first connected pane's ``MetadataClient`` lazily at
    /// call time (panes churn, the engine outlives them).
    private let clipboardSync: ClipboardSyncEngine
    /// The Dock progress/error-tint controller (`NSApp.dockTile`). Fed the store's resolved
    /// ``WorkspaceStore/dockTileModel`` on each progress/completion edge; the bounce rides
    /// ``CommandCompletionNotifier/bounceDock``.
    private let dockProgress: DockProgressController
    /// The live keybinding dispatcher. ONE app-level `NSEvent` `.keyDown` local monitor (the re-scope of
    /// DECISIONS.md's "no NSEvent monitor" rule — a multi-key prefix can't be a menu item and the menu
    /// can't swallow a sequence's follow-up before the terminal first responder). Installed once at
    /// launch, from ``applicationDidFinishLaunching(_:)``.
    private let keyDispatcher: WorkspaceKeyDispatcher
    /// The CLIENT-side control socket server (`AF_UNIX` NDJSON), the runtime surface the `slopdesk` CLI
    /// drives the running GUI through (windows/tabs/panes, jump/font/keybind, pane capture/
    /// send-keys, agent status). Built once here over a ``WorkspaceControlBackend`` adapter and bound at
    /// launch; compiled-only + never unit-tested (hang-safety, mirroring the host's
    /// `AgentControlListener`).
    private let clientControlServer: ClientControlServer
    /// The host-windows feed behind Open Quickly's host-window rows. App-owned so its renewal loop
    /// outlives column mounts; the loop self-gates on OQ/connection.
    private let hostWindowFeed: HostWindowFeed
    /// Retains the notification click-router (the `UNUserNotificationCenter` delegate is held weakly).
    ///
    /// ⚠️ AN INSTANCE PROPERTY, NOT A STATIC. It was a `static var` because a SwiftUI `App` is a value
    /// type with no identity to hang a lifetime off — the router had to be retained by SOMETHING that
    /// outlived the struct being copied around, and the only such thing was the type itself. The
    /// delegate is that thing now.
    private let notificationRouter: PaneNotificationRouter
    /// A WEAK handle to the workspace `NSWindow`, so the ⌘⇧W / menu / palette `performClose` actuators
    /// reach the live window WITHOUT the forbidden `NSApplication.windows` scan. Weak even though the
    /// controller below holds it strongly: the box is what ``workspaceWindowIsKey(captured:keyWindow:)``
    /// reads, and a closed window must read as "no workspace window", not as a stale one.
    private let windowBox: WeakWindowBox
    /// The detach-pane satellite windows (one plain-AppKit `NSWindowController` per
    /// ``WorkspaceStore/detachedPanes`` entry) — never a second workspace window, so the single-window
    /// machinery (`windowBox` / chord dispatcher / close gate) is untouched.
    private let satelliteWindows = SatelliteWindowsCoordinator()
    /// The summoned cards that are WINDOWS of their own (docs/56 stage D) — one `NSPanel` over the
    /// workspace window per overlay the Mac has taken out of the shared SwiftUI host.
    private let overlayPanels = MacOverlayPanels()
    /// The cross-container pane-drag rendezvous: the sidebar rows, the canvas, and every satellite window
    /// live in SEPARATE view trees, so the free pane drag (move across tabs / break to a new tab / tear
    /// off to a window / merge back) meets here. Its `store` weak ref is bound at launch.
    /// The chip — the card that follows the cursor — is INJECTED rather than owned, because it is a
    /// DRAWING and the coordinator is a floor below every drawing. `chip:` defaults to `nil`, so a
    /// caller that forgets this compiles and silently draws no chip; this is the one caller, and on iOS
    /// the default is the right answer rather than an omission (no cursor, one window, nothing to
    /// follow).
    private let paneDrag = PaneDragCoordinator(chip: MacPaneDragChipPanel())

    /// THE WORKSPACE WINDOW, and the split shell inside it. Created at
    /// ``applicationDidFinishLaunching(_:)`` — not in `init` — because everything it does to the window
    /// (geometry, traffic lights, the close gate) wants a live `NSApp` and a real screen.
    private var windowController: MacWorkspaceWindowController?

    /// The long-lived process loops (clipboard monitor, clipboard sync, host-window feed, autoconnect).
    /// They were scene `.task`s, which tied their lifetime to a VIEW; they are the PROCESS's, and that
    /// is the same change the phone's shell made in docs/62 stage A. Held so the array is non-empty
    /// (the guard in ``startProcessLoops()``) and so nothing cancels them by dropping the last
    /// reference.
    private var loops: [Task<Void, Never>] = []

    // A section note, not a doc comment: it describes the follows below rather than any one
    // declaration, and `///` on a line that declares nothing is an orphaned doc comment.
    //
    // The hand-written re-arm chain has no handle to cancel, so it is stopped the only way an
    // observation chain can be: by the observer going away. Nothing here ever does — this object
    // outlives every other object in the process — so the follows below capture `[weak self]` purely
    // as the discipline the rest of the target keeps, not as a live teardown path. That is also why
    // these are LAST in line for the ``ObservationFollow`` conversion: the handle it returns buys
    // this file nothing, and its weak owner is a teardown path this owner never takes.

    // MARK: The composition's parts, read straight through

    private var store: WorkspaceStore { app.store }
    private var connection: AppConnection { app.connection }
    private var preferences: PreferencesStore { app.preferences }
    private var overlayCoordinator: OverlayCoordinator { app.overlay }
    // No `agentHooks` shorthand: nothing on this platform reads it. The hooks are enforced from the
    // composition's own connection edge, with no surface to bind.
    private var chrome: WorkspaceChromeState { app.chrome }

    override public init() {
        // Promote `SLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read (a LaunchServices `open` sanitises the inherited env, so `--args` is the
        // only remote channel).
        ClientComposition.applyLaunchArgumentEnvironment()

        // Pin the whole app to the LIGHT appearance — the ground is cream, so semantic chrome ink must
        // resolve light or the navigator draws white-on-cream under an OS in dark mode. Armed here and
        // re-fired at didFinishLaunching — `install()` arms its own
        // `NSApplication.didFinishLaunchingNotification` observer when it finds `NSApp == nil`, which
        // is exactly the case here: ``main()`` constructs this delegate BEFORE it touches
        // `NSApplication.shared`, so there is no application object to pin yet. Nothing has to call it
        // a second time.
        SlateAppearancePin.install()
        // The terminal CELLS adopt the app palette's flat colours — filled by
        // ``ClientTerminalPalette``, below both shells. It was this closure, written out here and
        // again in the phone's shell, until docs/62 stage A rewrote that file and the clone detector
        // named the pair.
        ClientTerminalPalette.install()

        let app = ClientComposition(deviceClass: .mac)
        self.app = app
        let store = app.store
        let overlay = app.overlay

        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local macOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let explicitNotifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak store] idString in store?.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        notificationRouter = router

        // The Dock progress/error-tint controller. The bounce is driven from the notifier (a DELIVERED
        // banner, NOT the bell): the "Bounce Dock Icon" toggle gates it HERE at the actuation seam so the
        // pure `CommandCompletionNotifier` stays toggle-agnostic. Returning to the app while the Dock is
        // red jumps to the next failing tab + clears the tint (the closest-faithful stand-in for the
        // dock-click hook AppKit reserves for a delegate method — see docs/DECISIONS.md).
        let dockProgress = DockProgressController()
        explicitNotifier.bounceDock = { [weak dockProgress] in
            guard SettingsKey.bounceDockIconEnabled else { return }
            dockProgress?.bounce()
        }
        dockProgress.onActivatedWhileErrored = { [weak store] in store?.revealNextErrorPane() }
        self.dockProgress = dockProgress

        // The three OS-notification sinks the composition leaves open — filled by
        // ``ClientNotificationSinks``, below both shells. ⚠️ THE PHONE INSTALLS ALL THREE (its own
        // `installNotificationSinks`, since `UserNotifications` stopped being the Mac's alone); the
        // note that used to stand here said it installed NONE, which was true when it was written and
        // was still being read as a rule long after it stopped being a fact. The toast half of each
        // fan-out already fired inside the composition, on both platforms.
        //
        // The one thing that is genuinely this platform's is the CUE'S SPEAKER: the herdr-style system
        // sounds (Submarine on a finish, Glass on awaiting-input) play through `NSSound(named:)` —
        // nothing bundled — and the banner beside them stays silent. Which cue rings at all is
        // ``AgentSoundPolicy``'s, on both.
        ClientNotificationSinks.install(
            on: app,
            notifier: explicitNotifier,
            cue: .played { NSSound(named: $0.rawValue)?.play() },
        )

        // Host-windows FEED: Open Quickly's host-window rows. Its renewal loop gates on OQ visibility +
        // connection — no OQ up costs the host exactly 0 Hz.
        hostWindowFeed = HostWindowFeed(
            isActive: { overlay.openQuicklyVisible },
            isConnected: { [weak app] in app?.connection.status == .connected },
            target: { [weak app] in app?.connection.target ?? .default },
        )
        // Held in a local so the dispatcher's `isWorkspaceWindowKey` closure below captures the SAME
        // `WeakWindowBox` the window controller fills.
        let windowBox = WeakWindowBox()
        self.windowBox = windowBox
        // The `slopdesk` command, linked into `~/.local/bin` without asking. Idempotent and silent —
        // see ``CLILink`` for why this is not a switch on a card.
        CLILink.ensureLinked()
        clipboardMonitor = ClipboardMonitor(store: store)
        // CLIPBOARD SYNC: copy on this Mac → the HOST pasteboard mirrors it within a tick (so Claude
        // Code's Ctrl+V image paste and a plain ⌘V in a remote-desktop pane just work), and a host-side
        // copy flows back. Routed through whichever pane carries a live channel — the same
        // resolve-at-call-time idiom as the Agents card / hostInfo fetcher.
        clipboardSync = ClipboardSyncEngine(
            attendedReadsFrom: store,
            push: { [weak store] clip in
                guard let store, let client = store.firstConnectedMetadataClient else { return false }
                return await client.setClipboard(clip)
            },
            pull: { [weak store] lastSeen in
                guard let store, let client = store.firstConnectedMetadataClient else { return nil }
                return await client.readClipboard(lastSeenChangeCount: lastSeen)
            },
        )
        // Build the live keybinding dispatcher over the single store. A new-pane action (split / new-tab
        // / new-session) mints a terminal pane directly via the store's routing, focused, so the user
        // picks Terminal / Remote window INSIDE the new pane; ⌘T stays a direct-terminal escape hatch
        // (it routes via `.newPane(.terminal)`, never `.newTab`).
        //
        // The dispatcher's `textBinding`/`unbind` resolution is LIVE here regardless of the overlay
        // layer — a user `text:`/`csi:`/`esc:` config binding injects via `sendBytes` and an `unbind:`
        // passes through, both resolved from `WorkspaceBindingRegistry.activeOverrides`. The palette
        // (⌘⇧P) + cheat-sheet (⌘/) toggles thread into THIS monitor so the overlay layer is driven by the
        // SAME single chord owner (never a competing menu key equivalent). `toggleFind` stays nil — its
        // `route` arm falls back to the tree-path `requestFindInActivePane()`.
        keyDispatcher = WorkspaceKeyDispatcher(
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
            // chords; the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL (handled by the picker's own
            // key handling, never registered in `WorkspaceBindingRegistry`).
            toggleOpenQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            // While the Open-Quickly picker is presented the dispatcher yields the whole keyboard to it
            // like a modal sheet. Without this the app monitor — which PREEMPTS the responder chain —
            // resolves the GLOBAL chord behind the picker, so ⌘1–9 switched the background tab (not
            // quick-pick) and ⌘W destroyed the focused pane. The Peek & Reply card YIELDS the same way.
            isOverlayCapturingKeys: { [overlay] in overlay.capturesKeyboardWhileVisible },
            // Gate the app-wide NSEvent monitor on the WORKSPACE window being key, so a satellite window
            // and any attached sheet receive their own keystrokes instead of a bound chord
            // (⌘W/⌘T/⌘1–9/…) resolving against the hidden workspace tree behind them. The predicate is a
            // pure IDENTITY check against `NSApp.keyWindow` (`workspaceWindowIsKey`), so a nil capture
            // NEVER claims the keyboard.
            isWorkspaceWindowKey: { [windowBox] in
                Self.workspaceWindowIsKey(captured: windowBox.window, keyWindow: NSApp.keyWindow)
            },
        )
        // Diagnostics tap for the keyboard-focus saga — inert unless SLOPDESK_FOCUS_DEBUG=1.
        FocusDebugProbe.installIfRequested()
        // The code panel's warm-swap focus restore needs the workspace's ACTIVE TAB (the pool cannot see
        // the store) — same late-wiring idiom as the dispatcher's closures above.
        CodeSidebarWebViewPool.activeTabID = { [store] in store.tree.activeSession?.activeTab?.id }
        // The client control socket server over a ``WorkspaceControlBackend`` adapter on the SAME live
        // stores the GUI uses (the backend holds them WEAKLY — the composition retains the originals).
        // Built here so it outlives the window; BOUND at launch (the bind/listen is deferred).
        clientControlServer = ClientControlServer(
            backend: WorkspaceControlBackend(store: store, folders: app.folders),
        )
        super.init()
    }

    // MARK: Launch

    public func applicationDidFinishLaunching(_: Notification) {
        // THE MENU BAR, built once. There is no MainMenu.nib and no `NSApplicationMain`, so an empty
        // `NSApp.mainMenu` is what this process starts with — including no Edit menu, which is what
        // ⌘C/⌘V/⌘X/⌘A resolve through in every `NSTextField` the app puts up (the palette's query
        // field, the Connect sheet's form). Built once and never rebuilt: the two items whose LOOK is
        // live (the ✓ on Pin Window, the greying of the pane actions) re-resolve on every menu open
        // through ``validateMenuItem(_:)`` below, which is AppKit's own equivalent of a body
        // re-evaluation and costs nothing while the menu is closed.
        NSApp.mainMenu = WorkspaceCommands.mainMenu(target: self)

        // The palette's "Open Settings" row opens the config FILE, the same thing ⌘, does. There is
        // no settings surface for it to raise any more.
        overlayCoordinator.openSettingsAction = { ConfigFile.openInEditor() }

        // THE WINDOW. Everything that used to be a scene modifier (`.windowStyle(.hiddenTitleBar)`,
        // `.defaultSize`, `.defaultPosition`, `.windowLevel`) is inside the controller, spelled as the
        // `NSWindow` properties they always compiled down to.
        let controller = MacWorkspaceWindowController(
            store: store,
            connection: connection,
            overlay: overlayCoordinator,
            chrome: chrome,
            preferences: preferences,
            paneDrag: paneDrag,
            // Wire ⌘⇧L (Toggle Tabs Panel), ⌘⇧R (Toggle Code Panel), ⌥⌘R (focus the code panel) and the
            // chord-less Pin Window action to the window's live chrome ON the app-level `keyDispatcher`,
            // so each routes through the SAME NSEvent monitor that owns every other chord.
            installSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleSidebar(toggle) },
            installCodeSidebarToggle: { [keyDispatcher] toggle in keyDispatcher.setToggleCodeSidebar(toggle) },
            installFocusCodePanel: { [keyDispatcher] focus in keyDispatcher.setFocusCodePanel(focus) },
            installPinToggle: { [keyDispatcher] toggle in keyDispatcher.setTogglePinWindow(toggle) },
        )
        windowController = controller
        guard let window = controller.window else { return }

        // Install the window-close confirmation gate. The store owns the policy decision
        // (`requestCloseWindow()` → `pendingWindowClose`); the delegate routes through
        // `WindowCloseGate` and presents a synchronous confirmation so a parked close always resolves
        // (the window is never stranded).
        Self.installWindowCloseGate(on: window, store: store)
        // Install the ⌘⇧W "Close Window" actuator on the SAME NSEvent monitor that owns every chord.
        // It calls `performClose(nil)` on the captured window (via the weak `windowBox`), firing
        // `windowShouldClose` → the gate just installed — so the chord ACTUATES a close instead of
        // parking a flag nothing reads.
        keyDispatcher.setCloseWindow { [windowBox] in windowBox.window?.performClose(nil) }
        // The palette "Close Window" row routes through the SAME `performClose(nil)` actuator → the
        // close-confirmation gate, so it actuates a real close instead of the dead
        // `requestCloseWindow()` park.
        overlayCoordinator.closeWindow = { [windowBox] in windowBox.window?.performClose(nil) }
        windowBox.window = window
        // Pass the LIVE chrome (for the grid `chromeOverhead` — the revealed sidebar) + the configured
        // terminal font size (the font-derived fallback cell used only before the terminal surface lays
        // out). The grid sizing DEFERS its once-per-open commit until real cell metrics exist, and the
        // controller re-offers it when the first terminal surface reports them.
        Self.applyInitialWindowSize(
            to: window, store: store, chrome: chrome,
            fontPointSize: CGFloat(preferences.terminal.fontSize),
        )
        controller.retryGridSizeWhenCellMetricsArrive { [weak self] in
            guard let self, let window = windowBox.window else { return }
            Self.applyInitialWindowSize(
                to: window, store: store, chrome: chrome,
                fontPointSize: CGFloat(preferences.terminal.fontSize),
            )
        }
        // Bring the traffic lights DOWN onto the band's top line, where the island's top edge and every
        // other control in the band start (see helper).
        Self.lowerTrafficLightsToTheTopLine(on: window)
        controller.showWindow(nil)
        // AUTOMATION ONLY: bring the window to front + make it key so an autoconnect launch goes live
        // without a manual click. It lost its `…Once` suffix with the one-shot it named: the introspect
        // closure re-fired and would have yanked focus back whenever the user switched apps, so the
        // activate had to mark the window it had activated. This runs once because it is called once.
        Self.automationBringToFront(window)

        // Late-bind the drag coordinator's weak store (chip labels + destination gating) — the two
        // objects cannot reference each other at property-init time.
        paneDrag.store = store
        // `NSApplication.isActive` is the truth at launch; the two activation delegate methods below
        // keep it so.
        store.isAppActive = NSApplication.shared.isActive
        // The store stays AppKit-free, so a reveal calls back into this coordinator through the
        // injected seam instead of minting a second live stream.
        store.revealSatelliteWindow = { [satelliteWindows] paneID in satelliteWindows.reveal(paneID) }

        startProcessLoops()
        startFollows()
    }

    // MARK: The process loops

    /// The four long-lived loops, started once. They were scene `.task`s — cancelled when the view
    /// went away, restarted when it came back — and they are the PROCESS's: a clipboard poll that
    /// stops because a window closed is a bug the scene shape was hiding. The guard is the same one
    /// the phone's shell carries.
    private func startProcessLoops() {
        guard loops.isEmpty else { return }
        loops = [
            Task { [clipboardMonitor, app] in
                guard !app.isAutomation else { return }
                await clipboardMonitor.run()
            },
            // Clipboard-sync poll loop (push local copies to the host, pull host copies back).
            // Skipped under automation like the monitor: an E2E run must not mirror the developer's
            // real pasteboard onto the test host (or vice versa).
            Task { [clipboardSync, app] in
                guard !app.isAutomation else { return }
                await clipboardSync.run()
            },
            // Host-windows FEED renewal loop (docs/45). Self-gating: a collapsed rail with Open
            // Quickly hidden (or a disconnected app) idles with ZERO wire traffic.
            Task { [hostWindowFeed] in await hostWindowFeed.run() },
            // AUTOMATION: auto-connect so an autoconnect launch goes live without a manual click.
            // OTHERWISE (Goal B): a normal launch silently re-connects the MRU host. On a fresh
            // install `connectIfSavedTarget()` no-ops and the user opens the Connect-to-Host editor
            // (the top-bar status pill / "Connect to Host…" palette action).
            // SLOPDESK_SKIP_AUTO_RECONNECT=1 turns the second half off.
            Task { [connection, app] in
                guard app.isAutomation else {
                    await connection.connectIfSavedTarget()
                    return
                }
                let env = WorkspaceStore.automationInputs()
                if env["SLOPDESK_AUTOCONNECT_HOST"]?.isEmpty == false {
                    await connection.connect()
                } else {
                    // Video-only automation (the video host serves UDP only, no TCP listener): mark
                    // connected so the workspace mounts and the video pane opens its UDP flow.
                    connection.markConnectedForAutomation()
                }
            },
        ]

        // Install the keybinding dispatcher's `.keyDown` local monitor. It runs under automation too
        // (the keybinding path is part of what HW E2E drives); the monitor swallows ONLY the prefix +
        // armed follow-ups + bound chords and passes every bare key through, so it never interferes
        // with autoconnect typing.
        keyDispatcher.install()

        // Bind the client control socket so the `slopdesk` CLI can drive this running GUI. The
        // bind/listen is a couple of syscalls + a detached accept thread (the per-connection read loops
        // stay OFF the cooperative pool — hang-safety, mirroring the host ctl socket). A bind failure
        // (stale path the OS won't reclaim, etc.) is swallowed: the CLI control plane is a convenience,
        // never load-bearing, and must never crash the app.
        do {
            try clientControlServer.start()
        } catch {
            // Best-effort: log + continue; the GUI is fully usable without the CLI socket.
            FileHandle.standardError.write(Data("client-control: socket bind failed: \(error)\n".utf8))
        }
    }

    // MARK: The observation edges

    /// Re-arm `body` whenever anything it reads changes, forever.
    ///
    /// ⚠️ ONE CALL PER EDGE, never one call around all of them. `withObservationTracking` records the
    /// union of everything the body touched, so a single mega-follow over all nine edges below would
    /// re-run the Dock apply, the satellite diff and all seven panel syncs on every keystroke that
    /// moves any of them — which is exactly the re-render storm ``RailRowsMemo`` exists to kill, moved
    /// one floor up. Each edge reads the narrowest thing that answers it.
    ///
    /// The re-arm is deferred to the next main-actor turn because `onChange` fires at `willSet`: the
    /// value the body would read inside it is still the OLD one, so the body must run after the
    /// mutation lands, not during it. This is the same idiom ``MacTitlebarBand/follow()`` uses.
    ///
    /// The body is CALLED inside a fresh closure rather than passed as the `apply:` argument itself:
    /// `withObservationTracking`'s first parameter is declared non-isolated, and an inline closure
    /// inherits this method's `@MainActor` isolation where a stored function value does not.
    private func follow(_ body: @escaping @MainActor () -> Void) {
        withObservationTracking { body() } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.follow(body)
                }
            }
        }
    }

    /// Every `@Observable` edge the scene used to spell as a `.onChange`. Each body runs ONCE at arm
    /// time, which is the `initial: true` the close-confirmation and Dock edges asked for explicitly
    /// and which the others are indifferent to (a panel told to be hidden while it is hidden is a
    /// no-op, and the satellite diff against an empty list is the launch sync the scene ran in a
    /// `.task`).
    private func startFollows() {
        // Drive the Dock tile from the store's resolved aggregate. `dockTileModel` reads `paneProgress`
        // + `panePendingCompletion` (@Observable), so a progress/completion edge re-applies the tile; a
        // last-session-end edge resolves to `.inert` → the controller CLEARS (no stuck red tile).
        follow { [weak self] in
            guard let self else { return }
            dockProgress.apply(store.dockTileModel)
        }
        // Pin Window (chord-less; menu/palette flips `chrome.pinned`) maps to the WINDOW LEVEL. This
        // was `.windowLevel(chrome.pinned ? .floating : .normal)`, a scene modifier that re-evaluated
        // because the scene body read the flag; the follow reads the same flag and actuates the same
        // property. The single-window model means it only ever touches the one workspace window.
        follow { [weak self] in
            guard let self else { return }
            windowBox.window?.level = chrome.pinned ? .floating : .normal
        }
        // SATELLITE WINDOWS (Detach Pane into Window): diff one plain-AppKit window per detached pane.
        // Driven off the `@Observable` detached list — the store stays headless; only this app layer
        // touches NSWindow. The launch restore re-docks satellites (v1: they don't persist as windows),
        // so the arm-time run is normally a no-op — kept for the automation/replay paths that could
        // restore a mid-detach state.
        follow { [weak self] in
            guard let self else { return }
            satelliteWindows.sync(
                store.detachedPanes, store: store, paneDrag: paneDrag, overlay: overlayCoordinator,
            )
        }
        // THE ⌘/ CHEAT SHEET is the Mac's own AppKit panel (docs/56 stage D) — driven from HERE for the
        // same reason the satellites are: `windowBox` holds the one workspace window, and a card is a
        // child window of it. The coordinator's flag stays the single truth; the panel follows this
        // edge, and every dismissal inside it flips the flag back rather than tearing itself down.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.setCheatSheet(
                overlayCoordinator.cheatSheetVisible,
                host: windowBox.window, store: store, coordinator: overlayCoordinator,
            )
        }
        // THE ⌘⇧P PALETTE is the Mac's own AppKit panel (docs/56 stage D) — the first MODAL surface
        // across, and the one that settles the palette family's shape: a pre-focused field, a ranked
        // list steered THROUGH that field's editing commands, and a card that measures itself against
        // its own results. `toggledState` is built from the LIVE chrome, so the ✓ gutter tracks real
        // visibility and a ⌘↩ that keeps the card up flips its own row.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.setPalette(
                overlayCoordinator.paletteVisible,
                host: windowBox.window, store: store, coordinator: overlayCoordinator,
                toggledState: PalettePresentation.toggledState(chrome: chrome, store: store),
            )
        }
        // THE ⌘⌥J PEEK CARD is the Mac's own AppKit panel (docs/56 stage D) — the second MODAL surface
        // across, and the first whose CONTENT moves under it: a reply advances the queue, and the card
        // is re-cut for the next blocked pane without the panel ever going away. It takes no
        // `toggledState`-style injection because everything it shows is the store's and the
        // coordinator's already.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.setPeekReply(
                overlayCoordinator.peekReplyVisible,
                host: windowBox.window, store: store, coordinator: overlayCoordinator,
            )
        }
        // THE ⌘⇧O / ⌘J PICKER is the Mac's own AppKit panel (docs/56 stage D), and the LAST card to
        // move: with it gone, the shared overlay host draws no card on macOS at all.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.setOpenQuickly(
                overlayCoordinator.openQuicklyVisible,
                host: windowBox.window, store: store, coordinator: overlayCoordinator,
            )
        }
        // THE ⇧⌘F RESULTS PANEL is the Mac's own AppKit panel (docs/56 stage D). It is the one of the
        // three that is FIXED-SIZE: the query re-runs on every keystroke, and a panel that resized with
        // the match count would move under the pointer — which on that surface is the selection itself.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.setGlobalSearch(
                overlayCoordinator.globalSearchVisible,
                host: windowBox.window, store: store, coordinator: overlayCoordinator,
            )
        }
        // CONNECT-TO-HOST is the Mac's own AppKit SHEET (docs/56 stage D) — the last surface over the
        // workspace to leave the shared SwiftUI floor, and the one that was never a card: a form you
        // fill in and commit is what the platform's own modal is for, so it is a real `beginSheet`
        // rather than a borderless panel. Same discipline as the cards regardless — Cancel, Esc and a
        // successful connect flip the coordinator's flag, and this edge is what opens and closes it.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.setConnect(
                overlayCoordinator.connectVisible,
                host: windowBox.window, connection: connection, coordinator: overlayCoordinator,
            )
        }
        // THE CLOSE CONFIRMATION is the Mac's own `NSAlert` sheet (docs/56 stage D), and with it the
        // window root mounts no SwiftUI above the split at all. Driven off the store's two parks rather
        // than a flag — a park IS the state — and both buttons resolve the park, so the store and the
        // sheet cannot disagree. The arm-time run covers a launch that restores straight into a parked
        // close (this is the edge that used to carry `initial: true`).
        follow { [weak self] in
            guard let self else { return }
            _ = CloseConfirmationCopy.request(store: store)
            overlayPanels.syncCloseConfirmation(store: store, host: windowBox.window)
        }
        // THE NOTIFICATION CORNER is the Mac's own AppKit panel too (docs/56 stage D), and it is what
        // took the last ALWAYS-MOUNTED `NSHostingView` off the window root: the toast host used to be a
        // full-bleed SwiftUI layer over the whole workspace, toggling `allowsHitTesting` so the split
        // beneath stayed clickable. The panel is sized to the column instead, so the only region that
        // takes hits is the cards themselves. Driven off the list rather than off a flag, because an
        // ambient surface has no flag — its content IS its state.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.syncToasts(
                overlayCoordinator.toasts,
                host: windowBox.window, store: store, coordinator: overlayCoordinator,
            )
        }
        // THE ⌃⇥ READOUT, the last ambient tenant of the shared host and now an `NSPanel` that ignores
        // the mouse outright. Driven off the store's gesture rather than a coordinator flag, because the
        // gesture IS the state — the dispatcher owns open/step/commit/cancel and this only draws what it
        // decided.
        follow { [weak self] in
            guard let self else { return }
            overlayPanels.syncPaneSwitcher(store.paneSwitcher, host: windowBox.window, store: store)
        }
    }

    // MARK: Activation

    public func applicationDidBecomeActive(_: Notification) {
        // ⚠️ THIS IS NOT `scenePhase`, AND THAT IS THE POINT. SwiftUI's `scenePhase` tracks WINDOW
        // VISIBILITY on this platform, not app activation — it stays `.active` while the window sits
        // visible-but-backgrounded behind another app, which kept `isAppActive` permanently true and
        // silently suppressed every command/error/agent UN banner (default `notifyWhileForeground ==
        // .off`). The real AppKit activation signal was already what the scene subscribed to through
        // `.onReceive`; now it is the delegate method the notification was posted from.
        store.isAppActive = true
        // Coming back to the app is exactly the moment somebody has finished editing the config file in
        // another one. A no-op when the file has not moved (``ConfigFile`` compares before re-applying)
        // — otherwise every ⌘Tab back would rebuild the terminal config and re-measure the PTY grid.
        ConfigFile.reload(preferences)
    }

    public func applicationDidResignActive(_: Notification) {
        store.isAppActive = false
    }

    /// ⌘H. The closest thing this platform has to the `scenePhase == .background` the scene flushed
    /// the tree on: the app is no longer on screen and the next thing that happens to it may be a
    /// force-quit. `saveImmediately()` is idempotent and cheap, and ⌘Q has its own save below.
    public func applicationDidHide(_: Notification) {
        store.saveImmediately()
    }

    /// A Dock-icon click (or an `open -a`) with no window on screen puts the workspace back.
    ///
    /// ⚠️ THIS IS THE ONE THING `WindowGroup` DID FOR FREE THAT AN `NSWindowController` DOES NOT. A
    /// scene re-instantiates its window on a reopen; a controller just sits there holding a closed
    /// one, so without this method a confirmed ⌘W leaves the app alive as a menu bar with no route
    /// back to itself — running, unquittable except through ⌘Q, and showing nothing. The window is
    /// `isReleasedWhenClosed = false` and the controller is held by this delegate precisely so the
    /// answer is to show the SAME window again rather than to build a second workspace over the same
    /// store. Returning `false` tells AppKit the reopen is handled and suppresses its own
    /// untitled-document attempt.
    public func applicationShouldHandleReopen(
        _: NSApplication, hasVisibleWindows: Bool,
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        windowController?.showWindow(nil)
        return false
    }

    // MARK: Quit

    /// Associated state for the quit drain — set while a ⌘Q is in flight so a second one during the
    /// bounded drain window does not start a second drain (it cancels instead, leaving the first to
    /// reply).
    private var draining = false

    /// QUIT-DRAIN (orphaned-session leak): park ⌘Q behind a BOUNDED ``WorkspaceStore/quiesce()`` so
    /// in-flight pane teardowns (the bye/channelClose of a just-closed busy pane) reach the wire
    /// before the process dies.
    ///
    /// ⚠️ THIS IS `SlopDeskAppTerminationDelegate`, FOLDED IN AND DELETED. That class existed only
    /// because a SwiftUI `App` is a value type and cannot be the application delegate: the drain
    /// needed an `NSObject` for `@NSApplicationDelegateAdaptor` to instantiate, and because SwiftUI
    /// instantiated it, the store could not be handed over at init and reached it through a
    /// `weak static var` instead. Both the second object and the static seam are gone; this method
    /// reads the store this delegate has owned since `init`.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second ⌘Q while the first is draining CANCELS rather than stacking: the in-flight drain is
        // bounded and will reply on its own, and two `reply(toApplicationShouldTerminate:)` calls for
        // one termination is undefined.
        guard !draining else { return .terminateCancel }
        // The confirmation is the store's policy, not the window's: a quit with open tabs asks, an
        // Apple-Event quit (a script, a logout) never does, and `SLOPDESK_QUIT_CONFIRM` overrides both.
        if QuitConfirmPolicy.requiresConfirmation(
            hasOpenTabs: store.tree.sessions.contains { !$0.tabs.isEmpty },
            isAppleEventQuit: NSAppleEventManager.shared().currentAppleEvent != nil,
            envValue: EnvConfig.string("SLOPDESK_QUIT_CONFIRM"),
        ), !Self.confirmQuit() {
            return .terminateCancel
        }
        draining = true
        // Save UP FRONT as well as in `applicationWillTerminate`, in case the drain window is
        // interrupted (a force-quit during the two seconds).
        store.saveImmediately()
        Task { @MainActor [store] in
            await TerminationDrain.drain(timeout: Self.drainTimeout) { await store.quiesce() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_: Notification) {
        // macOS delivers no reliable flush on ⌘Q; flush the tree synchronously on termination. Fires
        // AFTER the drain above has replied — termination proceeds only then — so this is the LAST-WORD
        // save.
        store.saveImmediately()
        // `.remember` window-size: capture the final frame at quit — the end-of-gesture observers
        // (`applyRememberedFrame`) cover resize/move, but a plain ⌘Q after a zoom (no live-resize
        // gesture) would otherwise miss the last frame. Automation quits never save (they run at the
        // odiff reference geometry, not the user's).
        if SettingsKey.windowSize == .remember, !app.isAutomation, let window = windowBox.window {
            SettingsKey.savedWindowFrame = window.frameDescriptor
        }
        // Reset the process-global Dock tile on teardown so a quit never leaves a stuck progress/red
        // tile behind for the next app to inherit.
        dockProgress.clear()
    }

    // MARK: Menu actions

    /// ⌘, — the app menu's own item. It opens `config.toml`; there is no settings window to raise, and
    /// the file IS the settings surface (docs/58 — there is NO settings GUI).
    @objc
    func openConfiguration(_: Any?) {
        ConfigFile.openInEditor()
    }

    /// The Window ▸ Close Window row (and File ▸ Close, ⌘W's menu twin) ACTUATES a real close on the
    /// window the user is LOOKING AT: a key SATELLITE closes itself (its delegate reattaches the pane —
    /// never the hidden main window, which would be the surprise target of the once-captured
    /// `windowBox`); otherwise `performClose(nil)` on the workspace `NSWindow` fires the native
    /// `windowShouldClose` → the ``WindowCloseConfirmationDelegate`` gate, preserving the
    /// close-confirmation policy, rather than routing to `store.requestCloseWindow()`, which only parks
    /// a flag nothing observes.
    @objc
    func closeWorkspaceWindow(_: Any?) {
        if let satellite = NSApp.keyWindow as? SatellitePaneWindow {
            satellite.performClose(nil)
        } else {
            windowBox.window?.performClose(nil)
        }
    }

    /// Every workspace menu row lands here, carrying its ``WorkspaceBinding`` id in
    /// `NSMenuItem.representedObject`. Dispatch is ``WorkspaceCommands/perform(id:…)``'s, which routes
    /// through the SAME ``WorkspaceBindingRegistry`` the `NSEvent` monitor reads — the menu is a second
    /// ENTRY, never a second dispatcher.
    @objc
    func performWorkspaceAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let id = item.representedObject as? String else { return }
        WorkspaceCommands.perform(
            id: id,
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
            // The View ▸ Jump To… menu item opens the folded-in Jump-To (the Open-Quickly picker at the
            // `.current` pill), the SAME overlay the ⌘J chord drives.
            toggleJumpTo: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .current) },
            // The View ▸ Open Quickly… menu row opens the picker at the merged `.all` pill.
            openQuickly: { [overlayCoordinator] in overlayCoordinator.toggleOpenQuickly(filter: .all) },
            // Pin Window is CHORD-LESS (no default keybinding), so the menu item is its primary entry.
            // Flip the SAME live `chrome.pinned` the follow above actuates to `NSWindow.level`.
            togglePinWindow: { [chrome] in chrome.togglePin() },
            closeWindow: { [weak self] in self?.closeWorkspaceWindow(nil) },
        )
    }

    /// The menu's LIVE half, re-resolved by AppKit every time a menu opens — which is what replaces a
    /// `.commands` body re-evaluation. Two questions only:
    ///
    ///   * a row whose action ``WorkspaceAction/requiresActivePane`` greys out when there is no active
    ///     pane (the `.disabled(…)` the SwiftUI `Button` carried);
    ///   * View ▸ Pin Window draws its ✓ from the live `chrome.pinned` (the `Toggle` it was).
    ///
    /// Everything else validates by existing.
    ///
    /// ⚠️ NOT AN `override`. `validateMenuItem(_:)` is not an `NSObject` method — it is the sole
    /// requirement of the `NSMenuItemValidation` protocol, which AppKit looks for on the TARGET of a
    /// row's action by conformance, not by inheritance. Spelling `override` here does not compile.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performWorkspaceAction(_:)),
              let id = menuItem.representedObject as? String
        else { return true }
        menuItem.state = WorkspaceCommands.checkmark(id: id, chrome: chrome) ? .on : .off
        return WorkspaceCommands.isEnabled(
            id: id, activePaneID: store.tree.activeSession?.activeTab?.activePane,
        )
    }
}
