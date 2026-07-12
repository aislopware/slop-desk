// ThemeCatalog — the single ClientUI-side theme directory: the shipped built-in `SlateTheme`s
// (keyed by their stable id).
//
// WHY a catalog distinct from `ThemeStore`: `ThemeStore` owns the ACTIVE theme + the cross-`NSHostingController`
// repaint seam; the catalog owns the AVAILABLE themes (the Theme picker lists from `builtinThemes`).
//
// GOLDEN-SAFE: themes are pure client chrome — nothing here reaches `EnvConfig` / the sidecar / the wire
// (the `AppearancePreferences` invariant).

#if canImport(SwiftUI)
import Foundation

/// The available-themes directory: the shipped built-in `SlateTheme`s and the id → theme lookup ClientUI uses.
@MainActor
enum ThemeCatalog {
    /// Every shipped built-in theme, in the Theme-picker order. Pure list (the picker reads it for labels /
    /// preview; resolution goes through ``builtin(id:)`` / ``ThemeStore/builtin(id:)``).
    static let builtinThemes: [SlateTheme] = [
        .monokaiProClassic,
        .monokaiProClassicLight,
        .monokaiProOctagon,
        .monokaiProMachine,
        .monokaiProRistretto,
        .monokaiProSpectrum,
        .paper,
        .dark,
    ]

    /// The shipped `SlateTheme` for a stable built-in id, or `nil` for an unknown id. Delegates to
    /// ``ThemeStore/builtin(id:)`` so there is ONE built-in id→theme table.
    static func builtin(id: String) -> SlateTheme? { ThemeStore.builtin(id: id) }
}
#endif
