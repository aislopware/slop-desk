// WorkspaceKeyDispatcher — the LIVE keybinding dispatcher.
//
// A "no NSEvent monitor — an off-menu binding is a dead chord" rule (DECISIONS.md, the ⌘⇧I sync-input
// note) only holds while every chord is a single ⌘/⌥ shortcut a SwiftUI `.commands` menu can express.
// A tmux/zellij MULTI-KEY prefix (⌃B then D) can't be a `.keyboardShortcut`, and a `.commands` menu can't
// SWALLOW the follow-up key BEFORE the terminal first responder (libghostty's `GhosttyLayerBackedView`)
// sees it — so the second key would leak into the PTY. Hence ONE app-level
// `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` installed at launch. DECISIONS.md records the scope.
//
// CONTRACT (load-bearing): a BARE unmodified key MUST pass through untouched — normal typing always reaches
// the PTY/video responder. The monitor only intercepts:
//   • the configured prefix (arm / send-prefix double-tap),
//   • armed-state follow-up keys (resolve a bound chord/sequence, or swallow an unbound one), and
//   • bound single chords (the ⌘D/⌘T/… table, override-aware via `resolvedChordTable`).
// Everything else returns the event UNCHANGED.
//
// PURITY: NSEvent→`KeyChord` normalization lives in the pure, AppKit-free `KeyChordNormalizer` (mirrors
// GhosttyTerminalView's `ghosttyMods` + `charactersIgnoringModifiers` for parity) so it's unit-tested
// headlessly; transition logic lives in the pure `PrefixStateMachine`. Only NSEvent→intent wiring is here.

#if os(macOS)
import AppKit
import SlopDeskWorkspaceCore

/// Owns the app-level `.keyDown` local monitor and the pure `PrefixStateMachine`, turning each keystroke
/// into a `WorkspaceBindingRegistry.route(...)` call (single chord OR completed prefix sequence) or a
/// passthrough. `@MainActor` — installed once at app launch and retained for the process lifetime.
@MainActor
final class WorkspaceKeyDispatcher {
    private let store: WorkspaceStore
    /// The view-overlay toggles `route(...)` takes (palette / cheat sheet / find / peek-reply). The live app
    /// wires these to its `@State`; `nil` keeps those actions graceful no-ops via `route`.
    private let togglePalette: (() -> Void)?
    private let toggleCheatSheet: (() -> Void)?
    private let toggleFind: (() -> Void)?
    private let togglePeekReply: (() -> Void)?
    /// The cross-tab Global Search overlay toggle (⇧⌘F). ``OverlayCoordinator`` state, passed as a closure;
    /// `nil` (headless / test default) keeps `.globalSearch` a graceful no-op via `route` — never a dead chord.
    private let toggleGlobalSearch: (() -> Void)?
    /// The Jump-To panel toggle (⌘J). ``OverlayCoordinator`` state, passed as a closure; `nil` (headless /
    /// test default) keeps `.jumpTo` a graceful no-op via `route` — never a dead chord. ⌘J opens Open-Quickly
    /// at `.current` (Jump-To is folded into it); still threaded here as `toggleJumpTo`.
    private let toggleJumpTo: (() -> Void)?
    /// The Open-Quickly picker toggle (⌘⇧O → the merged `.all` pill). ``OverlayCoordinator`` state
    /// (`openQuicklyVisible`/`openQuicklyFilter`), passed as a closure; `nil` (headless / test default) keeps
    /// `.openQuickly` a graceful no-op via `route` — never a dead chord. ⌘⇧O (this) and ⌘J (`toggleJumpTo`)
    /// are the ONLY global Open-Quickly chords — the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL (in
    /// `OpenQuicklyView`).
    private let toggleOpenQuickly: (() -> Void)?
    /// The left sidebar / Tabs-panel toggle (⌘⇧L). View-owned `@State`: macOS collapse is
    /// `WorkspaceChromeState.sidebarCollapsed` (the native split reads it), NOT the legacy
    /// `store.sidebarCollapsed`, so the root view installs the real closure via ``setToggleSidebar(_:)`` on
    /// appear. Until then `nil` ⇒ `.toggleSidebar` falls back to the store flag in `route` — never a dead chord.
    private var toggleSidebar: (() -> Void)?
    /// "Pin Window" (View ▸ Pin Window). View-owned `@State` (`WorkspaceChromeState`), installed late by the
    /// root view via ``setTogglePinWindow(_:)`` once the chrome exists. Pin Window is CHORD-LESS by default, so
    /// this fires only if a user binds a chord to `.pinWindow`; until installed `nil` ⇒ graceful no-op.
    private var togglePinWindow: (() -> Void)?
    /// The "Close Window" actuator (⌘⇧W / View ▸ Close Window). An `NSWindow.performClose(_:)` concern,
    /// installed late by the app via ``setCloseWindow(_:)`` once the scene's window is captured; wired to
    /// `window.performClose(nil)`, which fires `windowShouldClose` → the existing close-confirmation gate.
    /// Until installed `nil` ⇒ `.closeWindow` falls back to `store.requestCloseWindow()` in `route` — never a
    /// dead chord.
    private var closeWindow: (() -> Void)?

