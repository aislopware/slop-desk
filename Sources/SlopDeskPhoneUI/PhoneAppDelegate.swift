// PhoneAppDelegate — the iOS app OBJECT: the composition it owns, the process-wide loops, and the
// responder chain's tail.
//
// It replaces `SlopDeskPhoneApp: App` (docs/62 stage A). What used to be a `WindowGroup` and five
// property wrappers is a delegate and a scene delegate, because every one of those wrappers was
// paying for a declarative update this shell never used: the scene's `body` re-evaluated to place
// one hosting controller, and `@Environment(\.scenePhase)` reported four phases through a single
// `onChange` that then had to re-derive which of them it was looking at.
//
// WHAT THE APP IS still lives in ``ClientComposition`` (`SlopDeskClientCore`): the store, the
// connection, the preferences, the overlay coordinator, the Folders frecency, the Agents card, the
// chrome flags and every seam between them, identical to the Mac's. What this object adds is only
// what a phone has:
//
//   * the per-idiom live-video ceiling (a phone gets one live stream, an iPad two);
//   * the OS-notification sinks, filled by the SHARED ``ClientNotificationSinks`` rather than by a
//     second copy of the Mac's three closures — that copy is what docs/62 stage A's ledger row was
//     waiting to be paid, and paying it is what removes the row rather than re-pinning it;
//   * the responder chain's TAIL, which is this class and not a separate delegate any more.
//
// ## Why the workspace chords live HERE
//
// The rung has to be an ANCESTOR of every first responder the workspace can have, and on this
// platform there is exactly one such place: `UIApplication` and then its delegate ARE the chain's
// tail by construction, for every window and every responder in the process. That used to make this
// a `@UIApplicationDelegateAdaptor` — a real delegate mounted for its responder-ness alone, holding
// three weak references it was handed on appear because it could not reach the composition itself.
// Now it IS the delegate, so the references are the composition it already owns and the `attach`
// hop is gone.
//
// That shape is also what keeps the rule small (``PhoneRootKeyPolicy``): the Mac's `NSEvent` monitor
// PREEMPTS the chain and pays for it with one hand-written yield per surface it would otherwise
// steal keys from, while a tail rung yields to every one of them by simply being last. Two surfaces
// the chain cannot speak for keep a gate — a summoned overlay whose focused field walks ⌘-chords
// past itself, and the panel's full-screen cover — and nothing else needs one.
//
// ## What the tail deliberately does NOT do
//
// It never touches a BARE key. A press that resolves to no chord in the table is forwarded, so
// typing that arrives here (a text field that declined it, a pane with no responder) is still the
// system's. It does not repeat: a held ⌘D that split twenty times a second is not what holding ⌘D
// means, which is the same argument ``TerminalInputHostView/swallowsAsWorkspaceChord(_:)`` makes.
// And it sends no literal-byte `text:` binding — those are terminal INPUT and belong to the pane
// that has the keyboard, not to a rung that runs when no pane does.
//
// ## The loops are the PROCESS's, and that is a change
//
// The clipboard poll, the clipboard-sync loop and the two connect-on-launch tasks were four `.task`
// modifiers on the scene's content, so an iPad that opened a second window ran a second copy of each
// — two pollers reading one pasteboard, two auto-reconnects racing one connection. They are started
// once here instead, against the one composition, and they live as long as the process does. See
// ``PhoneSceneDelegate`` for the half that genuinely IS per-scene.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import UIKit
import UserNotifications // explicit OSC 9/777 + long-command + agent edges → local notifications

/// The app delegate: the composition root, the process-wide loops and the responder chain's tail.
@preconcurrency
@MainActor
public final class PhoneAppDelegate: UIResponder, UIApplicationDelegate {
    /// THE COMPOSITION ROOT — what the app IS, built and wired once in `SlopDeskClientCore` so this
    /// shell and the Mac's can never grow two copies of it (docs/56 §2).
    ///
    /// A `let`, built in ``init()``: `UIApplicationMain` mints this object before it delivers any
    /// callback, so there is no window in which the app exists and its composition does not — which
    /// is what the `App` struct's `@State` box was buying with an extra indirection, and what an
    /// optional here would re-introduce as a question every reader has to answer again.
    private let composition: ClientComposition

    /// Retains the notification click-router (`UNUserNotificationCenter` holds its delegate weakly, so
    /// nothing else in this process would). A stored property rather than the `static` the `App`
    /// struct needed: a value type had nowhere to put it, and this object outlives every scene.
    private var notificationRouter: PaneNotificationRouter?

    /// The clipboard-history poller, the same type the Mac shell runs. On this platform it consumes
    /// the board's `changeCount` and records nothing: iOS refuses an unattended CONTENT read, so the
    /// ring is filled by ``WorkspaceStore/currentLocalClipboard()`` on the paths the user asked to
    /// paste on. Running it anyway is what keeps the seen count honest across the session.
    private var clipboardMonitor: ClipboardMonitor?

