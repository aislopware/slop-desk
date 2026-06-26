import Foundation

/// PURE HTML→Markdown converter behind the Composer's **rich paste** (`⌘V`, otty parity —
/// E12 / ES-E12-3).
///
/// When the user pastes into the Composer with `⌘V`, the platform pasteboard is read for an
/// HTML (or RTF, rendered to HTML) flavour at the **view call site** (NSPasteboard on macOS,
/// UIPasteboard on iOS — both AppKit/UIKit, both GUI-only and untested by `swift test`). The
/// resulting HTML string is handed to ``markdown(fromHTML:)``, which is this testable heart:
/// a small, self-contained, AppKit/UIKit-free converter that turns the common rich-text
/// constructs into Markdown the agent can read. `⇧⌘V` bypasses this entirely (plain text).
///
/// Mirrors `PasteTransform`'s pure-transform discipline: cross-platform, allocation-light, and
/// a **total function** — there is no input that traps. Hostile or malformed clipboard HTML
/// (unterminated tags, stray `<`, bogus entities, mismatched nesting) is **validated-then-
/// degraded**, never force-unwrapped and never crashed on; the worst case is that an
/// unrecognised fragment passes through as text. Empty input yields the empty string.
///
/// Coverage (the otty rich-paste set): headings (`<h1>`…`<h6>` → `#`…`######`), bold
/// (`<strong>`/`<b>` → `**…**`), italic (`<em>`/`<i>` → `*…*`), links
/// (`<a href=…>` → `[…](…)`), unordered lists (`<ul><li>` → `- …`), ordered lists
/// (`<ol><li>` → `1. …`), inline code (`<code>` → `` `…` ``), preformatted blocks
/// (`<pre>` → fenced ```` ``` ````), images (`<img src alt>` → `![alt](src)`), paragraphs
/// (`<p>` / block tags → blank-line separation) and hard breaks (`<br>` → newline). HTML
/// entities (named + numeric `&#…;` / `&#x…;`) are decoded.
public enum RichPasteMarkdown {
    /// Converts a clipboard HTML fragment into Markdown.
    ///
    /// Total over every `String`: empty in → empty out; un-parseable in → best-effort text.
    public static func markdown(fromHTML html: String) -> String {
        guard !html.isEmpty else { return "" }
        let tokens = tokenize(Array(html))
        var emitter = Emitter()
        for token in tokens {
            emitter.consume(token)
        }
        return emitter.finish()
    }

    // MARK: - Tokenizer

    /// One lexed HTML token. Attributes are kept only for the converter's needs (`href`,
    /// `src`, `alt`); everything else is parsed-and-dropped.
    private enum HTMLToken {
        case startTag(name: String, attrs: [String: String], selfClosing: Bool)
        case endTag(name: String)
        case text(String)
    }

    /// HTML void elements — they never have a matching end tag, so they're treated as
    /// self-closing regardless of how they were written.
    private static let voidElements: Set<String> = [
        "br", "hr", "img", "meta", "link", "input", "base", "col", "area",
        "source", "track", "wbr", "embed", "param",
    ]

    /// Splits the character stream into tags and text runs. Defensive by construction:
    /// comments / declarations are skipped, an unterminated tag at EOF is dropped, and a
    /// bare `<` not introducing a tag is emitted as literal text — no index ever escapes
    /// `chars`'s bounds and nothing traps.
    private static func tokenize(_ chars: [Character]) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var textBuf = ""
        var i = 0
        let n = chars.count

        func flushText() {
            if !textBuf.isEmpty {
                tokens.append(.text(textBuf))
                textBuf = ""
            }
        }

