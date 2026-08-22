// PhoneRootKeyRung — which chords the phone's LAST responder may spend, as a pure function.
//
// The phone had exactly one place a workspace chord could resolve: the focused terminal pane's
// responder (`SlopDeskPhoneUI.TerminalInputHostView`), which asks the shared binding table off the
// pane's own ``TerminalKeyInterceptor``. So ⌘⇧P, ⌘T, ⌘D, ⌘1–9, ⌃⇥ and ⌘⇧O were alive while a
// TERMINAL pane held the keyboard and dead everywhere else — over a desktop/GUI pane, with no pane
// focused at all, and under the panel's full-screen cover. A capability that appears and disappears
// with focus is not a layout difference (docs/56 §3), so the phone grows a rung at the END of the
// responder chain and this is the rule that rung consults.
//
// ## Why the phone's rule is SMALLER than the Mac's, and must be
//
// `WorkspaceKeyDispatcher` (`SlopDeskMacUI`) is an app-level `NSEvent` monitor, and a monitor
// PREEMPTS the responder chain — it sees every keystroke before the focused view does. Everything it
// carries beyond the table is therefore a hand-written YIELD, one per surface that would otherwise
// have its keys resolved out from under it: the key-window gate, the modal-overlay gate, the webview
// gate, the literal-byte branch that must fire before the table.
//
// The phone's rung is the opposite shape: it is the LAST responder, so a chord reaches it only
// because nothing in front of it wanted the press. Precedence is then the chain itself rather than a
// second rule — a focused terminal still owns ⌘D because its responder answers first, and normal
// typing never arrives here at all. Only the two surfaces the chain CANNOT speak for need a gate:
//
//   * a summoned overlay that owns the keyboard through a focused text field. UIKit walks unhandled
//     ⌘-chords past that field to the chain's end, so without a gate ⌘W would destroy the pane behind
//     an open picker — the exact hazard the Mac's monitor names, arriving by a different road.
//   * the panel's full-screen COVER, which is the phone's layout for the Mac's third split column.
//     A chord that mutates the tree behind a cover acts on a workspace the reader cannot see, so the
//     cover yields everything EXCEPT the chords that give the keyboard back — the same two the Mac's
//     webview yield keeps, and for the same reason (see ``CodePanelKeyYield``).
//
// Pinned by `PhoneRootKeyRungTests`.

import SlopDeskWorkspaceCore

/// What the phone's last responder may do with one press.
public enum PhoneRootKeyRung: Equatable, Sendable {
    /// Resolve against the whole workspace table, ⌃⇥ walk included.
    case workspace
    /// Resolve, but spend only what ``CodePanelKeyYield`` lets through — the panel is covering the
    /// workspace and the only chords worth having are the ones that uncover it.
    case panelEscape
    /// Take nothing: a summoned surface owns the keyboard and the press is on its way to it.
    case yield
}

public enum PhoneRootKeyPolicy {
    /// The rung one press lands on.
    ///
    /// The COVER is asked first and deliberately: it is a system presentation, so it is also true
    /// that "something is presented" while it is up, and answering that question first would leave a
    /// railed panel with no chord to close it. Pure — pinned by `PhoneRootKeyRungTests`.
    ///
    /// - Parameters:
    ///   - panelPresented: the right panel's cover is up (`!chrome.codeSidebarCollapsed`).
    ///   - overlayCapturesKeyboard: ``OverlayCoordinator/capturesKeyboardWhileVisible`` — the single
    ///     source of truth the Mac's monitor reads for the same question.
    ///   - systemPresentationUp: any other modal presentation over the workspace (Settings, the
    ///     first-launch checklist, the cheat sheet's sheet). Read off UIKit rather than off a flag,
    ///     because a phone's summoned surfaces are presentations and the presenter already knows.
    public static func rung(
        panelPresented: Bool, overlayCapturesKeyboard: Bool, systemPresentationUp: Bool,
    ) -> PhoneRootKeyRung {
        if panelPresented { return .panelEscape }
        if overlayCapturesKeyboard || systemPresentationUp { return .yield }
        return .workspace
    }
}

/// The workspace actions that still fire while the embedded code panel owns the screen.
///
/// ONE set, both shells. On the Mac the panel owns the KEYBOARD (its `WKWebView` is first responder
/// and the whole VS Code chord vocabulary collides with the workspace table); on the phone it owns
/// the SCREEN (a full-screen cover over the workspace). Different layouts, one question — how does
/// the keyboard get back out — and one answer, so it is spelled here rather than once per shell.
///
/// It must stay exactly the size of that job. ⌘⇧R hides the panel; ⌥⌘R hands the keyboard to the
/// pane that had it. Anything broader would start shadowing the editor's own chords, which is what
/// the reader went into the panel to use. Pure — pinned by `PhoneRootKeyRungTests`.
public enum CodePanelKeyYield {
    public static func survives(_ action: WorkspaceAction) -> Bool {
        action == .toggleCodeSidebar || action == .focusCodePanel
    }
}
