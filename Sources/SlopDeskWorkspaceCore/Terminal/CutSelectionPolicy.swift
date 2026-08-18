import CSlopDeskFFI

// MARK: - Cut (⌘X / Edit ▸ Cut) decision — terminal copy/cut/paste parity (audit fix)

/// What ⌘X / Edit ▸ Cut should do on the terminal surface, decided from the live selection + screen state.
///
/// - ``none``: nothing is selected — ⌘X is a no-op (there is nothing to cut).
/// - ``copyOnly``: copy the selection but NEVER delete — read-only scrollback, or a full-screen / foreground
///   program owns the screen (the delete bytes would corrupt the program's input).
/// - ``copyAndDelete``: an EDITABLE shell prompt — copy AND attempt to delete the selected run, subject to the
///   geometry ceiling ``CutSelectionPolicy/deleteCount(selection:selectionEndsAtCursor:)`` documents.
public enum CutAction: Equatable, Sendable {
    case none
    case copyOnly
    case copyAndDelete
}

/// The embedder half of the terminal **Cut** (⌘X). The GUI surface (`GhosttyTerminalView`, compile-only
/// behind `#if canImport(CGhostty)`) is the thin actuator: it performs the `copy_to_clipboard` binding
/// action for a non-``CutAction/none`` decision, and on ``CutAction/copyAndDelete`` sends
/// ``deleteCount(selection:selectionEndsAtCursor:)`` DEL (`0x7F`) bytes.
///
/// The ladder and its safe defaults are `slopdesk_terminal::surface::cut_action` /
/// `cut_delete_count` — including why the alternate screen is checked before the prompt zone, and why an
/// unprovable geometry deletes nothing rather than the wrong characters.
public enum CutSelectionPolicy {
    /// Decide what a Cut (⌘X / Edit ▸ Cut) should do.
    ///
    /// - Parameters:
    ///   - hasSelection: whether the surface currently holds a text selection (`GhosttySurface.hasSelection()`).
    ///   - isAlternateScreen: whether a full-screen / foreground program owns the screen (DECSET 1049/47/1047
    ///     via the client `TerminalModeTracker`). `true` ⇒ copy only, never delete.
    ///   - isPromptZone: whether the terminal is at an EDITABLE shell prompt (OSC-133 idle + connected) — the
    ///     only place DEL bytes can faithfully erase the selected run.
    public static func action(hasSelection: Bool, isAlternateScreen: Bool, isPromptZone: Bool) -> CutAction {
        switch slopdesk_term_cut_action(hasSelection, isAlternateScreen, isPromptZone) {
        case 1: .copyOnly
        case 2: .copyAndDelete
        default: .none
        }
    }

    /// The number of DEL (`0x7F`) bytes the GUI actuator sends for the delete half of a
    /// ``CutAction/copyAndDelete``; `0` degrades the cut to a copy.
    ///
    /// `selectionEndsAtCursor` is the documented seam for a FUTURE libghostty geometry API; until then the
    /// GUI passes `false` and the delete half is dormant.
    public static func deleteCount(selection: String, selectionEndsAtCursor: Bool) -> Int {
        var selection = selection
        return selection.withUTF8 {
            Int(slopdesk_term_cut_delete_count($0.baseAddress, $0.count, selectionEndsAtCursor))
        }
    }
}
