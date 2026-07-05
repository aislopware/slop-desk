import Foundation

// MARK: - BlockReRunEncoder (re-inject a captured command verbatim)

/// Encodes a ``CommandBlock``'s captured `commandText` into the exact bytes to RE-INJECT into the pane's
/// shell as if the user re-typed and ran it (WB3 — "Re-run Command"). The bytes funnel through
/// ``TerminalViewModel/sendInput(_:)`` (wire type 3 `.input`) — there is NO host / wire change; the host
/// sees ordinary keystrokes.
///
/// SECURITY + CORRECTNESS — why this DELIBERATELY differs from ``LaunchPreset``'s user-authored command:
///   - **Verbatim literal UTF-8, never `SendKeysParser`.** A captured command may literally CONTAIN the
///     substrings `"<Enter>"` / `"<cr>"` (e.g. `echo "<Enter>"`); routing it through the send-keys parser
///     would CORRUPT it (turning the literal text into a control byte) AND is an injection hazard (host
///     output is attacker-influenced). ``LaunchPreset`` parses its command field because THAT is
///     user-authored macro text; a re-run replays exactly what was already executed, so it stays literal.
///   - **Exactly ONE trailing newline.** Any trailing CR/LF the host segmented into `commandText` is
///     stripped, then a single `0x0A` is appended to EXECUTE — preventing a double-execute when the
///     captured text already ended in a newline.
///   - **Embedded MIDDLE newlines are preserved** — the user typed a multi-line command; replay it as-is.
///   - **Empty / whitespace-only → `nil`** — never send a bare newline (which would just re-draw the
///     prompt and is a confusing no-op).
enum BlockReRunEncoder {
    /// The bytes to inject to re-run `commandText`, or `nil` for an empty / whitespace-only command.
    ///
    /// The command is encoded as VERBATIM literal UTF-8 (never `SendKeysParser`), with any trailing CR/LF
    /// removed and exactly one `0x0A` appended to execute it.
    static func bytes(for commandText: String) -> Data? {
        // Whitespace-only (or empty) → no-op: never send a bare newline.
        guard !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Strip ANY trailing CR/LF run (a captured command may end in "\n" or "\r\n"); MIDDLE newlines
        // stay — the user typed them. Trim at the BYTE level, NOT by `Character`: Swift clusters "\r\n"
        // into ONE grapheme, so a `Character`-based trim would miss "make\r\n" → double newline.
        var bytes = [UInt8](commandText.utf8)
        while let last = bytes.last, last == 0x0A || last == 0x0D {
            bytes.removeLast()
        }

        // VERBATIM literal UTF-8 of the (suffix-trimmed) command + EXACTLY one newline to execute.
        bytes.append(0x0A)
        return Data(bytes)
    }
}
