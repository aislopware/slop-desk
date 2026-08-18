// CodeSidebarWebView — the WKWebView carrying the project-scoped embedded VS Code (code-server),
// plus the per-project keep-alive pool behind it.
//
// The pool is the load-bearing piece (the cmux lesson): ONE WKWebView per project root, created on
// first expand and kept for the app's lifetime, so switching the focused pane between projects swaps
// an already-warm workbench back in instantly instead of re-booting the whole VS Code renderer
// (multi-second, editor state lost). A detached WKWebView keeps its web-content process alive; the
// idle throttling that comes with being unparented is fine for an editor (no background work needed).
//
// HANG-SAFETY: nothing in the unit-test dependency closure may construct a WKWebView — the pool is
// only reached from the macOS column view; all decision logic lives in `CodeSidebarModel` (pure).

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import WebKit

/// When a `becomeFirstResponder` on the embedded workbench may be HONORED. VS Code aggressively
/// focuses its own editor — on load, on file open, on layout changes — and WebKit forwards each
/// page-level `focus()` as a first-responder claim. Unguarded, an autofocus mid-keystroke silently
/// re-routes the keyboard from the terminal to the editor (the cmux focus-steal lesson). The rule:
/// only a direct user MOUSE-DOWN inside the webview hands VS Code the keyboard; everything else
/// (JS autofocus arrives with no current event, or riding whatever unrelated event is current) is
/// refused. Pure — pinned by `CodeSidebarFocusPolicyTests`.
package enum CodeSidebarFocusPolicy {
    static func shouldAcceptFocus(eventType: NSEvent.EventType?, clickWasInsideWebView: Bool) -> Bool {
        switch eventType {
        case .leftMouseDown,
             .otherMouseDown,
             .rightMouseDown:
            clickWasInsideWebView
        default:
            false
        }
    }

    /// App/window-management chords the embedded workbench may NEVER own. `WKWebView`'s
    /// `performKeyEquivalent` claims ⌘-chords for the page BEFORE the main menu gets a look, so with
    /// the editor focused ⌘Q simply vanished into VS Code's key handling instead of quitting. These
    /// are refused at the responder seam (the event falls through to the menu bar); everything else —
    /// ⌘W (close editor tab), ⌘, (VS Code settings), ⌘P/⌘F/… — stays with the workbench, which the
    /// user focused ON PURPOSE (the click-to-focus rule above). Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`. The key arrives as `charactersIgnoringModifiers` lowercased.
    ///
    /// ⌘` (cycle app windows) used to be listed here and no longer is: the app's NSEvent monitor runs
    /// ahead of the whole responder chain and now spends ⌘`/⌃` on the hand-back to the terminal pane
    /// while the editor holds the keyboard (`WorkspaceKeyDispatcher.codePanelLocalAction`), so this
    /// seam is never reached for it. A case here would only read as a live rule that isn't one.
    static func isReservedAppChord(modifiers: NSEvent.ModifierFlags, key: String?) -> Bool {
        guard let key else { return false }
        let chord = modifiers.intersection([.command, .shift, .option, .control])
        switch (chord, key) {
        case ([.command], "q"), // Quit
             ([.command], "h"), // Hide SlopDesk
             ([.command, .option], "h"), // Hide Others
             ([.command], "m"): // Minimize
            return true
        default:
            return false
        }
    }

    /// The standard editing command a bare ⌘-chord maps to while the webview owns the keyboard.
    /// The set is EXACTLY the three clipboard chords, and that is not a taste call: VS Code
    /// registers `editor.action.clipboardCut/Copy/PasteAction` with their keybinding gated on the
    /// NATIVE build (`kbOpts: isNative ? {…} : undefined`), because in a browser those belong to
    /// the Edit menu, which drives the DOM cut/copy/paste. This app's menus are shortcut-less by
    /// design, so nobody sent WebKit the editing actions and the chords fell through "unhandled".
    /// Worse than a no-op: WebKit re-dispatches an unhandled key equivalent, and the terminal's
    /// doCommand-redispatch tail swallowed the second pass as terminal input — libghostty's own
    /// `cmd+v = paste` binding then pasted into the PTY while the user was looking at the editor
    /// (user-reported 2026-08-03). The webview claiming these three (first-responder-gated, exactly
    /// like the terminal's own claim) is the same contract a browser's Edit menu provides.
    ///
    /// Every OTHER chord — including ⌘A, ⌘Z and ⌘⇧Z — must NOT be claimed here. Those carry an
    /// unconditional core keybinding in the web build (`editor.action.selectAll` / `undo` / `redo`,
    /// weight 0), and each routes itself to a native text input when one has focus, so the page
    /// handles them everywhere. Claiming ⌘A drove WebKit's DOM select-all against the editor's
    /// hidden textarea — which holds a scratch buffer, not the document — so select-all in the
    /// editor did nothing at all (user-reported 2026-08-05). Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`.
    enum EditingCommand: Equatable {
        case copy
        case paste
        case cut
    }

    static func editingCommand(modifiers: NSEvent.ModifierFlags, key: String?) -> EditingCommand? {
        guard let key,
              modifiers.intersection([.command, .shift, .option, .control]) == [.command]
        else { return nil }
        switch key {
        case "c": return .copy
        case "v": return .paste
        case "x": return .cut
        default: return nil
        }
    }

    /// The keyboard-ownership flag after a key-window change. Re-derive from the live responder only
    /// while the app still HAS a key window — an intra-app move (a satellite pane window taking key)
    /// really does relocate the keyboard without any responder transition. When `hasKeyWindow` is
    /// false the whole APP lost the keyboard (⌘⇥ to another app fires `didResignKey` with
    /// `NSApp.keyWindow` already nil): ownership WITHIN the app is unchanged, so the previous value
    /// stands. Dropping the flag there let the workspace-focused terminal reclaim first responder
    /// from the editor while the app sat in the background, so ⌘⇥-ing back landed the keyboard in
    /// the terminal the user had left the editor from (user-reported 2026-08-03). Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`.
    static func keyboardOwnership(
        previous: Bool, hasKeyWindow: Bool, webViewHoldsFirstResponder: Bool,
    ) -> Bool {
        hasKeyWindow ? webViewHoldsFirstResponder : previous
    }

    /// THE PER-TAB FOCUS REGION. A workspace tab remembers which surface the keyboard was last in —
    /// its terminal pane, or the code panel — and the answer is the tab's, not the window's. The
    /// memory maps a tab to the project workbench that held the keyboard there; a tab absent from it
    /// focuses its terminal, which is every tab's starting state.
    ///
    /// It replaces a single global "the keyboard was claimed in tab X" slot that only survived an
    /// UNMOUNT. With both tabs on one project nothing ever unmounts, so the slot was simply
    /// overwritten: editing in tab A's panel, switching to tab B and clicking B's terminal erased
    /// the fact that A was a panel tab, and coming back to A landed in A's terminal (user-reported
    /// 2026-08-10). One entry per tab is the shape the question actually has.
    ///
    /// Whether a REMOUNTED webview gets the keyboard handed back reads straight off it. The pool's
    /// webviews are warm — a project switch (workspace tab carrying another project), the panel's
    /// Desktop tab, or a panel collapse unmounts the view (which forcibly resigns first responder)
    /// and a later remount shows the workbench exactly as it was left — so when the tab being
    /// remounted into is a PANEL tab, the user reads the remount as "I'm back" and types straight
    /// into it; without the hand-back those keys land in the terminal that auto-claimed in between
    /// (user-reported 2026-08-03: ⌘⇧P after a tab round-trip opened the APP's palette, not VS
    /// Code's). The project must match too: a remount of ANOTHER project's workbench in this tab is
    /// not the workbench this tab was reading. Pure — pinned by `CodeSidebarFocusPolicyTests`.
    static func shouldRestoreOnRemount<Tab: Hashable>(
        memory: [Tab: String], activeTab: Tab?, projectRoot: String,
    ) -> Bool {
        guard let activeTab else { return false }
        return memory[activeTab] == projectRoot
    }

    /// The focus-region memory after a webview resign — the ONLY path that ever forgets a tab.
    ///
    /// Still-in-window ⇒ the USER moved the keyboard out of the panel (a terminal click, an overlay,
    /// the ⌥⌘R hand-back): that tab's region is the terminal again. Off-window ⇒ a warm-swap
    /// unmount took the keyboard, which is not a decision the user made — the tab stays a panel tab
    /// and its remount hands the keyboard back.
    ///
    /// `resigningTab` is the tab the resign HAPPENED in, captured synchronously at the responder
    /// seam rather than read here: the classification runs a hop later, by which time a tab click
    /// that moved the keyboard has already switched the active tab, and this would forget the tab
    /// the user was ARRIVING at instead of the one they left. Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`.
    static func memoryAfterResign<Tab: Hashable>(
        _ memory: [Tab: String], resigningTab: Tab?, stillInWindow: Bool,
    ) -> [Tab: String] {
        guard stillInWindow, let resigningTab else { return memory }
        var out = memory
        out.removeValue(forKey: resigningTab)
        return out
    }

    /// Where the keyboard belongs when the workspace's ACTIVE TAB changes — the switch is the moment
    /// the per-tab region is honoured.
    ///
    /// A panel tab arriving with the keyboard elsewhere CLAIMS the editor; any other tab arriving
    /// while the editor holds the keyboard YIELDS it back to the workspace, so a terminal tab never
    /// inherits the panel focus of the tab before it. `leaveAlone` covers the two already-correct
    /// cases, including a panel tab arriving while the editor still holds the keyboard: when that
    /// tab reads ANOTHER project the column's own swap unmounts and remounts the workbench, and the
    /// remount restore (``shouldRestoreOnRemount(memory:activeTab:projectRoot:)``) is what moves the
    /// keyboard to the right workbench. Pure — pinned by `CodeSidebarFocusPolicyTests`.
    enum TabSwitchFocus: Equatable {
        /// The arriving tab is a panel tab — claim this project's mounted workbench.
        case claimEditor(projectRoot: String)
        /// The arriving tab reads its terminal — let the workspace's focused pane take the keyboard.
        case yieldToWorkspace
        /// The keyboard is already where the arriving tab wants it.
        case leaveAlone
    }

    static func tabSwitchFocus<Tab: Hashable>(
        incoming: Tab?, memory: [Tab: String], editorHoldsKeyboard: Bool,
    ) -> TabSwitchFocus {
        guard let incoming, let projectRoot = memory[incoming] else {
            return editorHoldsKeyboard ? .yieldToWorkspace : .leaveAlone
        }
        return editorHoldsKeyboard ? .leaveAlone : .claimEditor(projectRoot: projectRoot)
    }

    /// WHICH QUESTION A FOCUS CHANGE IS ASKING. The workspace's focus moved; the shell has to decide
    /// whether the arriving TAB's remembered region applies, or whether a PANE was named and the
    /// keyboard owes it.
    ///
    /// The landing alone cannot answer it — switching tabs moves the focused pane too, so a tab
    /// switch and a cross-tab pane jump look identical in `(tab, pane)`. What separates them is
    /// ``WorkspaceStore/FocusIntent``: a FRESH intent naming a pane means the user aimed at that
    /// pane, wherever it lives, and the panel must let go even when the arriving tab is one they
    /// were last editing in. Everything else falls back to the shape of the change, which is what
    /// covers the moves that pass through no choke point at all: a split's new leaf, a close's
    /// landing, another client's focus arriving in the document. Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`.
    package enum FocusLandingAction: Equatable {
        /// Hand the arriving tab its own region (terminal or panel).
        case honourTabRegion
        /// A pane was named — the panel gives the keyboard back.
        case yieldToPane
        /// Nothing moved that the keyboard cares about.
        case none
    }

    package static func landingAction(
        intentNamedPane: Bool, intentIsFresh: Bool, tabChanged: Bool, paneChanged: Bool,
    ) -> FocusLandingAction {
        if intentIsFresh, intentNamedPane { return .yieldToPane }
        if tabChanged { return .honourTabRegion }
        return paneChanged ? .yieldToPane : .none
    }

    /// What ⌥⌘R (Focus Code Panel) should do, given where the keyboard is and whether the panel is
    /// even on screen. One chord, both directions — the editor is otherwise reachable ONLY by
    /// clicking it, because every other focus claim is refused by design (see
    /// ``shouldAcceptFocus(eventType:clickWasInsideWebView:)``). Pure — pinned by
    /// `CodeSidebarFocusPolicyTests`.
    enum FocusToggleOutcome: Equatable {
        /// The editor has the keyboard — give it back to the view it was taken from.
        case handBack
        /// The panel is up and mounted; claim the keyboard for the workbench.
        case claimEditor
        /// The panel is hidden: reveal it first, then claim once the webview mounts.
        case revealThenClaim
        /// Nothing to focus — the panel is open but showing a placeholder (no project, still
        /// starting, no code-server), so there is no webview to hand the keyboard to.
        case none
    }

    static func focusToggle(
        webViewHoldsKeyboard: Bool, hasMountedWebView: Bool, panelCollapsed: Bool,
    ) -> FocusToggleOutcome {
        if webViewHoldsKeyboard { return .handBack }
        if panelCollapsed { return .revealThenClaim }
        return hasMountedWebView ? .claimEditor : .none
    }

    /// Which project's warm workbench to discard when the pool is over its cap, given `recency`
    /// (least-recently-used FIRST) and the projects that must not be touched. `nil` = nothing to
    /// evict.
    ///
    /// The pool exists to make a project switch instant, and it paid for that by keeping every
    /// project's workbench alive for the app's lifetime — one WKWebView, one web content process
    /// and one fully booted VS Code renderer apiece, with no ceiling. Across a working day of
    /// hopping between repos that is unbounded growth for warmth nobody is going to use again. A
    /// cap bounds it: the projects in active rotation stay instant, and a long-cold one pays a
    /// workbench boot on return — its open editors come back regardless, because the workbench
    /// keeps that state in browser storage on the proxy's deliberately stable origin.
    ///
    /// The MOUNTED project is never a victim (evicting the view on screen would blank it), and a
    /// project with the keyboard-restore armed is spared too — its hand-back is still owed. Pure —
    /// pinned by `CodeSidebarFocusPolicyTests`.
    static func evictionVictim(
        recency: [String], protected: Set<String>, cap: Int,
    ) -> String? {
        guard recency.count > cap else { return nil }
        return recency.first { !protected.contains($0) }
    }

    /// Whether `responder` is worth remembering as the keyboard's rightful owner — the repair
    /// target for a refused page focus pull (see ``CodeSidebarWKWebView/becomeFirstResponder()``).
    /// Only a real VIEW that is neither the window's stand-in (`firstResponder == window` IS the
    /// orphaned state) nor part of any pooled webview qualifies: remembering a webview would make
    /// the repair hand the keyboard to the thief. Pure — pinned by `CodeSidebarFocusPolicyTests`.
    static func isTrackableKeyboardOwner(
        responderIsView: Bool, responderIsWindow: Bool, responderInsidePooledWebView: Bool,
    ) -> Bool {
        responderIsView && !responderIsWindow && !responderInsidePooledWebView
    }
}

