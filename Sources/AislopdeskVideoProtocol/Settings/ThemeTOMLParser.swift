import Foundation

/// E15 (WI-4) — the hand-rolled `.ottytheme` parser. Turns a user-authored TOML SUBSET into a validated
/// ``ThemeDocument`` (or `nil`).
///
/// WHY hand-rolled (no TOML dependency): otty's `.ottytheme` files are "real TOML", but we only need a tiny,
/// well-defined slice of it — `[section]` headers, `key = value` lines, double-quoted strings, booleans,
/// numbers, and homogeneous arrays (`["a", "b"]` / `[8, 16]`, possibly spanning lines). Pulling in a full TOML
/// library for that — across the `#if os(iOS)` slice too — is unjustified weight, so we follow the exact
/// pattern ``KeybindConfigLoader`` set: a pure, headless, `String` → struct transform with NO I/O.
///
/// **VALIDATE-THEN-DROP (CLAUDE.md §3, file edition).** A `.ottytheme` is an untrusted user file, handled with
/// the same discipline as a hostile UDP datagram: every malformed shape is DROPPED rather than trapped. A line
/// that does not parse is skipped; a value that is the wrong type is ignored for that key; and the whole
/// document is returned ONLY if it satisfies ``ThemeDocument/isValid`` ( `[terminal]` foreground + background +
/// a 16-entry hex palette present and well-formed). Any missing-`[terminal]` / short-palette / bad-hex file
/// resolves to `nil`. There is no force-unwrap and no `fatalError` anywhere on this path.
///
/// **Inheritance.** A top-level `inherits = "<name>"` derives the document from a parent: `resolveParent` is a
/// caller-supplied lookup ( the themes library passes the already-scanned customs + built-ins ). When the
/// parent resolves, only the keys EXPLICITLY present in this file override it — every other field is inherited.
/// When the parent does NOT resolve, the file must stand on its own (it is built with no base; if it is then
/// incomplete it drops). This keeps the parser total: it never recurses (the lookup hands back finished
/// documents, never re-parses) and never traps on a dangling / self-referential `inherits`.
///
/// COLOUR NORMALISATION: a value like `"#FF6188"` is stored on the document WITHOUT the leading `#` (the shape
/// libghostty's `palette = N=<hex>` and `Color(ottyHex:)` both consume). `background` additionally accepts the
/// literal `none` (transparent). Case is preserved (``ThemeDocument/isValidHex(_:)`` is case-insensitive) so a
/// serialise → parse round-trip is byte-stable.
public enum ThemeTOMLParser {
    /// Parse `text` (the contents of a `.ottytheme` file) into a validated ``ThemeDocument``, or `nil` when the
    /// file is malformed / incomplete (validate-then-drop).
    ///
    /// - Parameters:
    ///   - text: the raw TOML-subset file contents.
    ///   - fallbackName: the on-disk theme name (the file's base name) used as the display name when the file
    ///     carries no `[meta] name`. otty theme files have no `[meta]` section — their identity IS the file
    ///     name — so the library passes the file's base name here.
    ///   - resolveParent: resolves a top-level `inherits = "<name>"` to a parent document (by display name or
    ///     slug). Defaults to "no parent" for the standalone parser tests.
    public static func parse(
        _ text: String,
        fallbackName: String? = nil,
        resolveParent: (String) -> ThemeDocument? = { _ in nil },
    ) -> ThemeDocument? {
        let toml = ParsedTOML(text)
        var base: ThemeDocument?
        if let parentName = toml.string("", "inherits") {
            base = resolveParent(parentName)
        }
        let doc = buildDocument(toml: toml, base: base, fallbackName: fallbackName)
        return doc.isValid ? doc : nil
    }

    /// The top-level `inherits = "<name>"` target of `text`, or `nil` when the file declares no inheritance.
    /// Lets the themes library order its scan (resolve standalone themes before their dependants) without a
    /// full second parse.
    public static func inheritsName(_ text: String) -> String? {
        ParsedTOML(text).string("", "inherits")
    }

    // MARK: - Document assembly (pure; overlays the file onto an optional inherited base)

