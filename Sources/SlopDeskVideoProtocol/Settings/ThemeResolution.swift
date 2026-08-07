import Foundation

/// The PURE dual-slot follow-OS resolver. Picks the active built-in theme id for the
/// current OS appearance from an ``AppearancePreferences`` — headlessly testable (no `NSApp`, no SwiftUI).
/// The caller (``ThemeStore`` on macOS) supplies `osIsDark` from the live OS appearance and re-runs this on
/// every OS-appearance change, so the theme switches LIVE with the system colour scheme.
///
/// MODEL (mirrors ``AppearancePreferences``): `theme` is the LIGHT / single / primary slot; `themeDark` the
/// DARK slot. When `useSeparateDarkTheme` is OFF (or `nil`) a CONCRETE primary choice applies for EVERY OS
/// appearance (one fixed theme, no follow-OS); an UNSET primary slot (fresh install) and the legacy `.system`
/// choice both still FOLLOW the OS by construction (light/dark default per `osIsDark`), matching the picker's
/// "System" presentation. When it is ON, the OS appearance selects the slot: light → light slot, dark → dark
/// slot.
///
/// GOLDEN-SAFE: this resolver is pure client-chrome routing — it never touches the wire / `EnvConfig` /
/// sidecar (it just selects which built-in `SlateTheme` the chrome + terminal cells adopt).
public enum ThemeResolution {
    /// The compile-time default built-in id for the OS-DARK appearance (Foundry Ember).
    /// MIRRORS `SlateTheme.foundryEmber.id`.
    public static let defaultDarkID = "foundry-ember"
    /// The OS-light default — Ember LIGHT (user-directed 2026-08-07, polish round: the theme choice
    /// now drives the WHOLE app's appearance, chrome included, so a follow-OS user gets an all-light
    /// app under OS light and an all-dark one under OS dark — never the split-tone half-and-half).
    /// MIRRORS `SlateTheme.foundryEmberLight.id`.
    public static let defaultLightID = "foundry-ember-light"

    /// Resolve the active built-in theme id for `appearance` under the current OS appearance.
    ///
    /// `osIsDark` ⇒ the live system colour scheme (the caller probes `NSApp.effectiveAppearance` on macOS; a
    /// test injects a stub). Returns a stable built-in `SlateTheme` id — the `ThemeStore` / catalog resolves
    /// it to a concrete theme (an unknown id gracefully falls back to the default there); this stays a pure,
    /// total selector.
    public static func activeBuiltinID(appearance: AppearancePreferences, osIsDark: Bool) -> String {
        if appearance.useSeparateDarkTheme ?? false, osIsDark {
            return builtinID(for: appearance.themeDark, osIsDark: true)
        }
        return builtinID(for: appearance.theme, osIsDark: osIsDark)
    }

    /// The built-in ``SlateTheme`` id for a (possibly `nil` / `.system`) ``ThemeChoice`` under `osIsDark`:
    ///   - `nil` (unset slot — the FRESH-INSTALL default) ⇒ the OS-appearance default (dark →
    ///     ``defaultDarkID``, light → ``defaultLightID``) — the whole-app Ember pair, so a fresh
    ///     install follows the OS with an all-dark or all-light app;
    ///   - `.system` ⇒ likewise the OS-appearance default;
    ///   - any concrete choice ⇒ its fixed `SlateTheme.id` (via ``ThemeChoice/builtinID``).
    public static func builtinID(for choice: ThemeChoice?, osIsDark: Bool) -> String {
        guard let choice else { return osIsDark ? defaultDarkID : defaultLightID }
        if let id = choice.builtinID { return id }
        return osIsDark ? defaultDarkID : defaultLightID
    }
}