/// The pooled webview class: applies ``CodeSidebarFocusPolicy`` at the responder seam, so the
/// embedded VS Code can never STEAL the keyboard — it can only be handed it by a click (or the
/// pool's own remount RESTORE, which is app-directed, never page-directed).
final class CodeSidebarWKWebView: WKWebView {
    /// The pool key this webview serves — the focus-restore bookkeeping is keyed by it.
    let projectRoot: String

    /// Armed (scoped) by ``claimKeyboardForRestore()`` — the ONE non-click path
    /// `becomeFirstResponder` honors. App-directed: only the pool's remount restore sets it; a
    /// page-level `focus()` can never reach it.
    private var programmaticRestoreArmed = false

    init(projectRoot: String, frame: CGRect, configuration: WKWebViewConfiguration) {
        self.projectRoot = projectRoot
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The same policy for every AppKit path that ASKS before moving the keyboard — the key-view
    /// loop, initial-first-responder assignment, window restoration. `NSWindow.makeFirstResponder`
    /// itself never consults this (it resigns the current responder first and asks
    /// `becomeFirstResponder` second — measured, not assumed; see the orphan repair there), so
    /// this cannot be the only gate, but the asking paths should get the honest answer too.
    override var acceptsFirstResponder: Bool {
        guard let app = NSApp as NSApplication? else { return false }
        return programmaticRestoreArmed
            || CodeSidebarFocusPolicy.shouldAcceptFocus(
                eventType: app.currentEvent?.type,
                clickWasInsideWebView: app.currentEvent.map(eventLandsInside) ?? false,
            )
    }

    override func becomeFirstResponder() -> Bool {
        // `NSApp` is nil in a headless test process — optional access, never the implicit unwrap.
        guard let app = NSApp as NSApplication? else { return false }
        guard programmaticRestoreArmed
            || CodeSidebarFocusPolicy.shouldAcceptFocus(
                eventType: app.currentEvent?.type,
                clickWasInsideWebView: app.currentEvent.map(eventLandsInside) ?? false,
            )
        else {
            // The refusal arrives MID-`makeFirstResponder`: the page pulled native focus
            // (`WebPageProxy::MakeFirstResponder` — the workbench does it while booting), and
            // AppKit had the current responder RESIGN before asking here, so returning false
            // strands first responder on the window — every key dead until the next click
            // (user-reported 2026-08-04: opening the app with the panel expanded showed cursors
            // blinking in both the terminal and the editor, with the keyboard in neither). Hand
            // the keyboard straight back to the responder it was lifted from; one hop later so
            // the surrounding `makeFirstResponder` finishes first. The `firstResponder == window`
            // guard keeps the repair out of every legitimate move (a real taker means no orphan).
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.firstResponder === window,
                      let owner = CodeSidebarWebViewPool.shared.lastKeyboardOwner,
                      owner.window === window
                else { return }
                window.makeFirstResponder(owner)
            }
            return false
        }
        let became = super.becomeFirstResponder()
        if became {
            CodeSidebarKeyboardState.shared.set(true)
            CodeSidebarWebViewPool.shared.noteKeyboardClaimed(projectRoot: projectRoot)
        }
        return became
    }

