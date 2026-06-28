import Foundation

// MARK: - WorkspaceStore × snippet expansion (E16 WI-10 — reserved vars + caret)

/// The snippet body → wire-bytes resolution, factored out of the ``WorkspaceStore`` class body. The store's
/// ``WorkspaceStore/runSnippet(_:values:)`` calls ``snippetBytes(for:values:)`` to turn a snippet into the
/// bytes it injects; the reserved-var read (clipboard/date/time) is injected by the app through
/// ``WorkspaceStore/snippetReservedValues`` so the pure resolver (``ReservedSnippetVars``) never touches the
/// real pasteboard / clock.
extension WorkspaceStore {
    /// Resolve `snippet` into the bytes ``runSnippet(_:values:)`` injects:
    ///   1. ``ReservedSnippetVars`` substitutes the reserved vars FIRST (`{{clipboard}}`/`{{date}}`/`{{time}}`,
    ///      injected via ``snippetReservedValues``) and strips `{{cursor}}` to a byte offset; everything else
    ///      falls through to the user-prompt ``SnippetExpander`` (unknown slots stay literal);
    ///   2. ``SendKeysParser`` turns the resolved text's `<Token>`s into control bytes;
    ///   3. a `{{cursor}}` marker appends cursor-left bytes (``snippetCursorLeftBytes(text:byteOffset:)``) so
    ///      the prompt caret lands where the snippet author placed it — NO Enter is ever appended.
    func snippetBytes(for snippet: Snippet, values: [String: String]) -> [UInt8] {
        let resolved = ReservedSnippetVars.resolve(
            body: snippet.body,
            reserved: snippetReservedValues?() ?? ReservedSnippetValues(),
            values: values,
        )
        var bytes = SendKeysParser.encode(resolved.text)
        if let offset = resolved.cursorOffset {
            bytes += Self.snippetCursorLeftBytes(text: resolved.text, byteOffset: offset)
        }
        return bytes
    }

    /// E16 ES-E16-4 — the bytes to inject for an AT-PROMPT alias auto-expansion of `snippet`, or `[]` to
    /// DECLINE. Declines a snippet that still has unresolved user-prompt `{{placeholders}}` (`ssh {{host}}`):
    /// those need the value-entry sheet that only the ⌘K palette path arms, so auto-expanding them would inject
    /// literal `{{name}}` braces. A reserved-only / placeholder-free body (the spec's `gco` = `git checkout
    /// {{cursor}}`) resolves through the SAME ``snippetBytes(for:values:)`` the palette uses (reserved vars +
    /// `{{cursor}}` caret), so the two surfaces stay byte-consistent. Injected into ``SnippetAliasExpander`` as
    /// its `resolveBytes` policy by ``wireSnippetExpander(terminal:)``.
    func autoExpandBytes(for snippet: Snippet) -> [UInt8] {
        guard ReservedSnippetVars.userPlaceholders(in: snippet.body).isEmpty else { return [] }
        return snippetBytes(for: snippet, values: [:])
    }

    /// E16 WI-10 — the cursor-left (`ESC [ D`) bytes that reposition the prompt caret onto a snippet's
    /// `{{cursor}}` marker AFTER the line is typed: one move per grapheme AFTER `byteOffset` (a UTF-8 byte
    /// offset into `text`). A marker at the END of the line yields `[]` (no move — the common `… {{cursor}}`
    /// case). Pure + total — an out-of-range / mid-grapheme offset yields `[]` rather than trapping, and NO
    /// Enter is ever appended (the spec's "final cursor position", not command submission).
    static func snippetCursorLeftBytes(text: String, byteOffset: Int) -> [UInt8] {
        let utf8 = text.utf8
        guard byteOffset >= 0, byteOffset <= utf8.count else { return [] }
        let byteIndex = utf8.index(utf8.startIndex, offsetBy: byteOffset)
        guard let stringIndex = byteIndex.samePosition(in: text) else { return [] }
        let trailing = text.distance(from: stringIndex, to: text.endIndex)
        guard trailing > 0 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(trailing * 3)
        for _ in 0..<trailing { out.append(contentsOf: [0x1B, 0x5B, 0x44]) }
        return out
    }
}
