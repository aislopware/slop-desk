import CSlopDeskFFI

// MARK: - Right-click paste-protection interception

/// Whether the embedder must INTERCEPT a bare (non-⌃) right-click as a PASTE — routing it through the broad
/// paste-protection pre-check (``PastePrecheck``) — rather than letting libghostty perform the configured
/// `right-click-action` directly.
///
/// The hole this closes, and the gates that close it, are `slopdesk_terminal::surface`'s
/// `right_click_intercepts_as_paste`: libghostty owns the bare-right-click dispatch end to end and its own
/// paste gate only flags a newline or a bracketed-paste end, so the four-danger analysis ⌘V runs is
/// unreachable from a right-click unless the embedder takes the click first.
///
/// The action crosses as its ``RightClickAction/rawValue`` — the same kebab-case token the config file
/// carries — so there is no second vocabulary to keep in step.
public enum RightClickPasteInterceptPolicy {
    /// Whether a bare (non-⌃) right-click should be intercepted as a paste and routed through the pre-check.
    ///
    /// - Parameters:
    ///   - action: the live ``RightClickAction`` (``SettingsKey/rightClickAction``).
    ///   - hasSelection: whether the surface holds a selection at click time (`GhosttySurface.hasSelection()`).
    ///     Read BEFORE the click is forwarded, so it is the genuine pre-click selection.
    ///   - mouseCaptured: whether a mouse-reporting program owns the pointer (`GhosttySurface.mouseCaptured`).
    public static func interceptsAsPaste(
        action: RightClickAction,
        hasSelection: Bool,
        mouseCaptured: Bool,
    ) -> Bool {
        var token = action.rawValue
        return token.withUTF8 {
            slopdesk_term_right_click_intercepts_as_paste(
                $0.baseAddress, $0.count, hasSelection, mouseCaptured,
            )
        }
    }
}
