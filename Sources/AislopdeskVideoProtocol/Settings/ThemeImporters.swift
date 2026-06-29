import Foundation

/// E15 (WI-5) — pure format converters that turn a third-party terminal colour scheme into a validated
/// ``ThemeDocument``, the same uniform model the `.ottytheme` parser produces.
///
/// otty's "Import Theme…" dropdown accepts five formats; we mirror them: the native otty `.ottytheme`
/// (delegated to ``ThemeTOMLParser`` — chrome preserved), iTerm2 `.itermcolors` (an XML plist of 0…1 sRGB
/// colour dicts), Kitty `.conf` (`foreground #fff` / `color0 #000`), Alacritty `[colors.*]` `.toml`, and
/// Ghostty (`foreground = #fff` / `palette = 0=#000`). Each converter is a PURE `String`/`Data` → document
/// transform with no I/O, so it is headlessly unit-testable; the filesystem wiring (read the file, pick a
/// collision-free slug, write the `.ottytheme`) lives in ``ThemeLibrary/importFile(at:format:into:environment:builtinSlugs:)``.
///
/// **VALIDATE-THEN-DROP (CLAUDE.md §3, file edition).** An imported file is untrusted user input, handled with
/// the same discipline as a hostile UDP datagram: a bad plist, a short palette, a malformed hex, or a missing
/// foreground/background DROPS the whole document (`nil`) — never a force-unwrap, never a trap, never a silent
/// half-fix. Every converter builds a candidate document and returns it only when ``ThemeDocument/isValid``
/// holds.
///
/// **LIGHT/DARK INFERENCE.** Third-party schemes carry no `[meta] mode`, so the slot is inferred from the
/// background's relative luminance (the same Rec. 709 helper the `.ottytheme` parser uses) — a dark background
/// lands the theme in the dark slot. `none`/unparseable backgrounds default to the dark slot.
///
/// COLOUR NORMALISATION: every converter funnels its raw colour tokens through ``normalizeHex(_:)``, which
/// accepts `#rrggbb`, `0xrrggbb`, bare `rrggbb`, the CSS-style `#rgb` shorthand (expanded), and `#rrggbbaa`
/// (alpha dropped) — all case-preserved — and rejects anything else, so the document is built from clean
/// `#`-less 6-hex strings exactly like the TOML path. Float→hex (iTerm2) uses
/// SEPARATE clamp + multiply with NaN-faithful ordered clamps (`Double.minimum`/`Double.maximum`), never
/// `fma`/`addingProduct`.
public enum ThemeImporters {
    /// The set of import formats otty's dropdown offers. The raw value is the stable lowercase id used by the
    /// UI menu / any future CLI.
    public enum Format: String, CaseIterable, Codable, Sendable, Equatable {
        /// Native otty `.ottytheme` TOML — delegated to ``ThemeTOMLParser`` (chrome styling preserved).
        case ottytheme
        /// iTerm2 `.itermcolors` — an XML plist of 0…1 sRGB component dicts.
        case iterm2
        /// Kitty colour `.conf` — whitespace-separated `key value` lines (`foreground #fff` / `color0 #000`).
        case kitty
        /// Alacritty `.toml` — `[colors.primary]` / `[colors.normal]` / `[colors.bright]` sections.
        case alacritty
        /// Ghostty config — `key = value` lines (`foreground = #fff` / `palette = 0=#000`).
        case ghostty

        /// The human-readable label otty shows in the Import dropdown row.
        public var displayLabel: String {
            switch self {
            case .ottytheme: "Otty"
            case .iterm2: "iTerm2"
            case .kitty: "Kitty"
            case .alacritty: "Alacritty"
            case .ghostty: "Ghostty"
            }
        }
    }

    // MARK: - Dispatch + auto-detect

