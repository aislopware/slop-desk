// CodeSidebarFocusPolicy — every decision about where the keyboard belongs when an embedded VS Code
// is on screen, as pure functions with no view in them.
//
// The problem it exists for is one-sided: VS Code aggressively focuses its own editor — on load, on
// file open, on layout changes — and WebKit forwards each page-level `focus()` as a native
// first-responder claim. Unguarded, an autofocus mid-keystroke silently re-routes the keyboard from
// the terminal to the editor (the cmux focus-steal lesson). So nothing here ever ASKS the page; every
// rule is the shell deciding, and the webview only ever obeys.
//
// MOST OF IT IS PLATFORM-NEUTRAL, and that is deliberate rather than incidental: the per-tab focus
// region, the resign classification, the tab-switch verdict, the ⌥⌘R toggle and the pool's eviction
// choice are all about TABS, PROJECTS and WHO HOLDS THE KEYBOARD — none of which is an AppKit
// concept. What genuinely needs AppKit is the reading of one `NSEvent`, and that is the extension at
// the bottom, three functions long. The phone reaches none of them: iOS has no app-level event
// monitor to lose a chord to, no menu bar to keep ⌘Q out of, and no shared field editor to duel with.
//
// Pinned by `CodeSidebarFocusPolicyTests`.

#if canImport(AppKit)
import AppKit
#endif

package enum CodeSidebarFocusPolicy {
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

#if canImport(AppKit)
/// The three rules that are genuinely about an AppKit EVENT. Everything above is about tabs and
/// projects and holds on both platforms; these read an `NSEvent`, and there is no iOS question they
/// answer — the phone has no app-level event monitor to lose a chord to and no menu bar to keep ⌘Q
/// out of.
extension CodeSidebarFocusPolicy {
    /// When a `becomeFirstResponder` on the embedded workbench may be HONORED: only a direct user
    /// MOUSE-DOWN inside the webview hands VS Code the keyboard. Everything else is refused — a JS
    /// autofocus arrives with no current event, or riding whatever unrelated event happens to be
    /// current, and neither is a person aiming at the editor.
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
}
#endif
