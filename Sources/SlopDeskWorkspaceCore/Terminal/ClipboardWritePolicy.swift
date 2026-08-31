import CSlopDeskFFI

// MARK: - The embedder side of the clipboard-WRITE "Ask" gate

/// What the terminal surface should do when a program asks it to WRITE the pasteboard — a
/// `copy_to_clipboard` binding action or, the security-relevant case, a remote program's OSC-52 WRITE.
///
/// - ``write``: write the text to the pasteboard now (the program is allowed — `clipboard-write = allow`).
/// - ``confirm``: a confirmation is REQUIRED before writing (`clipboard-write = ask`). The surface presents
///   the "a program wants to set your clipboard" sheet and writes ONLY on approve; a cancel drops the write.
/// - ``drop``: nothing to write — an empty payload, or `clipboard-write = deny`.
public enum ClipboardWriteDecision: Equatable, Sendable {
    case write
    case confirm
    case drop
}

/// The client half of the **clipboard-write** gate.
///
/// ⚠️ **ALL THREE ARMS ARE THIS SIDE'S NOW, and that is a change.** The deleted fork's libghostty
/// enforced `deny` and `allow` inside the engine and delegated only `ask`, passing a per-call
/// `confirm` bool the embedder had to honour. `libghostty-vt` holds no such config: it reports every
/// OSC-52 write unconditionally through `slopdesk_term_surface_take_clipboard_writes` and decides
/// nothing. So a caller that only handled the `ask` arm would now let `deny` write the pasteboard —
/// the same class of silent-overwrite defect the old flag existed to prevent, arriving from the
/// opposite direction.
///
/// ``decide(access:text:)`` is therefore the entry point every caller should use: it takes the
/// user's `clipboard-write` setting and cannot be called without deciding what `deny` means.
/// ``decide(confirmRequested:text:)`` remains the two-arm primitive underneath it, for the
/// `copy_to_clipboard` binding action, where the user's own keystroke IS the consent and only the
/// emptiness check applies.
///
/// The verdict itself is `slopdesk_terminal::surface::clipboard_write`'s, so the rule lives in one
/// language. The READ direction stays a separate type (``ClipboardAccess/silentClipboardRead(text:)``).
public enum ClipboardWritePolicy {
    /// Decide what a program's clipboard WRITE should do, given the user's `clipboard-write` setting.
    ///
    /// The one door for the OSC-52 path. ``ClipboardAccess/deny`` drops before the text is looked at,
    /// which is also why the deny arm cannot be forgotten: it is not a flag a caller passes, it is a
    /// case this function handles.
    public static func decide(access: ClipboardAccess, text: String) -> ClipboardWriteDecision {
        switch access {
        case .deny: .drop
        case .allow: decide(confirmRequested: false, text: text)
        case .ask: decide(confirmRequested: true, text: text)
        }
    }

    /// Decide what a clipboard WRITE should do from a per-call confirm flag.
    ///
    /// - Parameters:
    ///   - confirmRequested: `true` when the write must be confirmed before it happens.
    ///   - text: the text/plain payload being asked for.
    public static func decide(confirmRequested: Bool, text: String) -> ClipboardWriteDecision {
        var text = text
        let answer = text.withUTF8 {
            slopdesk_term_clipboard_write(confirmRequested, $0.baseAddress, $0.count)
        }
        return switch answer {
        case 0: .write
        case 1: .confirm
        default: .drop
        }
    }
}