    /// Cross-device clipboard sync, the same engine the Mac shell runs. The PULL half is whole here —
    /// a copy on the host lands on the phone's pasteboard within a tick, which needs no permission —
    /// and the push half runs on the ATTENDED reads instead of the timer, which is the only shape iOS
    /// permits: the tick may not read board CONTENT unattended (that is a modal "Allow Paste?" alert
    /// once a second), so ``WorkspaceStore/currentLocalClipboard()`` hands each clip the user actually
    /// asked to paste straight to the engine's queue. See ``ClipboardSyncEngine``.
    private var clipboardSync: ClipboardSyncEngine?

    /// The process-wide loops, held so they are cancellable and so nothing starts a second copy.
    private var loops: [Task<Void, Never>] = []

    /// The pane's own interceptor, at root scope: the same override-aware table, the same `route`
    /// sink, minted by the store so there is one resolve-and-dispatch in the app rather than two.
    private var interceptor: TerminalKeyInterceptor?

    /// The rung THIS press landed on, resolved once at the top of ``take(_:)`` and read back by the
    /// interceptor's filter. A stored beat rather than a second derivation: the rung's third input
    /// walks every connected scene's windows, and asking it twice per keystroke is a walk this rung
    /// has no reason to pay for.
    private var pressRung: PhoneRootKeyRung = .workspace

    override public init() {
        // Promote `SLOPDESK_<KEY>=<VALUE>` launch arguments into the process environment BEFORE any
        // env-gated knob is read — including the ceiling below, which reads one.
        ClientComposition.applyLaunchArgumentEnvironment()

        // Pin the whole app to the CHROME polarity — the ground is cream, so semantic chrome ink must
        // resolve light or the navigator draws white-on-cream under an OS in dark mode. The same one
        // line the Mac shell runs, for the same reason: the requirement belongs to the GROUND, which
        // is the same fixed hex on both platforms. Armed here and re-fired per scene as each connects
        // — the pin observes `UIScene.willConnectNotification` itself, so this is the only call site
        // even though a phone can grow a second window an hour in (see ``SlateAppearancePin``).
        SlateAppearancePin.install()

        // The terminal CELLS adopt the app palette's flat colours — filled by
        // ``ClientTerminalPalette``, below both shells, because it is the same closure on both.
        //
        // ⚠️ BEFORE the composition, not after: `PreferencesStore` builds a terminal config as it
        // comes up, and that build asks the seam. Installed second, the FIRST config a pane sees
        // resolves against an unfilled closure and the cells come up in libghostty's own colours
        // until something dirties the config. Both shells install it ahead of their composition for
        // this reason; keeping the order identical is what keeps them one launch sequence.
        ClientTerminalPalette.install()

        // The concurrent live-video ceiling, resolved ONCE at launch from the device idiom: an iPad in
        // a regular projection can hold two live streams, a phone one.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        composition = ClientComposition(deviceClass: isPad ? .pad : .phone)
        super.init()
    }

    // MARK: The composition's parts, read straight through

    /// The live workspace, for the scene that has to mount it.
    var store: WorkspaceStore { composition.store }
    var connection: AppConnection { composition.connection }
    var preferences: PreferencesStore { composition.preferences }
    var overlayCoordinator: OverlayCoordinator { composition.overlay }
    var chrome: WorkspaceChromeState { composition.chrome }

    // MARK: Launch

