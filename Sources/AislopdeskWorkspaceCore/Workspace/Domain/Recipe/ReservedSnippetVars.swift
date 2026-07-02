import Foundation

// MARK: - ReservedSnippetValues (the injected reserved-var strings)

/// The four reserved snippet placeholders, resolved on the app side and INJECTED here as already-formatted
/// strings — the pure resolver never reads the real clock or pasteboard (keeps the layer headless +
/// deterministic + testable without `NSPasteboard`/`UIPasteboard`/`Date`).
///
/// - `clipboard` — current clipboard contents (app reads `NSPasteboard.general` / `UIPasteboard.general`).
/// - `date` — today's date, already formatted `YYYY-MM-DD` by the app.
/// - `time` — current time, already formatted `HH:mm` (24-hour) by the app.
///
/// `{{cursor}}` is NOT here: it is a caret-position marker, resolved by ``ReservedSnippetVars/resolve(body:reserved:values:)``
/// into a byte offset, not a substituted string.
public struct ReservedSnippetValues: Equatable, Sendable {
    public var clipboard: String
    public var date: String
    public var time: String

    public init(clipboard: String = "", date: String = "", time: String = "") {
        self.clipboard = clipboard
        self.date = date
        self.time = time
    }
}

// MARK: - ReservedSnippetVars (reserved-var layer ABOVE SnippetExpander)

/// The reserved-variable resolution layer that sits ABOVE the user-prompt ``SnippetExpander``.
///
/// `SnippetExpander` treats EVERY `{{name}}` as a user-prompt slot. The snippet spec, however, reserves four
/// names that must NEVER prompt the user:
///
/// | Reserved | Resolved from |
/// |----------|---------------|
/// | `{{clipboard}}` | injected ``ReservedSnippetValues/clipboard`` |
/// | `{{date}}` | injected ``ReservedSnippetValues/date`` (`YYYY-MM-DD`) |
/// | `{{time}}` | injected ``ReservedSnippetValues/time`` (`HH:mm`) |
/// | `{{cursor}}` | stripped → final caret byte offset (no auto-Enter) |
///
/// `resolve` substitutes the reserved names FIRST (so they never surface in `missing`/`placeholders`, even
/// when the injected value is empty), strips `{{cursor}}` and returns its UTF-8 byte offset into the final
/// text, and lets every OTHER `{{name}}` fall through to ``SnippetExpander/expand(_:values:)`` — so an
/// unknown `{{host}}` is still reported as a user-prompt slot. Pure + deterministic.
public enum ReservedSnippetVars {
    /// The four names the resolver owns — excluded from user-prompt placeholders + `missing`.
    public static let reservedNames: Set<String> = ["clipboard", "date", "time", "cursor"]

    /// Private-use sentinel standing in for `{{cursor}}` through the ``SnippetExpander`` pass: it carries no
    /// `{{` so the expander never treats it as a placeholder, and it is sanitized OUT of every injected /
    /// user value first (see ``resolve(body:reserved:values:)``) so the ONLY source of the sentinel in the
    /// expanded text is our own `{{cursor}}` substitution — making the caret-offset lookup unambiguous.
    private static let cursorMarker = "\u{E000}\u{E001}"

