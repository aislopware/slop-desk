// WorkspaceKeyDispatcher — the LIVE keybinding dispatcher.
//
// ONE app-level `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` installed at launch. A SwiftUI
// `.commands` menu alone cannot express everything the chord table needs: a user `text:`/`csi:`/`esc:`
// literal-byte binding must SWALLOW its chord and inject bytes before the terminal first responder
// (libghostty's `GhosttyLayerBackedView`) sees it, an `unbind:` must suppress a default without a menu
// edit, and ⌘D must be claimed before libghostty's own keymap eats it. DECISIONS.md records the scope
// (WS-B / B3; the tmux-style multi-key prefix that once shared this monitor is REMOVED — 2026-07-22).
//
// CONTRACT (load-bearing): a BARE unmodified key MUST pass through untouched — normal typing always reaches
// the PTY/video responder. The monitor only intercepts bound single chords (the ⌘D/⌘T/… table,
// override-aware via `resolvedChordTable`, plus `text:`-style literal-byte bindings). Everything else
// returns the event UNCHANGED.
//
// PURITY: NSEvent→`KeyChord` normalization lives in the pure, AppKit-free `KeyChordNormalizer` (mirrors
// GhosttyTerminalView's `ghosttyMods` + `charactersIgnoringModifiers` for parity) so it's unit-tested
// headlessly. Only NSEvent→intent wiring is here.