        while i < n {
            let c = chars[i]
            guard c == "<" else {
                textBuf.append(c)
                i += 1
                continue
            }
            let next = i + 1 < n ? chars[i + 1] : " "
            if next == "!" {
                // Comment `<!-- … -->` or declaration `<!doctype …>` — skip the whole span.
                if i + 3 < n, chars[i + 2] == "-", chars[i + 3] == "-" {
                    var j = i + 4
                    while j + 2 < n, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") {
                        j += 1
                    }
                    i = j + 2 < n ? j + 3 : n
                } else {
                    var j = i + 1
                    while j < n, chars[j] != ">" {
                        j += 1
                    }
                    i = j < n ? j + 1 : n
                }
                continue
            }
            if next.isLetter || next == "/" {
                // A real tag: read up to the next `>`.
                var j = i + 1
                while j < n, chars[j] != ">" {
                    j += 1
                }
                guard j < n else {
                    // Unterminated tag at EOF — drop the remainder rather than mis-parse it.
                    i = n
                    break
                }
                flushText()
                if let token = parseTag(String(chars[(i + 1)..<j])) {
                    tokens.append(token)
                }
                i = j + 1
                continue
            }
            // A `<` that doesn't introduce a tag — keep it as literal text.
            textBuf.append(c)
            i += 1
        }
        flushText()
        return tokens
    }

    /// Parses the inside of a `<…>` (no angle brackets) into a token, or `nil` if there's no
    /// usable tag name.
    private static func parseTag(_ raw: String) -> HTMLToken? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            let body = trimmed.dropFirst()
            let name = String(body.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
            guard !name.isEmpty else { return nil }
            return .endTag(name: name)
        }

        var selfClosing = false
        var body = Substring(trimmed)
        if body.hasSuffix("/") {
            selfClosing = true
            body = body.dropLast()
        }

        let scalars = Array(body)
        var k = 0
        var nameChars = ""
        while k < scalars.count, scalars[k].isLetter || scalars[k].isNumber {
            nameChars.append(scalars[k])
            k += 1
        }
        let name = nameChars.lowercased()
        guard !name.isEmpty else { return nil }

        if voidElements.contains(name) {
            selfClosing = true
        }
        let attrs = parseAttributes(Array(scalars[k...]))
        return .startTag(name: name, attrs: attrs, selfClosing: selfClosing)
    }

    /// Parses `key`, `key=value`, `key="value"` and `key='value'` attribute forms. Only the
    /// keys the converter consumes matter; the rest are harmlessly retained. Never traps on a
    /// malformed run (a missing close-quote just reads to the end of the attribute span).
    private static func parseAttributes(_ chars: [Character]) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = 0
        let n = chars.count
        while i < n {
            while i < n, chars[i].isWhitespace {
                i += 1
            }
            guard i < n else { break }

            var name = ""
            while i < n, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" {
                name.append(chars[i])
                i += 1
            }
            while i < n, chars[i].isWhitespace {
                i += 1
            }

            var value = ""
            if i < n, chars[i] == "=" {
                i += 1
                while i < n, chars[i].isWhitespace {
                    i += 1
                }
                if i < n, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    while i < n, chars[i] != quote {
                        value.append(chars[i])
                        i += 1
                    }
                    if i < n {
                        i += 1
                    }
                } else {
                    while i < n, !chars[i].isWhitespace {
                        value.append(chars[i])
                        i += 1
                    }
                }
            }
            if !name.isEmpty {
                attrs[name.lowercased()] = value
            }
        }
        return attrs
    }

    // MARK: - Emitter

    /// Walks the token stream and builds Markdown. All block-boundary and inline-marker logic
    /// lives here; whitespace is collapsed (outside `<pre>`) and block spacing is normalised so
    /// the output is tidy regardless of how the source HTML was indented.
    private struct Emitter {
        /// Block tags that map to a single newline boundary (generic containers).
        static let lineBlockTags: Set<String> = [
            "div", "section", "article", "header", "footer", "main", "nav", "aside",
            "ul", "ol", "table", "thead", "tbody", "tr",
        ]
        /// Block tags that map to a blank-line (paragraph) boundary.
        static let paragraphTags: Set<String> = ["p", "blockquote"]
        /// Elements whose entire contents are dropped (head matter, scripts, styles).
        static let skipElements: Set<String> = ["head", "script", "style", "title", "noscript"]

        var out = ""
        var listStack: [(ordered: Bool, index: Int)] = []
        var hrefStack: [String] = []
        var skipUntil: String?
        var preDepth = 0

        mutating func consume(_ token: HTMLToken) {
            if let skip = skipUntil {
                if case let .endTag(name) = token, name == skip {
                    skipUntil = nil
                }
                return
            }
            switch token {
            case let .text(raw):
                appendText(raw)
            case let .startTag(name, attrs, selfClosing):
                startTag(name, attrs: attrs, selfClosing: selfClosing)
            case let .endTag(name):
                endTag(name)
            }
        }

        mutating func finish() -> String {
            out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: Tags

        private mutating func startTag(_ name: String, attrs: [String: String], selfClosing: Bool) {
            if Self.skipElements.contains(name) {
                if !selfClosing {
                    skipUntil = name
                }
                return
            }
            switch name {
            case "h1",
                 "h2",
                 "h3",
                 "h4",
                 "h5",
                 "h6":
                let level = Int(name.dropFirst()) ?? 1
                blankLineIfNeeded()
                out += String(repeating: "#", count: level) + " "
            case "br":
                lineBreak()
            case "hr":
                blankLineIfNeeded()
                out += "---"
                blankLineIfNeeded()
            case "strong",
                 "b":
                if preDepth == 0 { out += "**" }
            case "em",
                 "i":
                if preDepth == 0 { out += "*" }
            case "code":
                if preDepth == 0 { out += "`" }
            case "pre":
                blankLineIfNeeded()
                out += "```\n"
                preDepth += 1
            case "ul":
                if listStack.isEmpty { blankLineIfNeeded() }
                listStack.append((ordered: false, index: 1))
            case "ol":
                if listStack.isEmpty { blankLineIfNeeded() }
                listStack.append((ordered: true, index: 1))
            case "li":
                startListItem()
            case "a":
                if let href = attrs["href"], !href.isEmpty {
                    out += "["
                    hrefStack.append(RichPasteMarkdown.decodeEntities(href))
                } else {
                    hrefStack.append("")
                }
            case "img":
                let src = RichPasteMarkdown.decodeEntities(attrs["src"] ?? "")
                let alt = RichPasteMarkdown.decodeEntities(attrs["alt"] ?? "")
                if !src.isEmpty { out += "![\(alt)](\(src))" }
            default:
                if Self.paragraphTags.contains(name) {
                    blankLineIfNeeded()
                } else if Self.lineBlockTags.contains(name) {
                    newlineIfNeeded()
                }
            }
        }

        private mutating func endTag(_ name: String) {
            switch name {
            case "h1",
                 "h2",
                 "h3",
                 "h4",
                 "h5",
                 "h6":
                blankLineIfNeeded()
            case "strong",
                 "b":
                if preDepth == 0 { out += "**" }
            case "em",
                 "i":
                if preDepth == 0 { out += "*" }
            case "code":
                if preDepth == 0 { out += "`" }
            case "pre":
                if preDepth > 0 { preDepth -= 1 }
                newlineIfNeeded()
                out += "```"
                blankLineIfNeeded()
            case "ul",
                 "ol":
                if !listStack.isEmpty { listStack.removeLast() }
                if listStack.isEmpty {
                    blankLineIfNeeded()
                } else {
                    newlineIfNeeded()
                }
            case "li":
                newlineIfNeeded()
            case "a":
                if let href = hrefStack.popLast(), !href.isEmpty {
                    out += "](\(href))"
                }
            default:
                if Self.paragraphTags.contains(name) {
                    blankLineIfNeeded()
                } else if Self.lineBlockTags.contains(name) {
                    newlineIfNeeded()
                }
            }
        }

        private mutating func startListItem() {
            newlineIfNeeded()
            let depth = max(0, listStack.count - 1)
            out += String(repeating: "  ", count: depth)
            guard !listStack.isEmpty else {
                out += "- "
                return
            }
            let last = listStack.count - 1
            if listStack[last].ordered {
                out += "\(listStack[last].index). "
                listStack[last].index += 1
            } else {
                out += "- "
            }
        }

        // MARK: Text + spacing

        private mutating func appendText(_ raw: String) {
            let decoded = RichPasteMarkdown.decodeEntities(raw)
            if preDepth > 0 {
                out += decoded
                return
            }
            var text = RichPasteMarkdown.collapseWhitespace(decoded)
            if out.isEmpty || out.hasSuffix("\n") {
                while text.first == " " {
                    text.removeFirst()
                }
            }
            guard !text.isEmpty else { return }
            out += text
        }

        private mutating func lineBreak() {
            trimTrailingSpaces()
            out += "\n"
        }

        private mutating func newlineIfNeeded() {
            guard !out.isEmpty else { return }
            trimTrailingSpaces()
            if !out.hasSuffix("\n") {
                out += "\n"
            }
        }

        private mutating func blankLineIfNeeded() {
            guard !out.isEmpty else { return }
            trimTrailingSpaces()
            while !out.hasSuffix("\n\n") {
                out += "\n"
            }
        }

        private mutating func trimTrailingSpaces() {
            while let last = out.last, last == " " || last == "\t" {
                out.removeLast()
            }
        }
    }

    // MARK: - Entities & whitespace

    /// The named HTML entities common in pasted rich text. Unknown names are left literal.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "laquo": "«", "raquo": "»", "deg": "°", "middot": "·", "bull": "•", "dagger": "†",
        "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾",
    ]

    /// Decodes named and numeric (`&#…;` decimal, `&#x…;` hex) HTML entities. A `&` that does
    /// not open a well-formed entity (no `;` within a small window, an unknown name, or an
    /// out-of-range code point) is left as a literal `&` — degrade, never trap.
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var result = ""
        var i = 0
        let n = chars.count
        while i < n {
            guard chars[i] == "&" else {
                result.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            let limit = min(n, i + 33)
            while j < limit, chars[j] != ";" {
                j += 1
            }
            if j < limit, chars[j] == ";",
               let decoded = decodeEntityBody(String(chars[(i + 1)..<j]))
            {
                result += decoded
                i = j + 1
            } else {
                result.append("&")
                i += 1
            }
        }
        return result
    }

    /// Resolves a single entity body (the text between `&` and `;`) to its character, or `nil`
    /// if it is not a recognised name or a valid numeric code point.
    private static func decodeEntityBody(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32? =
                if digits.first == "x" || digits.first == "X" {
                    UInt32(digits.dropFirst(), radix: 16)
                } else {
                    UInt32(digits, radix: 10)
                }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return namedEntities[body]
    }

    /// Collapses every run of whitespace (incl. newlines) to a single space, the way an HTML
    /// renderer folds insignificant whitespace. Leading/trailing single spaces are preserved so
    /// inline word boundaries survive; the emitter drops a leading space at the start of a line.
    private static func collapseWhitespace(_ s: String) -> String {
        var result = ""
        var lastWasSpace = false
        for ch in s {
            if ch.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result
    }
}
