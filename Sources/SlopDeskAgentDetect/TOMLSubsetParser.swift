import Foundation

/// A minimal TOML parser covering exactly the subset the bundled agent manifests use:
/// comments, bare keys, basic (`"…"`, with escapes) and literal (`'…'`) strings, integers,
/// booleans, (multi-line) arrays with trailing commas, inline tables (arbitrarily nested),
/// and `[[array-of-tables]]` headers. Everything else — dotted keys, `[table]` headers,
/// multi-line strings, datetime literals, floats — is rejected with a thrown error.
///
/// Validate-then-drop: any malformed input throws `TOMLSubsetError` with a line number; the
/// parser never traps on hostile input. Values are returned as a plain tree of
/// `TOMLValue` — the manifest schema layer decodes and validates on top.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case array([Self])
    case table([String: Self])
}

public struct TOMLSubsetError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "TOML parse error (line \(line)): \(message)" }
}

public enum TOMLSubsetParser {
    /// Parses a whole document into a root table. `[[name]]` headers append a fresh table to a
    /// root-level array under `name`; keys before any header land in the root table.
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        // The table currently receiving keys: nil = root, else (arrayName, index into it).
        var currentArray: String?

        var lineNumber = 0
        var rest = Substring(text)
        while !rest.isEmpty {
            let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
            var line = rest[rest.startIndex..<lineEnd]
            rest = lineEnd < rest.endIndex ? rest[rest.index(after: lineEnd)...] : Substring("")
            lineNumber += 1

            line = stripComment(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("[[") {
                guard trimmed.hasSuffix("]]"), trimmed.count > 4 else {
                    throw TOMLSubsetError(line: lineNumber, message: "malformed table-array header")
                }
                let name = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                guard isBareKey(name) else {
                    throw TOMLSubsetError(line: lineNumber, message: "unsupported table-array name '\(name)'")
                }
                var existing: [TOMLValue] = if case let .array(items)? = root[name] { items } else { [] }
                existing.append(.table([:]))
                root[name] = .array(existing)
                currentArray = name
                continue
            }
            if trimmed.hasPrefix("[") {
                throw TOMLSubsetError(line: lineNumber, message: "plain [table] headers are not supported")
            }

            // key = value — the value may span multiple lines (multi-line array).
            guard let eq = line.firstIndex(of: "=") else {
                throw TOMLSubsetError(line: lineNumber, message: "expected 'key = value'")
            }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else {
                throw TOMLSubsetError(line: lineNumber, message: "unsupported key '\(key)'")
            }
            var valueText = Substring(String(line[line.index(after: eq)...]))
            // Pull in continuation lines until the value parses to completion (arrays/inline
            // tables can span lines). Bounded by the document length, so this always terminates.
            var value: TOMLValue
            while true {
                do {
                    value = try parseCompleteValue(valueText, line: lineNumber)
                    break
                } catch let error as TOMLSubsetError where error.message == incompleteMarker {
                    guard !rest.isEmpty else {
                        throw TOMLSubsetError(line: lineNumber, message: "unterminated value")
                    }
                    let nextEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
                    let nextLine = stripComment(rest[rest.startIndex..<nextEnd])
                    rest = nextEnd < rest.endIndex ? rest[rest.index(after: nextEnd)...] : Substring("")
                    lineNumber += 1
                    valueText += "\n" + nextLine
                }
            }

            if let arrayName = currentArray {
                guard case var .array(items)? = root[arrayName],
                      case var .table(table) = items[items.count - 1]
                else {
                    throw TOMLSubsetError(line: lineNumber, message: "internal table-array state")
                }
                guard table[key] == nil else {
                    throw TOMLSubsetError(line: lineNumber, message: "duplicate key '\(key)'")
                }
                table[key] = value
                items[items.count - 1] = .table(table)
                root[arrayName] = .array(items)
            } else {
                guard root[key] == nil else {
                    throw TOMLSubsetError(line: lineNumber, message: "duplicate key '\(key)'")
                }
                root[key] = value
            }
        }
        return root
    }

    // MARK: - Value scanning

    /// Sentinel message distinguishing "value continues on the next line" from a real error.
    private static let incompleteMarker = "…incomplete…"

    private static func parseCompleteValue(_ text: Substring, line: Int) throws -> TOMLValue {
        var scanner = Scanner(text: text, line: line)
        let value = try scanner.value()
        scanner.skipWhitespaceAndNewlines()
        guard scanner.isAtEnd else {
            throw TOMLSubsetError(line: line, message: "trailing characters after value")
        }
        return value
    }

