import Foundation

// MARK: - Cut (⌘X / Edit ▸ Cut) decision — terminal copy/cut/paste parity (audit fix)

/// What ⌘X / Edit ▸ Cut should do on the terminal surface, decided from the live selection + screen state.
///
/// The Cut behavior (tracked in `docs/ui-shell/spec/terminal-features__input.md`): Cut (⌘X) always copies the
/// selection to the clipboard; if editable prompt text, also deletes it; on read-only, falls back to a plain copy.
///
/// - ``none``: nothing is selected — ⌘X is a no-op (there is nothing to cut).
/// - ``copyOnly``: copy the selection but NEVER delete — read-only scrollback, or a full-screen / foreground
///   program owns the screen (the delete bytes would corrupt the program's input).
/// - ``copyAndDelete``: an EDITABLE shell prompt — copy AND attempt to delete the selected run, subject to the
///   SAME geometry ceiling as ``BackspaceSelectionPolicy`` (see ``CutSelectionPolicy/deleteCount(selection:selectionEndsAtCursor:)``).
public enum CutAction: Equatable, Sendable {
    case none
    case copyOnly
    case copyAndDelete
}

/// The PURE, headless decision behind the terminal **Cut** (⌘X). The GUI surface (`GhosttyTerminalView`,
/// compile-only behind `#if canImport(CGhostty)`) is a thin actuator: it always performs the
/// `copy_to_clipboard` binding action for a non-``CutAction/none`` decision, and on ``CutAction/copyAndDelete``
/// sends ``deleteCount(selection:selectionEndsAtCursor:)`` DEL (`0x7F`) bytes.
///
/// ## The gates (the safe defaults, mirroring ``BackspaceSelectionPolicy``)
/// 1. **No selection** → ``CutAction/none``: nothing to copy or cut.
/// 2. **A full-screen / foreground program owns the screen** (`isAlternateScreen`) → ``CutAction/copyOnly``:
///    copy the native selection, but NEVER inject deletes (the key/bytes belong to the program).
/// 3. **At an editable prompt** (`isPromptZone`) → ``CutAction/copyAndDelete`` (the feature).
/// 4. **Off the prompt (read-only scrollback)** → ``CutAction/copyOnly`` (the spec's read-only fallback).
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
        guard hasSelection else { return .none }
        // A full-screen / foreground program owns the screen → copy the selection, but never inject deletes.
        guard !isAlternateScreen else { return .copyOnly }
        // Editable prompt → copy + delete; read-only scrollback → copy only (the spec's read-only fallback).
        return isPromptZone ? .copyAndDelete : .copyOnly
    }

    /// The number of DEL (`0x7F`) bytes the GUI actuator sends for the delete half of a
    /// ``CutAction/copyAndDelete``.
    ///
    /// Subject to the SAME geometry ceiling ``BackspaceSelectionPolicy/leadingDeleteCount(selection:selectionEndsAtCursor:)``
    /// documents: DEL bytes ALWAYS erase the characters immediately BEFORE the host cursor, so they only erase
    /// the SELECTED run when that run ENDS AT THE CURSOR. The pinned libghostty fork exposes no
    /// set-selection / cursor-geometry API, so the embedder cannot prove that — and an optimistic pre-send of
    /// a mid-line selection would delete the WRONG characters (silent data loss). Therefore this returns a
    /// non-zero count ONLY when the caller can PROVE the selection ends at the cursor AND it is a single line;
    /// otherwise 0, so the cut degrades to copy-only (the documented ceiling).
    ///
    /// Unlike Backspace there is NO fall-through key for ⌘X, so the FULL selection length is returned (not
    /// `count - 1`). `selectionEndsAtCursor` is the documented seam for a FUTURE libghostty geometry API; until
    /// then the GUI passes `false` and the delete half is dormant.
    public static func deleteCount(selection: String, selectionEndsAtCursor: Bool) -> Int {
        // Cannot prove the run ends at the cursor → never pre-send (degrade to copy-only).
        guard selectionEndsAtCursor else { return 0 }
        // Multi-line / empty selections can't be mapped to a contiguous DEL run → degrade likewise.
        guard !selection.isEmpty, !selection.contains("\n"), !selection.contains("\r") else { return 0 }
        return selection.count
    }
}
