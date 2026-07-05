// WorkspaceKeyDispatcher — the LIVE keybinding dispatcher (WS-B / B3).
//
// THE re-scope: docs/DECISIONS.md previously recorded "there is no NSEvent monitor — a binding absent from
// the menu is a dead chord" (the ⌘⇧I sync-input note). That rule held while every workspace chord was a
// single ⌘/⌥-prefixed shortcut a SwiftUI `.commands` menu could express. The WS-B prefix engine breaks that
// premise: a tmux/zellij-style MULTI-KEY prefix (e.g. ⌃A then D) cannot be expressed by `.keyboardShortcut`,
// and — more importantly — a `.commands` menu cannot SWALLOW the follow-up key BEFORE the terminal first
// responder (libghostty's `GhosttyLayerBackedView`) sees it, so the second key of a sequence would leak into
// the PTY. Hence ONE app-level `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` installed at launch.
// docs/DECISIONS.md is updated to record this re-scope (per CLAUDE.md "update DECISIONS.md when re-scoping").
//
// CONTRACT (the load-bearing rule): a BARE unmodified key MUST pass through untouched — normal typing always
// reaches the PTY/video responder. The monitor only intercepts:
//   • the configured prefix (arm / send-prefix double-tap),
//   • armed-state follow-up keys (resolve a bound chord/sequence, or swallow an unbound one), and
//   • bound single chords (the existing ⌘D/⌘T/… table, override-aware via `resolvedChordTable`).
// Everything else returns the event UNCHANGED so it flows to the focused responder.
//
// PURITY: the NSEvent→`KeyChord` normalization is factored into the pure, AppKit-free `KeyChordNormalizer`
// (mirroring GhosttyTerminalView's `ghosttyMods` + `charactersIgnoringModifiers` for parity) so the chord
// mapping is unit-tested headlessly; the transition logic lives entirely in the pure `PrefixStateMachine`
// (B2). Only the thin NSEvent→intent wiring lives here.

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
    /// wires these to its `@State`; omitted here keeps those actions graceful no-ops. E1/WI-7 widens the
    /// construction so E2 can thread `toggleFind`/`togglePeekReply` without re-touching this seam (nil OK in
    /// E1 — those overlays don't exist yet, so the corresponding actions stay graceful no-ops via `route`).
    private let togglePalette: (() -> Void)?
    private let toggleCheatSheet: (() -> Void)?
    private let toggleFind: (() -> Void)?
    private let togglePeekReply: (() -> Void)?
    /// E5 / WI-4: the cross-tab Global Search overlay toggle (⇧⌘F). View-overlay state (the
    /// ``OverlayCoordinator``), so it is passed in as a closure like `togglePalette`; `nil` (the headless /
    /// test default) keeps `.globalSearch` a graceful no-op via `route` — never a dead chord.
    private let toggleGlobalSearch: (() -> Void)?
    /// E10 / WI-8: the Jump-To panel toggle (⌘J). View-overlay state (the ``OverlayCoordinator``), so it is
    /// passed in as a closure like `toggleGlobalSearch`; `nil` (the headless / test default) keeps `.jumpTo`
    /// a graceful no-op via `route` — never a dead chord. E11 re-points the app's `⌘J` binding to "open
    /// Open-Quickly at `.current`" (the folded-in Jump-To); the dispatcher still threads it as `toggleJumpTo`.
    private let toggleJumpTo: (() -> Void)?
    /// E11 / WI-7: the Open-Quickly picker toggle (⌘⇧O → the merged `.all` pill). View-overlay state (the
    /// ``OverlayCoordinator`` owns `openQuicklyVisible`/`openQuicklyFilter`), so it is passed in as a closure
    /// like `toggleJumpTo`; `nil` (the headless / test default) keeps `.openQuickly` a graceful no-op via
    /// `route` — never a dead chord. ⌘⇧O (this) and ⌘J (`toggleJumpTo`) are the ONLY global Open-Quickly
    /// chords — the pill / ⌘1–9 / Tab / ⌘K chords are PICKER-LOCAL (handled in `OpenQuicklyView`).
    private let toggleOpenQuickly: (() -> Void)?
    /// The left sidebar / Tabs-panel toggle (⌘⇧L). View-owned `@State`:
    /// the macOS sidebar collapse is `WorkspaceChromeState.sidebarCollapsed` (the native split reads it), NOT
    /// the legacy `store.sidebarCollapsed`, so the root view installs the real closure via
    /// ``setToggleSidebar(_:)`` on appear. Until then `nil` ⇒ `.toggleSidebar` falls back to the store flag in
    /// `route` (a non-trapping graceful op), never a dead chord.
    private var toggleSidebar: (() -> Void)?
    /// E19/A30 (WI-4): "Pin Window" (View ▸ Pin Window). View-owned `@State` (`WorkspaceChromeState`), so
    /// it is installed late by the root view via ``setTogglePinWindow(_:)`` once the chrome exists. Pin Window
    /// is CHORD-LESS by default (no chord ships out of the box), so this fires only if a user binds a chord to the
    /// `.pinWindow` action; until installed `nil` ⇒ `.pinWindow` is a graceful no-op (never a dead chord).
    private var togglePinWindow: (() -> Void)?
    /// E3 WI-4 (audit fix): the "Close Window" actuator (⌘⇧W / View ▸ Close Window). A macOS
    /// `NSWindow.performClose(_:)` concern, so it is installed late by the app via ``setCloseWindow(_:)`` once
    /// the scene's window is captured; the app wires it to `window.performClose(nil)`, which fires the native
    /// `windowShouldClose` → the existing window-close confirmation gate. Until installed `nil` ⇒ `.closeWindow`
    /// falls back to `store.requestCloseWindow()` in `route` (a non-trapping graceful park), never a dead chord.
    private var closeWindow: (() -> Void)?

    /// E11 review fix: a predicate the monitor consults BEFORE resolving any chord — `true` while a
    /// keyboard-capturing overlay (the Open-Quickly picker) is presented. The app NSEvent monitor is built to
    /// PREEMPT the responder chain (a multi-key prefix can't be a `.commands` menu item), so without this gate
    /// every globally-bound ⌘-chord is resolved + SWALLOWED before the picker's `.onKeyPress` runs — ⌘1–9 would
    /// switch the tab BEHIND the picker (instead of quick-picking the Nth result) and ⌘W would DESTRUCTIVELY
    /// close the focused pane/session behind the open picker. When this returns `true` the monitor behaves like
    /// a modal sheet and YIELDS the whole keyboard to the focused overlay: every key passes through UNCHANGED so
    /// the picker owns its picker-local chords (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J, ⌘1–9, ⌘K), and Esc / a scrim-tap close it.
    /// `{ false }` (the headless / test default) keeps the at-rest behaviour byte-identical; ⌘⇧O / ⌘J stay the
    /// GLOBAL entry chords only while the picker is HIDDEN (they open it).
    private let isOverlayCapturingKeys: () -> Bool

    /// A predicate the monitor consults FIRST — `true` only while the WORKSPACE window is the key window. The
    /// app NSEvent monitor is application-wide (a `.keyDown` local monitor fires for events delivered to ANY
    /// window in this process), so without this gate a bound chord typed while the separate stock SwiftUI
    /// Settings scene window (⌘,) — or an attached sheet (first-launch / close-confirm) — is
    /// key resolves against the HIDDEN main-window workspace tree and is swallowed before the Settings window
    /// ever sees it: ⌘W closes a background terminal pane while Settings refuses to close, ⌘T/⌘D/⌘1–9 mutate
    /// the hidden tree, and the keybindings recorder is starved (this monitor eats the chord it is trying to
    /// record). When this returns `false` every key passes through UNCHANGED so the frontmost Settings window /
    /// sheet owns its own keystrokes. `{ true }` (the headless / test default) keeps the at-rest behaviour
    /// byte-identical — a test with no real window server always reports the workspace as key.
    private let isWorkspaceWindowKey: () -> Bool

    /// Keyboard-improvement (prefix-armed indicator): reports every ARMED edge of the prefix machine — `true`
    /// when the prefix arms, `false` on ANY disarm (a resolved follow-up, an unbound follow-up, the double-tap
    /// send-prefix, or the escape TIMEOUT via ``armExpiryTask``). The app wires this to
    /// ``OverlayCoordinator/setPrefixArmed(_:)`` so the workspace chip shows exactly while a follow-up key is
    /// awaited. `{ _ in }` (the headless / test default) keeps the dispatcher inert without a UI.
    private let onPrefixArmedChange: (Bool) -> Void

    /// The pure prefix machine (B2). Its sequence resolver reads the override-aware `resolvedSequenceTable`
    /// (single-chord fallback to `resolvedChordTable`) so a rebind — single OR multi-key — takes effect; the
    /// prefix chord itself is configurable (defaults to the store's live `workspaceKeyPrefix`).
    private let machine: PrefixStateMachine

    /// The pending armed-timeout expiry: scheduled when the prefix arms, cancelled on the next keystroke.
    /// The machine itself is clock-lazy (a stale arm expires only when `feed`/`expireIfStale` runs), so
    /// WITHOUT this task an abandoned arm would leave the indicator lit until the next keypress. Firing it
    /// calls `expireIfStale` (idempotent) and reports the `false` edge.
    private var armExpiryTask: Task<Void, Never>?

    private var monitor: Any?

    /// - Parameter prefix: the configured prefix chord. Pass `nil` (the default) to adopt the store's live
    ///   ``WorkspaceStore/workspaceKeyPrefix`` so the app monitor and the per-surface ``TerminalKeyInterceptor``
    ///   arm on ONE shared, configured prefix (no split-brain when the prefix is moved off ⌃A). An explicit
    ///   value overrides the store (test seam).
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
        // The prefix machine resolves a post-prefix key against the override-aware SEQUENCE table FIRST (so a
        // multi-key prefix sequence whose tail key is not a standalone binding still fires), falling back to
        // the SINGLE-CHORD table (so the seeded ⌃A→⌘D, where ⌘D is also a standalone chord, keeps working and
        // an override is honoured). The prefix itself defaults to the store's live `workspaceKeyPrefix`.
        machine = PrefixStateMachine(
            prefix: prefix ?? store.workspaceKeyPrefix,
            resolveAfterPrefix: { chord in WorkspaceBindingRegistry.resolvedChordTable[chord] },
            resolveSequenceAfterPrefix: { sequence in WorkspaceBindingRegistry.resolvedSequenceTable[sequence] },
        )
    }

    /// Re-point the configured prefix (a settings change moved it off ⌃A). Keeps the app monitor and the
    /// per-surface interceptors arming on ONE shared prefix.
    func setPrefix(_ chord: KeyChord) { machine.prefix = chord }

    /// Re-tune the armed escape timeout (seconds). Internal seam — the indicator timeout test shrinks it so
    /// the expiry edge is observable without a 1 s wait; the machine clamps a negative/NaN value itself.
    func setPrefixTimeout(_ timeout: TimeInterval) { machine.timeout = timeout }

    /// Install the left sidebar / Tabs-panel toggle once the `WorkspaceChromeState` exists (the root view
    /// wires this to `chrome.toggleSidebar` on appear). Without it, ⌘⇧L resolves to `.toggleSidebar` and
    /// `route` falls back to the legacy `store.sidebarCollapsed` (which nothing reads on macOS) — so this
    /// closure makes ⌘⇧L actually collapse the native sidebar item ("Toggle Tabs Panel").
    func setToggleSidebar(_ toggle: @escaping () -> Void) { toggleSidebar = toggle }

    /// Install the "Pin Window" toggle once the `WorkspaceChromeState` exists (the root view wires this to
    /// `chrome.togglePin()` on appear). Pin Window is chord-less by default, so this only fires when a user
    /// binds a chord to the `.pinWindow` action; until installed `.pinWindow` is a graceful no-op.
    func setTogglePinWindow(_ toggle: @escaping () -> Void) { togglePinWindow = toggle }

    /// Install the "Close Window" actuator once the scene's `NSWindow` is captured (the app wires this to
    /// `window.performClose(nil)`, which fires `windowShouldClose` → the existing window-close confirmation
    /// gate). Until installed, `.closeWindow` falls back to `store.requestCloseWindow()` in `route` (a
    /// non-trapping graceful park), so ⌘⇧W is never a dead chord. The closure makes ⌘⇧W ACTUATE a close
    /// (the audit found the bare store-park path never closed anything — it had no SwiftUI observer).
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

    /// Remove the monitor (app-lifetime in practice, so rarely called — exposed for completeness / tests).
    /// No `deinit`-time removal: the monitor captures `self` weakly and the dispatcher lives for the whole
    /// process, and a `nonisolated deinit` cannot touch the non-`Sendable` monitor token anyway.
    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        armExpiryTask?.cancel()
        armExpiryTask = nil
    }

    /// Map one `NSEvent` keystroke to swallow (`nil`) or pass-through (the event), routing any resolved
    /// action through `WorkspaceBindingRegistry.route(...)`. Pure transition logic lives in the machine; this
    /// only does NSEvent→chord normalization + the intent→effect wiring. `internal` (not `private`) so the
    /// modal-yield gate below is unit-testable headlessly via `@testable` (it constructs a synthetic NSEvent,
    /// never a window-server resource — the hang-safety rule is about SCStream/VT/Metal, not NSEvent).
    func handle(_ event: NSEvent) -> NSEvent? {
        // KEY-WINDOW GATE: the monitor is application-wide, but every workspace chord is meaningful ONLY when
        // the workspace window holds focus. If a separate window is key — the stock Settings scene (⌘,), or an
        // attached sheet — pass EVERY key through UNCHANGED so that window receives its own keystrokes (and the
        // keybindings recorder can capture the chord it is trying to record) instead of this monitor resolving
        // + swallowing it against the hidden workspace tree behind them.
        if !isWorkspaceWindowKey() { return event }
        // MODAL YIELD: while a keyboard-capturing overlay (the Open-Quickly picker) is presented, this monitor
        // — which PREEMPTS the responder chain — must NOT resolve the global chord table behind it, or ⌘1–9
        // would switch the BACKGROUND tab (instead of quick-picking the Nth result) and ⌘W would DESTROY the
        // focused pane behind the open picker. Yield the whole keyboard to it like a modal sheet: pass every
        // key through UNCHANGED so the picker's `.onKeyPress` owns its picker-local chords (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J,
        // ⌘1–9, ⌘K) and Esc / a scrim-tap close it. (⌘⇧O / ⌘J are global only while the picker is hidden.)
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
            // E1/WI-7: a user `text:`/`csi:`/`esc:` config binding (a literal-byte binding) resolves
            // BEFORE the action table — the chord sends its already-resolved bytes (ESC/CSI lead bytes baked
            // in by `KeybindGrammar`) to the focused pane and is swallowed.
            if let textBinding = WorkspaceBindingRegistry.textBinding(for: passed) {
                if let active = activePaneID {
                    store.handle(for: active)?.sendBytes(textBinding.payload)
                }
                return nil // swallow — the text binding owns this chord
            }
            // An `unbind:` target suppresses its DEFAULT action: pass the event straight through to the
            // focused responder (the terminal/video pane handles it) instead of firing the registry action.
            if WorkspaceBindingRegistry.isUnbound(passed) {
                return event
            }
            // Idle + an unbound key: a workspace single chord still resolves here (the machine only owns the
            // prefix-sequence path). A plain/Ctrl-letter the table does not bind falls through to the PTY.
            if let action = WorkspaceBindingRegistry.resolvedChordTable[passed] {
                dispatch(action)
                return nil // swallow — the workspace owns this chord
            }
            return event // bare typing / unbound chord → reaches the focused responder UNCHANGED

        case .consumedArm:
            return nil // armed on the prefix; swallow it (never leak the prefix to the terminal)

        case let .resolved(action):
            dispatch(action)
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