    /// Resolves a snippet body into the text to inject, the final caret byte offset, and the still-missing
    /// USER-prompt names.
    ///
    /// - `body` — the snippet body (may contain reserved + user `{{name}}` slots).
    /// - `reserved` — the injected reserved strings (clipboard/date/time); the pure code never reads them
    ///   from the system.
    /// - `values` — user-supplied values for NON-reserved placeholders (reserved keys here are ignored —
    ///   the user can't shadow a reserved name).
    ///
    /// Returns `(text, cursorOffset, missing)` where:
    /// - `text` is the body with reserved vars substituted, `{{cursor}}` stripped, and unknown slots left
    ///   literal (so the gap stays visible) — NO trailing Enter is ever appended.
    /// - `cursorOffset` is the UTF-8 byte offset of the FIRST `{{cursor}}` into `text`, or `nil` if the body
    ///   had no `{{cursor}}`.
    /// - `missing` is the unknown (non-reserved, unprovided) placeholder names, first-appearance order,
    ///   deduped — exactly ``SnippetExpander``'s `missing`, with the reserved names guaranteed absent.
    public static func resolve(
        body: String,
        reserved: ReservedSnippetValues,
        values: [String: String] = [:],
    ) -> (text: String, cursorOffset: Int?, missing: [String]) {
        // Strip any stray sentinel so the only `cursorMarker` in the expanded text comes from OUR
        // `{{cursor}}` substitution (a clipboard/date/time/user value can't be mistaken for the caret).
        func clean(_ s: String) -> String { s.replacingOccurrences(of: cursorMarker, with: "") }

        // Build the value table the expander resolves against. Reserved names are pre-populated (even when
        // empty) so they substitute instead of landing in `missing`; user values fill the rest but can NOT
        // shadow a reserved name.
        var table: [String: String] = [:]
        for (name, value) in values where !reservedNames.contains(name) {
            table[name] = clean(value)
        }
        table["clipboard"] = clean(reserved.clipboard)
        table["date"] = clean(reserved.date)
        table["time"] = clean(reserved.time)
        table["cursor"] = cursorMarker

        // Everything that is NOT reserved falls through to the existing user-prompt expander.
        let (expanded, missing) = SnippetExpander.expand(body, values: table)

        // No `{{cursor}}` → no caret offset; return the expanded text verbatim.
        guard let markerRange = expanded.range(of: cursorMarker) else {
            return (expanded, nil, missing)
        }

        // Caret = UTF-8 byte offset of the FIRST sentinel into the final (sentinel-free) text. Stripping the
        // sentinel never shifts bytes before it, so the prefix length IS the final offset.
        let offset = expanded[expanded.startIndex..<markerRange.lowerBound].utf8.count
        let text = expanded.replacingOccurrences(of: cursorMarker, with: "")
        return (text, offset, missing)
    }

    /// Resolves `body` straight to the injection BYTES, WITHOUT ever running ``SendKeysParser`` over a
    /// substituted value. Reserved vars / user-prompt values are treated as UNTRUSTED literal content —
    /// a `<Enter>`/`<C-c>`/`<Esc>` inside `{{clipboard}}` or a sheet-entered value is emitted as its own
    /// literal UTF-8 bytes, never parsed into a control-key token; only the snippet AUTHOR's own template
    /// text is token-scanned. This is the verbatim-injection invariant `BlockReRunEncoder` also enforces
    /// for untrusted text elsewhere in the codebase.
    ///
    /// Returns `(bytes, text, cursorOffset, missing)` where `text`/`cursorOffset` mirror
    /// ``resolve(body:reserved:values:)`` (needed by ``WorkspaceStore/snippetCursorLeftBytes(text:byteOffset:)``,
    /// which counts trailing graphemes of the merged text) and `bytes` is the safe injection payload.
    public static func resolveBytes(
        body: String,
        reserved: ReservedSnippetValues,
        values: [String: String] = [:],
    ) -> (bytes: [UInt8], text: String, cursorOffset: Int?, missing: [String]) {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: cursorMarker, with: "") }

        var table: [String: String] = [:]
        for (name, value) in values where !reservedNames.contains(name) {
            table[name] = clean(value)
        }
        table["clipboard"] = clean(reserved.clipboard)
        table["date"] = clean(reserved.date)
        table["time"] = clean(reserved.time)
        table["cursor"] = cursorMarker

        let (segments, missing) = SnippetExpander.expandSegments(body, values: table)

        var bytes: [UInt8] = []
        var text = ""
        var cursorOffset: Int?
        for segment in segments {
            switch segment {
            case let .literal(s):
                bytes += SendKeysParser.encode(s)
                text += s
            case let .substituted(value):
                if value == cursorMarker {
                    // Only the FIRST {{cursor}} marks the caret (matches `resolve`); every other stray
                    // sentinel occurrence is simply dropped, contributing no bytes/text.
                    if cursorOffset == nil { cursorOffset = text.utf8.count }
                } else {
                    bytes += Array(value.utf8) // literal UTF-8 — NEVER re-scanned for <Token>s
                    text += value
                }
            }
        }
        return (bytes, text, cursorOffset, missing)
    }

    /// The USER-prompt placeholder names in `body` — i.e. ``SnippetExpander/placeholders(in:)`` with the
    /// reserved names removed. This is what drives the value-entry sheet: a body of only reserved vars
    /// (`git checkout {{cursor}}`, `echo {{date}}`) needs NO prompt and runs straight away.
    public static func userPlaceholders(in body: String) -> [String] {
        SnippetExpander.placeholders(in: body).filter { !reservedNames.contains($0) }
    }
}
