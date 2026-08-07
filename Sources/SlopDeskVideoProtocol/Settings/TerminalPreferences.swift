import Foundation

/// Live, client-side terminal-render preferences (decision #6: these DO apply live, unlike the video
/// flags). Persisted via `@AppStorage` / `UserDefaults` (the model is the source of truth); font/theme
/// apply live via `ghostty_config_load_string` before `ghostty_config_finalize`.
///
/// Pure `Codable` value type — no SwiftUI import, so it is headlessly testable and the libghostty
/// config-string builder (`ghosttyConfigString()`) can be unit-tested without a surface. Every
/// field has a real default (these are render prefs, not env overrides), so a default-constructed
/// value is a sensible terminal.
public struct TerminalPreferences: Codable, Sendable, Equatable {
    /// Monospace font family (libghostty `font-family`).
    public var fontFamily: String
    /// Font point size (libghostty `font-size`).
    public var fontSize: Double
    /// Font weight token (libghostty `font-style`, e.g. "regular" / "bold").
    public var fontWeight: String
    /// Theme name / palette (libghostty `theme`). Default EMPTY ⇒ no `theme` line: named themes are
    /// not bundled, so the explicit `background`/`foreground`/palette lines are the whole theme.
    public var theme: String
    /// Terminal background colour (libghostty `background`, 6-hex). Defaults to the Foundry Ember
    /// `face` so the terminal surface matches the chrome even before the ``ThemeStore`` overrides land.
    public var background: String
    /// Terminal foreground / text colour (libghostty `foreground`, 6-hex). Ember's primary ink.
    public var foreground: String

    /// Cursor style (libghostty `cursor-style`). Four styles: Block,
    /// Block (hollow), Bar, Underline. `block_hollow` is a native libghostty cursor style
    /// (`terminal/cursor.zig`); the raw values are the libghostty config tokens 1:1.
    public enum CursorStyle: String, Codable, Sendable, CaseIterable {
        case block
        case blockHollow = "block_hollow"
        case bar
        case underline

        /// The UI-facing display label (the dropdown text), since the kebab-style raw value
        /// (`block_hollow`) does not capitalize into "Block (hollow)".
        public var displayName: String {
            switch self {
            case .block: "Block"
            case .blockHollow: "Block (hollow)"
            case .bar: "Bar"
            case .underline: "Underline"
            }
        }
    }

    /// Whether the cursor blinks (libghostty `cursor-style-blink`). A TRI-STATE "Cursor blink style"
    /// setting: ``default`` defers to DEC mode 12 (the
    /// default), ``on`` / ``off`` force it. libghostty's `cursor-style-blink` is an optional bool (`?bool` —
    /// null = defer to DEC mode 12), so ``default`` SKIPS the config line and only ``on`` / ``off`` emit
    /// `true` / `false` (see ``TerminalConfigBuilder``).
    public enum CursorBlink: String, Codable, Sendable, CaseIterable {
        /// Defer to DEC mode 12 (the program decides) — emits NO `cursor-style-blink` line (the default).
        case `default`
        /// Force blinking on (`cursor-style-blink = true`).
        case on
        /// Force blinking off (`cursor-style-blink = false`).
        case off
    }

    /// Terminal cursor style.
    public var cursorStyle: CursorStyle
    /// Cursor blink behaviour (libghostty `cursor-style-blink`), default ``CursorBlink/default`` (defer to
    /// DEC mode 12).
    public var cursorBlink: CursorBlink
    /// Scrollback buffer size in lines (libghostty `scrollback-limit`, rows).
    public var scrollbackLines: Int

    // Cursor color / text-under / opacity / animation render prefs (Appearance → Cursor). These
    // are render prefs with real defaults — applied live exactly like `cursorStyle` / `cursorBlink` — NOT
    // env overrides, so they never reach the EnvConfig overlay. Empty colour strings mean "follow the
    // theme" (the builder skips an empty `cursor-color` / `cursor-text` line — the "unset honoured" rule).
    /// Cursor body colour (libghostty `cursor-color`, 6-hex). Empty = follow the foreground automatically
    /// ("Default"); a non-empty value pins the caret colour.
    public var cursorColor: String
    /// Glyph colour rendered UNDER the cursor (libghostty `cursor-text`, 6-hex). Empty = follow the
    /// background automatically ("Default").
    public var cursorTextColor: String
    /// Cursor body opacity (libghostty `cursor-opacity`, `0.0`…`1.0`), default `1.0` (fully opaque).
    public var cursorOpacity: Double