    /// The pool's remount hand-back (``CodeSidebarFocusPolicy/shouldRestoreOnRemount(claimedTab:activeTab:)``).
    func claimKeyboardForRestore() {
        guard let window else { return }
        programmaticRestoreArmed = true
        defer { programmaticRestoreArmed = false }
        window.makeFirstResponder(self)
    }

    /// Anything that takes the keyboard back (a terminal click, an overlay, the panel collapsing
    /// and unparenting this view) resigns through here — the observable flag tracks it so the
    /// workspace's focused pane re-lights the moment the keyboard actually returns. The resign's
    /// CAUSE is classified one runloop later, once the swap (if any) has finished unparenting:
    /// off-window ⇒ a warm-swap unmount (the tab stays a panel tab), still-in-window ⇒ a genuine
    /// keyboard move by gesture (that tab's region is the terminal again — see
    /// ``CodeSidebarFocusPolicy/memoryAfterResign(_:resigningTab:stillInWindow:)``).
    ///
    /// The tab is read NOW, not in the deferred hop: a click on another tab's row moves the keyboard
    /// on mouse-down and switches the tab after, so the hop would name the wrong tab.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            CodeSidebarKeyboardState.shared.set(false)
            let resigningTab = CodeSidebarWebViewPool.activeTabID()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                CodeSidebarWebViewPool.shared.classifyResign(
                    tab: resigningTab, stillInWindow: window != nil,
                )
                // The page keeps rendering a caret unless it is TOLD the keyboard left (see
                // `syncFocusTruth()`).
                syncFocusTruth()
            }
        }
        return resigned
    }

    /// Make the PAGE agree that it does not have the keyboard.
    ///
    /// The workbench decides where its caret blinks from its own DOM focus, and it re-focuses the
    /// editor on its own schedule — a remount, a layout change, an editor opening. Those pulls are
    /// refused at the native seam (only a click hands the panel the keyboard), but refusing the
    /// NATIVE claim does not undo the PAGE's: `document.activeElement` is the editor, VS Code has
    /// seen its `focus` event, and it blinks a caret next to the terminal's — two live cursors, and
    /// the keys going to the terminal (user-reported 2026-08-10). WebKit is no help here: a view
    /// that loses first responder by being UNPARENTED never delivers the page its blur.
    ///
    /// So the correction is driven from this side too: replay the missing blur through the page's
    /// own focus-truth hook, which no-ops the moment `document.hasFocus()` is honestly true. The
    /// hook self-installs at document start (``CodeSidebarPageDressing/focusTruthScript()``); the
    /// `&&` guard makes this inert on a page that has not run it yet.
    func syncFocusTruth() {
        evaluateJavaScript(CodeSidebarPageDressing.focusTruthSyncCall)
    }

    /// Whether `event`'s location falls inside THIS webview — same window, point within bounds.
    private func eventLandsInside(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Refuse the app-reserved chords (``CodeSidebarFocusPolicy/isReservedAppChord(modifiers:key:)``)
    /// so they continue up to the main menu — WebKit's own implementation forwards ⌘-chords to the
    /// page and returns `true`, which is how a focused editor swallowed ⌘Q whole. The standard
    /// clipboard chords are CLAIMED here instead and driven through WebKit's native editing actions
    /// (``CodeSidebarFocusPolicy/editingCommand(modifiers:key:)`` — the Edit-menu contract a browser
    /// gives VS Code web, which this app's shortcut-less menus never provided): the DOM
    /// copy/paste/cut runs against whatever has focus in the page, and the clipboard bridge sees
    /// the copies. First-responder-gated like the terminal's claim, so a focused find bar / native
    /// field never loses its own ⌘C/⌘V to the panel. Nothing else may be added to that set — the
    /// workbench binds the rest itself and a claim here silently outranks it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if CodeSidebarFocusPolicy.isReservedAppChord(modifiers: event.modifierFlags, key: key) {
            return false
        }
        if event.type == .keyDown, window?.firstResponder === self,
           let command = CodeSidebarFocusPolicy.editingCommand(modifiers: event.modifierFlags, key: key)
        {
            // WKWebView implements the standard editing IBActions (they back the Edit menu in every
            // WebKit browser) without declaring them publicly — selector dispatch is the seam. The
            // `responds` guard keeps a hypothetical WebKit that dropped one on the `super` path
            // instead of silently eating the chord.
            let action: Selector =
                switch command {
                case .copy: #selector(NSText.copy(_:))
                case .paste: #selector(NSText.paste(_:))
                case .cut: #selector(NSText.cut(_:))
                }
            if responds(to: action) {
                perform(action, with: nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Per-project veil state for the workbench's main-frame navigation. The webview stays COVERED by
/// the column's dark waiting surface from load-start until the navigation settles — WebKit paints
/// its default white between the provisional commit and the page's own (dark) first paint, and in a
/// multi-second code-server cold boot that reads as black → white flash → workbench. `@Observable`
/// so the column's overlay fades out exactly on settle; a reload re-veils through the same events.
@MainActor
@Observable
final class CodeSidebarWebLoadState {
    private(set) var veiled = true
    func navigationStarted() { veiled = true }
    func navigationSettled() { veiled = false }
}

/// The retained `WKNavigationDelegate` driving a ``CodeSidebarWebLoadState`` (`navigationDelegate`
/// is weak — the pool holds this alongside the webview). Failures also settle: a dead endpoint must
/// surface WebKit's error page, never an eternal spinner veil.
@MainActor
private final class CodeSidebarNavigationObserver: NSObject, WKNavigationDelegate {
    let state: CodeSidebarWebLoadState

    init(state: CodeSidebarWebLoadState) {
        self.state = state
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation?) {
        state.navigationStarted()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        state.navigationSettled()
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError _: Error) {
        state.navigationSettled()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError _: Error) {
        state.navigationSettled()
    }
}

/// The per-project webview pool. `@MainActor` (WKWebView is main-thread only); keyed by the
/// project's canonical root (the host-pushed `projectKey` — the same key the sidebar sections use).
/// The host's code-server is a single shared instance; each pool entry is one project's WORKBENCH
/// on it (same origin, its own `?folder=` and editor state).
@MainActor
package final class CodeSidebarWebViewPool {
    package static let shared = CodeSidebarWebViewPool()

    /// The workspace's active tab — wired once by the app layer (the pool cannot see the store).
    /// Drives the focus-restore tab match; the `nil` default (headless tests, pre-wiring renders)
    /// simply never restores.
    package static var activeTabID: @MainActor () -> TabID? = { nil }

    /// How many project workbenches stay warm at once. Three covers the rotation a person actually
    /// keeps in their head (the repo, its dependency, the thing they are comparing against) while
    /// bounding what an all-day session can accumulate — see ``CodeSidebarFocusPolicy/evictionVictim(recency:protected:cap:)``.
    static let warmWebViewCap = 3

    private var webViews: [String: WKWebView] = [:]
    /// Project roots in least-recently-used order — the eviction queue. Touched on every mint and
    /// every mount, which between them are the only moments a project is "used".
    private var recency: [String] = []
    private var loadStates: [String: CodeSidebarWebLoadState] = [:]
    private var navigationObservers: [String: CodeSidebarNavigationObserver] = [:]
    private var keyWindowObservers: [NSObjectProtocol] = []
    /// THE PER-TAB FOCUS REGION — every workspace tab whose keyboard belongs to the code panel,
    /// mapped to the project workbench it belongs to. A tab absent from here reads its terminal.
    /// Written at the responder seam (claim / resign) and honoured on every tab switch and remount;
    /// see ``CodeSidebarFocusPolicy/shouldRestoreOnRemount(memory:activeTab:projectRoot:)``.
    private var sidebarFocusMemory: [TabID: String] = [:]
    /// The last first responder that was a real view OUTSIDE every pooled webview — the repair
    /// target when a refused page focus pull strands the keyboard on the window (see
    /// ``CodeSidebarWKWebView/becomeFirstResponder()``). Tracked from `NSWindow.didUpdate`
    /// (AppKit offers no first-responder-change notification); weak, and re-validated against
    /// the live window at repair time, so a torn-down view can never be revived by the repair.
    private(set) weak var lastKeyboardOwner: NSView?

    init() {
        // The responder overrides keep `CodeSidebarKeyboardState` honest WITHIN one window, but a
        // key-window change moves the keyboard without any responder transition (the webview stays
        // its window's first responder while a satellite pane window is key). Re-derive on both
        // edges so the flag always answers for the window that actually receives keys — but only
        // while SOME window of ours is key: app deactivation is not an intra-app keyboard move
        // (`CodeSidebarFocusPolicy.keyboardOwnership` — the ⌘⇥ round-trip fix).
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    CodeSidebarKeyboardState.shared.set(CodeSidebarFocusPolicy.keyboardOwnership(
                        previous: CodeSidebarKeyboardState.shared.ownsKeyboard,
                        hasKeyWindow: (NSApp as NSApplication?)?.keyWindow != nil,
                        webViewHoldsFirstResponder: Self.shared.holdsFirstResponder(),
                    ))
                }
            })
        }
        // The rightful-owner tracker behind the orphan repair. `didUpdate` fires on every window
        // update pass — the guards are cheap and the write is a weak-pointer store.
        keyWindowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main,
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                Self.shared.noteWindowUpdate(window)
            }
        })
    }

    /// Remember the current first responder as the keyboard's rightful owner when
    /// ``CodeSidebarFocusPolicy/isTrackableKeyboardOwner(responderIsView:responderIsWindow:responderInsidePooledWebView:)``
    /// says it qualifies (a real view, not the window's orphan stand-in, not a pooled webview).
    private func noteWindowUpdate(_ window: NSWindow?) {
        guard let window, window.isKeyWindow else { return }
        let responder = window.firstResponder
        let view = responder as? NSView
        guard CodeSidebarFocusPolicy.isTrackableKeyboardOwner(
            responderIsView: view != nil,
            responderIsWindow: responder === window,
            responderInsidePooledWebView: view.map(isInsidePooledWebView) ?? false,
        ), let view else { return }
        lastKeyboardOwner = view
    }

    /// The project's veil state — the column reads `veiled` to hold its dark waiting surface over
    /// the webview until the workbench paints. Created on demand so the read can precede the
    /// webview's own creation in the same body evaluation.
    func loadState(for projectRoot: String) -> CodeSidebarWebLoadState {
        if let existing = loadStates[projectRoot] { return existing }
        let state = CodeSidebarWebLoadState()
        loadStates[projectRoot] = state
        return state
    }

    /// The (created-on-first-use) webview for `projectRoot`, pointed at `url`. An existing entry is
    /// re-loaded ONLY when the endpoint moved (`CodeSidebarModel.endpointMoved` — a respawned
    /// service on a fresh port); the page otherwise owns its own navigation.
    ///
    func webView(for projectRoot: String, url: URL) -> WKWebView {
        touch(projectRoot)
        if let existing = webViews[projectRoot] {
            if CodeSidebarModel.endpointMoved(current: existing.url, target: url) {
                existing.load(URLRequest(url: url))
            }
            return existing
        }
        let configuration = WKWebViewConfiguration()
        // No user-gesture gate on media — VS Code's own UI sounds/previews must not silently stall.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The client's own faces, served as subresources instead of inlined into the sheet as
        // ~4 MB of base64 (see `CodeSidebarFontScheme`). Must be set BEFORE the webview is built —
        // a configuration is copied at construction.
        configuration.setURLSchemeHandler(
            Self.fontSchemeHandler, forURLScheme: CodeSidebarFontScheme.scheme,
        )
        installWorkbenchDressing(on: configuration.userContentController)
        let webView = CodeSidebarWKWebView(
            projectRoot: projectRoot, frame: .zero, configuration: configuration,
        )
        // Right-click → Inspect Element on the embedded workbench (Safari Web Inspector) — the only
        // window into a misbehaving code-server page.
        webView.isInspectable = true
        // Paint the GROUND behind the page so the first load / a bounce never flashes a tone the
        // column does not wear (the cmux `underPageBackgroundColor` trick).
        webView.underPageBackgroundColor = NSColor(slateHex: Slate.theme.groundHexValue)
        // CHROME polarity — the workbench is a sunken panel on the ground, not an island (ONE ISLAND
        // law 1): it stands on the same cream ground as the navigator, so it follows the chrome's
        // LIGHT appearance and the seeded colour customizations paint it in the ground tone. Pinned
        // HERE, at creation, and nowhere else — a re-pin pass over the pool existed and was never
        // called, which was correct: `Slate.theme` does not change while the app runs.
        webView.appearance = NSAppearance(named: .aqua)
        // WebKit's own base canvas is WHITE until the page's first paint — with a multi-second
        // workbench boot that is a visible flash between the dark chrome and the dark editor. There
        // is no public macOS API for it; the long-standing KVC key makes the canvas transparent so
        // the dark column shows through instead.
        webView.setValue(false, forKey: "drawsBackground")
        let observer = CodeSidebarNavigationObserver(state: loadState(for: projectRoot))
        navigationObservers[projectRoot] = observer
        webView.navigationDelegate = observer
        webView.load(URLRequest(url: url))
        webViews[projectRoot] = webView
        evictColdestIfOverCap()
        return webView
    }

    /// The workbench's five user scripts, in the order their injection times require. Split out so
    /// the mint reads as "pick a dressing" rather than sixty lines of one branch.
    private func installWorkbenchDressing(on controller: WKUserContentController) {
        // The finishing coat (terminal-mono + nerd-font @font-faces, Slate softening, slopcat
        // letterpress) rides every navigation — user scripts persist on the controller, so a
        // reload/respawn re-dresses itself.
        controller.addUserScript(WKUserScript(
            source: Self.dressingScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
        ))
        // The recommendation-tips GRAFT: code-server's boot configuration never carries the
        // recommendation catalogue (its server forwards only the gallery), leaving the Extensions
        // view's RECOMMENDED section empty. The script rewrites the configuration meta tag with
        // the bundled catalogue before the workbench boots — document START (the rewrite must
        // precede the workbench's read), MAIN frame only (the meta lives on the top document).
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.recommendationTipsScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        // The focus-truth corrector: replay the blur a never-focused page misses, so only the
        // real keyboard owner renders a caret (see `focusTruthScript`). Document START (the
        // timers must span the workbench's whole boot), MAIN frame (the workbench top frame
        // owns the editor).
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.focusTruthScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        // The clipboard BRIDGE: WebKit's async clipboard API drops the workbench's copy (the
        // transient user activation is spent by the time VS Code's async path calls `writeText`),
        // so ⌘C in the editor never reached NSPasteboard. The wrap posts the text to the native
        // handler, which writes the pasteboard directly — document START (before the workbench
        // captures the API) and ALL frames (extension webviews copy too).
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.clipboardBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
        ))
        // The webview CANVAS: VS Code webview content documents are transparent at every layer
        // and scroll at frame level, so WebKit painted the slivers a markdown-preview scroll
        // exposes WHITE (`underPageBackgroundColor` and the KVC `drawsBackground` never reach a
        // subframe). Document START (the first paint needs the colour) and ALL frames (the
        // preview lives two iframes deep). See `webviewCanvasScript`.
        controller.addUserScript(WKUserScript(
            source: CodeSidebarPageDressing.webviewCanvasScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
        ))
        controller.add(Self.clipboardBridge, name: CodeSidebarPageDressing.clipboardHandlerName)
    }

    // MARK: LRU

    /// Mark `projectRoot` most-recently-used.
    private func touch(_ projectRoot: String) {
        recency.removeAll { $0 == projectRoot }
        recency.append(projectRoot)
    }

    /// Discard the coldest evictable workbench while the pool sits over
    /// ``warmWebViewCap``. Loops because a burst of mints (or a run of protected entries) can leave
    /// more than one over the line.
    private func evictColdestIfOverCap() {
        while let victim = CodeSidebarFocusPolicy.evictionVictim(
            recency: recency, protected: protectedProjectRoots(), cap: Self.warmWebViewCap,
        ) {
            evict(victim)
        }
    }

    /// The roots eviction must leave alone: whatever is on screen, and whatever is owed a keyboard
    /// hand-back on remount.
    private func protectedProjectRoots() -> Set<String> {
        Set(webViews.filter { $0.value.window != nil }.keys).union(sidebarFocusMemory.values)
    }

    /// Tear one project's workbench down completely. The webview is unparented by construction (a
    /// mounted one is never a victim); stopping the load first keeps a half-finished navigation
    /// from resolving into a released observer. Every side table drops with it, so the next visit
    /// mints a fresh webview and re-veils honestly through its boot.
    private func evict(_ projectRoot: String) {
        let webView = webViews.removeValue(forKey: projectRoot)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        navigationObservers.removeValue(forKey: projectRoot)
        loadStates.removeValue(forKey: projectRoot)
        recency.removeAll { $0 == projectRoot }
    }

    /// Hard-reload the project's webview (the strip's reload plate) — a no-op if none exists yet
    /// (the accompanying generation bump re-ensures and mints one). `package` because the plate that
    /// calls it is AppKit, one target up: the panel's strip crossed with docs/56 stage D.
    package func reload(projectRoot: String) {
        webViews[projectRoot]?.reload()
    }

    // MARK: Keyboard restore across warm swaps

    /// A webview took the keyboard (click or restore) — the tab it happened in is a PANEL tab from
    /// now on, reading this project's workbench.
    func noteKeyboardClaimed(projectRoot: String) {
        guard let tab = Self.activeTabID() else { return }
        sidebarFocusMemory[tab] = projectRoot
    }

    /// The one-hop-deferred verdict on a webview resign (see
    /// ``CodeSidebarWKWebView/resignFirstResponder()``) —
    /// ``CodeSidebarFocusPolicy/memoryAfterResign(_:resigningTab:stillInWindow:)`` decides whether
    /// the tab stops being a panel tab.
    func classifyResign(tab: TabID?, stillInWindow: Bool) {
        sidebarFocusMemory = CodeSidebarFocusPolicy.memoryAfterResign(
            sidebarFocusMemory, resigningTab: tab, stillInWindow: stillInWindow,
        )
    }

    /// A pooled webview re-entered the hierarchy. When the tab being remounted into is a PANEL tab
    /// reading THIS project (``CodeSidebarFocusPolicy/shouldRestoreOnRemount(memory:activeTab:projectRoot:)``),
    /// the keyboard is handed back; otherwise the page is told it does not have the keyboard, because
    /// the workbench autofocuses its editor on the remount and would blink a caret beside the
    /// terminal's (see ``CodeSidebarWKWebView/syncFocusTruth()``).
    func noteRemount(projectRoot: String) {
        // A mount is a use — it is what keeps the project in rotation ahead of the ones the user
        // has stopped visiting.
        touch(projectRoot)
        guard CodeSidebarFocusPolicy.shouldRestoreOnRemount(
            memory: sidebarFocusMemory, activeTab: Self.activeTabID(), projectRoot: projectRoot,
        ) else {
            (webViews[projectRoot] as? CodeSidebarWKWebView)?.syncFocusTruth()
            return
        }
        claimWhenMounted(projectRoot: projectRoot)
    }

    /// The workspace switched tabs — honour the arriving tab's focus region
    /// (``CodeSidebarFocusPolicy/tabSwitchFocus(incoming:memory:editorHoldsKeyboard:)``).
    ///
    /// `liveTabs` prunes the memory of tabs that have since closed: the pool cannot see the store,
    /// and a `TabID` nobody can reach again would otherwise sit in the map for the session's life.
    package func noteActiveTabChanged(to tab: TabID?, liveTabs: Set<TabID>) {
        sidebarFocusMemory = sidebarFocusMemory.filter { liveTabs.contains($0.key) }
        switch CodeSidebarFocusPolicy.tabSwitchFocus(
            incoming: tab, memory: sidebarFocusMemory, editorHoldsKeyboard: holdsFirstResponder(),
        ) {
        case let .claimEditor(projectRoot):
            claimWhenMounted(projectRoot: projectRoot)
        case .yieldToWorkspace:
            yieldKeyboardToWorkspace()
        case .leaveAlone:
            break
        }
    }

    /// The workspace moved its focus to a PANE inside the tab already on screen (a split's new leaf,
    /// ⌘-arrow, a rail row, a palette landing) — the tab reads its terminal again, and the keyboard
    /// has to follow.
    ///
    /// Without this the move was silently swallowed whenever the panel held the keyboard: the pane
    /// tree gates every pane's rendered focus on ``CodeSidebarKeyboardState/ownsKeyboard`` (so the
    /// terminal never re-lights and never claims first responder), and no workspace path asks the
    /// webview to resign. A fresh split then arrived with no keyboard, no focus corner and a hollow
    /// cursor, and only a CLICK into it — which forces first responder the hard way — put things
    /// right, which is what made it read as intermittent (user-reported 2026-08-10).
    package func noteWorkspacePaneFocused(tab: TabID?) {
        if let tab { sidebarFocusMemory.removeValue(forKey: tab) }
        guard holdsFirstResponder() else { return }
        yieldKeyboardToWorkspace()
    }

    /// Hand the keyboard to `projectRoot`'s workbench once the pass that asked for it has mounted it
    /// — deferred TWO runloop hops so it lands after the focused terminal's own deferred one-hop
    /// claim (the transition claim scheduled by the same render), settling the race in the editor's
    /// favour exactly once. Re-checked on arrival against BOTH the live memory and what is actually
    /// on screen, so a tab switch the user has already moved on from claims nothing.
    private func claimWhenMounted(projectRoot: String) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let pool = Self.shared
                    guard let webView = pool.mountedWebView(),
                          webView.projectRoot == projectRoot,
                          CodeSidebarFocusPolicy.shouldRestoreOnRemount(
                              memory: pool.sidebarFocusMemory,
                              activeTab: Self.activeTabID(),
                              projectRoot: projectRoot,
                          )
                    else { return }
                    webView.claimKeyboardForRestore()
                }
            }
        }
    }

    /// Give the keyboard back to the workspace: drop the ownership flag, which re-lights the active
    /// tab's focused pane and — through the terminal's focus-gated responder claim — has it take
    /// first responder, which is what actually resigns the webview.
    ///
    /// The flag leads the responder move by a hop on purpose (the pool cannot reach into the pane
    /// tree to name a view), so it is re-checked afterwards: when nothing claimed — the tab's
    /// focused pane is a video surface, or there is no pane at all — the editor really does still
    /// have the keyboard and the flag must say so, or the workspace would draw a live cursor for a
    /// pane the keys are not going to.
    private func yieldKeyboardToWorkspace() {
        CodeSidebarKeyboardState.shared.set(false)
        // Long enough for the SwiftUI pass and the pane's own deferred `makeFirstResponder` — this
        // is a repair, and being late costs nothing while being early would undo the hand-back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                guard Self.shared.holdsFirstResponder() else { return }
                CodeSidebarKeyboardState.shared.set(true)
            }
        }
    }

    // MARK: Keyboard focus by chord (⌥⌘R)

    /// Actuates ``CodeSidebarFocusPolicy/focusToggle(webViewHoldsKeyboard:hasMountedWebView:panelCollapsed:)``.
    /// `reveal` shows the panel when it is collapsed; the claim is then deferred until the webview
    /// has actually been mounted by the resulting SwiftUI pass (two hops, the same settling the
    /// warm-swap restore uses). Returns nothing — every outcome is best-effort chrome.
    package func toggleKeyboardFocus(panelCollapsed: Bool, reveal: @MainActor () -> Void) {
        switch CodeSidebarFocusPolicy.focusToggle(
            webViewHoldsKeyboard: holdsFirstResponder(),
            hasMountedWebView: mountedWebView() != nil,
            panelCollapsed: panelCollapsed,
        ) {
        case .handBack:
            guard let owner = lastKeyboardOwner, let window = owner.window else { return }
            window.makeFirstResponder(owner)
        case .claimEditor:
            mountedWebView()?.claimKeyboardForRestore()
        case .revealThenClaim:
            reveal()
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.shared.mountedWebView()?.claimKeyboardForRestore()
                    }
                }
            }
        case .none:
            break
        }
    }

    /// The pooled webview currently IN the view hierarchy. At most one is mounted at a time (the
    /// column shows the active project's workbench and unmounts the rest — that is what makes a
    /// project switch a warm swap), so this is the chord's unambiguous target.
    private func mountedWebView() -> CodeSidebarWKWebView? {
        webViews.values.lazy.compactMap { $0 as? CodeSidebarWKWebView }.first { $0.window != nil }
    }

    /// The dressing user-script source, built ONCE per process and shared by every pooled webview.
    /// The faces themselves ride the `slopdesk-font:` scheme (``CodeSidebarFontScheme``) rather
    /// than base64 data URIs, so this string is a couple of KB instead of ~4 MB. A face whose
    /// bundle resource is missing is simply left out of the sheet, never a crash.
    private static let dressingScriptSource: String = CodeSidebarPageDressing.userScript(
        styleSheet: CodeSidebarPageDressing.styleSheet(
            nerdFontURL: fontURL(.nerdSymbols),
            monoUprightURL: fontURL(.monoUpright),
            monoItalicURL: fontURL(.monoItalic),
        ),
    )

    /// The sheet's `src` URL for a face, or `nil` when the bundle has no such resource — the
    /// presence check stays HERE so the sheet never names a URL the handler would 404.
    private static func fontURL(_ face: CodeSidebarFontScheme.Face) -> String? {
        CodeSidebarFontScheme.bundledURL(for: face).map { _ in CodeSidebarFontScheme.url(for: face) }
    }

    /// Serves the `slopdesk-font:` faces to every pooled configuration. One instance for the
    /// process — the handler is stateless (it maps a URL to a memory-mapped bundle file).
    private static let fontSchemeHandler = CodeSidebarFontSchemeHandler()

    /// The clipboard bridge's native side — retained by every pool configuration's user-content
    /// controller; writes each posted copy straight to the general pasteboard.
    private static let clipboardBridge = CodeSidebarClipboardBridge()

    /// Whether the key window's first responder sits inside ANY pooled webview — the
    /// `WorkspaceKeyDispatcher`'s webview-yield predicate (while true, the embedded VS Code owns the
    /// keyboard). Checked per keystroke against the live responder; WebKit's actual first responder is
    /// an internal content subview, hence the descendant walk rather than an identity check.
    package func holdsFirstResponder() -> Bool {
        // `NSApp` is an IMPLICITLY-unwrapped global that is genuinely nil in a headless test process —
        // touch it optionally or the default dispatcher predicate traps every dispatcher unit test.
        guard let app = NSApp as NSApplication?,
              let responder = app.keyWindow?.firstResponder as? NSView
        else { return false }
        return isInsidePooledWebView(responder)
    }

    /// Whether `view` is (inside) any pooled webview — WebKit's actual first responder is an
    /// internal content subview, hence the descendant walk rather than an identity check.
    private func isInsidePooledWebView(_ view: NSView) -> Bool {
        webViews.values.contains { view === $0 || view.isDescendant(of: $0) }
    }
}

