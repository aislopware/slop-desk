import CSlopDeskFFI

// MARK: - Mouse-over-to-focus decision

/// The embedder half of "Mouse-over-to-focus" / `focus-follows-mouse`: given the live setting and whether
/// THIS pane is already the focused one, should hovering it claim the workspace focus?
///
/// The gate — and why the already-focused term is load-bearing rather than an optimisation — is
/// `slopdesk_terminal::surface::focus_follows_mouse`. The GUI view (`GhosttyTerminalView`, compile-only
/// behind `#if canImport(CGhostty)`) is the thin actuator: its `mouseEntered` / `mouseMoved` consult this
/// and, on `true`, fire `TerminalViewModel.onRequestFocus`.
public enum FocusFollowsMousePolicy {
    /// Whether a hover over this pane should request the workspace focus.
    ///
    /// - Parameters:
    ///   - focusFollowsMouse: the live `focus-follows-mouse` setting (read by the view from
    ///     ``SettingsKey/focusFollowsMouseEnabled`` so a Settings toggle takes effect on the next hover).
    ///   - isAlreadyFocused: whether THIS pane is already the workspace's focused pane.
    public static func shouldRequestFocus(focusFollowsMouse: Bool, isAlreadyFocused: Bool) -> Bool {
        slopdesk_term_focus_follows_mouse(focusFollowsMouse, isAlreadyFocused)
    }
}
