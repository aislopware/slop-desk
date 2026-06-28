import Foundation

// MARK: - RecipeTOMLCodec (`.ottyrecipe` ⇄ Recipe)

/// The hand-rolled `.ottyrecipe` TOML codec: ``emit(_:)`` serialises a ``Recipe`` to plain TOML and
/// ``parse(_:)`` reads an untrusted `.ottyrecipe` file back into a ``Recipe`` (or `nil`).
///
/// **WHY hand-rolled (no TOML dependency).** Like ``ThemeTOMLParser`` (whose discipline this follows but
/// whose flat reader can NOT do recipes' arrays-of-tables), `.ottyrecipe` needs only a small, well-defined
/// slice of TOML: a `[recipe]` table plus the two arrays-of-tables `[[window.tabs]]` and
/// `[[window.tabs.panes]]`, with double-/single-quoted strings, integers, floats, and string arrays. Pulling
/// in a full TOML library across the `#if os(iOS)` slice is unjustified weight. This is a pure, headless,
/// `String` ⇄ struct transform with NO I/O (the file engine `RecipeLibrary` owns disk).
///
/// **VALIDATE-THEN-DROP (CLAUDE.md §3).** A `.ottyrecipe` is an untrusted user/teammate file and — because
/// its `commands` drive shell replay — is handled with the same discipline as a hostile UDP datagram: any
/// malformed shape DROPS the whole file (`nil`), never traps. The structure is bounded BEFORE allocating
/// (``maxTabs`` / ``maxPanesPerTab``) so a pathological file can't exhaust memory; `size` is clamped to
/// `0…1`; an unknown `scope` drops the file; an unknown `split` drops just that field; there is no
/// force-unwrap and no `fatalError` anywhere on this path.
public enum RecipeTOMLCodec {
    /// Upper bound on `[[window.tabs]]` headers in one file. A file declaring more is DROPPED before the
    /// (count+1)th tab is allocated — bounded allocation on untrusted input (CLAUDE.md §3).
    public static let maxTabs = 256
    /// Upper bound on `[[window.tabs.panes]]` headers in one tab. Same bounded-allocation rationale.
    public static let maxPanesPerTab = 256

    // MARK: Emit