#if os(macOS)
import AppKit
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// Owns the app-level `.keyDown` local monitor, turning each keystroke into a
/// `WorkspaceBindingRegistry.route(...)` call (a bound single chord) or a passthrough. `@MainActor` —
/// installed once at app launch and retained for the process lifetime.
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
    /// (the Open-Quickly picker) is presented. The monitor PREEMPTS the responder chain (it fires before the
    /// first responder), so without this gate every global ⌘-chord is resolved + SWALLOWED before the
    /// picker's `.onKeyPress` runs — ⌘1–9 would switch the tab BEHIND the picker and ⌘W would
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

    private var monitor: Any?

    /// How long ⌘ must be held before the sidebar swaps in its ⌘-digit number hints. A HOLD threshold,
    /// not debounce polish: every ⌘-chord (⌘C, ⌘W, …) starts with the same `.flagsChanged` transition,
    /// and hint-on-⌘-down would flash the whole rail on each of them. Internal so tests can zero it
    /// (`.zero` flips the flag synchronously — no timer to await).
    var shortcutHintHoldDelay: Duration = .milliseconds(250)
    /// The pending hold timer — armed on the ⌘-down transition, cancelled by release / focus loss / a
    /// capturing overlay.
    private var shortcutHintTask: Task<Void, Never>?
    /// The LIVE modifier state (`NSEvent.modifierFlags`, the class property — hardware truth, not an
    /// event's snapshot). The hint's stuck-on guards read it, because the ⌘ KEY-UP is not guaranteed
    /// to reach this monitor: ⌘⇥ hands the release to the NEXT app, and menu tracking swallows it in
    /// its own event loop. Injectable so tests can hold/lift a phantom ⌘.
    var readLiveModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// Clears the hint when the APP deactivates (⌘⇥ away mid-hold) — the one exit where no further
    /// event of ANY kind reaches a local monitor, so neither the release path nor the keystroke
    /// self-heal below can run. Installed with the monitor.
    private var appResignObserver: NSObjectProtocol?

    init(
        store: WorkspaceStore,
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
    }

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

    /// Install the local monitor. Returning `nil` from the handler SWALLOWS the event; returning the event
    /// passes it through to the focused responder (the terminal / video pane).
    ///
    /// `.flagsChanged` rides the same monitor because the ⌃⇥ tab switcher COMMITS on the ⌃ key-up: a
    /// modifier transition is the end of that gesture, not a keystroke. Those events are always passed
    /// through — the monitor reads them, it never consumes them.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            // `queue: .main` delivers on the main queue; hop into the actor formally.
            MainActor.assumeIsolated { self?.updateShortcutHint(commandHeld: false) }
        }
    }

    /// Remove the monitor (app-lifetime, so rarely called — exposed for tests). No `deinit`-time removal: the
    /// monitor captures `self` weakly and the dispatcher lives the whole process, and a `nonisolated deinit`
    /// cannot touch the non-`Sendable` monitor token anyway.
    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let appResignObserver { NotificationCenter.default.removeObserver(appResignObserver) }
        appResignObserver = nil
        shortcutHintTask?.cancel()
        shortcutHintTask = nil
    }

    /// The ⌘-held NUMBER-HINT gesture: the sidebar swaps each row's leading run for its ⌘-digit
    /// (``WorkspaceStore/shortcutNumber(for:)``) while ⌘ has been held past ``shortcutHintHoldDelay``.
    /// Driven from `.flagsChanged` transitions — ⌘ going down arms the hold timer; ANY exit (release,
    /// key-window loss, a keyboard-capturing overlay, whose own ⌘1–9 mean picker rows, not sidebar
    /// panes) cancels the timer and clears the hint. The store holds the observable flag; this owns
    /// WHEN it flips.
    private func updateShortcutHint(commandHeld: Bool) {
        guard commandHeld, !isOverlayCapturingKeys() else {
            shortcutHintTask?.cancel()
            shortcutHintTask = nil
            store.setShortcutHintActive(false)
            return
        }
        // Already armed or already showing (a ⌘⇧/⌘⌥ transition mid-hold lands here) — nothing to do.
        guard shortcutHintTask == nil, !store.shortcutHintActive else { return }
        guard shortcutHintHoldDelay > .zero else {
            // The synchronous test path — the arming event itself just asserted ⌘ is down.
            store.setShortcutHintActive(true)
            return
        }
        shortcutHintTask = Task { [weak self, delay = shortcutHintHoldDelay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            shortcutHintTask = nil
            // RE-VALIDATE AT FIRE TIME (the park-and-revalidate idiom): the arming transition is
            // 250 ms stale by now, and the ⌘ key-up that would have cancelled this timer can be
            // swallowed past the monitor entirely (menu tracking, an app switch completing). Showing
            // on the timer's word alone is how the rail ends up numbered with no key held.
            guard readLiveModifiers().contains(.command), isWorkspaceWindowKey(),
                  !isOverlayCapturingKeys()
            else { return }
            store.setShortcutHintActive(true)
        }
    }

    /// Map one `NSEvent` keystroke to swallow (`nil`) or pass-through (the event), routing any resolved action
    /// through `WorkspaceBindingRegistry.route(...)`. `internal` (not `private`) so the modal-yield gate
    /// is unit-testable via `@testable` (a synthetic NSEvent is not a window-server resource — the hang-safety
    /// rule is about SCStream/VT/Metal, not NSEvent).
    func handle(_ event: NSEvent) -> NSEvent? {
        // STUCK-HINT SELF-HEAL: a showing hint whose ⌘ is no longer physically down means the key-up
        // was swallowed past this monitor (menu tracking runs its own event loop; an app switch hands
        // the release to the next app). The next event of ANY kind — this one — clears it, so a
        // stranded hint outlives its hold by at most one keystroke/modifier tick.
        if store.shortcutHintActive, !readLiveModifiers().contains(.command) {
            updateShortcutHint(commandHeld: false)
        }
        // KEY-WINDOW GATE: the monitor is application-wide, but a workspace chord is meaningful ONLY when the
        // workspace window holds focus. If a separate window is key (Settings, a sheet), pass EVERY key through
        // UNCHANGED so that window (and the keybindings recorder) receives its own keystrokes instead of this
        // monitor resolving + swallowing against the hidden workspace tree.
        //
        // An in-flight ⌃⇥ switcher is ABANDONED here rather than left open: the window that lost key will
        // never deliver the ⌃ key-up that would commit it, so the overlay would hang with a highlight the
        // user can no longer act on.
        if !isWorkspaceWindowKey() {
            store.cancelPaneSwitcher()
            // The ⌘ key-up that would clear the hint will land on the OTHER window's monitor pass —
            // this same early return — so the clear must ride it (and every later pass) too.
            updateShortcutHint(commandHeld: false)
            return event
        }
        // MODIFIER TRANSITIONS: releasing ⌃ COMMITS an armed ⌃⇥ switcher — that key-up IS the selection.
        // This must precede every `charactersIgnoringModifiers` read below: a `.flagsChanged` event carries
        // no characters and asking it for them raises `NSInternalInconsistencyException`. A transition is
        // never swallowed — the terminal tracks modifier state too.
        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(.control) { store.commitPaneSwitcherOnModifierRelease() }
            updateShortcutHint(commandHeld: event.modifierFlags.contains(.command))
            return event
        }
        // MODAL YIELD: while a keyboard-capturing overlay (the Open-Quickly picker) is presented, this monitor
        // — which PREEMPTS the responder chain — must NOT resolve the global chord table behind it, or ⌘1–9
        // would focus a pane BEHIND the picker and ⌘W would DESTROY the focused pane behind it. Pass every key
        // through UNCHANGED so the picker's `.onKeyPress` owns its picker-local chords (⌘0/⌘W/⌘R/⌘Z/⌘G/⌘J,
        // ⌘1–9, ⌘K); Esc / a scrim-tap close it. (⌘⇧O / ⌘J are global only while the picker is hidden.)
        if isOverlayCapturingKeys() { return event }
        // The ⌃⇥ pane-switcher gesture, resolved BEFORE the chord table because it is not expressible as a
        // table row: one chord means open / step / commit depending on whether the switcher is already up,
        // and Escape — its cancel key — normalizes to no chord at all (`\u{1B}` is a control scalar the
        // normalizer rejects, precisely so a bare Esc always reaches the TUI).
        if consumePaneSwitcher(event) { return nil }
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

        // A user `text:`/`csi:`/`esc:` literal-byte binding resolves BEFORE the action table — the chord
        // sends its already-resolved bytes (ESC/CSI lead bytes baked in by `KeybindGrammar`) to the focused
        // pane and is swallowed.
        if let textBinding = WorkspaceBindingRegistry.textBinding(for: chord) {
            if let active = activePaneID {
                store.handle(for: active)?.sendBytes(textBinding.payload)
            }
            return nil // swallow — the text binding owns this chord
        }
        // An `unbind:` target suppresses its DEFAULT action: pass the event through to the focused
        // responder instead of firing the registry action.
        if WorkspaceBindingRegistry.isUnbound(chord) {
            return event
        }
        if let action = WorkspaceBindingRegistry.resolvedChordTable[chord] {
            dispatch(action)
            return nil // swallow — the workspace owns this chord
        }
        return event // bare typing / unbound chord → reaches the focused responder UNCHANGED
    }

    /// The ⌃⇥ switcher's key handling. Returns `true` when the event was consumed (the caller swallows it).
    ///
    /// Keyed off `keyCode` rather than a normalized `KeyChord` for two reasons: Escape has no chord (by
    /// design — see `KeyChordNormalizer`), and matching the physical key keeps ⇥ recognisable regardless of
    /// what `charactersIgnoringModifiers` reports under a non-US layout.
    ///
    /// THE BOUNDARY THIS FUNCTION DEFENDS: a bare ⇥ is shell completion and ⇧⇥ is how Claude Code cycles
    /// permission modes. Neither carries ⌃, and with the switcher closed neither is claimed here — they fall
    /// straight through to the PTY. Only ⌃⇥ opens the gesture; only while it is open do Esc / Return /
    /// arrows / a bare ⇥ mean anything to us.
    private func consumePaneSwitcher(_ event: NSEvent) -> Bool {
        let control = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        let isOpen = store.paneSwitcher != nil
        // ⇧ selects the direction: ⌃⇥ walks toward less-recent, ⌃⇧⇥ walks back.
        let forward = !shift

        switch event.keyCode {
        case 48: // Tab
            // Ours only when ⌃ is held (the gesture) or the switcher is already up (a palette-opened one has
            // no held modifier). Otherwise this is the terminal's Tab and we must not touch it.
            guard control || isOpen else { return false }
            // `unbind: ctrl+tab` gives the GESTURE back — the escape hatch a Neovim user needs once the
            // Kitty protocol delivers ⌃⇥ to the PTY as `CSI 9 ; 5 u`. The gesture has no table row, so
            // the ordinary unbind branch below (which runs after this one) would never see it.
            //
            // Gates OPENING only, and reclaims each chord INDIVIDUALLY — unbinding ⌃⇥ is not a statement
            // about ⌃⇧⇥. Once the switcher is up it owns ⇥ regardless, or an unbind would strand an
            // overlay with no way to step it.
            var mods: KeyChord.Modifiers = []
            if control { mods.insert(.control) }
            if shift { mods.insert(.shift) }
            if !isOpen, WorkspaceBindingRegistry.isUnbound(KeyChord(.tab, mods)) { return false }
            store.openOrStepPaneSwitcher(forward: forward, armedByModifier: control)
            // A refusal (one pane ⇒ nothing to switch to) leaves the switcher nil; pass ⌃⇥ through rather
            // than swallowing it into a gesture that cannot happen.
            return store.paneSwitcher != nil
        case 53: // Escape — abandon the walk
            guard isOpen else { return false }
            store.cancelPaneSwitcher()
            return true
        // Return / keypad Enter — commit (the palette-opened switcher's only commit path)
        case 36,
             76:
            guard isOpen else { return false }
            store.commitPaneSwitcher()
            return true
        // ← / → — step the highlight while the switcher is up
        case 123,
             124:
            guard isOpen else { return false }
            store.openOrStepPaneSwitcher(forward: event.keyCode == 124, armedByModifier: false)
            return true
        default:
            return false
        }
    }

    /// The active pane id (the literal-byte binding's send target). `nil` when no pane is focused (the send
    /// is then a no-op, which is correct — there is nothing to type into).
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
