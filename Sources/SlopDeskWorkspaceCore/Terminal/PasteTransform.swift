import Foundation
import SlopDeskWorkspaceModel

// MARK: - "Paste as…" clipboard transforms

/// PURE clipboard transforms behind the **Edit ▸ Paste as…** submenu. Each rewrites the text (or file
/// bytes) BEFORE the engine frames it. Cross-platform, AppKit-free, allocation-light.
///
/// ## What is deliberately NOT here: the framing
///
/// This type used to carry a `bracketed(_:)` that wrapped text in `ESC [ 200 ~` / `ESC [ 201 ~` and
/// stripped any smuggled end marker. Every one of those is a rule about how the FAR side's parser
/// behaves, and the engine that owns that parser implements all of them plus the control-byte scrub
/// and the newline rewrite — `slopdesk_term_surface_encode_paste`. Two spellings of the framing is
/// how one of them drifts, and the one that would drift is the one with no VT100 test suite behind
/// it. `TerminalSurfaceDriver.PasteBracketing` is where "bracketed or not" is now decided.
///
/// Two of the four Paste-as variants are not transforms at all: **Paste Selection** is a source swap
/// (the surface's selection instead of the clipboard) and **Bracketed Paste** is a framing override.
///
/// The two that ARE transforms:
/// - ``shellEscaped(_:)`` — POSIX shell-quote so spaces / metacharacters land as literals (ideal for a
///   pasted file path).
/// - ``base64(ofFileBytes:)`` — base64-encode chosen file bytes so binary content can ride a text session.
public enum PasteTransform {
    /// POSIX shell-quotes `text` (equivalent to Python's `shlex.quote`): a token of only safe characters is
    /// returned verbatim; anything else is wrapped in single quotes, with each embedded single-quote emitted
    /// as `'\''` (close-quote, backslash-escaped quote, reopen-quote). The empty string becomes `''`.
    ///
    /// A face over ``ShellQuoting/shlexQuote(_:)``, which reads the safe set in Rust — the same rule the
    /// `cd` a jump emits and a template's opening line are quoted by.
    public static func shellEscaped(_ text: String) -> String { ShellQuoting.shlexQuote(text) }

    /// Base64-encodes raw file bytes for ferrying binary content over a plain-text session. Empty input
    /// yields the empty string. The caller reads the file defensively (an unreadable file never reaches
    /// here) — this is a total function over whatever bytes it is handed.
    public static func base64(ofFileBytes bytes: Data) -> String {
        bytes.base64EncodedString()
    }
}