    public func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        // ``SlateAppearancePin`` and ``ClientTerminalPalette`` are already armed — they run in
        // `init()`, ahead of the composition, because the composition's first terminal config asks
        // the palette seam on its way up.
        let app = composition

        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777) + long-command + agent-attention → local iOS
        // notifications, tagged with the pane id so a click reveals the pane (the router routes back).
        let notifier = CommandCompletionNotifier()
        let router = PaneNotificationRouter()
        router.onReveal = { [weak app] idString in app?.store.revealPane(byIDString: idString) }
        UNUserNotificationCenter.current().delegate = router
        notificationRouter = router
        // The three sinks, filled BELOW both shells. The cue rides the BANNER here rather than a
        // second audio path: the phone's cues are the notification request's own `sound` field, so
        // one posting carries one sound and the system decides whether a silenced device hears it.
        // Which cue rings at all is ``AgentSoundPolicy``'s, on both platforms. `bounceDock` stays at
        // its `{}` default — there is no Dock tile on a phone, and that is the one asymmetry,
        // expressed as an unbound seam rather than as a gate.
        ClientNotificationSinks.install(on: app, notifier: notifier, cue: .withTheBanner)

        // The FILTER is read at resolve time, so one interceptor serves both rungs the policy can put
        // this responder on: under the cover it spends only what gives the keyboard back.
        interceptor = app.store.makeKeyInterceptor(allowing: { [weak self] action in
            self?.pressRung != .panelEscape || CodePanelKeyYield.survives(action)
        })

        startProcessLoops(app)
        return true
    }

    /// Hands every connecting scene the same delegate class.
    ///
    /// Registered in CODE rather than through an `Info.plist` `UISceneConfigurations` array: that key
    /// wants the runtime's module-qualified class name (`SlopDeskPhoneUI.PhoneSceneDelegate`), which
    /// is a string nothing type-checks and which `project.yml` would have to carry as a literal. A
    /// returned configuration names the class itself, so a rename is a compile error.
    public func application(
        _: UIApplication,
        configurationForConnecting session: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = PhoneSceneDelegate.self
        return configuration
    }

    // MARK: The process-wide loops

    /// Starts the four loops that belong to the PROCESS, once.
    ///
    /// Under `WindowGroup` these were `.task` modifiers on the scene's content, which is why an iPad
    /// with two windows ran two clipboard pollers against one pasteboard and two auto-reconnects
    /// against one connection. There is one composition, so there is one of each.
    private func startProcessLoops(_ app: ClientComposition) {
        guard loops.isEmpty else { return }
        let monitor = ClipboardMonitor(store: app.store)
        // CLIPBOARD SYNC, wired exactly as `SlopDeskMacApp` wires it: routed through whichever pane
        // carries a live channel, resolved at call time (the same idiom as the Agents card / hostInfo
        // fetcher). A phone differs from the Mac in LAYOUT, not in which features exist — docs/56 §3 —
        // and this one is a phone's best case: copy on the host, paste on the device in your hand.
        let sync = ClipboardSyncEngine(
            attendedReadsFrom: app.store,
            push: { [weak store = app.store] clip in
                guard let store, let client = store.firstConnectedMetadataClient else { return false }
                return await client.setClipboard(clip)
            },
            pull: { [weak store = app.store] lastSeen in
                guard let store, let client = store.firstConnectedMetadataClient else { return nil }
                return await client.readClipboard(lastSeenChangeCount: lastSeen)
            },
        )
        clipboardMonitor = monitor
        clipboardSync = sync

        guard !app.isAutomation else {
            // AUTOMATION ONLY (env-gated): auto-connect so an autoconnect launch goes live without a
            // manual tap. The clipboard pair is skipped like the Mac's — an E2E run must not mirror
            // the developer's real pasteboard onto the test host (or vice versa).
            loops.append(Task { [weak self] in
                guard let self else { return }
                if ClientComposition.hasTerminalAutoconnectHost() {
                    await connection.connect()
                } else {
                    // Video-only automation (the video host serves UDP only, no TCP listener): mark
                    // connected so the workspace mounts and the video pane opens its UDP flow.
                    connection.markConnectedForAutomation()
                }
            })
            return
        }
        loops.append(Task { await monitor.run() })
        loops.append(Task { await sync.run() })
        // AUTO-RECONNECT (Goal B): a normal launch silently re-connects to the MRU host. No-op under
        // any AUTOCONNECT env (automation keeps precedence); SLOPDESK_SKIP_AUTO_RECONNECT=1 off.
        loops.append(Task { [weak self] in await self?.connection.connectIfSavedTarget() })
    }

    // MARK: The tail of the chain

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, take(PhoneKey.Press(key)) else {
                unhandled.insert(press)
                continue
            }
        }
        // Anything this rung did not spend still belongs to whatever is behind it (nothing, here) —
        // forwarded rather than dropped, so the chain's contract is unchanged for every other key.
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// Takes the press, or reports that it was never ours.
    private func take(_ press: PhoneKey.Press) -> Bool {
        pressRung = rung
        switch pressRung {
        case .yield:
            return false
        case .panelEscape:
            // No ⌃⇥ walk under the cover: the card it draws is over the workspace the cover is
            // covering, and stepping it would move a focus the reader cannot see land.
            return swallowsAsWorkspaceChord(press)
        case .workspace:
            // The walk is asked FIRST, exactly as it is in the pane's responder and in the Mac's
            // monitor: one key means open, step or commit depending on whether the walk is already
            // up, which no table row can say.
            if store.takePaneSwitcherKey(press) { return true }
            return swallowsAsWorkspaceChord(press)
        }
    }

    /// Which rung the live state puts this press on. Read per press — a cover can be dismissed and a
    /// card raised between two keystrokes, and a remembered copy would answer for a screen that is
    /// gone.
    private var rung: PhoneRootKeyRung {
        PhoneRootKeyPolicy.rung(
            panelPresented: !chrome.codeSidebarCollapsed,
            overlayCapturesKeyboard: overlayCoordinator.capturesKeyboardWhileVisible,
            systemPresentationUp: Self.systemPresentationUp(),
        )
    }

    /// Whether the workspace's binding table claims this press, through the interceptor the store
    /// minted. A refused chord forwards; a claimed one has already been routed by the time this
    /// returns.
    private func swallowsAsWorkspaceChord(_ press: PhoneKey.Press) -> Bool {
        guard let chord = PhoneKey.keyChord(for: press),
              let interceptor,
              case .swallow = interceptor.intercept(chord)
        else { return false }
        return true
    }

    /// Whether anything is presented over the workspace — Settings, the first-launch checklist, the
    /// cheat sheet.
    ///
    /// Asked of UIKit rather than of three `@State` flags, and that is the honest source: they are
    /// PRESENTATIONS, so the presenter already records them, and a flag threaded up here would be a
    /// second copy of a fact the window manager keeps. It reports the panel's cover too — which is
    /// why ``PhoneRootKeyPolicy`` asks about the cover first.
    private static func systemPresentationUp() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
}
#endif
