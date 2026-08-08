import Foundation
import SlopDeskVideoProtocol

/// The seam by which the headless ``PreferencesStore`` (in `SlopDeskWorkspaceCore`) reads the GUI's
/// terminal-cell palette without depending on `SlopDeskClientUI` (the SwiftUI/AppKit layer that
/// `WorkspaceCore` must not import). Mirrors the `TerminalRenderingView.shared` /
/// `VideoWindowFactory.shared` injected-closure pattern.
///
/// Headless / no-store (the golden + ImageRenderer paths): the hook is `nil`, so the terminal keeps the
/// ``TerminalPreferences`` colours and headless renders stay byte-identical to today.
///
/// The theme-APPLY and active-slug hooks that used to sit here went with the theme picker
/// (user-directed 2026-08-08): with one appearance there is nothing to repoint and no slot to name.
@preconcurrency
@MainActor
public enum AppearanceApplier {
    /// Registered by `SlopDeskClientUI`: returns the app's terminal-cell palette — the libghostty
    /// `background`/`foreground` (6-hex, no `#`) plus the 16-entry ANSI `palette` and
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
    /// libghostty `background` (6-hex, no `#`).
    public var background: String
    /// libghostty `foreground` (6-hex, no `#`).
    public var foreground: String
    /// The 16-entry ANSI palette (6-hex each); `nil` ⇒ no `palette` lines emitted.
    public var palette: [String]?
    /// The `selection-background` colour (bare 6-hex RGB); `nil` ⇒ no `selection-background` line.
    /// Builder always pairs with `selection-foreground = cell-foreground` (keep original glyph colours).
    public var selectionBackground: String?

    public init(
        background: String,
        foreground: String,
        palette: [String]? = nil,
        selectionBackground: String? = nil,
    ) {
        self.background = background
        self.foreground = foreground
        self.palette = palette
        self.selectionBackground = selectionBackground
    }
}
