import Foundation

/// Live, client-side terminal-render preferences (decision #6: these DO apply live, unlike the video
/// flags). Persisted via `@AppStorage` / `UserDefaults` (the model is the source of truth); W13 applies
/// font/theme live via `ghostty_config_load_string` before `ghostty_config_finalize`.
///
/// Pure `Codable` value type — no SwiftUI import, so it is headlessly testable and the libghostty
/// config-string builder (`ghosttyConfigString()`, W13) can be unit-tested without a surface. Every
/// field has a real default (these are render prefs, not env overrides), so a default-constructed
/// value is a sensible terminal.
public struct TerminalPreferences: Codable, Sendable, Equatable {
    /// Monospace font family (libghostty `font-family`).
    public var fontFamily: String
    /// Font point size (libghostty `font-size`).
    public var fontSize: Double
    /// Font weight token (libghostty `font-style`, e.g. "regular" / "bold").
    public var fontWeight: String
    /// Theme name / palette (libghostty `theme`).
    public var theme: String
    /// Terminal background colour (libghostty `background`, 6-hex). Defaults to otty's "Paper" warm
    /// off-white so the terminal surface matches the Paper chrome (named themes are not bundled, so an
    /// explicit colour — applied AFTER `theme` — is what actually pins the surface light).
    public var background: String
    /// Terminal foreground / text colour (libghostty `foreground`, 6-hex). otty's primary text on Paper.
    public var foreground: String

    /// Cursor style (libghostty `cursor-style`). otty's four styles (`cursor-style.png`): Block,
    /// Block (hollow), Bar, Underline. `block_hollow` is a native libghostty cursor style
    /// (`terminal/cursor.zig`); the raw values are the libghostty config tokens 1:1.
    public enum CursorStyle: String, Codable, Sendable, CaseIterable {
        case block
        case blockHollow = "block_hollow"
        case bar
        case underline

        /// The otty-facing display label (the dropdown text), since the kebab-style raw value
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

    /// Whether the cursor blinks (libghostty `cursor-style-blink`). A TRI-STATE matching otty's three-value
    /// "Cursor blink style" dropdown (`cursor-style.png`): ``default`` defers to DEC mode 12 (the otty
    /// default), ``on`` / ``off`` force it. libghostty's `cursor-style-blink` is an optional bool (`?bool` —
    /// null = defer to DEC mode 12), so ``default`` SKIPS the config line and only ``on`` / ``off`` emit
    /// `true` / `false` (see ``TerminalConfigBuilder``).
    public enum CursorBlink: String, Codable, Sendable, CaseIterable {
        /// Defer to DEC mode 12 (the program decides) — emits NO `cursor-style-blink` line (the otty default).
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

    /// Cursor body-glide animation (otty `cursor.animation`).
    public enum CursorAnimation: String, Codable, Sendable, CaseIterable {
        /// No animation — the caret jumps discretely (the libghostty default; the otty default).
        case off
        /// Glide the caret on same-row moves and add a small elastic overshoot on click / focus. A
        /// CLIENT-side render layer (the pinned libghostty fork exposes no cursor-animation key, so the
        /// glide is the documented ceiling, deferred — E8 DECISIONS); the value persists + surfaces today.
        case smooth
    }

    // E8 WI-1: cursor color / text-under / opacity / animation render prefs (Appearance → Cursor). These
    // are render prefs with real defaults — applied live exactly like `cursorStyle` / `cursorBlink` — NOT
    // env overrides, so they never reach the EnvConfig overlay. Empty colour strings mean "follow the
    // theme" (the builder skips an empty `cursor-color` / `cursor-text` line — the "unset honoured" rule).
    /// Cursor body colour (libghostty `cursor-color`, 6-hex). Empty = follow the foreground automatically
    /// (otty's "Default"); a non-empty value pins the caret colour.
    public var cursorColor: String
    /// Glyph colour rendered UNDER the cursor (libghostty `cursor-text`, 6-hex). Empty = follow the
    /// background automatically (otty's "Default").
    public var cursorTextColor: String
    /// Cursor body opacity (libghostty `cursor-opacity`, `0.0`…`1.0`), default `1.0` (fully opaque).
    public var cursorOpacity: Double
    /// Cursor glide animation (otty `cursor.animation`), default ``CursorAnimation/off``.
    public var cursorAnimation: CursorAnimation

    // E12 (Composer): CLIENT-only composer prefs (otty "Composer max height" + the persisted pin flag).
    // Live client UI prefs — NOT host `AgentPreferences`, no `video-prefs.json` sidecar, no env overlay, no
    // golden corpus (decision #6). Both are OPTIONAL so an absent value falls back to the documented default
    // (no migration needed when a stored prefs blob predates E12 — `nil` decodes cleanly).
    /// The fraction of the pane's height the Composer field grows to before it switches to internal scroll
    /// (otty "Composer max height", value unspecified on the docs page → default ``defaultComposerMaxHeightFraction``,
    /// ~0.4). `nil` = use the default; a stored value is clamped into `0.15…0.9` at the read site.
    public var composerMaxHeightFraction: Double?
    /// Whether the Composer is PINNED (rides along across tab switches via a window-level mount, E12 WI-6).
    /// `nil` = not pinned (the default). Persisted so a pinned Composer survives an app relaunch.
    public var composerPinned: Bool?

    /// The default Composer max-height fraction when ``composerMaxHeightFraction`` is unset (~0.4 of the pane
    /// height — the value suggested by the Composer docs page, which leaves the number unspecified).
    public static let defaultComposerMaxHeightFraction: Double = 0.4

    public init(
        fontFamily: String = "SF Mono",
        fontSize: Double = 13,
        fontWeight: String = "regular",
        theme: String = "Aislopdesk Dark",
        background: String = "FCFBF9",
        foreground: String = "37352F",
        cursorStyle: CursorStyle = .block,
        cursorBlink: CursorBlink = .default,
        scrollbackLines: Int = 10000,
        cursorColor: String = "",
        cursorTextColor: String = "",
        cursorOpacity: Double = 1.0,
        cursorAnimation: CursorAnimation = .off,
        composerMaxHeightFraction: Double? = nil,
        composerPinned: Bool? = nil,
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
        self.cursorAnimation = cursorAnimation
        self.composerMaxHeightFraction = composerMaxHeightFraction
        self.composerPinned = composerPinned
    }

    /// The resolved Composer max-height fraction — the stored ``composerMaxHeightFraction`` clamped into a
    /// sane `0.15…0.9` band, or ``defaultComposerMaxHeightFraction`` when unset. The view multiplies this by
    /// the live pane height to get the field's max height (then internal scroll). Ordered min/max (NaN-safe).
    public var resolvedComposerMaxHeightFraction: Double {
        guard let fraction = composerMaxHeightFraction else { return Self.defaultComposerMaxHeightFraction }
        return Double.minimum(0.9, Double.maximum(0.15, fraction))
    }
}
