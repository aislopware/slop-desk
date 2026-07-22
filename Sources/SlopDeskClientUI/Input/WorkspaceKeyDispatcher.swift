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
    }

    /// Map one `NSEvent` keystroke to swallow (`nil`) or pass-through (the event), routing any resolved action
    /// through `WorkspaceBindingRegistry.route(...)`. `internal` (not `private`) so the modal-yield gate
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