/// The native side of the clipboard bridge (`CodeSidebarPageDressing.clipboardBridgeScript()`):
/// every copy the embedded workbench performs posts its plain text here, and the handler writes
/// NSPasteboard directly — the WebKit async-clipboard permission dance can no longer drop it.
private final class CodeSidebarClipboardBridge: NSObject, WKScriptMessageHandler {
    func userContentController(
        _: WKUserContentController, didReceive message: WKScriptMessage,
    ) {
        guard message.name == CodeSidebarPageDressing.clipboardHandlerName,
              let text = message.body as? String
        else { return }
        ClientPasteboard.write(text)
    }
}

/// The webview's mount that DECAPITATES the web title bar. The workbench force-shows its title
/// bar while the activity bar sits at "top" (seed v12 — the band must host the relocated
/// accounts/manage actions), and the grid positions every part with inline absolute geometry, so
/// a CSS `display: none` leaves a dead gap instead of reflowing. The clip is the clean cut: the
/// webview is laid out TALLER than the container by exactly the title-bar height and shifted up,
/// so the band renders above the clip line — the workbench still believes in it, the user never
/// sees it (user-directed 2026-08-03). Hit-testing is bounds-guarded: without it the overhang
/// would sit under the panel's strip and eat its clicks.
final class CodeSidebarClippedContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// Mounts the pooled webview for one project inside a clipping container view. A container (not
/// the webview itself) because the pooled NSView must survive this representable's teardown —
/// SwiftUI destroys `makeNSView`'s product on structural identity changes, and the whole point of
/// the pool is that the workbench outlives the column's re-renders and project switches.
struct CodeSidebarWebView: NSViewRepresentable {
    let projectRoot: String
    let url: URL

