import Foundation

// MARK: - E8 WI-11 (I18): undo-at-prompt key intercept

/// The PURE, headless decision behind **Undo at prompt** (I18): given a ⌘Z (undo) or ⌘⇧Z / ⌘Y
/// (redo) gesture and whether the terminal sits at an EDITABLE shell prompt, what raw bytes — if any —
/// should the client send to the host PTY?
///
/// ## Why a policy (and why redo is omitted)
/// The terminal renders in the CLIENT's libghostty; there is no host round-trip for the keystroke decision.
/// slopdesk maps ⌘Z at the prompt to the **readline undo** control code — Ctrl-`_` (`0x1F`) — so the remote
/// shell's line editor (readline / zle) rolls back the last prompt edit (`docs/ui-shell/spec/terminal-features__input.md`:
/// "slopdesk can intercept `⌘Z`/`⌘⇧Z` and emit the corresponding readline undo sequences (`⌃_` for undo)").
/// There is **no portable readline *redo*** sequence (GNU readline binds `C-_`/`C-x C-u` to undo but exposes
/// no inverse), so ⌘⇧Z / ⌘Y is a **documented omit**: the policy recognises the redo intent and returns `nil`
/// (the view forwards / drops it; it never fabricates a wrong byte). This enum is the **testable heart** of
/// the feature; the GUI surface (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) is the
/// thin actuator that maps the NSEvent → these flags and sends the returned bytes.
///
/// ## The gate (see `docs/ui-shell/spec/terminal-features__input.md` + the safe default)
/// Undo "applies to the current prompt line; it is unavailable inside full-screen programs (vim, less,
/// editors) which manage their own undo history" (`docs/ui-shell/spec/terminal-features__input.md`). So the single gate is
/// the **prompt zone**: only when the terminal is at an editable shell prompt (the GUI derives this exactly
/// like ``BackspaceSelectionPolicy`` — connected AND OSC-133 idle, which is false while a TUI owns the
/// alternate screen) does ⌘Z emit the undo byte. Off the prompt — inside `vim`/`less`, mid-command, or
/// disconnected — the policy returns `nil` so the chord falls through and the foreground program keeps its
/// own undo (the "⌘Z in vim passes through" leg).
///
/// Pinned by `PromptEditPolicyTests`: an implementation that ignored the prompt-zone gate, emitted bytes for
/// redo, or used the wrong control code each fails a specific case.
public enum PromptEditPolicy {
    /// The readline UNDO control byte: **Ctrl-`_`** == `0x1F` (the underscore `0x5F` masked to its C0 control
    /// code, `0x5F & 0x1F`). GNU readline / zsh-zle bind this to `undo`; sending it at the prompt rolls back
    /// the last line edit.
    public static let readlineUndo: UInt8 = 0x1F

    /// Decide what bytes a prompt-edit gesture should send to the host PTY.
    ///
    /// - Parameters:
    ///   - undo: whether the gesture is an UNDO (⌘Z without Shift). Maps to the readline undo byte when in the
    ///     prompt zone.
    ///   - redo: whether the gesture is a REDO (⌘⇧Z or ⌘Y). Recognised so the view can centralise the
    ///     decision here, but **always** yields `nil` — there is no portable readline redo (documented omit).
    ///   - inPromptZone: whether the terminal is at an EDITABLE shell prompt (the GUI derives this as
    ///     connected AND OSC-133 idle — false while a full-screen program owns the alternate screen). The only
    ///     place the readline undo byte is meaningful; off the prompt the gesture belongs to the program.
    /// - Returns: the raw bytes to send (`[``readlineUndo``]` for an in-prompt undo), or `nil` to forward /
    ///   drop the gesture (off the prompt, a redo, or neither).
    public static func bytes(forUndo undo: Bool, redo: Bool, inPromptZone: Bool) -> [UInt8]? {
        // Off the editable prompt (inside vim/less, mid-command, or disconnected) → never intercept; the
        // foreground program owns its own undo history.
        guard inPromptZone else { return nil }
        // Redo is recognised but unsupported — there is no portable readline redo (documented omit) — so a
        // redo gesture yields no bytes; only an undo emits the readline undo control code.
        if redo { return nil }
        return undo ? [readlineUndo] : nil
    }
}
