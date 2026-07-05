import Foundation

// MARK: - Right-click paste-protection interception (audit fix — rightclick-paste-protection-hole)

/// The PURE decision behind closing the right-click paste-protection hole: whether the embedder must
/// INTERCEPT a bare (non-⌃) right-click as a PASTE — routing it through the broad paste-protection
/// pre-check (``PastePrecheck``) — rather than letting libghostty perform the configured `right-click-action`
/// directly.
///
/// ## Why this exists
/// The bare-right-click dispatch is owned END-TO-END by libghostty via the `right-click-action` config
/// (WI-7), so a `Paste` / `Copy or Paste` action pastes through libghostty's OWN gate, which only flags a
/// `\n` / bracketed-end payload (`isSafe`). This codebase's four-danger analyzer (single-line `sudo`/`su`, control
/// chars, trailing newline, multi-line) is therefore UNREACHABLE for a right-click paste — a single-line
/// `sudo rm -rf …` reaches the shell with no protection sheet. When this returns `true` the embedder
/// intercepts the click BEFORE forwarding and runs the same ``PastePrecheck`` ⌘V uses.
///
/// ## The gates
/// - **A mouse-reporting program owns the click** (`mouseCaptured`) → never intercept: the click is the
///   program's input (it would otherwise steal a TUI's right-click).
/// - **``RightClickAction/paste``** → intercept (always a paste).
/// - **``RightClickAction/copyOrPaste``** → intercept ONLY when there is NO selection (with a selection it
///   copies, which needs no protection; with none it pastes). The selection is read at click time, BEFORE
///   forwarding, so it is the genuine pre-click selection — not a word-select libghostty injected.
/// - **``RightClickAction/contextMenu`` / ``copy`` / ``ignore``** → do not intercept (no paste happens; the
///   click is handed to libghostty as before).
public enum RightClickPasteInterceptPolicy {
    /// Whether a bare (non-⌃) right-click should be intercepted as a paste and routed through the pre-check.
    ///
    /// - Parameters:
    ///   - action: the live ``RightClickAction`` (``SettingsKey/rightClickAction``).
    ///   - hasSelection: whether the surface holds a selection at click time (`GhosttySurface.hasSelection()`).
    ///   - mouseCaptured: whether a mouse-reporting program owns the pointer (`GhosttySurface.mouseCaptured`).
    public static func interceptsAsPaste(
        action: RightClickAction,
        hasSelection: Bool,
        mouseCaptured: Bool,
    ) -> Bool {
        // A mouse-reporting program owns the click — never steal it for a local paste.
        guard !mouseCaptured else { return false }
        switch action {
        case .paste:
            return true
        case .copyOrPaste:
            // Copy-or-Paste pastes only when there is nothing selected to copy.
            return !hasSelection
        case .contextMenu,
             .copy,
             .ignore:
            return false
        }
    }
}