    /// A predicate the monitor consults BEFORE resolving any chord — `true` while a keyboard-capturing overlay
    /// (the Open-Quickly picker) is presented. The monitor PREEMPTS the responder chain (a multi-key prefix
    /// can't be a `.commands` menu item), so without this gate every global ⌘-chord is resolved + SWALLOWED
    /// before the picker's `.onKeyPress` runs — ⌘1–9 would switch the tab BEHIND the picker and ⌘W would
    /// DESTRUCTIVELY close the focused pane behind it. When `true` the monitor yields the whole keyboard like a
    /// modal sheet: every key passes through UNCHANGED so the picker owns its picker-local chords
    /// (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J, ⌘1–9, ⌘K), and Esc / a scrim-tap close it. `{ false }` (headless / test default)
    /// keeps at-rest behaviour byte-identical; ⌘⇧O / ⌘J are GLOBAL entry chords only while the picker is HIDDEN.
    private let isOverlayCapturingKeys: () -> Bool

    /// A predicate the monitor consults FIRST — `true` only while the WORKSPACE window is key. The monitor is
    /// application-wide (a `.keyDown` local monitor fires for events to ANY window in this process), so without
    /// this gate a chord typed while the stock Settings window (⌘,) — or an attached sheet (first-launch /
    /// close-confirm) — is key resolves against the HIDDEN workspace tree and is swallowed before Settings sees
    /// it: ⌘W closes a background pane while Settings refuses to close, ⌘T/⌘D/⌘1–9 mutate the hidden tree, and
    /// the keybindings recorder is starved (this monitor eats the chord it is recording). When `false` every key
    /// passes through UNCHANGED so the frontmost window / sheet owns its keystrokes. `{ true }` (headless / test
    /// default) keeps at-rest behaviour byte-identical — a test with no window server reports workspace as key.
    private let isWorkspaceWindowKey: () -> Bool

    /// Prefix-armed indicator: reports every ARMED edge — `true` when the prefix arms, `false` on ANY disarm
    /// (resolved follow-up, unbound follow-up, double-tap send-prefix, or the escape TIMEOUT via
    /// ``armExpiryTask``). The app wires this to ``OverlayCoordinator/setPrefixArmed(_:)`` so the chip shows
    /// exactly while a follow-up key is awaited. `{ _ in }` (headless / test default) keeps the dispatcher inert.
    private let onPrefixArmedChange: (Bool) -> Void

    /// Fired whenever an action resolves through the PREFIX path — a bound follow-up chord OR the
    /// tmux-faithful implied-⌘ fold (`⌃B, ⇧i` → the ⌘⇧I binding). The app wires this to a toast naming
    /// the action, because the fold makes workspace actions reachable from TWO stray terminal keystrokes
    /// (`⌃B` is readline back-char / vi page-up) and a silently-fired MODE toggle reads as a bug: the
    /// field report "two panes leaking into each other" was sync-input armed exactly this way, with no
    /// feedback. A direct single chord (⌘⇧I typed deliberately) does NOT fire this — only prefix
    /// resolutions, where the user's intent is least certain. `nil` (headless / test default) is inert.
    private let onPrefixActionFired: ((WorkspaceAction) -> Void)?