    /// Strips a `#` comment — but not inside a string. A conservative scan that tracks quoting.
    private static func stripComment(_ line: Substring) -> Substring {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if inBasic {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inBasic = false }
            } else if inLiteral {
                if c == "'" { inLiteral = false }
            } else if c == "\"" {
                inBasic = true
            } else if c == "'" {
                inLiteral = true
            } else if c == "#" {
                return line[line.startIndex..<index]
            }
            index = line.index(after: index)
        }
        return line
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - Scanner

    private struct Scanner {
        var text: Substring
        var index: Substring.Index
        let line: Int

        init(text: Substring, line: Int) {
            self.text = text
            index = text.startIndex
            self.line = line
        }

        var isAtEnd: Bool { index == text.endIndex }

        mutating func skipWhitespaceAndNewlines() {
            while index < text.endIndex, text[index] == " " || text[index] == "\t" || text[index] == "\n" {
                index = text.index(after: index)
            }
        }

        mutating func value() throws -> TOMLValue {
            skipWhitespaceAndNewlines()
            guard index < text.endIndex else { throw incomplete() }
            switch text[index] {
            case "\"": return try basicString()
            case "'": return try literalString()
            case "[": return try array()
            case "{": return try inlineTable()
            default: return try scalar()
            }
        }

        mutating func basicString() throws -> TOMLValue {
            index = text.index(after: index) // consume "
            var out = ""
            while index < text.endIndex {
                let c = text[index]
                index = text.index(after: index)
                if c == "\"" { return .string(out) }
                if c == "\n" { throw error("newline in basic string") }
                if c == "\\" {
                    guard index < text.endIndex else { throw error("dangling escape") }
                    let e = text[index]
                    index = text.index(after: index)
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u",
                         "U":
                        let width = e == "u" ? 4 : 8
                        var hex = ""
                        for _ in 0..<width {
                            guard index < text.endIndex, text[index].isHexDigit else {
                                throw error("bad unicode escape")
                            }
                            hex.append(text[index])
                            index = text.index(after: index)
                        }
                        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw error("bad unicode escape")
                        }
                        out.unicodeScalars.append(scalar)
                    default:
                        throw error("unsupported escape '\\\(e)'")
                    }
                    continue
                }
                out.append(c)
            }
            throw error("unterminated basic string")
        }

        mutating func literalString() throws -> TOMLValue {
            index = text.index(after: index) // consume '
            var out = ""
            while index < text.endIndex {
                let c = text[index]
                index = text.index(after: index)
                if c == "'" { return .string(out) }
                if c == "\n" { throw error("newline in literal string") }
                out.append(c)
            }
            throw error("unterminated literal string")
        }

        mutating func array() throws -> TOMLValue {
            index = text.index(after: index) // consume [
            var items: [TOMLValue] = []
            while true {
                skipWhitespaceAndNewlines()
                guard index < text.endIndex else { throw incomplete() }
                if text[index] == "]" {
                    index = text.index(after: index)
                    return .array(items)
                }
                try items.append(value())
                skipWhitespaceAndNewlines()
                guard index < text.endIndex else { throw incomplete() }
                if text[index] == "," {
                    index = text.index(after: index)
                } else if text[index] != "]" {
                    throw error("expected ',' or ']' in array")
                }
            }
        }

        mutating func inlineTable() throws -> TOMLValue {
            index = text.index(after: index) // consume {
            var table: [String: TOMLValue] = [:]
            skipWhitespaceAndNewlines()
            guard index < text.endIndex else { throw incomplete() }
            if text[index] == "}" {
                index = text.index(after: index)
                return .table(table)
            }
            while true {
                skipWhitespaceAndNewlines()
                var key = ""
                while index < text.endIndex, text[index].isLetter || text[index].isNumber
                    || text[index] == "_" || text[index] == "-"
                {
                    key.append(text[index])
                    index = text.index(after: index)
                }
                guard !key.isEmpty else { throw error("expected key in inline table") }
                skipWhitespaceAndNewlines()
                guard index < text.endIndex, text[index] == "=" else {
                    throw error("expected '=' in inline table")
                }
                index = text.index(after: index)
                guard table[key] == nil else { throw error("duplicate key '\(key)'") }
                table[key] = try value()
                skipWhitespaceAndNewlines()
                guard index < text.endIndex else { throw incomplete() }
                if text[index] == "," {
                    index = text.index(after: index)
                    continue
                }
                if text[index] == "}" {
                    index = text.index(after: index)
                    return .table(table)
                }
                throw error("expected ',' or '}' in inline table")
            }
        }

        mutating func scalar() throws -> TOMLValue {
            var out = ""
            while index < text.endIndex, text[index] != ",", text[index] != "]",
                  text[index] != "}", text[index] != "\n"
            {
                out.append(text[index])
                index = text.index(after: index)
            }
            let token = out.trimmingCharacters(in: .whitespaces)
            switch token {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            default:
                if let n = Int64(token) { return .integer(n) }
                throw error("unsupported scalar '\(token)'")
            }
        }

        func error(_ message: String) -> TOMLSubsetError {
            TOMLSubsetError(line: line, message: message)
        }

        func incomplete() -> TOMLSubsetError {
            TOMLSubsetError(line: line, message: TOMLSubsetParser.incompleteMarker)
        }
    }
}

public extension TOMLValue {
    var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    var integerValue: Int64? { if case let .integer(n) = self { n } else { nil } }
    var booleanValue: Bool? { if case let .boolean(b) = self { b } else { nil } }
    var arrayValue: [TOMLValue]? { if case let .array(a) = self { a } else { nil } }
    var tableValue: [String: TOMLValue]? { if case let .table(t) = self { t } else { nil } }
}
