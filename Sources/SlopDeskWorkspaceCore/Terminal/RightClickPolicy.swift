import CSlopDeskFFI

// MARK: - Bare right-click dispatch

/// What a bare (non-⌃) right-click does on the terminal surface.
///
/// - ``forward``: hand the press to the program — it asked for the pointer, so the click is its input.
/// - ``paste``: take it as a paste, through the broad pre-check (``PastePrecheck``).
/// - ``copy``: copy the selection.
/// - ``menu``: pop the native context menu (``TerminalContextMenu``).
/// - ``ignore``: swallow it.
public enum RightClickOutcome: Equatable, Sendable {
    case forward
    case paste
    case copy
    case menu
    case ignore
}

/// The embedder half of the bare right-click. The GUI surface (`MacTerminalRendererView`) is the thin
/// actuator: it performs the outcome and, for ``RightClickOutcome/forward``, falls through to the menu
/// only when the engine did not consume the press after all.
///
/// The ladder is `slopdesk_terminal::surface::right_click` — including why a mouse-reporting program
/// outranks every arm, why Copy-or-Paste reads the PRE-CLICK selection, and why the paste arm has to
/// pass through this side at all rather than dispatching inside the engine.
///
/// The action crosses as its ``RightClickAction/rawValue`` — the same kebab-case token the config file
/// carries — so there is no second vocabulary to keep in step.
public enum RightClickPolicy {
    /// Decide what a bare (non-⌃) right-click should do.
    ///
    /// - Parameters:
    ///   - action: the live ``RightClickAction`` (``SettingsKey/rightClickAction``).
    ///   - hasSelection: whether the surface holds a selection at click time (`TerminalSurfaceActions.hasSelection()`).
    ///     Read BEFORE the click is forwarded, so it is the genuine pre-click selection.
    ///   - mouseCaptured: whether a mouse-reporting program owns the pointer.
    public static func outcome(
        action: RightClickAction,
        hasSelection: Bool,
        mouseCaptured: Bool,
    ) -> RightClickOutcome {
        var token = action.rawValue
        let answer = token.withUTF8 {
            slopdesk_term_right_click($0.baseAddress, $0.count, hasSelection, mouseCaptured)
        }
        return switch answer {
        case 1: .paste
        case 2: .copy
        case 4: .ignore
        case 0: .forward
        default: .menu
        }
    }
}