    /// The pure prefix machine. Its sequence resolver reads the override-aware `resolvedSequenceTable`
    /// (single-chord fallback to `resolvedChordTable`) so a rebind — single OR multi-key — takes effect; the
    /// prefix chord is configurable (defaults to the store's live `workspaceKeyPrefix`).
    private let machine: PrefixStateMachine

    /// The pending armed-timeout expiry: scheduled when the prefix arms, cancelled on the next keystroke.
    /// The machine is clock-lazy (a stale arm expires only when `feed`/`expireIfStale` runs), so WITHOUT this
    /// an abandoned arm would leave the indicator lit until the next keypress. Firing calls `expireIfStale`
    /// (idempotent) and reports the `false` edge.
    private var armExpiryTask: Task<Void, Never>?

    private var monitor: Any?

    /// - Parameter prefix: the configured prefix chord. Pass `nil` (default) to adopt the store's live
    ///   ``WorkspaceStore/workspaceKeyPrefix`` so the app monitor and the per-surface ``TerminalKeyInterceptor``
    ///   arm on ONE shared prefix (no split-brain when the prefix moves off the ⌃B default). An explicit value overrides the
    ///   store (test seam).
    init(
        store: WorkspaceStore,
        prefix: KeyChord? = nil,
        togglePalette: (() -> Void)? = nil,
        toggleCheatSheet: (() -> Void)? = nil,
        toggleFind: (() -> Void)? = nil,
        togglePeekReply: (() -> Void)? = nil,
        toggleSidebar: (() -> Void)? = nil,
        toggleGlobalSearch: (() -> Void)? = nil,
        toggleJumpTo: (() -> Void)? = nil,
        toggleOpenQuickly: (() -> Void)? = nil,
        togglePinWindow: (() -> Void)? = nil,
        isOverlayCapturingKeys: @escaping () -> Bool = { false },
        isWorkspaceWindowKey: @escaping () -> Bool = { true },
        onPrefixArmedChange: @escaping (Bool) -> Void = { _ in },
        onPrefixActionFired: ((WorkspaceAction) -> Void)? = nil,
    ) {
        self.store = store
        self.togglePalette = togglePalette
        self.toggleCheatSheet = toggleCheatSheet
        self.toggleFind = toggleFind
        self.togglePeekReply = togglePeekReply
        self.toggleSidebar = toggleSidebar
        self.toggleGlobalSearch = toggleGlobalSearch
        self.toggleJumpTo = toggleJumpTo
        self.toggleOpenQuickly = toggleOpenQuickly
        self.togglePinWindow = togglePinWindow
        self.isOverlayCapturingKeys = isOverlayCapturingKeys
        self.isWorkspaceWindowKey = isWorkspaceWindowKey
        self.onPrefixArmedChange = onPrefixArmedChange
        self.onPrefixActionFired = onPrefixActionFired
        // Resolve a post-prefix key against the override-aware SEQUENCE table FIRST (so a multi-key sequence
        // whose tail key isn't a standalone binding still fires), falling back to the SINGLE-CHORD table (so the
        // seeded ⌃B→⌘D keeps working and an override is honoured). Prefix defaults to the store's live
        // `workspaceKeyPrefix`.
        machine = PrefixStateMachine(
            prefix: prefix ?? store.workspaceKeyPrefix,
            resolveAfterPrefix: { chord in WorkspaceBindingRegistry.resolvedChordTable[chord] },
            resolveSequenceAfterPrefix: { sequence in WorkspaceBindingRegistry.resolvedSequenceTable[sequence] },
        )
    }

    /// Re-point the configured prefix (a settings change moved it off the default). Keeps the app monitor and the
    /// per-surface interceptors arming on ONE shared prefix.
    func setPrefix(_ chord: KeyChord) { machine.prefix = chord }

    /// Re-tune the armed escape timeout (seconds). Internal seam — the indicator timeout test shrinks it so
    /// the expiry edge is observable without a 1 s wait; the machine clamps a negative/NaN value itself.
    func setPrefixTimeout(_ timeout: TimeInterval) { machine.timeout = timeout }

