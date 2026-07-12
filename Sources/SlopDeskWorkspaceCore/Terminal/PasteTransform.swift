import Foundation

// MARK: - "Paste as…" clipboard transforms

/// PURE clipboard transforms behind the **Edit ▸ Paste as…** submenu. Each variant rewrites the text
/// (or file bytes) BEFORE it reaches the shell via the surface's `text(_:)` typing path. Cross-platform,
/// AppKit-free, allocation-light — the testable heart of the Paste-as wiring in `GhosttyTerminalView`.
///
/// One of the four Paste-as variants is NOT a transform and lives in the GUI/store as ROUTING, not here:
/// - **Paste Selection** reads `surface.readSelection()` instead of the clipboard (a source swap).
///
/// The three that ARE transforms:
/// - ``bracketed(_:)`` — force DEC bracketed-paste framing even if the program never advertised it.
/// - ``shellEscaped(_:)`` — POSIX shell-quote so spaces / metacharacters land as literals (ideal for a
///   pasted file path).
/// - ``base64(ofFileBytes:)`` — base64-encode chosen file bytes so binary content can ride a text session.
public enum PasteTransform {
    /// DEC bracketed-paste START marker (`ESC [ 200 ~`).
    public static let bracketStart = "\u{1b}[200~"
    /// DEC bracketed-paste END marker (`ESC [ 201 ~`).
    public static let bracketEnd = "\u{1b}[201~"

    /// Wraps `text` in DEC bracketed-paste markers so the receiving program treats it as one inert block
    /// (newlines are NOT interpreted as Enter), regardless of whether it advertised `?2004h`.
    ///
    /// Any END marker already embedded in `text` is STRIPPED first: a clipboard payload that smuggled an
    /// `ESC [ 201 ~` could otherwise terminate the bracketed block early and inject the trailing bytes as
    /// live input (the classic bracketed-paste breakout). Removing it keeps the whole payload inert — the
    /// guarantee the "Paste Bracketed Safe" skip rule (`PasteSafetyAnalyzer`) relies on.
    public static func bracketed(_ text: String) -> String {
        let inert = text.replacingOccurrences(of: bracketEnd, with: "")
        return bracketStart + inert + bracketEnd
    }

    /// POSIX shell-quotes `text` (equivalent to Python's `shlex.quote`): a token of only safe characters is
    /// returned verbatim; anything else is wrapped in single quotes, with each embedded single-quote emitted
    /// as `'\''` (close-quote, backslash-escaped quote, reopen-quote). The empty string becomes `''`.
    ///
    /// The "safe" set mirrors `shlex` — `[A-Za-z0-9_@%+=:,./-]` — so a typical file path with spaces becomes
    /// `'…'` and `$`, `;`, `&`, `|`, `*`, `(`, `)`, backticks etc. are neutralised as literals.
    public static func shellEscaped(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        if text.unicodeScalars.allSatisfy(isShellSafe) { return text }
        // Wrap in single quotes; an embedded ' closes the quote, emits an escaped quote, then reopens.
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    /// Base64-encodes raw file bytes for ferrying binary content over a plain-text session. Empty input
    /// yields the empty string. The caller reads the file defensively (an unreadable file never reaches
    /// here) — this is a total function over whatever bytes it is handed.
    public static func base64(ofFileBytes bytes: Data) -> String {
        bytes.base64EncodedString()
    }

    // MARK: Private

    /// Whether `s` is safe to leave unquoted in a POSIX shell word (the `shlex` safe set).
    private static func isShellSafe(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "a"..."z",
             "A"..."Z",
             "0"..."9":
            true
        case "@",
             "%",
             "+",
             "=",
             ":",
             ",",
             ".",
             "/",
             "-",
             "_":
            true
        default:
            false
        }
    }
}
