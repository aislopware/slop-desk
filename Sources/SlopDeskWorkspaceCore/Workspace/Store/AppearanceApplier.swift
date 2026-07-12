import Foundation
import SlopDeskVideoProtocol

/// The seam by which the headless ``PreferencesStore`` (in `SlopDeskWorkspaceCore`) repoints the GUI
/// runtime theme without depending on `SlopDeskClientUI` (which owns `ThemeStore` — the SwiftUI/AppKit
/// layer that `WorkspaceCore` must not import). Mirrors the `TerminalRenderingView.shared` /
/// `VideoWindowFactory.shared` injected-closure pattern: `SlopDeskClientUI` registers a closure at app
/// launch that applies the whole ``AppearancePreferences`` to its `ThemeStore.shared` + re-pins
/// `NSWindow.appearance`.
///
/// Headless / no-store (the golden + ImageRenderer paths): the hook is `nil`, so applying appearance is a
/// no-op for the theme side — the density `UserDefaults` write still happens (it is pure `WorkspaceCore`
/// state), but no SwiftUI/AppKit token repoints, keeping headless renders byte-identical to today.
@preconcurrency
@MainActor
public enum AppearanceApplier {
    /// Registered by `SlopDeskClientUI` at app launch. Receives the WHOLE selected ``AppearancePreferences``
    /// (not a bare ``ThemeChoice?``) so the GUI layer resolves the full dual-slot / custom-slug / follow-OS
    /// selection via `ThemeStore.shared.apply(appearance:)` + re-pins the window
    /// appearance. `nil` here ⇒ headless / pre-launch ⇒ the theme side is skipped.
    public static var apply: ((AppearancePreferences) -> Void)?

    /// Registered by `SlopDeskClientUI`: returns the CURRENTLY-active theme's terminal-cell palette — the
    /// libghostty `background`/`foreground` (6-hex, no `#`) plus the 16-entry ANSI `palette` and
    /// `selection-background` — read from `ThemeStore.shared.active`, which already resolves the dual-slot /
    /// `.system` selection to a concrete light/dark theme. ``PreferencesStore`` consults this when rebuilding
    /// the terminal config so the terminal CELLS adopt the same flat palette as the chrome (a flat, gradient-free design).
    /// `nil` (headless / pre-launch) ⇒ the terminal keeps the ``TerminalPreferences`` colours, unchanged.
    public static var resolveTerminalColors: (() -> ResolvedTerminalTheme?)?

    /// Registered by `SlopDeskClientUI`: returns the slug of the theme ACTIVE under the current OS appearance
    /// — `ThemeStore.shared.active.id`, which already resolves the dual-slot / `.system` selection to a concrete
    /// light/dark theme (built-in id or custom slug). ``PreferencesStore`` keys the per-theme font override
    /// (`appearance.themeFonts[slug]`) by this when rebuilding the terminal config, so the Font → Light/Dark
    /// scope font reaches the live terminal (pure ``FontScopeResolver`` precedence). `nil`
    /// (headless / pre-launch) ⇒ no per-scope lookup, the Global ``TerminalPreferences/fontFamily`` stands.
    public static var resolveActiveThemeSlug: (() -> String?)?
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
