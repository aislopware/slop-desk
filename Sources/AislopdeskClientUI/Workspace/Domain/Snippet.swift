import Foundation

// MARK: - Snippet (a saved, parameterized command macro)

/// A named, reusable command macro the user runs into a pane from ⌘K — the multiplexer "send-keys" /
/// snippet-library power feature. The `body` is literal text that may carry two kinds of markup:
///
/// - `{{placeholder}}` slots, resolved from user-supplied values at run time (so one "ssh {{host}}"
///   snippet serves every host), and
/// - `<Token>` control keys (`<Enter>`, `<Tab>`, `<Esc>`, `<C-c>`, `<Up>`…) parsed to their control
///   bytes, so a snippet can drive a TUI or chain commands (`git add -A<Enter>git commit<Enter>`).
///
/// Codable + persisted on ``Workspace`` (like ``LayoutPreset`` / bookmarks). Pure value type.
public struct Snippet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var body: String

    public init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    /// The `{{placeholder}}` names the body references, in first-appearance order, deduped — drives the
    /// run-time value-entry sheet (and `placeholders.isEmpty` means a snippet can run straight from ⌘K).
    public var placeholders: [String] { SnippetExpander.placeholders(in: body) }
}

// MARK: - SnippetExpander (placeholder resolution)

/// Pure resolver for `{{name}}` placeholders in a snippet body. Names are `[A-Za-z0-9_.-]+` with optional
/// surrounding whitespace inside the braces. Fully table-tested — no view, no store.
public enum SnippetExpander {
    /// Matches one `{{ name }}` placeholder, capturing the trimmed name.
    private static let pattern: NSRegularExpression = {
        // The pattern is a compile-time constant literal known to be valid, so this never fails in
        // practice; treat a compile failure as a programmer error (same trap intent as the old `try!`).
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}"#) else {
            preconditionFailure("Snippet placeholder regex literal failed to compile")
        }
        return regex
    }()

    /// Replaces every `{{name}}` with `values[name]`. A name with no value is LEFT in place (so the user
    /// sees what is unresolved) and reported in `missing` (first-appearance order, deduped).
    public static func expand(_ body: String, values: [String: String]) -> (text: String, missing: [String]) {
        var missing: [String] = []
        var seenMissing = Set<String>()
        // NSString is required: NSRegularExpression yields UTF-16 NSRanges, consumed via
        // NSString.substring(with:)/.length — a pure-Swift rewrite needs error-prone UTF-16↔String
        // index bookkeeping with behaviour-change risk.
        // swiftlint:disable:next legacy_objc_type
        let ns = body as NSString
        let matches = pattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var out = ""
        var cursor = 0
        for m in matches {
            let whole = m.range
            out += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            let name = ns.substring(with: m.range(at: 1))
            if let value = values[name] {
                out += value
            } else {
                out += ns.substring(with: whole) // keep the literal {{name}} so the gap is visible
                if seenMissing.insert(name).inserted { missing.append(name) }
            }
            cursor = whole.location + whole.length
        }
        out += ns.substring(from: cursor)
        return (out, missing)
    }

    /// The distinct placeholder names in `body`, in first-appearance order.
    public static func placeholders(in body: String) -> [String] {
        // NSString required for NSRegularExpression's UTF-16 NSRanges (see expand above).
        // swiftlint:disable:next legacy_objc_type
        let ns = body as NSString
        var seen = Set<String>()
        var names: [String] = []
        for m in pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }
}

// MARK: - SendKeysParser (tmux-style control-key tokens → bytes)

/// Pure parser turning a (placeholder-expanded) snippet body into the raw byte sequence to feed a PTY.
/// Literal runs become their UTF-8 bytes; `<Token>` markers become control bytes. An UNRECOGNIZED
/// `<...>` (or a bare `<` with no close) is emitted LITERALLY, so ordinary text containing `<` (`a < b`,
/// `printf "<3"`) is never mangled. Token names are case-insensitive. Fully table-tested.
public enum SendKeysParser {
    public static func encode(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "<" {
                // Look for a closing '>' within a bounded window (token names are short).
                if let close = findClose(scalars, from: i + 1),
                   let bytes = token(String(String.UnicodeScalarView(scalars[(i + 1)..<close])))
                {
                    out += bytes
                    i = close + 1
                    continue
                }
                // Not a recognized token — emit '<' literally and advance one scalar.
                out += Array("<".utf8)
                i += 1
                continue
            }
            out += Array(String(s).utf8)
            i += 1
        }
        return out
    }

    /// Index of the next '>' after `from`, within a small window (a token name is short), or `nil`.
    private static func findClose(_ scalars: [Unicode.Scalar], from: Int) -> Int? {
        let limit = min(scalars.count, from + 12) // longest token ("Backspace") + slack
        var j = from
        while j < limit {
            if scalars[j] == ">" { return j }
            if scalars[j] == "<" { return nil } // a nested '<' means the first wasn't a token open
            j += 1
        }
        return nil
    }

    private static let esc: UInt8 = 0x1B

    /// The bytes for a token name (without the angle brackets), or `nil` if unrecognized.
    private static func token(_ raw: String) -> [UInt8]? {
        let name = raw.lowercased()
        switch name {
        case "enter",
             "cr",
             "return": return [0x0D]
        case "nl",
             "lf",
             "newline": return [0x0A]
        case "tab": return [0x09]
        case "esc",
             "escape": return [esc]
        case "space": return [0x20]
        case "bs",
             "backspace": return [0x7F]
        case "del",
             "delete": return [esc, 0x5B, 0x33, 0x7E] // ESC [ 3 ~
        case "up": return [esc, 0x5B, 0x41] // ESC [ A
        case "down": return [esc, 0x5B, 0x42]
        case "right": return [esc, 0x5B, 0x43]
        case "left": return [esc, 0x5B, 0x44]
        case "home": return [esc, 0x5B, 0x48]
        case "end": return [esc, 0x5B, 0x46]
        default:
            // Ctrl chord: <C-x> → control byte (x masked to 0x1F). Meta chord: <M-x> → ESC + x.
            if name.hasPrefix("c-"), name.count == 3, let ch = name.last, let a = ch.asciiValue {
                // a..z / @ [ \ ] ^ _ map to 0x00..0x1F via & 0x1F (upper-case folding for letters).
                let upper = (ch.isLetter ? Character(ch.uppercased()) : ch)
                guard let u = upper.asciiValue else { return nil }
                _ = a
                return [u & 0x1F]
            }
            if name.hasPrefix("m-"), name.count == 3, let ch = name.last, ch.isASCII {
                return [esc] + Array(String(ch).utf8)
            }
            return nil
        }
    }
}
