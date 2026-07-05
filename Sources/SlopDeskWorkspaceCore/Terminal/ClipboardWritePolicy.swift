import Foundation

// MARK: - E8 WI-2 (I11): the embedder side of the clipboard-WRITE "Ask" gate

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

/// The PURE, headless decision behind the **clipboard-write = ask** gate at the libghostty `write_clipboard_cb`.
///
/// ## Why this exists (the inert-"Ask" bug)
/// E8 surfaces a clipboard-write Allow / Deny / Ask picker and the config builder emits `clipboard-write =
/// ask`. libghostty enforces `deny` itself (it never calls the write callback) and `allow` itself (it calls
/// the callback with `confirm == false`), but `ask` is DELEGATED to the embedder: libghostty calls
/// `write_clipboard_cb` with `confirm == true` and trusts the embedder to gate the write. The old callback
/// IGNORED that `confirm` argument and wrote the pasteboard unconditionally — so "Ask" silently behaved like
/// "Allow", and any remote OSC-52 could overwrite the system clipboard with no prompt.
///
/// This enum is the **testable heart** of the fix; the GUI surface (`GhosttyTerminalView.write_clipboard_cb`,
/// compile-only behind `#if canImport(CGhostty)`) is the thin actuator that reads the C `confirm` bool,
/// calls ``decide(confirmRequested:text:)``, and either writes, presents the confirmation sheet, or drops.
/// It mirrors the READ-ask plumbing (``ClipboardAccess/silentClipboardRead(text:)`` →
/// `slopdeskConfirmClipboardRead`); the two directions stay separate enums because the READ access is a
/// 3-state config value the embedder resolves, while the WRITE confirm is a per-call flag libghostty hands us.
public enum ClipboardWritePolicy {
    /// Decide what a libghostty clipboard WRITE should do.
    ///
    /// - Parameters:
    ///   - confirmRequested: the libghostty `write_clipboard_cb` `confirm` flag — `true` when
    ///     `clipboard-write = ask` (the embedder must confirm before writing), `false` when `allow`.
    ///   - text: the text/plain payload libghostty is asking to write.
    /// - Returns: ``ClipboardWriteDecision/drop`` for an empty payload (validate-then-drop),
    ///   ``ClipboardWriteDecision/confirm`` when a prompt is required, else ``ClipboardWriteDecision/write``.
    public static func decide(confirmRequested: Bool, text: String) -> ClipboardWriteDecision {
        guard !text.isEmpty else { return .drop }
        return confirmRequested ? .confirm : .write
    }
}