    /// The web workbench title bar's laid-out height at zoom 1 (30px on Code 1.131). The webview
    /// overhangs the container by this much; see ``CodeSidebarClippedContainer``. Coupled to seed
    /// v12's `activityBar.location: "top"` — a seed that stops forcing the title bar should retire
    /// this to 0.
    ///
    /// It is NOT a CSS constant to grep: the workbench grid positions its parts with inline
    /// geometry, so the honest measurement is the laid-out box —
    /// `document.querySelector('#workbench\\.parts\\.titlebar').getBoundingClientRect().height`
    /// against a real workbench. It went 35 → 30 across Code 1.112 → 1.131; re-measure on every
    /// code-server bump, because being wrong here clips the editor tab row instead.
    static let clippedTitleBarHeight: CGFloat = 30

    private var topOverhang: CGFloat { Self.clippedTitleBarHeight }

    func makeNSView(context _: Context) -> NSView {
        let container = CodeSidebarClippedContainer()
        container.wantsLayer = true
        container.clipsToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = CodeSidebarWebViewPool.shared.webView(for: projectRoot, url: url)
        // Re-apply the theme backdrop on every update: the pooled webview outlives a theme
        // switch, and the creation-time snapshot would otherwise flash the OLD theme's tone on
        // scroll bounce (an appearance flip re-runs this via the colorScheme environment change).
        webView.underPageBackgroundColor = NSColor(slateHex: Slate.theme.groundHexValue)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor, constant: -topOverhang),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // A (re)mount may owe the keyboard back — the warm-swap focus restore (a first-ever mount
        // has no restore armed; the call is then a no-op).
        CodeSidebarWebViewPool.shared.noteRemount(projectRoot: projectRoot)
    }
}
#endif