    // FONT-PARITY render prefs (Appearance → Font). Like the cursor render fields these are
    // pure-chrome prefs with real defaults — applied live via `TerminalConfigBuilder` → libghostty — NEVER
    // env overrides / `video-prefs.json` / golden corpus. Every default value below is the one that emits NO
    // new libghostty line, so a default-constructed value stays byte-identical to the builder output before
    // these fields existed (the regression guard). The enums + their token mapping live in ``TerminalFontSettings``.
    /// Comma-separated fallback font families; used when the primary font lacks a glyph (CJK, Nerd-Font
    /// icons). ghostty has NO `font-family-fallback` key — each entry is emitted as a REPEATED `font-family`
    /// line after the primary (`font-family` is a `RepeatableString`; see ``TerminalConfigBuilder``). Empty
    /// (the default) ⇒ only the primary `font-family` line.
    public var fontFamilyFallback: String
    /// Explicit bold face family (libghostty `font-family-bold`). Emitted ONLY when ``autoMatchWeightStyle``
    /// is OFF and non-empty (the UI surfaces the four manual face pickers only when auto-match is off).
    public var fontFamilyBold: String
    /// Explicit italic face family (libghostty `font-family-italic`). Same gate as ``fontFamilyBold``.
    public var fontFamilyItalic: String
    /// Explicit bold-italic face family (libghostty `font-family-bold-italic`). Same gate as ``fontFamilyBold``.
    public var fontFamilyBoldItalic: String
    /// "Auto-match weight & style" (default ON): pick the real bold/italic/bold-italic faces of the
    /// chosen family automatically. When OFF, the explicit `fontFamilyBold/Italic/BoldItalic` fields apply.
    public var autoMatchWeightStyle: Bool
    /// Ligature mode (`font-ligatures`), default ``FontLigatures/off`` (no `font-feature` line).
    public var fontLigatures: FontLigatures
    /// Extend ligation to alphabetic sequences (`font-ligatures-alphabet`), default `false`. When `true`
    /// AND ligatures are on, the builder appends `liga` to the `font-feature` list.
    public var fontLigaturesAlphabet: Bool
    /// Bold face mode (`font-bold`), default ``FontStyleMode/auto`` (no line).
    public var fontBold: FontStyleMode
    /// Italic face mode (`font-italic`), default ``FontStyleMode/auto`` (no line).
    public var fontItalic: FontStyleMode
    /// Glyph anti-aliasing blend mode (`font-blending`), default ``FontBlending/default``.
    /// ``FontBlending/macosLike`` maps to `font-thicken = true`.
    public var fontBlending: FontBlending
    /// Cell-height mode (`line-height`), default ``LineHeightMode/default`` (no `adjust-cell-height`
    /// line — the theme/font decides).
    public var lineHeight: LineHeightMode

    public init(
        fontFamily: String = "SF Mono",
        fontSize: Double = 13,
        fontWeight: String = "regular",
        theme: String = "",
        background: String = "27221E",
        foreground: String = "E6DED6",
        cursorStyle: CursorStyle = .block,
        cursorBlink: CursorBlink = .default,
        scrollbackLines: Int = 10000,
        cursorColor: String = "",
        cursorTextColor: String = "",
        cursorOpacity: Double = 1.0,
        fontFamilyFallback: String = "",
        fontFamilyBold: String = "",
        fontFamilyItalic: String = "",
        fontFamilyBoldItalic: String = "",
        autoMatchWeightStyle: Bool = true,
        fontLigatures: FontLigatures = .off,
        fontLigaturesAlphabet: Bool = false,
        fontBold: FontStyleMode = .auto,
        fontItalic: FontStyleMode = .auto,
        fontBlending: FontBlending = .default,
        lineHeight: LineHeightMode = .default,
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.theme = theme
        self.background = background
        self.foreground = foreground
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.scrollbackLines = scrollbackLines
        self.cursorColor = cursorColor
        self.cursorTextColor = cursorTextColor
        self.cursorOpacity = cursorOpacity
        self.fontFamilyFallback = fontFamilyFallback
        self.fontFamilyBold = fontFamilyBold
        self.fontFamilyItalic = fontFamilyItalic
        self.fontFamilyBoldItalic = fontFamilyBoldItalic
        self.autoMatchWeightStyle = autoMatchWeightStyle
        self.fontLigatures = fontLigatures
        self.fontLigaturesAlphabet = fontLigaturesAlphabet
        self.fontBold = fontBold
        self.fontItalic = fontItalic
        self.fontBlending = fontBlending
        self.lineHeight = lineHeight
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily
        case fontSize
        case fontWeight
        case theme
        case background
        case foreground
        case cursorStyle
        case cursorBlink
        case scrollbackLines
        case cursorColor
        case cursorTextColor
        case cursorOpacity
        case fontFamilyFallback
        case fontFamilyBold
        case fontFamilyItalic
        case fontFamilyBoldItalic
        case autoMatchWeightStyle
        case fontLigatures
        case fontLigaturesAlphabet
        case fontBold
        case fontItalic
        case fontBlending
        case lineHeight
    }

