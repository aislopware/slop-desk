import CSlopDeskFFI

// MARK: - Undo-at-prompt key intercept

/// The embedder half of **Undo at prompt**: given a ⌘Z (undo) or ⌘⇧Z / ⌘Y (redo) gesture and whether the
/// terminal sits at an EDITABLE shell prompt, what raw bytes — if any — the client sends to the host PTY.
///
/// The rule is `slopdesk_terminal::surface::prompt_edit_byte`, including the readline undo byte itself, why
/// redo is recognised and deliberately unanswered, and why the prompt zone is the only place the gesture is
/// intercepted at all. The GUI surface (`GhosttyTerminalView`, compile-only behind
/// `#if canImport(CGhostty)`) is the thin actuator that maps the `NSEvent` → these flags and sends the bytes.
public enum PromptEditPolicy {
    /// Decide what bytes a prompt-edit gesture should send to the host PTY.
    ///
    /// - Parameters:
    ///   - undo: whether the gesture is an UNDO (⌘Z without Shift).
    ///   - redo: whether the gesture is a REDO (⌘⇧Z or ⌘Y). Recognised so the view can centralise the
    ///     decision here, but **always** yields `nil` — there is no portable readline redo.
    ///   - inPromptZone: whether the terminal is at an EDITABLE shell prompt (the GUI derives this as
    ///     connected AND OSC-133 idle — false while a full-screen program owns the alternate screen).
    /// - Returns: the raw bytes to send, or `nil` to forward / drop the gesture.
    public static func bytes(forUndo undo: Bool, redo: Bool, inPromptZone: Bool) -> [UInt8]? {
        let byte = slopdesk_term_prompt_edit_byte(undo, redo, inPromptZone)
        guard let byte = UInt8(exactly: byte) else { return nil }
        return [byte]
    }
}
