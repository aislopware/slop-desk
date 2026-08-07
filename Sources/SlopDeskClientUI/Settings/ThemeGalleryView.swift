// ThemeGalleryView — the Appearance → Theme picker as a GALLERY of the themes themselves.
//
// The theme was chosen from a `.menu` `Picker`: nine names in a dropdown, no colour anywhere, so picking a
// theme meant selecting one blind and looking at the result. A theme is the one setting in this whole surface
// whose entire subject is how it LOOKS — a text list is the worst possible control for it.
//
// otty shows a searchable list with the name plus four palette dots (`docs/ui-shell/screenshots/theme-list.png`).
// This goes one step further and renders each theme as a miniature of its own terminal (``SettingsThemeSwatch``:
// its chrome band, its background, three code lines in its own ANSI colours, its caret), because dots tell you
// a theme has a red in it and a miniature tells you what code looks like in it.
//
// TWO SLOTS, ONE GALLERY: the light/primary slot and the dark slot (shown when "Use separated theme for dark
// mode" is on) render the SAME view with different bindings, so the two slots can never drift into offering
// different theme sets — the failure the old duplicated `themeOptions` `@ViewBuilder` invited.
//
// SYSTEM is drawn as what it does: a split card, the light default on one side and the dark default on the
// other, since `.system` FOLLOWS the OS appearance (`ThemeResolution.builtinID(for:osIsDark:)`) rather than
// pinning a palette.
//
// COLOUR EXCEPTION: everything else in Settings is painted in system semantics (`SettingsInk`), but a
// theme swatch MUST draw from the theme it previews — in system colours the gallery would be seven
// identical cards. Geometry rides `Slate.Metric` (`scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import SwiftUI

// MARK: - The gallery's option list (pure)

/// The theme cards, in gallery order: System first (the follow-the-OS choice), then the four FOUNDRY
/// seeds. Mirrors ``ThemeCatalog/builtinThemes`` order.
///
/// Pinned exhaustively against `ThemeChoice.allCases` (`SettingsOptionCatalogTests`): a new built-in theme that
/// isn't added here would be silently unreachable, and unlike a dropdown a card grid gives no hint that
/// anything is missing.
enum SettingsThemeGallery {
    static let entries: [SettingsOption<ThemeChoice>] = [
        // "Follows the OS" spelled short: HW review showed "Follows macOS" truncating to "Follows macO" in a
        // 96pt card. A caption that clips is worse than a terser one.
        SettingsOption(.system, "System", caption: "Follows OS"),
        SettingsOption(.foundryEmber, "Ember", caption: "Foundry"),
        SettingsOption(.foundryEmberLight, "Ember Light", caption: "Foundry"),
        SettingsOption(.foundryDusk, "Dusk", caption: "Foundry"),
        SettingsOption(.foundryGraphite, "Graphite", caption: "Foundry"),
    ]
}

// MARK: - ThemeGalleryView

/// The theme card grid for ONE slot. `title` names the slot ("Theme" / "Dark Theme") so the two instances are
/// distinguishable on the page.
struct ThemeGalleryView: View {
    let title: String
    let subtitle: String?
    @Binding var selection: ThemeChoice

    var body: some View {
        SettingsOptionCards(
            title,
            subtitle: subtitle,
            options: SettingsThemeGallery.entries,
            selection: $selection,
        ) { option in
            ThemeSwatchArt(choice: option.value)
        }
    }
}

// MARK: - ThemeSwatchArt (one card's art: the theme, or the OS split)

/// One theme card's art. A concrete choice renders that theme's miniature; ``ThemeChoice/system`` renders the
/// light and dark defaults side by side, because that is literally the pair it chooses between.
private struct ThemeSwatchArt: View {
    let choice: ThemeChoice

    var body: some View {
        if choice == .system, ThemeResolution.defaultLightID != ThemeResolution.defaultDarkID {
            HStack(spacing: Slate.Metric.hairline) {
                swatch(id: ThemeResolution.defaultLightID)
                swatch(id: ThemeResolution.defaultDarkID)
            }
        } else if choice == .system {
            // Both OS appearances resolve to the one split-tone default — a single honest swatch.
            swatch(id: ThemeResolution.defaultDarkID)
        } else {
            swatch(id: choice.builtinID)
        }
    }

    /// The miniature for a built-in id. An unknown / `nil` id draws the neutral placeholder rather than
    /// substituting some other theme's palette — a swatch that lies about its colours is worse than a blank.
    @ViewBuilder
    private func swatch(id: String?) -> some View {
        if let id, let theme = ThemeCatalog.builtin(id: id) {
            SettingsThemeSwatch(theme: theme)
        } else {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                .fill(SettingsInk.inset)
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall, style: .continuous)
                        .strokeBorder(SettingsInk.hairline, lineWidth: Slate.Metric.hairline),
                )
        }
    }
}
#endif