    /// Convert raw file `data` in `format` to a validated ``ThemeDocument``, or `nil` (validate-then-drop).
    /// `fallbackName` is the display name (the file's base name) — third-party files carry no `[meta] name`.
    public static func parse(_ data: Data, format: Format, fallbackName: String) -> ThemeDocument? {
        switch format {
        case .ottytheme:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return ThemeTOMLParser.parse(text, fallbackName: fallbackName)
        case .iterm2:
            return importITerm2(data, fallbackName: fallbackName)
        case .kitty:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return importKitty(text, fallbackName: fallbackName)
        case .alacritty:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return importAlacritty(text, fallbackName: fallbackName)
        case .ghostty:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return importGhostty(text, fallbackName: fallbackName)
        }
    }

    /// Best-effort format detection from the file extension first, then a content sniff. Returns `nil` when the
    /// shape matches nothing (the caller surfaces "unknown format"). The Import dropdown picks the format
    /// explicitly, so this is the Finder-drop / auto path.
    public static func detectFormat(pathExtension: String, contents: String) -> Format? {
        switch pathExtension.lowercased() {
        case "ottytheme": return .ottytheme
        case "itermcolors": return .iterm2
        case "conf": return .kitty
        case "toml": return .alacritty
        default: break
        }

        let lower = contents.lowercased()
        if lower.contains("<plist") || lower.contains("ansi 0 color") { return .iterm2 }
        if contents.contains("[colors.") || lower.contains("[colors]") { return .alacritty }
        if contents.contains("[terminal]") { return .ottytheme }
        // Ghostty: an indexed `palette = N=` line (otty's `.ottytheme` palette is a `[ … ]` array instead).
        if contents.contains("palette =") || contents.contains("palette=") {
            let isArrayPalette = contents.contains("palette = [") || contents.contains("palette=[")
            if !isArrayPalette { return .ghostty }
        }
        if rangeOfColorIndex(contents) { return .kitty } // `color0` … `color15`
        return nil
    }

    /// `true` when `text` contains a Kitty-style `colorN` palette key (the kitty content marker).
    private static func rangeOfColorIndex(_ text: String) -> Bool {
        for index in 0..<16 where text.contains("color\(index)") { return true }
        return false
    }

    // MARK: - iTerm2 (.itermcolors XML plist)

    /// iTerm2 `.itermcolors`: an XML plist whose `Ansi 0 Color` … `Ansi 15 Color`, `Background Color`,
    /// `Foreground Color`, `Cursor Color`, `Cursor Text Color`, and `Selection Color` keys each map to a dict
    /// of `Red/Green/Blue Component` floats in 0…1. We read them with `PropertyListSerialization` (Foundation,
    /// cross-platform) and quantise each channel to 8-bit hex.
    public static func importITerm2(_ data: Data, fallbackName: String) -> ThemeDocument? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let top = plist as? [String: Any]
        else { return nil }

        var palette: [String] = []
        palette.reserveCapacity(ThemeDocument.paletteCount)
        for index in 0..<ThemeDocument.paletteCount {
            guard let hex = iTermColor(top["Ansi \(index) Color"]) else { return nil }
            palette.append(hex)
        }

        let foreground = iTermColor(top["Foreground Color"]) ?? ""
        let background = iTermColor(top["Background Color"]) ?? ""

