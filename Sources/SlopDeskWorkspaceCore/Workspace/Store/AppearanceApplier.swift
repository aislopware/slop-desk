import SlopDeskVideoProtocol // TerminalPreferences — the colours the FILE states

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
    /// Registered by the app target at launch: returns the app's terminal-cell palette — the
    /// background and foreground, the 16-entry ANSI ladder and the selection fill, all as packed
    /// `0x00RRGGBB` words. ``PreferencesStore`` consults this when re-resolving the terminal settings so
    /// the terminal CELLS adopt the same flat palette as the chrome (a flat, gradient-free design).
    /// `nil` (headless / pre-launch) ⇒ the terminal keeps the ``TerminalPreferences`` colours, unchanged.
    public static var resolveTerminalColors: (() -> ResolvedTerminalTheme?)?
}

/// The active theme's TERMINAL-cell colours, resolved by the GUI layer for ``PreferencesStore`` to
/// hand to `slopdesk_term_surface_set_theme`.
///
/// Packed `0x00RRGGBB` words, which is the form the theme publishes and the form the door takes. A
/// 6-hex STRING half used to ride alongside — the same four numbers spelled for the terminal config
/// text — and it died with the text: nothing parses it, so nothing needed the second spelling.
///
/// PURE client chrome: it carries colours only, never reaches the wire / `EnvConfig` / sidecar.
public struct ResolvedTerminalTheme: Sendable, Equatable {
    /// The cell background — also the surface's clear colour.
    public var background: UInt32
    /// The cell foreground.
    public var foreground: UInt32
    /// The ANSI colours, from index `0`. A PREFIX: the theme states sixteen and says nothing about
    /// the 6×6×6 cube or the greyscale ramp, which stay at the engine's own.
    public var palette: [UInt32]
    /// The selection fill.
    ///
    /// Required, and not optional as the dead hex twin was: the door takes three colours and a caller
    /// with none would have to INVENT one. A theme that states a background and a foreground has
    /// stated enough to derive this; one that cannot state it is not a theme this seam can carry.
    public var selection: UInt32

    public init(background: UInt32, foreground: UInt32, palette: [UInt32], selection: UInt32) {
        self.background = background
        self.foreground = foreground
        self.palette = palette
        self.selection = selection
    }

    /// The colours the CONFIG FILE states, for the reading where no app palette was handed in —
    /// headless, pre-launch, the golden and `ImageRenderer` paths. `nil` when the file's text is not
    /// a colour, which is the same answer as "the row was left alone".
    ///
    /// The palette is EMPTY, not invented: `terminal.background` and `terminal.foreground` are the
    /// only two colours the file states, and an empty prefix leaves all sixteen ANSI slots at the
    /// engine's own — which is what a user who set two colours asked for.
    ///
    /// The selection is DERIVED, and the seam's own contract is what licenses that: a theme that
    /// states a background and a foreground has stated enough. The per-channel MIDPOINT of the two is
    /// integer arithmetic, so it is exact and reproducible, and it lands between the fill and the
    /// glyph by construction — legible against both without either being named twice.
    public init?(preferences: TerminalPreferences) {
        guard let background = preferences.backgroundWord, let foreground = preferences.foregroundWord
        else { return nil }
        self.init(
            background: background,
            foreground: foreground,
            palette: [],
            selection: Self.midpoint(background, foreground),
        )
    }

    /// The per-channel midpoint of two `0x00RRGGBB` words.
    ///
    /// ⚠️ THE PARENTHESES AROUND THE HALVING ARE LOAD-BEARING. Swift binds `<<` TIGHTER than `/`
    /// (`BitwiseShiftPrecedence` outranks `MultiplicationPrecedence`), which is the opposite of C and
    /// Rust — so `sum / 2 << shift` reads as `sum / (2 << shift)` and divides the red channel by
    /// 131 072. The result still compiles, still type-checks, and comes out near-black.
    private static func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let sum = ((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)
            return (sum / 2) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
