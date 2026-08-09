import Foundation

// MARK: - BlockOutputSanitizer (raw VT bytes → clipboard plain text)

/// Turns a Block's RAW captured VT output bytes (control sequences preserved on the wire) into PLAIN
/// TEXT suitable for the clipboard (WB2): it strips the terminal control sequences (CSI / SGR colour
/// runs, OSC, single-char C0/C1 controls) and keeps the PRINTABLE characters + newlines + tabs.
///
/// This is a deliberately SMALL, robust VT skimmer — not a full terminal emulator. It does not try to
/// interpret cursor motion / clears (the host's captured output is already the on-screen byte stream for
/// the command, so a linear strip reproduces what the user saw closely enough for a copy). It is built to
/// NEVER trap on a malformed / truncated sequence: an unterminated CSI/OSC at end-of-buffer simply
/// consumes to the end, and every index advance is bounds-checked.
///
/// PURE + `nonisolated` so it runs off any actor and is headlessly unit-testable (the WB2 brief's ask:
/// colour runs stripped, text preserved, malformed sequences don't trap).
public enum BlockOutputSanitizer {
    /// Strips VT control sequences from `bytes` and decodes the surviving printable run as UTF-8
    /// (lossy: an invalid byte becomes U+FFFD — the clipboard text is best-effort, never a throw).
    ///
    /// It is ``AnsiStyledParser/lines(from:)`` with the styles DISCARDED. The skimming rules — the CR
    /// line-rewrite so a progress bar collapses to its final frame, `ESC [ K` truncation, C0
    /// dropping, tab and newline preservation, the zsh `PROMPT_EOL_MARK` chop — all live there now,
    /// so the clipboard's text and the peek card's coloured text can never be two behaviours
    /// (2026-08-09). Every rule this file used to own is still pinned by `BlockOutputSanitizerTests`.
    public nonisolated static func plainText(from bytes: Data) -> String {
        guard !bytes.isEmpty else { return "" }
        return AnsiStyledParser.lines(from: bytes)
            .map { $0.map(\.text).joined() }
            .joined(separator: "\n")
    }
}