    /// Serialise `recipe` to plain TOML matching the documented `.ottyrecipe` shape (`[recipe]` →
    /// `[[window.tabs]]` → `[[window.tabs.panes]]`). Strings are double-quoted with minimal escaping;
    /// optional pane fields are omitted when absent so a Layout-Only recipe stays clean. Ends with a
    /// trailing newline. `emit → parse` is an identity over a valid ``Recipe``.
    public static func emit(_ recipe: Recipe) -> String {
        var lines: [String] = []
        lines.append("[recipe]")
        lines.append("name = \(quote(recipe.name))")
        lines.append("version = \(recipe.version)")
        lines.append("scope = \(quote(recipe.scope.rawValue))")

        for tab in recipe.window.tabs {
            lines.append("")
            lines.append("[[window.tabs]]")
            if !tab.title.isEmpty {
                lines.append("title = \(quote(tab.title))")
            }
            for pane in tab.panes {
                lines.append("")
                lines.append("[[window.tabs.panes]]")
                if let cwd = pane.cwd {
                    lines.append("cwd = \(quote(cwd))")
                }
                if let split = pane.split {
                    lines.append("split = \(quote(split.rawValue))")
                }
                if let size = pane.size {
                    lines.append("size = \(String(size))")
                }
                if !pane.commands.isEmpty {
                    let joined = pane.commands.map { quote($0) }.joined(separator: ", ")
                    lines.append("commands = [\(joined)]")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Wrap `s` in a TOML basic (double-quoted) string with minimal escaping (`\`, `"`, newline, tab).
    /// Double-quoted-with-escapes is the robust emit choice for verbatim shell commands (a TOML literal
    /// single-quoted string can't contain a single quote at all).
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }

    // MARK: Parse

    /// Parse `text` (an untrusted `.ottyrecipe` file) into a validated ``Recipe``, or `nil` when the file is
    /// malformed / incomplete (validate-then-drop). `nil` cases: missing `[recipe]`, missing / empty `name`,
    /// missing / unknown `scope`, any broken line, an unknown table / array-of-tables, panes declared before
    /// any tab, or a structure exceeding ``maxTabs`` / ``maxPanesPerTab``.
    public static func parse(_ text: String) -> Recipe? {
        var state = ParseState()
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < rawLines.count {
            let line = stripComment(rawLines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if line.isEmpty { continue }

            // `[[window.tabs]]` / `[[window.tabs.panes]]` array-of-tables header.
            if line.hasPrefix("[[") {
                guard applyArrayHeader(line, into: &state) else { return nil }
                continue
            }
            // `[recipe]` table header.
            if line.hasPrefix("[") {
                guard applyTableHeader(line, into: &state) else { return nil }
                continue
            }

            // `key = value` — re-join a multi-line array value until its (unquoted) brackets balance.
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            var valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            while bracketBalance(valueText) > 0, index < rawLines.count {
                let continuation = stripComment(rawLines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                valueText += " " + continuation
            }
            guard !key.isEmpty, let value = parseValue(valueText) else { return nil }
            guard applyKeyValue(key: key, value: value, into: &state) else { return nil }
        }
        return finalize(state)
    }

    // MARK: Parse — state + per-context appliers

    private enum Context {
        case top
        case recipe
        case tab
        case pane
    }

    private struct ParseState {
        var sawRecipe = false
        var name: String?
        var version = Recipe.currentVersion
        var scopeRaw: String?
        var tabs: [RecipeTab] = []
        var context: Context = .top
    }

    /// Append a new tab / pane for an array-of-tables header. Returns `false` (→ DROP) on a malformed
    /// header, an unknown section, panes before any tab, or an over-count (bounded allocation).
    private static func applyArrayHeader(_ line: String, into state: inout ParseState) -> Bool {
        guard line.hasSuffix("]]") else { return false }
        let inner = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        switch inner {
        case "window.tabs":
            guard state.tabs.count < maxTabs else { return false }
            state.tabs.append(RecipeTab())
            state.context = .tab
            return true
        case "window.tabs.panes":
            guard let last = state.tabs.indices.last else { return false }
            guard state.tabs[last].panes.count < maxPanesPerTab else { return false }
            state.tabs[last].panes.append(RecipePane())
            state.context = .pane
            return true
        default:
            return false
        }
    }

    /// Open the `[recipe]` table. Returns `false` (→ DROP) on a malformed header or an unknown table.
    private static func applyTableHeader(_ line: String, into state: inout ParseState) -> Bool {
        guard line.hasSuffix("]"), !line.contains("=") else { return false }
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        switch inner {
        case "recipe":
            state.sawRecipe = true
            state.context = .recipe
            return true
        default:
            return false
        }
    }

    private static func applyKeyValue(key: String, value: Value, into state: inout ParseState) -> Bool {
        switch state.context {
        case .top: false // a key outside any known table → malformed
        case .recipe: applyRecipeKey(key, value, into: &state)
        case .tab: applyTabKey(key, value, into: &state)
        case .pane: applyPaneKey(key, value, into: &state)
        }
    }

    private static func applyRecipeKey(_ key: String, _ value: Value, into state: inout ParseState) -> Bool {
        switch key {
        case "name":
            guard case let .string(s) = value else { return false }
            state.name = s
        case "version":
            // Bounded + finite ONLY — `Int(Double)` traps on NaN/±inf/out-of-range, so a hostile
            // `version = 1e400` must never reach it. A non-numeric / wild version keeps the default.
            if case let .number(n) = value, n.isFinite, n >= 0, n < 1_000_000_000 {
                state.version = Int(n)
            }
        case "scope":
            guard case let .string(s) = value else { return false }
            state.scopeRaw = s
        default:
            break // forward-compatible: ignore an unknown recipe key
        }
        return true
    }

    private static func applyTabKey(_ key: String, _ value: Value, into state: inout ParseState) -> Bool {
        guard let last = state.tabs.indices.last else { return false }
        switch key {
        case "title":
            guard case let .string(s) = value else { return false }
            state.tabs[last].title = s
        default:
            break
        }
        return true
    }

    private static func applyPaneKey(_ key: String, _ value: Value, into state: inout ParseState) -> Bool {
        guard let t = state.tabs.indices.last, let p = state.tabs[t].panes.indices.last else { return false }
        switch key {
        case "cwd":
            guard case let .string(s) = value else { return false }
            state.tabs[t].panes[p].cwd = s
        case "commands":
            // `commands` is the executable payload → a malformed array DROPS the whole file (strict).
            guard let arr = stringArray(value) else { return false }
            state.tabs[t].panes[p].commands = arr
        case "split":
            // Unknown / wrong-typed split → DROP just this field; the pane survives.
            if case let .string(s) = value, let split = RecipeSplit(rawValue: s) {
                state.tabs[t].panes[p].split = split
            }
        case "size":
            // Clamp to 0…1 via ordered min/max; a non-number size drops the field.
            if case let .number(n) = value {
                state.tabs[t].panes[p].size = RecipePane.clampSize(n)
            }
        default:
            break
        }
        return true
    }

    /// Validate the required `[recipe]` fields and assemble the ``Recipe``, or `nil`.
    private static func finalize(_ state: ParseState) -> Recipe? {
        guard state.sawRecipe else { return nil }
        guard let name = state.name, !name.isEmpty else { return nil }
        guard let scopeRaw = state.scopeRaw, let scope = RecipeScope(rawValue: scopeRaw) else { return nil }
        return Recipe(name: name, version: state.version, scope: scope, window: RecipeWindow(tabs: state.tabs))
    }

    // MARK: TOML value reader (tiny, pure — like ParsedTOML but local to this module)

    private enum Value {
        case string(String)
        case number(Double)
        case array([Self])
    }

    /// Parse one TOML value: a `"basic"` / `'literal'` string, a `[a, b]` array (recursive), or a number.
    /// `nil` on any broken shape (unterminated quote, unbalanced bracket, bare non-numeric word) — STRICT,
    /// since for recipes a malformed value drops the whole file.
    private static func parseValue(_ raw: String) -> Value? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("[") {
            guard trimmed.hasSuffix("]") else { return nil }
            let inner = String(trimmed.dropFirst().dropLast())
            var out: [Value] = []
            for element in splitTopLevel(inner, separator: ",") {
                let piece = element.trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.isEmpty { continue } // tolerate a trailing comma / blank element
                guard let parsed = parseValue(piece) else { return nil }
                out.append(parsed)
            }
            return .array(out)
        }
        if trimmed.hasPrefix("\"") {
            guard let s = unquote(trimmed) else { return nil }
            return .string(s)
        }
        if trimmed.hasPrefix("'") {
            guard let s = unquoteLiteral(trimmed) else { return nil }
            return .string(s)
        }
        if let n = Double(trimmed) { return .number(n) }
        return nil // a bare unquoted non-number is malformed for a recipe
    }

    /// A homogeneous `[String]` from a `.array` of strings; a lone `.string` promotes to a 1-element array.
    /// `nil` when an element is not a string (→ the caller drops the file).
    private static func stringArray(_ value: Value) -> [String]? {
        switch value {
        case let .string(s):
            return [s]
        case let .array(values):
            var out: [String] = []
            out.reserveCapacity(values.count)
            for element in values {
                guard case let .string(s) = element else { return nil }
                out.append(s)
            }
            return out
        case .number:
            return nil
        }
    }

    /// Strip a surrounding pair of double quotes and resolve the minimal escapes (`\"`, `\\`, `\n`, `\t`).
    /// `nil` when the input is not a well-formed `"…"` (incl. a dangling trailing escape — an unterminated
    /// string).
    private static func unquote(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return nil }
        var out = ""
        var escaped = false
        for ch in raw.dropFirst().dropLast() {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { return nil } // the closing quote was itself escaped → unterminated
        return out
    }

    /// Strip a surrounding pair of SINGLE quotes — a TOML LITERAL string. NO escapes inside (a backslash is a
    /// literal backslash) and a `#` is NOT a comment, so `'{{current_folder}}/api'` survives verbatim. `nil`
    /// when the input is not a well-formed `'…'`.
    private static func unquoteLiteral(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") else { return nil }
        return String(raw.dropFirst().dropLast())
    }

    // MARK: line / token scanning (quote-aware; pure)

    /// Split `text` on `separator`, ignoring separators inside `"…"` / `'…'` strings or nested `[…]` brackets.
    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var inLiteral = false
        var escaped = false
        for char in text {
            if inLiteral {
                current.append(char)
                if char == "'" { inLiteral = false } // literal: no escapes
            } else if inString {
                current.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "'" {
                inLiteral = true
                current.append(char)
            } else if char == "\"" {
                inString = true
                current.append(char)
            } else if char == "[" {
                depth += 1
                current.append(char)
            } else if char == "]" {
                depth -= 1
                current.append(char)
            } else if char == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }

    /// Remove a trailing `#` comment from one physical line — but only when the `#` is OUTSIDE a quoted
    /// string (so a `"#x"` basic-string OR a `'#x'` literal-string value survives intact).
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var inString = false
        var inLiteral = false
        var escaped = false
        for char in line {
            if inLiteral {
                out.append(char)
                if char == "'" { inLiteral = false } // literal: no escapes, no `#` comment
            } else if inString {
                out.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "#" {
                break
            } else {
                if char == "\"" { inString = true }
                else if char == "'" { inLiteral = true }
                out.append(char)
            }
        }
        return out
    }

    /// The net unquoted bracket depth of `text` (`[` = +1, `]` = -1) — detects a value whose array continues
    /// onto the next line.
    private static func bracketBalance(_ text: String) -> Int {
        var depth = 0
        var inString = false
        var inLiteral = false
        var escaped = false
        for char in text {
            if inLiteral {
                if char == "'" { inLiteral = false }
            } else if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "'" {
                inLiteral = true
            } else if char == "\"" {
                inString = true
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth -= 1
            }
        }
        return depth
    }
}