    /// Install the left sidebar / Tabs-panel toggle once `WorkspaceChromeState` exists (the root view wires
    /// this to `chrome.toggleSidebar` on appear). Without it ⌘⇧L falls back to `store.sidebarCollapsed` (which
    /// nothing reads on macOS); this closure makes ⌘⇧L actually collapse the native sidebar item.
    func setToggleSidebar(_ toggle: @escaping () -> Void) { toggleSidebar = toggle }

    /// Install the "Pin Window" toggle once the `WorkspaceChromeState` exists (the root view wires this to
    /// `chrome.togglePin()` on appear). Pin Window is chord-less by default, so this only fires when a user
    /// binds a chord to the `.pinWindow` action; until installed `.pinWindow` is a graceful no-op.
    func setTogglePinWindow(_ toggle: @escaping () -> Void) { togglePinWindow = toggle }

    /// Install the "Close Window" actuator once the scene's `NSWindow` is captured (the app wires this to
    /// `window.performClose(nil)`, which fires `windowShouldClose` → the existing close-confirmation gate).
    /// Until installed, `.closeWindow` falls back to `store.requestCloseWindow()` in `route` — never a dead
    /// chord. The closure makes ⌘⇧W ACTUATE a close (the bare store-park path never closed anything — no
    /// SwiftUI observer).
    func setCloseWindow(_ close: @escaping () -> Void) { closeWindow = close }