        let document = ThemeDocument(
            displayName: fallbackName,
            slug: ThemeDocument.slug(from: fallbackName),
            mode: inferMode(background: background),
            foreground: foreground,
            background: background,
            palette: palette,
            cursor: iTermColor(top["Cursor Color"]),
            cursorText: iTermColor(top["Cursor Text Color"]),
            selectionBackground: iTermColor(top["Selection Color"]),
        )
        return document.isValid ? document : nil
    }

    /// Quantise one iTerm2 colour dict (`Red/Green/Blue Component`, 0…1 floats) to a `#`-less 6-hex string, or
    /// `nil` when the entry is absent / not a component dict.
    private static func iTermColor(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any],
              let r = component(dict["Red Component"]),
              let g = component(dict["Green Component"]),
              let b = component(dict["Blue Component"])
        else { return nil }
        return hexByte(r) + hexByte(g) + hexByte(b)
    }

    /// Read a plist real / integer as a `Double` (`<real>0.5</real>` or an integral `<integer>1</integer>`),
    /// via Swift value-type bridging — no bridged `NSNumber` reference type (the leaf forbids those).
    private static func component(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// Quantise a 0…1 channel to a 2-digit uppercase hex byte. The clamp is NaN-faithful ORDERED
    /// (`Double.maximum`/`Double.minimum`, never a bare `<`/`>` ternary) and the scale is a PLAIN `*` (never
    /// `fma`/`addingProduct`) — leaf float-math discipline even though this never reaches the wire.
    private static func hexByte(_ channel: Double) -> String {
        let clamped = Double.minimum(1.0, Double.maximum(0.0, channel))
        let scaled = clamped * 255.0
        let byte = Int(scaled.rounded())
        return String(format: "%02X", byte)
    }

    // MARK: - Kitty (.conf)

    /// Kitty colour `.conf`: whitespace-separated `key value` lines. `foreground`/`background`/`cursor`/
    /// `cursor_text_color`/`selection_background` map to the named roles; `color0`…`color15` to the palette.
    /// `#`-prefixed comment lines and unknown keys are ignored (validate-then-drop falls through to `isValid`).
    public static func importKitty(_ text: String, fallbackName: String) -> ThemeDocument? {
        var foreground = ""
        var background = ""
        var cursor: String?
        var cursorText: String?
        var selectionBackground: String?
        var palette = [String?](repeating: nil, count: ThemeDocument.paletteCount)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            let key = fields[0].lowercased()
            guard let hex = normalizeHex(fields[1]) else { continue }
            switch key {
            case "foreground": foreground = hex
            case "background": background = hex
            case "cursor": cursor = hex
            case "cursor_text_color": cursorText = hex
            case "selection_background": selectionBackground = hex
            default:
                if let index = kittyColorIndex(key), index < ThemeDocument.paletteCount {
                    palette[index] = hex
                }
            }
        }

        return assemble(
            fallbackName: fallbackName,
            foreground: foreground,
            background: background,
            palette: palette,
            cursor: cursor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
        )
    }

    /// The `N` of a `colorN` Kitty palette key (`color0`…`color255`), or `nil` for any other key.
    private static func kittyColorIndex(_ key: String) -> Int? {
        guard key.hasPrefix("color") else { return nil }
        return Int(key.dropFirst("color".count))
    }

    // MARK: - Alacritty (.toml)

    /// Alacritty `.toml`: `[colors.primary]` (background/foreground), `[colors.normal]` (palette 0–7),
    /// `[colors.bright]` (palette 8–15), `[colors.cursor]` (cursor/text), `[colors.selection]` (background).
    /// Reuses the proven ``ParsedTOML`` reader (comment/quote-aware) and accepts both `"#rrggbb"` and
    /// `"0xrrggbb"` colour literals.
    public static func importAlacritty(_ text: String, fallbackName: String) -> ThemeDocument? {
        let toml = ParsedTOML(text)
        func colour(_ section: String, _ key: String) -> String? {
            guard let raw = toml.string(section, key) else { return nil }
            return normalizeHex(raw)
        }

        let normal = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var palette = [String?](repeating: nil, count: ThemeDocument.paletteCount)
        for (offset, name) in normal.enumerated() {
            palette[offset] = colour("colors.normal", name)
            palette[offset + 8] = colour("colors.bright", name)
        }

        return assemble(
            fallbackName: fallbackName,
            foreground: colour("colors.primary", "foreground") ?? "",
            background: colour("colors.primary", "background") ?? "",
            palette: palette,
            // Alacritty's [colors.cursor] uses `cursor` for the block and `text` for the glyph under it.
            cursor: colour("colors.cursor", "cursor"),
            cursorText: colour("colors.cursor", "text"),
            selectionBackground: colour("colors.selection", "background"),
        )
    }

    // MARK: - Ghostty

    /// Ghostty config: `key = value` lines. `foreground`/`background`/`cursor-color`/`cursor-text`/
    /// `selection-background` map to the named roles; an indexed `palette = N=#hex` fills the palette. `#`
    /// comment lines and unknown keys are ignored.
    public static func importGhostty(_ text: String, fallbackName: String) -> ThemeDocument? {
        var foreground = ""
        var background = ""
        var cursor: String?
        var cursorText: String?
        var selectionBackground: String?
        var palette = [String?](repeating: nil, count: ThemeDocument.paletteCount)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "palette" {
                // `value` is `N=#hex` — split on the FIRST `=` into index + colour.
                let kv = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard kv.count == 2,
                      let index = Int(kv[0].trimmingCharacters(in: .whitespaces)),
                      index >= 0, index < ThemeDocument.paletteCount,
                      let hex = normalizeHex(kv[1].trimmingCharacters(in: .whitespaces))
                else { continue }
                palette[index] = hex
                continue
            }

            guard let hex = normalizeHex(value) else { continue }
            switch key {
            case "foreground": foreground = hex
            case "background": background = hex
            case "cursor-color": cursor = hex
            case "cursor-text": cursorText = hex
            case "selection-background": selectionBackground = hex
            default: break
            }
        }

        return assemble(
            fallbackName: fallbackName,
            foreground: foreground,
            background: background,
            palette: palette,
            cursor: cursor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
        )
    }

    // MARK: - Shared assembly + helpers

    /// Build a candidate document from per-role colours and an optional-entry palette, returning it only when
    /// ``ThemeDocument/isValid`` holds. A palette with any missing entry collapses to a short array (it drops
    /// the `nil`s), which fails the 16-entry check — exactly the validate-then-drop outcome.
    private static func assemble(
        fallbackName: String,
        foreground: String,
        background: String,
        palette: [String?],
        cursor: String?,
        cursorText: String?,
        selectionBackground: String?,
    ) -> ThemeDocument? {
        let resolvedPalette = palette.compactMap(\.self)
        let document = ThemeDocument(
            displayName: fallbackName,
            slug: ThemeDocument.slug(from: fallbackName),
            mode: inferMode(background: background),
            foreground: foreground,
            background: background,
            palette: resolvedPalette,
            cursor: cursor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
        )
        return document.isValid ? document : nil
    }

    /// Infer the light/dark slot from the background's relative luminance — a dark background lands the theme in
    /// the dark slot (`luminance < 0.5`). `none` / unparseable backgrounds default to dark. Bare ordered `<` is
    /// NaN-faithful here (luminance is a finite 0…1), and the threshold carries no golden weight (pure chrome).
    static func inferMode(background: String) -> ThemeDocument.Mode {
        if background != "none", let luminance = ThemeTOMLParser.luminance(background) {
            return luminance < 0.5 ? .dark : .light
        }
        return .dark
    }

    /// Normalise a third-party colour token to a `#`-less 6-hex string (case preserved), or `nil` when it is
    /// not a clean hex. Accepts a leading `#` or `0x`/`0X`; folds the transparent token to `none` (only valid
    /// for a `background`). Both Kitty and Ghostty accept CSS-style shorthand, so before the 6-hex check we
    /// EXPAND a 3-digit `rgb` → `rrggbb` (each nibble doubled) and TOLERATE an 8-digit `rrggbbaa` by dropping
    /// the alpha (terminal colours have no alpha channel) — both only when the digits are clean hex. Validation
    /// is the exact 6-hex check ``ThemeDocument/isValidHex(_:)`` — anything else (wrong length, stray
    /// characters) drops.
    static func normalizeHex(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a surrounding pair of quotes (some tools quote bare values).
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        if value.lowercased() == "none" { return "none" }
        if value.hasPrefix("#") {
            value = String(value.dropFirst())
        } else if value.hasPrefix("0x") || value.hasPrefix("0X") {
            value = String(value.dropFirst(2))
        }
        // CSS-style shorthand → canonical 6-hex (an invalid nibble still fails the final isValidHex check).
        if value.count == 3, value.allSatisfy(\.isHexDigit) {
            value = value.map { "\($0)\($0)" }.joined()
        } else if value.count == 8, value.allSatisfy(\.isHexDigit) {
            value = String(value.prefix(6))
        }
        return ThemeDocument.isValidHex(value) ? value : nil
    }
}
