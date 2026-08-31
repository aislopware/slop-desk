/// The seam by which the headless ``PreferencesStore`` (in `SlopDeskWorkspaceCore`) reads the GUI's
/// terminal-cell palette without depending on either UI shell (`SlopDeskMacUI` / `SlopDeskPhoneUI`),
/// which `WorkspaceCore` must not import. Mirrors the ``TerminalRendererFactory/shared`` /
/// `VideoWindowFactory.shared` injected-closure pattern: the app target sets it at launch and the
/// headless build simply never has one.
///
/// Headless / no-store (the golden + ImageRenderer paths): the hook is `nil`, so the terminal keeps the
/// ``TerminalPreferences`` colours and headless renders stay byte-identical to today.
///
/// The theme-APPLY and active-slug hooks that used to sit here went with the theme picker
/// (user-directed 2026-08-08): with one appearance there is nothing to repoint and no slot to name.
@preconcurrency
@MainActor
public enum AppearanceApplier {
    /// Registered by the app target at launch: returns the app's terminal-cell palette — the terminal
    /// config's `background`/`foreground` (6-hex, no `#`) plus the 16-entry ANSI `palette` and
    /// `selection-background`. ``PreferencesStore`` consults this when rebuilding the terminal config so
    /// the terminal CELLS adopt the same flat palette as the chrome (a flat, gradient-free design).
    /// `nil` (headless / pre-launch) ⇒ the terminal keeps the ``TerminalPreferences`` colours, unchanged.
    public static var resolveTerminalColors: (() -> ResolvedTerminalTheme?)?
}

/// The active theme's TERMINAL-cell colours, resolved by the GUI layer for ``PreferencesStore`` to thread into
/// ``TerminalConfigBuilder``. `background`/`foreground` are 6-hex (no `#`); the optional `palette`
/// (exactly 16 entries when present) and `selectionBackground` ride the builder overrides — `nil` for
/// either ⇒ the builder emits no `palette`/`selection-background` line.
///
/// PURE client chrome: it carries colour strings only, never reaches the wire / `EnvConfig` / sidecar.
public struct ResolvedTerminalTheme: Sendable, Equatable {
    /// The terminal config's `background` (6-hex, no `#`).
    public var background: String
    /// The terminal config's `foreground` (6-hex, no `#`).
    public var foreground: String
    /// The 16-entry ANSI palette (6-hex each); `nil` ⇒ no `palette` lines emitted.
    public var palette: [String]?
    /// The `selection-background` colour (bare 6-hex RGB); `nil` ⇒ no `selection-background` line.
    /// Builder always pairs with `selection-foreground = cell-foreground` (keep original glyph colours).
    public var selectionBackground: String?
    /// The SAME four colours as the packed words the renderer's doors take.
    ///
    /// ⚠️ **Not a second source and not a duplicate to keep in sync** — the theme publishes 24-bit RGB
    /// literals and the strings above are `hex6` of these very numbers, so this is the form that was
    /// there first. Both halves are carried because their two consumers speak different grammars: the
    /// config string (which nothing shipping parses any more — see ``TerminalConfigBroadcaster``) and
    /// `slopdesk_term_surface_set_theme`, which takes `0x00RRGGBB` words. The hex half dies with the
    /// string; the words are what the cells are actually painted from.
    public var words: Words

    /// The packed `0x00RRGGBB` form of the four colours, as the FFI doors take them.
    public struct Words: Sendable, Equatable {
        /// The cell background — also the surface's clear colour.
        public var background: UInt32
        /// The cell foreground.
        public var foreground: UInt32
        /// The ANSI colours, from index `0`. A PREFIX: the theme states sixteen and says nothing
        /// about the 6×6×6 cube or the greyscale ramp, which stay at the engine's own.
        public var palette: [UInt32]
        /// The selection fill.
        ///
        /// Required, where the hex ``ResolvedTerminalTheme/selectionBackground`` is optional, and the
        /// difference is real rather than an oversight: the config string can simply omit the line,
        /// whereas the door takes three colours and a caller with none would have to INVENT one. A
        /// theme that states a background and a foreground has stated enough to derive this; one that
        /// cannot state it is not a theme this seam can carry.
        public var selection: UInt32

        public init(background: UInt32, foreground: UInt32, palette: [UInt32], selection: UInt32) {
            self.background = background
            self.foreground = foreground
            self.palette = palette
            self.selection = selection
        }
    }

    public init(
        background: String,
        foreground: String,
        palette: [String]? = nil,
        selectionBackground: String? = nil,
        words: Words,
    ) {
        self.background = background
        self.foreground = foreground
        self.palette = palette
        self.selectionBackground = selectionBackground
        self.words = words
    }
}
