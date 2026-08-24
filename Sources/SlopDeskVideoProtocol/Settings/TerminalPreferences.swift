import CSlopDeskFFI
import Foundation

/// What a FRESH INSTALL carries, read from `slopdesk-terminal`'s `config`.
///
/// A default IS a rule — it decides what the terminal looks like for everyone who never opens
/// Settings — and these six used to be spelled in this file's `init` defaults AND again in the
/// crate's own test fixture, with nothing connecting the two lists.
public enum TerminalFactoryDefaults {
    /// The primary monospace family.
    public static let fontFamily = text(0)
    /// The weight token (`font-style`).
    public static let fontWeight = text(1)
    /// The surface background, 6-hex without a leading `#`.
    public static let background = text(2)
    /// The text colour, same form.
    public static let foreground = text(3)
    /// The point size.
    public static let fontSize = slopdesk_terminal_factory_number(0)
    /// The cursor opacity.
    public static let cursorOpacity = slopdesk_terminal_factory_number(1)
    /// The scrollback depth, in lines.
    public static let scrollbackLines = Int(slopdesk_terminal_factory_number(2))

    private static func text(_ field: UInt8) -> String {
        var out = [UInt8](repeating: 0, count: 64)
        let needed = out.withUnsafeMutableBufferPointer { room in
            slopdesk_terminal_factory_text(field, room.baseAddress, room.count)
        }
        guard needed > 0, needed <= out.count else { return "" }
        return String(bytes: out[0..<needed], encoding: .utf8) ?? ""
    }
}

/// Live, client-side terminal-render preferences (decision #6: these DO apply live, unlike the video
/// flags). READ from the config file's `[terminal]` table via ``init(_:)``; font/theme apply live via
/// `ghostty_config_load_string` before `ghostty_config_finalize`.
///
/// **Not `Codable`.** It used to be, for a `UserDefaults` blob that no longer exists: the file is the
/// only authoring surface now and ``AppConfig`` already decodes it, so a second decode path here
/// would be the same setting spelled twice. The additive-tolerant `decodeIfPresent` init went with
/// it — a config file simply omits what it does not override, and the row's own default answers.
///
/// Pure value type — no SwiftUI import, so it is headlessly testable and the libghostty
/// config-string builder (`ghosttyConfigString()`) can be unit-tested without a surface. Every
/// field has a real default (these are render prefs, not env overrides), so a default-constructed
/// value is a sensible terminal.
public struct TerminalPreferences: Sendable, Equatable {
    /// Monospace font family (libghostty `font-family`).
    public var fontFamily: String
    /// Font point size (libghostty `font-size`).
    public var fontSize: Double
    /// Font weight token (libghostty `font-style`, e.g. "regular" / "bold").
    public var fontWeight: String
    /// Theme name / palette (libghostty `theme`). Default EMPTY ⇒ no `theme` line: named themes are
    /// not bundled, so the explicit `background`/`foreground`/palette lines are the whole theme.
    public var theme: String
    /// Terminal background colour (libghostty `background`, 6-hex). Defaults to the Dracula
    /// `face` so the terminal surface matches the glass even before the resolved overrides land.
    public var background: String
    /// Terminal foreground / text colour (libghostty `foreground`, 6-hex). Dracula's primary ink.
    public var foreground: String

