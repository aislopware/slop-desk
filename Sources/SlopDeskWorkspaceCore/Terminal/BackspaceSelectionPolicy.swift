import Foundation

// MARK: - E8 WI-10 (I7): backspace-deletes-selection decision

/// What the terminal view should do when ``BackspaceSelectionPolicy`` is consulted on a Backspace press
/// with the live selection / setting / mode state.
///
/// - ``deleteSelection``: delete the WHOLE selected run. The GUI actuates this best-effort (the documented
///   geometry ceiling): for the common case — a single-line selection ending at the cursor — it sends
///   `readSelection()`-many DEL bytes so the host readline erases the run; if the selection is not that
///   common shape it degrades to ``clearThenSingle`` (see ``BackspaceSelectionPolicy`` for why a faithful
///   "delete anywhere" is impossible against the pinned libghostty fork).
/// - ``clearThenSingle``: clear the selection and apply a single Backspace — the safe fallback when the
///   feature is on but DEL bytes can't faithfully map to the selection (off the editable prompt, or a
///   multi-line / non-trailing run). With no `clear_selection` binding action in the pinned fork the GUI
///   realises this by FORWARDING the Backspace through libghostty's input path, whose default-ON
///   `selection-clear-on-typing` clears the highlight while the keystroke erases one character.
/// - ``forward``: do nothing special — hand the Backspace to the normal libghostty encoder path (no
///   selection, the feature is off, or a full-screen / foreground program owns the screen and must receive
///   the key itself).
public enum BackspaceAction: Equatable, Sendable {
    case deleteSelection
    case clearThenSingle
    case forward
}

/// The PURE, headless decision behind the "Backspace deletes selection" feature (I7): given the live selection
/// state, the setting, and whether a full-screen program owns the screen / the terminal is at an editable
/// shell prompt, what should a Backspace press do?
///
/// ## Why a policy (and a documented geometry ceiling)
/// The terminal renders in the CLIENT's libghostty, which exposes **no programmatic set-selection or
/// cursor-geometry API** in the pinned fork (`TerminalViewModel` current-state note). So a *faithful*
/// "delete the whole selection wherever it sits" — which needs to know the selection's start/end columns
/// relative to the cursor to emit the right edit — is not achievable. The closest faithful equivalent (and
/// the common case in practice) is a single prompt-line run that ENDS AT THE CURSOR: there, sending
/// `readSelection().count` DEL (`0x7F`) bytes makes the host readline erase exactly that run. This enum is
/// the **testable heart** of the feature; the GUI surface (`GhosttyTerminalView`, compile-only behind
/// `#if canImport(CGhostty)`) is the thin actuator that applies the DEL-count / falls back per the ceiling.
///
/// ## The gates (the safe defaults)
/// 1. **No selection** → ``BackspaceAction/forward``: an ordinary Backspace.
/// 2. **Feature off** → ``BackspaceAction/forward``: libghostty's `selection-clear-on-typing` still clears
///    the highlight on the keystroke; we add nothing.
/// 3. **A full-screen / foreground program owns the screen** (`isAlternateScreen`) → ``BackspaceAction/forward``:
///    NEVER intercept — the key belongs to the program (vim's own Backspace, a TUI's line editor). This is the
///    "repeat inside `vim` → single-char passthrough" leg of ES-E8-2.
/// 4. Otherwise (selection present, feature on, primary screen):
///    - **at an editable prompt** (`isPromptZone`) → ``BackspaceAction/deleteSelection`` (the feature).
///    - **off the prompt** → ``BackspaceAction/clearThenSingle`` (the safe fallback where DEL bytes can't be
///      trusted to map to the selection).
///
/// Pinned by `BackspaceSelectionPolicyTests` (the un-gated / wrong-gate implementations each fail a case), so
/// a refactor that drops the alt-screen passthrough or the prompt-zone gate fails the suite — the GUI view
/// itself is outside the headless build and cannot be tested.
public enum BackspaceSelectionPolicy {
    /// Decide what a Backspace press should do.
    ///
    /// - Parameters:
    ///   - hasSelection: whether the surface currently holds a text selection
    ///     (`GhosttySurface.hasSelection()`).
    ///   - setting: the live "Backspace deletes selection" toggle
    ///     (``SettingsKey/backspaceDeletesSelectionEnabled``, default OFF — honest-disclosure: the faithful
    ///     whole-run delete is a documented geometry ceiling, so the feature ships non-default).
    ///   - isAlternateScreen: whether a full-screen / foreground program owns the screen — the GUI derives
    ///     this from the OSC-133 shell-activity the host streams (a TUI/command runs as `.running`), so a
    ///     `true` means "do not intercept; the key is the program's".
    ///   - isPromptZone: whether the terminal is at an EDITABLE shell prompt (OSC-133 idle + connected) —
    ///     the only place DEL bytes faithfully erase the selected run.
    /// - Returns: the ``BackspaceAction`` the thin GUI actuator performs.
    public static func action(
        hasSelection: Bool,
        setting: Bool,
        isAlternateScreen: Bool,
        isPromptZone: Bool,
    ) -> BackspaceAction {
        // 1. Nothing selected → ordinary Backspace.
        guard hasSelection else { return .forward }
        // 2. Feature off → ordinary Backspace (libghostty's clear-on-typing still clears the highlight).
        guard setting else { return .forward }
        // 3. A full-screen / foreground program owns the screen → the key is the program's; never intercept.
        guard !isAlternateScreen else { return .forward }
        // 4. Selection present, feature on, primary screen:
        //    at the editable prompt → delete the run (best-effort DEL bytes); else → clear + single Backspace.
        return isPromptZone ? .deleteSelection : .clearThenSingle
    }