    private static func buildDocument(toml: ParsedTOML, base: ThemeDocument?, fallbackName: String?)
        -> ThemeDocument
    {
        let displayName = toml.string("meta", "name") ?? fallbackName ?? base?.displayName ?? "theme"

        // [selection] is the preferred selection source; [terminal] selection-background is the legacy key.
        let selectionBackground = toml.color("selection", "background")
            ?? toml.color("terminal", "selection-background")
            ?? base?.selectionBackground

        // STABLE slug from the on-disk FILE NAME (the `.ottytheme` basename), not the display name: a custom
        // theme is written as `<slug>.ottytheme`, so the file name IS its identity. Deriving the slug from the
        // mutable `[meta] name` would make a persisted `customLightSlug`/`customDarkSlug` unresolvable the
        // moment the display name changed. The standalone parser tests (no `fallbackName`) keep deriving from
        // the display name.
        return ThemeDocument(
            displayName: displayName,
            slug: ThemeDocument.slug(from: fallbackName ?? displayName),
            mode: resolveMode(toml: toml, base: base),
            foreground: toml.color("terminal", "foreground") ?? base?.foreground ?? "",
            background: toml.color("terminal", "background") ?? base?.background ?? "",
            palette: toml.palette() ?? base?.palette ?? [],
            cursor: toml.color("terminal", "cursor") ?? toml.color("cursor", "color") ?? base?.cursor,
            cursorText: toml.color("terminal", "cursor-text") ?? base?.cursorText,
            selectionBackground: selectionBackground,
            accent: toml.color("token", "accent") ?? base?.accent,
            window: toml.color("window", "background") ?? base?.window,
            sidebar: toml.color("sidebar", "background") ?? toml.color("ui", "tab-bar-bg") ?? base?.sidebar,
            titlebar: toml.color("titlebar", "background") ?? toml.color("ui", "title-bar-bg") ?? base?.titlebar,
            tab: toml.color("tab", "background") ?? toml.color("ui", "tab-active-bg") ?? base?.tab,
            panel: toml.color("panel", "background") ?? base?.panel,
            radius: toml.number("container", "radius") ?? base?.radius,
            shadow: toml.string("container", "shadow") ?? base?.shadow,
            border: toml.string("container", "border") ?? base?.border,
            padding: toml.doubleArray("container", "padding") ?? base?.padding,
            margin: toml.doubleArray("container", "margin") ?? base?.margin,
            fontMono: toml.stringArray("token", "font-mono") ?? base?.fontMono,
            fontUI: toml.stringArray("token", "font-ui") ?? base?.fontUI,
            fontSize: toml.number("token", "font-size") ?? base?.fontSize,
            adjustCellHeight: toml.cellHeightToken("token", "adjust-cell-height") ?? base?.adjustCellHeight,
        )
    }

    /// Resolve the light/dark slot: an explicit `[meta] mode` wins; otherwise infer from the background's
    /// relative luminance ( otty importers infer the same way ); otherwise inherit / default to dark.
    private static func resolveMode(toml: ParsedTOML, base: ThemeDocument?) -> ThemeDocument.Mode {
        if let raw = toml.string("meta", "mode")?.lowercased(), let mode = ThemeDocument.Mode(rawValue: raw) {
            return mode
        }
        let background = toml.color("terminal", "background") ?? base?.background
        if let background, background != "none", let luminance = Self.luminance(background) {
            // Dark slot when the background is dark. Bare ordered `<` is NaN-faithful here (luminance is a
            // finite 0...1 value); the threshold carries no golden weight (pure client-chrome routing).
            return luminance < 0.5 ? .dark : .light
        }
        return base?.mode ?? .dark
    }

    /// The relative luminance (0...1) of a `#`-less 6-hex colour, or `nil` if it is not a clean hex. Uses the
    /// Rec. 709 coefficients with SEPARATE `*` then `+` (never `addingProduct`/`fma`) — leaf float-math
    /// discipline, even though this value never reaches the wire.
    static func luminance(_ hex: String) -> Double? {
        guard ThemeDocument.isValidHex(hex) else { return nil }
        let chars = Array(hex)
        guard let r = UInt8(String(chars[0...1]), radix: 16),
              let g = UInt8(String(chars[2...3]), radix: 16),
              let b = UInt8(String(chars[4...5]), radix: 16)
        else { return nil }
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        return 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
    }
}