    /// Cursor style (libghostty `cursor-style`). Four silhouettes; `block_hollow` is a native
    /// libghostty cursor style (`terminal/cursor.zig`) and the raw values are the libghostty config
    /// tokens 1:1.
    ///
    /// What each style is CALLED is not here. It was — a `displayName` reading "Block (hollow)" —
    /// against `slopdesk_workspace::settings_catalog`'s `CURSOR_STYLES`, which calls the same token
    /// "Hollow". Both were user-visible and they were on the same page: the picker drew the
    /// catalog's label and the all-settings index printed this one beside the ✎ that jumps to that
    /// very picker, so one setting read as two different values a scroll apart. The catalog is the
    /// implementation — it is what the control itself draws — and this enum is now only the token.
    public enum CursorStyle: String, Codable, Sendable, CaseIterable {
        case block
        case blockHollow = "block_hollow"
        case bar
        case underline
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
        fontFamily: String = TerminalFactoryDefaults.fontFamily,
        fontSize: Double = TerminalFactoryDefaults.fontSize,
        fontWeight: String = TerminalFactoryDefaults.fontWeight,
        theme: String = "",
        background: String = TerminalFactoryDefaults.background,
        foreground: String = TerminalFactoryDefaults.foreground,
        cursorStyle: CursorStyle = .block,
        cursorBlink: CursorBlink = .default,
        scrollbackLines: Int = TerminalFactoryDefaults.scrollbackLines,
        cursorColor: String = "",
        cursorTextColor: String = "",
        cursorOpacity: Double = TerminalFactoryDefaults.cursorOpacity,
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

    /// Read the whole `[terminal]` table out of a resolved ``AppConfig``.
    ///
    /// Every field is a declared row with a compiled default, so this never has to spell one: an
    /// absent key resolves to the row's default INSIDE `config`, and a key whose value the row
    /// refuses (out of domain, unknown choice token) was already dropped at resolve time with a
    /// diagnostic. That is why there is not one `??` here — the fallbacks are one layer down, in
    /// `rust/slopdesk-settings`'s table, where they are also what `--schema` publishes.
    ///
    /// The one row that is not a plain scalar is `terminal.line-height`, a `Scale`: it lands as a
    /// TEXT stop (`default` / `compact` / `loose`) or as a raw FLOAT multiplier, never both. A float
    /// present means the user typed a number, so it wins; otherwise the token names the stop.
    public init(_ config: AppConfig) {
        self.init(
            fontFamily: config.text("terminal.font-family"),
            fontSize: config.double("terminal.font-size"),
            fontWeight: config.text("terminal.font-weight"),
            theme: config.text("terminal.theme"),
            background: config.text("terminal.background"),
            foreground: config.text("terminal.foreground"),
            cursorStyle: config.choice("terminal.cursor-style", CursorStyle.block),
            cursorBlink: config.choice("terminal.cursor-blink", CursorBlink.default),
            scrollbackLines: config.int("terminal.scrollback-limit"),
            cursorColor: config.text("terminal.cursor-color"),
            cursorTextColor: config.text("terminal.cursor-text-color"),
            cursorOpacity: config.double("terminal.cursor-opacity"),
            fontFamilyFallback: config.text("terminal.font-family-fallback"),
            fontFamilyBold: config.text("terminal.font-family-bold"),
            fontFamilyItalic: config.text("terminal.font-family-italic"),
            fontFamilyBoldItalic: config.text("terminal.font-family-bold-italic"),
            autoMatchWeightStyle: config.flag("terminal.auto-match-weight-style"),
            fontLigatures: config.choice("terminal.ligatures", FontLigatures.off),
            fontLigaturesAlphabet: config.flag("terminal.ligatures-alphabet"),
            fontBold: config.choice("terminal.bold", FontStyleMode.auto),
            fontItalic: config.choice("terminal.italic", FontStyleMode.auto),
            fontBlending: config.choice("terminal.blending", FontBlending.default),
            lineHeight: Self.lineHeight(config),
        )
    }

    /// The dual-typed `terminal.line-height` row: a float multiplier if the user typed one, else the
    /// named stop. An unrecognised token cannot occur (the row validates its own options), so the
    /// last resort is ``LineHeightMode/default`` rather than a trap.
    private static func lineHeight(_ config: AppConfig) -> LineHeightMode {
        if let multiplier = config.optionalDouble("terminal.line-height") {
            return .custom(multiplier)
        }
        switch config.text("terminal.line-height") {
        case "compact": return .compact
        case "loose": return .loose
        default: return .default
        }
    }
}