    /// The number of LEADING DEL (`0x7F`) bytes the GUI actuator may pre-send to the host PTY for a
    /// ``BackspaceAction/deleteSelection`` decision, BEFORE the fall-through Backspace keystroke (which
    /// sends the final DEL and clears the highlight via libghostty's default-ON `selection-clear-on-typing`).
    ///
    /// ## The data-loss trap this guards (ES-E8-2)
    /// DEL bytes ALWAYS erase the characters immediately BEFORE the host cursor — so pre-sending
    /// `count − 1` DELs only erases the *selected* run when that run **ends at the cursor**. The pinned
    /// libghostty fork exposes no set-selection / cursor-geometry API, so the embedder CANNOT verify that.
    /// Selecting a word in the MIDDLE of a typed command (a natural mouse action) and pressing Backspace
    /// would otherwise delete the last N characters of the line — the WRONG characters — silently
    /// corrupting the command. So even when the user opts INTO this feature (it ships default OFF — the
    /// faithful whole-run delete is a documented geometry ceiling), an optimistic pre-send would be data loss.
    ///
    /// Therefore this returns a non-zero count ONLY when the caller can PROVE the selection ends at the
    /// cursor (`selectionEndsAtCursor == true`) AND it is a single line. The GUI passes `false` against the
    /// pinned fork, so a `.deleteSelection` decision degrades to the safe ``BackspaceAction/clearThenSingle``
    /// behaviour (a single fall-through Backspace) — the worst case becomes a one-character delete, never
    /// wrong-character deletion. The `selectionEndsAtCursor` parameter is the documented seam for a FUTURE
    /// libghostty geometry API that can prove the trailing run; until then the faithful path is dormant.
    ///
    /// Grapheme `count` is the readline-character proxy (best-effort; wide/combining glyphs are the
    /// documented residual of the geometry ceiling).
    public static func leadingDeleteCount(selection: String, selectionEndsAtCursor: Bool) -> Int {
        // Cannot prove the run ends at the cursor → never pre-send (degrade to a single Backspace).
        guard selectionEndsAtCursor else { return 0 }
        // Multi-line / empty selections can't be mapped to a contiguous DEL run → degrade likewise.
        guard !selection.isEmpty, !selection.contains("\n"), !selection.contains("\r") else { return 0 }
        return selection.count - 1
    }
}
