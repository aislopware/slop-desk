import CSlopDeskFFI

// MARK: - The embedder side of the clipboard-WRITE "Ask" gate

/// What the terminal embedder should do when libghostty asks it to WRITE the pasteboard — a
/// `copy_to_clipboard` binding action or, the security-relevant case, a remote program's OSC-52 WRITE.
///
/// - ``write``: write the text to the pasteboard now (the program is allowed — `clipboard-write = allow`,
///   the libghostty default — so libghostty passes `confirm == false`).
/// - ``confirm``: a confirmation is REQUIRED before writing (`clipboard-write = ask` — libghostty passes
///   `confirm == true`). The embedder presents the "a program wants to set your clipboard" sheet and writes
///   ONLY on approve; a cancel drops the write.
/// - ``drop``: nothing to write (empty payload) — a no-op (validate-then-drop).
public enum ClipboardWriteDecision: Equatable, Sendable {
    case write
    case confirm
    case drop
}

/// The embedder half of the **clipboard-write = ask** gate at the libghostty `write_clipboard_cb`.
///
/// The decision is `slopdesk_terminal::surface::clipboard_write`, which also carries why it is a decision
/// at all: libghostty enforces `deny` and `allow` itself, but DELEGATES `ask` — it calls the write callback
/// with `confirm` set and trusts the embedder to gate, so a callback that ignored the flag would make "Ask"
/// behave as "Allow" and let any remote OSC-52 overwrite the clipboard silently.
///
/// The GUI surface (`GhosttyTerminalView.write_clipboard_cb`, compile-only behind `#if canImport(CGhostty)`)
/// reads the C `confirm` bool, calls ``decide(confirmRequested:text:)``, and either writes, presents the
/// sheet, or drops. The READ direction stays a separate type (``ClipboardAccess/silentClipboardRead(text:)``):
/// that access is a 3-state config value the embedder resolves, while this confirm is a per-call flag.
public enum ClipboardWritePolicy {
    /// Decide what a libghostty clipboard WRITE should do.
    ///
    /// - Parameters:
    ///   - confirmRequested: the libghostty `write_clipboard_cb` `confirm` flag — `true` when
    ///     `clipboard-write = ask` (the embedder must confirm before writing), `false` when `allow`.
    ///   - text: the text/plain payload libghostty is asking to write.
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