    /// ADDITIVE-TOLERANT decoding (NOT a migration — no-backcompat rule preserved). Each field is
    /// `decodeIfPresent ?? <default>`, so a stored blob written before a field existed (e.g. an existing
    /// user's terminal prefs from before the font-parity fields landed) DECODES SUCCESSFULLY with the
    /// new fields defaulted — it does NOT decode-fail and reset every terminal pref once on upgrade. The
    /// defaults are sourced from a default-constructed value so they can never drift from the memberwise
    /// init. GENUINE corruption still resets: a key that is PRESENT but holds an invalid value (e.g. an
    /// unknown `cursorStyle` raw) throws from `decodeIfPresent`, so `PreferencesStore.decode`'s `try?`
    /// falls back to the default — the validate-then-default discipline for hostile/stale data is intact.
    /// Mirrors the established ``KeybindingPreferences`` `decodeIfPresent` precedent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        try self.init(
            fontFamily: c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily,
            fontSize: c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize,
            fontWeight: c.decodeIfPresent(String.self, forKey: .fontWeight) ?? d.fontWeight,
            theme: c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme,
            background: c.decodeIfPresent(String.self, forKey: .background) ?? d.background,
            foreground: c.decodeIfPresent(String.self, forKey: .foreground) ?? d.foreground,
            cursorStyle: c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? d.cursorStyle,
            cursorBlink: c.decodeIfPresent(CursorBlink.self, forKey: .cursorBlink) ?? d.cursorBlink,
            scrollbackLines: c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? d.scrollbackLines,
            cursorColor: c.decodeIfPresent(String.self, forKey: .cursorColor) ?? d.cursorColor,
            cursorTextColor: c.decodeIfPresent(String.self, forKey: .cursorTextColor) ?? d.cursorTextColor,
            cursorOpacity: c.decodeIfPresent(Double.self, forKey: .cursorOpacity) ?? d.cursorOpacity,
            fontFamilyFallback: c.decodeIfPresent(String.self, forKey: .fontFamilyFallback) ?? d.fontFamilyFallback,
            fontFamilyBold: c.decodeIfPresent(String.self, forKey: .fontFamilyBold) ?? d.fontFamilyBold,
            fontFamilyItalic: c.decodeIfPresent(String.self, forKey: .fontFamilyItalic) ?? d.fontFamilyItalic,
            fontFamilyBoldItalic: c.decodeIfPresent(String.self, forKey: .fontFamilyBoldItalic)
                ?? d.fontFamilyBoldItalic,
            autoMatchWeightStyle: c.decodeIfPresent(Bool.self, forKey: .autoMatchWeightStyle)
                ?? d.autoMatchWeightStyle,
            fontLigatures: c.decodeIfPresent(FontLigatures.self, forKey: .fontLigatures) ?? d.fontLigatures,
            fontLigaturesAlphabet: c.decodeIfPresent(Bool.self, forKey: .fontLigaturesAlphabet)
                ?? d.fontLigaturesAlphabet,
            fontBold: c.decodeIfPresent(FontStyleMode.self, forKey: .fontBold) ?? d.fontBold,
            fontItalic: c.decodeIfPresent(FontStyleMode.self, forKey: .fontItalic) ?? d.fontItalic,
            fontBlending: c.decodeIfPresent(FontBlending.self, forKey: .fontBlending) ?? d.fontBlending,
            lineHeight: c.decodeIfPresent(LineHeightMode.self, forKey: .lineHeight) ?? d.lineHeight,
        )
    }
}