// MARK: - ParsedTOML — the tiny TOML-subset reader (private; pure)

/// A parsed TOML-subset table: `sections[""]` holds the top-level keys, `sections["terminal"]` a `[terminal]`
/// section, etc. Comment-aware (`#` outside a string), quote-aware (a `#` inside `"…"` is a hex colour, not a
/// comment), and array-continuation-aware (a `palette = [` value spanning several lines re-joins until its
/// brackets balance). Every accessor is total — a missing / wrong-typed key returns `nil`, never traps.
///
/// `internal` (not `private`) so the Alacritty importer (``ThemeImporters``) can reuse this proven reader for
/// its `[colors.*]` sections instead of duplicating the comment/quote handling — a dotted `[colors.normal]`
/// header is stored verbatim as the section key `"colors.normal"`.
struct ParsedTOML {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case number(Double)
        case array([Self])
    }

    private var sections: [String: [String: Value]] = [:]

    init(_ text: String) {
        var current = "" // the top-level (pre-section) table
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = Self.stripComment(lines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if line.isEmpty { continue }

            // `[section]` header: a bracket-wrapped line with no assignment.
            if line.hasPrefix("["), line.hasSuffix("]"), !line.contains("=") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if sections[current] == nil { sections[current] = [:] }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue } // malformed line → drop
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            var valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Re-join a multi-line array value until its (unquoted) brackets balance.
            while Self.bracketBalance(valueText) > 0, index < lines.count {
                let continuation = Self.stripComment(lines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                valueText += " " + continuation
            }

            guard !key.isEmpty, let value = Self.parseValue(valueText) else { continue }
            sections[current, default: [:]][key] = value
        }
    }

    // MARK: typed accessors

    func entry(_ section: String, _ key: String) -> Value? { sections[section]?[key] }

    /// The raw string at `section.key` (quotes already stripped), or `nil` when absent / not a string.
    func string(_ section: String, _ key: String) -> String? {
        if case let .string(raw)? = entry(section, key) { return raw }
        return nil
    }

    /// A colour at `section.key`, normalised to a `#`-less hex (case preserved) or the literal `none`. `nil`
    /// when the key is absent or not a string. Malformedness (bad hex) is NOT caught here — it is caught by
    /// ``ThemeDocument/isValid`` so the WHOLE document drops, never a silent half-fix.
    func color(_ section: String, _ key: String) -> String? {
        guard let raw = string(section, key) else { return nil }
        return Self.normalizeColor(raw)
    }

    /// The terminal `palette` array, each entry normalised like ``color(_:_:)``. `nil` when absent or not a
    /// homogeneous string array (count is validated downstream by ``ThemeDocument/isValid``).
    func palette() -> [String]? {
        guard case let .array(values)? = entry("terminal", "palette") else { return nil }
        var out: [String] = []
        out.reserveCapacity(values.count)
        for entry in values {
            guard case let .string(raw) = entry else { return nil }
            out.append(Self.normalizeColor(raw))
        }
        return out
    }

    /// A scalar number at `section.key`, or `nil` when absent / not a number.
    func number(_ section: String, _ key: String) -> Double? {
        if case let .number(scalar)? = entry(section, key) { return scalar }
        return nil
    }

    /// A homogeneous string array at `section.key`. A lone string is promoted to a 1-element array (a font
    /// stack may be written `font-mono = "Menlo"`). `nil` when absent or not all-strings.
    func stringArray(_ section: String, _ key: String) -> [String]? {
        guard let value = entry(section, key) else { return nil }
        switch value {
        case let .string(raw): return [raw]
        case let .array(values):
            var out: [String] = []
            out.reserveCapacity(values.count)
            for element in values {
                guard case let .string(raw) = element else { return nil }
                out.append(raw)
            }
            return out
        default: return nil
        }
    }

    /// A homogeneous number array at `section.key`. A lone number is promoted to a 1-element array (a scalar
    /// `padding = 8`). `nil` when absent or not all-numbers.
    func doubleArray(_ section: String, _ key: String) -> [Double]? {
        guard let value = entry(section, key) else { return nil }
        switch value {
        case let .number(scalar): return [scalar]
        case let .array(values):
            var out: [Double] = []
            out.reserveCapacity(values.count)
            for element in values {
                guard case let .number(scalar) = element else { return nil }
                out.append(scalar)
            }
            return out
        default: return nil
        }
    }

    /// The `adjust-cell-height` token, kept as the raw string (`"20%"` / `"2px"` / `"0"`). A bare number is
    /// stringified (`adjust-cell-height = 0` → `"0"`). `nil` when absent or a non-scalar.
    func cellHeightToken(_ section: String, _ key: String) -> String? {
        guard let value = entry(section, key) else { return nil }
        switch value {
        case let .string(raw): return raw
        case let .number(scalar): return Self.formatNumber(scalar)
        default: return nil
        }
    }

    // MARK: scalar/array value parsing

    /// Parse one TOML-subset value: a `"quoted string"`, a `[a, b]` array (recursive), `true`/`false`, a
    /// number, or — leniently — a bare word treated as a string (`mode = dark`). `nil` when the shape is
    /// broken (an unterminated quote / unbalanced bracket).
    static func parseValue(_ raw: String) -> Value? {
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
            guard let unquoted = unquote(trimmed) else { return nil }
            return .string(unquoted)
        }

        if trimmed.hasPrefix("'") {
            guard let unquoted = unquoteLiteral(trimmed) else { return nil }
            return .string(unquoted)
        }

        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if let number = Double(trimmed) { return .number(number) }
        return .string(trimmed) // lenient bare word
    }

    /// Strip a surrounding pair of double quotes and resolve the minimal escapes (`\"`, `\\`, `\n`, `\t`).
    /// `nil` when the input is not a well-formed `"…"`.
    static func unquote(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return nil }
        var out = ""
        var escaped = false
        for char in raw.dropFirst().dropLast() {
            if escaped {
                switch char {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default: out.append(char)
                }
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// Strip a surrounding pair of SINGLE quotes — a TOML LITERAL string. There are NO escapes inside a literal
    /// (a backslash is a literal backslash) and a `#` is NOT a comment, so Alacritty's idiomatic `'#rrggbb'`
    /// hex colours survive verbatim. `nil` when the input is not a well-formed `'…'`.
    static func unquoteLiteral(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") else { return nil }
        return String(raw.dropFirst().dropLast())
    }

    /// Split `text` on `separator`, ignoring separators inside `"…"` / `'…'` strings or nested `[…]` brackets.
    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
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

    /// Remove a trailing `#` comment from one physical line — but only when the `#` is OUTSIDE a quoted string
    /// (so a `"#FF6188"` basic-string OR a `'#FF6188'` literal-string hex value survives intact). Inside a
    /// single-quoted LITERAL there are no escapes and `#` is never a comment (TOML literal-string semantics).
    static func stripComment(_ line: String) -> String {
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

    /// The net unquoted bracket depth of `text` (`[` = +1, `]` = -1). Used to detect a value whose array
    /// continues onto the next line.
    static func bracketBalance(_ text: String) -> Int {
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

    /// Normalise a colour string: strip a single leading `#`, preserve case, and fold the transparent token to
    /// the canonical lowercase `none`. Validation (clean 6-hex) is left to ``ThemeDocument/isValid``.
    static func normalizeColor(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "none" { return "none" }
        if trimmed.hasPrefix("#") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    /// Format a `Double` for a round-trippable token: integral values print without a decimal (`13.0` → `13`),
    /// fractional values keep their decimal (`12.5` → `12.5`). Integrality is detected with NaN-faithful
    /// ORDERED comparisons (never a bare float `==`).
    static func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        let fraction = value - rounded
        // `fraction >= 0 && fraction <= 0` is true iff the value is integral, and false for NaN (ordered).
        if fraction >= 0, fraction <= 0, value < 1e15, value > -1e15 {
            return String(Int(rounded))
        }
        return String(value)
    }
}
