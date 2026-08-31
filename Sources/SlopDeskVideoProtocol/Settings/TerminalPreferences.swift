import CSlopDeskFFI
import Foundation

/// What a FRESH INSTALL carries, read from `slopdesk-terminal`'s `config`.
///
/// A default IS a rule — it decides what the terminal looks like for everyone who never opens
/// Settings — and these used to be spelled in this file's `init` defaults AND again in the
/// crate's own test fixture, with nothing connecting the two lists.
public enum TerminalFactoryDefaults {
    /// The primary monospace family.
    public static let fontFamily = text(0)
    /// The surface background, 6-hex without a leading `#`.
    public static let background = text(1)
    /// The text colour, same form.
    public static let foreground = text(2)
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
/// flags). READ from the config file's `[terminal]` table via ``init(_:)``; font/theme used to apply
/// live via the deleted fork's `ghostty_config_load_string` before `ghostty_config_finalize` — see
/// docs/68 for what replaced that apply path.
///
/// **Not `Codable`.** It used to be, for a `UserDefaults` blob that no longer exists: the file is the
/// only authoring surface now and ``AppConfig`` already decodes it, so a second decode path here
/// would be the same setting spelled twice. The additive-tolerant `decodeIfPresent` init went with
/// it — a config file simply omits what it does not override, and the row's own default answers.
///
/// Pure value type — no view framework, so it is headlessly testable without a surface. Every field
/// has a real default (these are render prefs, not env overrides), so a default-constructed value is
/// a sensible terminal.
public struct TerminalPreferences: Sendable, Equatable {
    /// Monospace font family (libghostty `font-family`).
    public var fontFamily: String
    /// Font point size (libghostty `font-size`).
    public var fontSize: Double
    /// Terminal background colour (`terminal.background`, 6-hex). Defaults to the profile's own
    /// `face`, so the terminal surface matches the glass even before the resolved theme lands.
    ///
    /// ⚠️ THE APP PALETTE WINS WHERE IT IS INSTALLED, which is every GUI build — one flat appearance
    /// is a design law, not a preference. These two answer where no palette was handed in at all
    /// (headless, pre-launch, the golden and `ImageRenderer` paths), which is the ONLY reading under
    /// which a file-stated colour is not contradicting the island it is drawn on.
    public var background: String
    /// Terminal foreground / text colour (`terminal.foreground`, 6-hex). See ``background``.
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

        /// The byte `slopdesk_term_surface_set_cursor_style` takes.
        ///
        /// Spelled beside the cases so the four numbers are written once. They are the DOOR's
        /// order, not this enum's declaration order, and nothing enforces the two agree — which is
        /// exactly why a call site is never allowed to spell one.
        public var surfaceCode: UInt8 {
            switch self {
            case .block: 0
            case .bar: 1
            case .underline: 2
            case .blockHollow: 3
            }
        }
    }

    /// Whether the cursor blinks (`terminal.cursor-blink`). A TRI-STATE setting: ``default`` defers to
    /// DEC mode 12 (the program decides), ``on`` / ``off`` force it. The door takes all three as
    /// ``surfaceCode``, and it sets the engine's DEFAULT — so a running program's own DEC-12 flip
    /// still wins, which is what makes the setting safe to push.
    public enum CursorBlink: String, Codable, Sendable, CaseIterable {
        /// Defer to DEC mode 12 (the program decides) — emits NO `cursor-style-blink` line (the default).
        case `default`
        /// Force blinking on (`cursor-style-blink = true`).
        case on
        /// Force blinking off (`cursor-style-blink = false`).
        case off

        /// The byte `slopdesk_term_surface_set_cursor_blink` takes: `1` on, `2` off, `0` the
        /// engine's own default. Three states rather than a bool for the reason above — a user who
        /// has not chosen leaves it to DEC mode 12, and a bool would have to invent their answer.
        public var surfaceCode: UInt8 {
            switch self {
            case .default: 0
            case .on: 1
            case .off: 2
            }
        }
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

    /// Cell-height mode (`line-height`), default ``LineHeightMode/default`` (no `adjust-cell-height`
    /// line — the theme/font decides).
    public var lineHeight: LineHeightMode

    public init(
        fontFamily: String = TerminalFactoryDefaults.fontFamily,
        fontSize: Double = TerminalFactoryDefaults.fontSize,
        background: String = TerminalFactoryDefaults.background,
        foreground: String = TerminalFactoryDefaults.foreground,
        cursorStyle: CursorStyle = .block,
        cursorBlink: CursorBlink = .default,
        scrollbackLines: Int = TerminalFactoryDefaults.scrollbackLines,
        cursorColor: String = "",
        cursorTextColor: String = "",
        cursorOpacity: Double = TerminalFactoryDefaults.cursorOpacity,
        lineHeight: LineHeightMode = .default,
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.background = background
        self.foreground = foreground
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.scrollbackLines = scrollbackLines
        self.cursorColor = cursorColor
        self.cursorTextColor = cursorTextColor
        self.cursorOpacity = cursorOpacity
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
            background: config.text("terminal.background"),
            foreground: config.text("terminal.foreground"),
            cursorStyle: config.choice("terminal.cursor-style", CursorStyle.block),
            cursorBlink: config.choice("terminal.cursor-blink", CursorBlink.default),
            scrollbackLines: config.int("terminal.scrollback-limit"),
            cursorColor: config.text("terminal.cursor-color"),
            cursorTextColor: config.text("terminal.cursor-text-color"),
            cursorOpacity: config.double("terminal.cursor-opacity"),
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

    /// The cell background as the door takes it, or `nil` when the file's text is not a colour.
    public var backgroundWord: UInt32? { Self.word(background) }

    /// The cell foreground as the door takes it, or `nil` when the file's text is not a colour.
    public var foregroundWord: UInt32? { Self.word(foreground) }

    /// The caret's colour as the door takes it, or `nil` to follow the foreground.
    public var cursorColorWord: UInt32? { Self.word(cursorColor) }

    /// The glyph-under-caret colour as the door takes it, or `nil` to keep the cell's background.
    public var cursorTextColorWord: UInt32? { Self.word(cursorTextColor) }

    /// A bare 6-hex colour as the `0x00RRGGBB` word every renderer door takes.
    ///
    /// `nil` for anything that is not exactly six hex digits, which folds the "unset honoured" rule
    /// and malformed input into one answer: both mean *this preference states no colour*, and the
    /// door's own `present: false` branch is the only place either can land. The strings arrive from
    /// a config row that does not validate colours, so refusing here is what keeps a typo from
    /// painting a caret some colour nobody chose.
    private static func word(_ hex: String) -> UInt32? {
        guard hex.count == 6 else { return nil }
        return UInt32(hex, radix: 16)
    }
}
