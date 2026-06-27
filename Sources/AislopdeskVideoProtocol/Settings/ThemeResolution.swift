import Foundation

/// The PURE dual-slot follow-OS resolver (E15 WI-3 / ES-E15-1). Picks the active ``ThemeRef`` for the current
/// OS appearance from an ``AppearancePreferences`` — headlessly testable (no `NSApp`, no SwiftUI). The caller
/// (``ThemeStore`` on macOS) supplies `osIsDark` from the live OS appearance and re-runs this on every
/// OS-appearance change, so the theme switches LIVE with the system colour scheme.
///
/// MODEL (mirrors ``AppearancePreferences``): `theme`/`customLightSlug` is the LIGHT / single / primary slot;
/// `themeDark`/`customDarkSlug` the DARK slot. When `useSeparateDarkTheme` is OFF (or `nil`) a CONCRETE primary
/// choice applies for EVERY OS appearance (one fixed theme, no follow-OS); an UNSET primary slot (fresh
/// install) and the legacy `.system` choice both still FOLLOW the OS by construction (light/dark default per
/// `osIsDark`), matching the picker's "System" presentation. When it is ON, the OS appearance selects the
/// slot: light → light slot, dark → dark slot. A non-empty per-slot `custom…Slug` overrides that slot's
/// built-in ``ThemeChoice`` (the slot then points at a scanned custom theme).
///
/// GOLDEN-SAFE: this resolver is pure client-chrome routing — it never touches the wire / `EnvConfig` /
/// sidecar (it just selects which `OttyTheme` / `ThemeDocument` the chrome + terminal cells adopt).
public enum ThemeResolution {
    /// The compile-time default DARK built-in id (Monokai Pro Classic) — the OS-dark fallback for an unset
    /// slot OR the `.system` choice (both follow the OS). MIRRORS `OttyTheme.monokaiProClassic.id`.
    public static let defaultDarkID = "monokai-classic"
    /// The compile-time default LIGHT built-in id (Monokai Pro Classic Light) — the OS-light fallback for an
    /// unset slot OR the `.system` choice. MIRRORS `OttyTheme.monokaiProClassicLight.id`.
    public static let defaultLightID = "monokai-classic-light"

    /// Resolve the active theme-slot reference for `appearance` under the current OS appearance.
    ///
    /// `osIsDark` ⇒ the live system colour scheme (the caller probes `NSApp.effectiveAppearance` on macOS; a
    /// test injects a stub). Returns a ``ThemeRef`` — `.builtin(id)` for a shipped theme, `.custom(slug)` for
    /// a scanned `.ottytheme`. The custom payload is NOT validated here (the ``ThemeStore`` / catalog resolves
    /// the slug → document and gracefully falls back when it's missing) — this stays a pure, total selector.
    public static func activeRef(appearance: AppearancePreferences, osIsDark: Bool) -> ThemeRef {
        if appearance.useSeparateDarkTheme ?? false, osIsDark {
            return slotRef(custom: appearance.customDarkSlug, choice: appearance.themeDark, osIsDark: true)
        }
        return slotRef(custom: appearance.customLightSlug, choice: appearance.theme, osIsDark: osIsDark)
    }

    /// One slot's reference: a NON-EMPTY `custom` slug → `.custom`, else the slot's built-in id.
    private static func slotRef(custom slug: String?, choice: ThemeChoice?, osIsDark: Bool) -> ThemeRef {
        if let slug, !slug.isEmpty { return .custom(slug: slug) }
        return .builtin(builtinID(for: choice, osIsDark: osIsDark))
    }

    /// The built-in ``OttyTheme`` id for a (possibly `nil` / `.system`) ``ThemeChoice`` under `osIsDark`:
    ///   - `nil` (unset slot — the FRESH-INSTALL default) ⇒ FOLLOWS the OS (dark → ``defaultDarkID``, light →
    ///     ``defaultLightID``), matching the Theme picker, which presents an unset light slot as "System"; a
    ///     fresh install therefore renders the light default in light mode and the dark default in dark mode,
    ///     rather than a fixed dark theme regardless of OS appearance (ES-E15);
    ///   - `.system` ⇒ likewise FOLLOWS the OS (dark → ``defaultDarkID``, light → ``defaultLightID``);
    ///   - any concrete choice ⇒ its fixed `OttyTheme.id` (via ``ThemeChoice/builtinID``).
    public static func builtinID(for choice: ThemeChoice?, osIsDark: Bool) -> String {
        guard let choice else { return osIsDark ? defaultDarkID : defaultLightID }
        if let id = choice.builtinID { return id }
        return osIsDark ? defaultDarkID : defaultLightID
    }
}