    /// Install the `.keyDown` local monitor. Returning `nil` from the handler SWALLOWS the event; returning
    /// the event passes it through to the focused responder (the terminal / video pane).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
    }

    /// Remove the monitor (app-lifetime, so rarely called — exposed for tests). No `deinit`-time removal: the
    /// monitor captures `self` weakly and the dispatcher lives the whole process, and a `nonisolated deinit`
    /// cannot touch the non-`Sendable` monitor token anyway.
    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        armExpiryTask?.cancel()
        armExpiryTask = nil
    }

    /// Map one `NSEvent` keystroke to swallow (`nil`) or pass-through (the event), routing any resolved action
    /// through `WorkspaceBindingRegistry.route(...)`. Pure transition logic lives in the machine; this does
    /// NSEvent→chord normalization + intent→effect wiring. `internal` (not `private`) so the modal-yield gate
    /// is unit-testable via `@testable` (a synthetic NSEvent is not a window-server resource — the hang-safety
    /// rule is about SCStream/VT/Metal, not NSEvent).
    func handle(_ event: NSEvent) -> NSEvent? {
        // KEY-WINDOW GATE: the monitor is application-wide, but a workspace chord is meaningful ONLY when the
        // workspace window holds focus. If a separate window is key (Settings, a sheet), pass EVERY key through
        // UNCHANGED so that window (and the keybindings recorder) receives its own keystrokes instead of this
        // monitor resolving + swallowing against the hidden workspace tree.
        if !isWorkspaceWindowKey() { return event }
        // MODAL YIELD: while a keyboard-capturing overlay (the Open-Quickly picker) is presented, this monitor
        // — which PREEMPTS the responder chain — must NOT resolve the global chord table behind it, or ⌘1–9
        // would switch the BACKGROUND tab and ⌘W would DESTROY the focused pane behind it. Pass every key
        // through UNCHANGED so the picker's `.onKeyPress` owns its picker-local chords (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J,
        // ⌘1–9, ⌘K); Esc / a scrim-tap close it. (⌘⇧O / ⌘J are global only while the picker is hidden.)
        if isOverlayCapturingKeys() { return event }
        // A keystroke that does not normalize to a chord we model (a pure modifier, a dead key, …) is left
        // untouched — never swallow what we cannot classify.
        guard let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifierFlags: KeyChordNormalizer.Modifiers(
                shift: event.modifierFlags.contains(.shift),
                control: event.modifierFlags.contains(.control),
                option: event.modifierFlags.contains(.option),
                command: event.modifierFlags.contains(.command),
            ),
        ) else { return event }

        let intent = machine.feed(chord, at: ProcessInfo.processInfo.systemUptime)
        // Every fed keystroke re-syncs the "prefix armed" indicator (arm lights it; ANY disarm — resolved /
        // unbound / double-tap — clears it; a fresh arm re-schedules the timeout expiry).
        syncPrefixArmedIndicator()
        switch intent {
        case let .passthrough(passed):
            // A user `text:`/`csi:`/`esc:` literal-byte binding resolves BEFORE the action table — the chord
            // sends its already-resolved bytes (ESC/CSI lead bytes baked in by `KeybindGrammar`) to the focused
            // pane and is swallowed.
            if let textBinding = WorkspaceBindingRegistry.textBinding(for: passed) {
                if let active = activePaneID {
                    store.handle(for: active)?.sendBytes(textBinding.payload)
                }
                return nil // swallow — the text binding owns this chord
            }
            // An `unbind:` target suppresses its DEFAULT action: pass the event through to the focused
            // responder instead of firing the registry action.
            if WorkspaceBindingRegistry.isUnbound(passed) {
                return event
            }
            // Idle: a workspace single chord still resolves here (the machine only owns the prefix-sequence
            // path). A plain/Ctrl-letter the table doesn't bind falls through to the PTY.
            if let action = WorkspaceBindingRegistry.resolvedChordTable[passed] {
                dispatch(action)
                return nil // swallow — the workspace owns this chord
            }
            return event // bare typing / unbound chord → reaches the focused responder UNCHANGED

        case .consumedArm:
            return nil // armed on the prefix; swallow it (never leak the prefix to the terminal)

        case let .resolved(action):
            dispatch(action)
            // Announce the PREFIX-fired action (toast seam): the implied-⌘ fold makes this reachable
            // from two stray terminal keystrokes, so it must never fire silently.
            onPrefixActionFired?(action)
            return nil // a bound key resolved while armed → run + swallow

        case .sendPrefixLiteral:
            // Double-tap the prefix (tmux `send-prefix`): emit the literal prefix byte to the focused pane,
            // then swallow. The prefix chord's C0 byte is what the terminal would have received raw.
            if let bytes = KeyChordNormalizer.literalBytes(for: machine.prefix),
               let active = activePaneID
            {
                store.handle(for: active)?.sendBytes(bytes)
            }
            return nil

        case .disarmSwallow:
            return nil // an unbound key while armed (tmux-faithful: disarm + eat the key, prefix not replayed)
        }
    }

    /// Report the machine's armed state to the indicator seam and (re-)schedule the timeout expiry. Called
    /// after every `feed`: a disarm cancels any pending expiry; an arm schedules one at `machine.timeout` + a
    /// small epsilon, which expires the stale arm (`expireIfStale` — idempotent, keystroke-safe: a keystroke
    /// that landed first already cancelled this task) and reports the `false` edge so the chip never stays
    /// lit after an abandoned prefix.
    private func syncPrefixArmedIndicator() {
        armExpiryTask?.cancel()
        armExpiryTask = nil
        onPrefixArmedChange(machine.isArmed)
        guard machine.isArmed else { return }
        let delay = machine.timeout + 0.05
        armExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            machine.expireIfStale(at: ProcessInfo.processInfo.systemUptime)
            if !machine.isArmed { onPrefixArmedChange(false) }
            armExpiryTask = nil
        }
    }

    /// The active pane id (the send-prefix-literal target). `nil` when no pane is focused (the send is then a
    /// no-op, which is correct — there is nothing to type into).
    private var activePaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func dispatch(_ action: WorkspaceAction) {
        WorkspaceBindingRegistry.route(
            action,
            to: store,
            togglePalette: togglePalette,
            toggleCheatSheet: toggleCheatSheet,
            toggleFind: toggleFind,
            togglePeekReply: togglePeekReply,
            toggleSidebar: toggleSidebar,
            toggleGlobalSearch: toggleGlobalSearch,
            toggleJumpTo: toggleJumpTo,
            openQuickly: toggleOpenQuickly,
            togglePinWindow: togglePinWindow,
            closeWindow: closeWindow,
        )
    }
}
#endif
