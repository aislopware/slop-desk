import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// E15 WI-2 — the pure ``FontScopeResolver`` that computes the "Computed" Font-Family scope value from the
/// Global / per-theme / default layers. Pins the otty precedence (Global "takes priority everywhere" >
/// active-slot per-theme > bundled default), headlessly. Each case checks the resolved family against the
/// INDEPENDENTLY-known precedence rule (not the resolver's own derivation), so every case FAILS on a
/// resolver with the wrong precedence.
final class FontScopeResolverTests: XCTestCase {
    private let fallback = "SF Mono"

    /// A non-empty Global override WINS everywhere, even when the active slot has its own per-theme font.
    func testGlobalOverrideWinsOverPerThemeAndDefault() {
        let resolved = FontScopeResolver.resolvedFamily(
            global: "JetBrains Mono",
            themeFonts: ["monokai-classic": "IBM Plex Mono"],
            slug: "monokai-classic",
            fallback: fallback,
        )
        XCTAssertEqual(resolved, "JetBrains Mono", "Global takes priority everywhere")
    }

    /// With NO Global override, the active slot's per-theme font applies.
    func testPerThemeAppliesWhenGlobalUnset() {
        let resolved = FontScopeResolver.resolvedFamily(
            global: nil,
            themeFonts: ["paper": "IBM Plex Mono", "dark": "Menlo"],
            slug: "dark",
            fallback: fallback,
        )
        XCTAssertEqual(resolved, "Menlo", "the active slot's per-theme font wins when Global is unset")
    }

    /// With neither Global nor a per-theme entry for the active slug, the bundled default is used.
    func testFallbackWhenNeitherScopeProvidesAValue() {
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(global: nil, themeFonts: nil, slug: "paper", fallback: fallback),
            fallback,
        )
        // A themeFonts dict that lacks the ACTIVE slug also falls through to the default.
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: nil, themeFonts: ["other": "Menlo"], slug: "paper", fallback: fallback,
            ),
            fallback, "a per-theme entry for a DIFFERENT slug does not apply",
        )
    }

    /// Empty / whitespace values count as "unset" at every level — they never win over a lower layer.
    func testEmptyAndWhitespaceValuesAreTreatedAsUnset() {
        // An empty Global falls through to the per-theme font.
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: "   ", themeFonts: ["dark": "Menlo"], slug: "dark", fallback: fallback,
            ),
            "Menlo", "a whitespace-only Global is unset → per-theme applies",
        )
        // An empty per-theme entry falls through to the default.
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: nil, themeFonts: ["dark": ""], slug: "dark", fallback: fallback,
            ),
            fallback, "an empty per-theme value is unset → default applies",
        )
    }

    /// A nil active slug skips the per-theme lookup entirely (Global > default only).
    func testNilSlugSkipsPerThemeLookup() {
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: nil, themeFonts: ["dark": "Menlo"], slug: nil, fallback: fallback,
            ),
            fallback, "no active slug ⇒ no per-theme override",
        )
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: "Fira Code", themeFonts: ["dark": "Menlo"], slug: nil, fallback: fallback,
            ),
            "Fira Code", "Global still wins with a nil slug",
        )
    }

    /// The resolved value is trimmed (a Global "  Fira Code  " resolves to the clean family name).
    func testResolvedValueIsTrimmed() {
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(global: "  Fira Code  ", themeFonts: nil, slug: nil, fallback: fallback),
            "Fira Code",
        )
    }

    // MARK: - Per-slot slug resolution (WI-8 scope tabs)

    /// The Light Theme tab keys `themeFonts` by a non-empty custom light slug, else the built-in id the light
    /// slot's `theme` resolves to under OS-light (`.system` → the OS-light default).
    func testLightSlotSlugPrefersCustomElseBuiltinLightID() {
        XCTAssertEqual(
            FontScopeResolver.lightSlotSlug(AppearancePreferences(customLightSlug: "my-light")),
            "my-light", "a non-empty custom light slug wins",
        )
        XCTAssertEqual(
            FontScopeResolver.lightSlotSlug(AppearancePreferences(theme: .system)),
            "monokai-classic-light", "the light slot resolves .system to the OS-light default",
        )
        XCTAssertEqual(
            FontScopeResolver.lightSlotSlug(AppearancePreferences(theme: .paper)),
            "paper", "a concrete light choice maps to its fixed id",
        )
        XCTAssertEqual(
            FontScopeResolver.lightSlotSlug(AppearancePreferences()),
            "monokai-classic-light", "an unset light slot follows the OS ⇒ the OS-light default",
        )
        // An empty (not nil) custom slug is treated as unset → the built-in id.
        XCTAssertEqual(
            FontScopeResolver.lightSlotSlug(AppearancePreferences(theme: .paper, customLightSlug: "  ")),
            "paper", "a whitespace-only custom slug is unset",
        )
    }

    /// The Dark Theme tab always targets the DARK slot's own theme — independent of the separate-dark toggle.
    func testDarkSlotSlugIsIndependentOfSeparateDarkToggle() {
        let off = AppearancePreferences(themeDark: .dark, useSeparateDarkTheme: false)
        XCTAssertEqual(FontScopeResolver.darkSlotSlug(off), "dark", "off ⇒ still the dark slot's theme")
        let on = AppearancePreferences(themeDark: .dark, useSeparateDarkTheme: true)
        XCTAssertEqual(FontScopeResolver.darkSlotSlug(on), "dark", "on ⇒ the dark slot's theme")
        XCTAssertEqual(
            FontScopeResolver.darkSlotSlug(AppearancePreferences(customDarkSlug: "my-dark")),
            "my-dark", "a non-empty custom dark slug wins",
        )
        XCTAssertEqual(
            FontScopeResolver.darkSlotSlug(AppearancePreferences()),
            "monokai-classic", "an unset dark slot ⇒ the compile-time default",
        )
    }

    /// The Computed tab follows the OS appearance ONLY when separate-dark is on; otherwise the single primary
    /// slot is active for every OS appearance.
    func testActiveSlotSlugFollowsOSOnlyWhenSeparateDarkOn() {
        let single = AppearancePreferences(theme: .paper, themeDark: .dark)
        XCTAssertEqual(FontScopeResolver.activeSlotSlug(single, osIsDark: true), "paper")
        XCTAssertEqual(FontScopeResolver.activeSlotSlug(single, osIsDark: false), "paper")
        let dual = AppearancePreferences(theme: .paper, themeDark: .dark, useSeparateDarkTheme: true)
        XCTAssertEqual(FontScopeResolver.activeSlotSlug(dual, osIsDark: false), "paper", "OS-light ⇒ light slot")
        XCTAssertEqual(FontScopeResolver.activeSlotSlug(dual, osIsDark: true), "dark", "OS-dark ⇒ dark slot")
    }

    /// Computed end-to-end: with Global unset, the ACTIVE slot's per-theme font is the effective family, and
    /// the active slot follows the OS only under separate-dark (light slot's font in light mode, dark in dark).
    func testComputedFamilyUsesActiveSlotPerThemeWhenGlobalUnset() {
        let dual = AppearancePreferences(
            theme: .paper, themeDark: .dark, useSeparateDarkTheme: true,
            themeFonts: ["paper": "IBM Plex Mono", "dark": "JetBrains Mono"],
        )
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: nil, themeFonts: dual.themeFonts,
                slug: FontScopeResolver.activeSlotSlug(dual, osIsDark: false), fallback: fallback,
            ),
            "IBM Plex Mono", "OS-light ⇒ the light slot's per-theme font",
        )
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: nil, themeFonts: dual.themeFonts,
                slug: FontScopeResolver.activeSlotSlug(dual, osIsDark: true), fallback: fallback,
            ),
            "JetBrains Mono", "OS-dark ⇒ the dark slot's per-theme font",
        )
        // And a non-empty Global still wins everywhere (otty's "takes priority everywhere").
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: "Menlo", themeFonts: dual.themeFonts,
                slug: FontScopeResolver.activeSlotSlug(dual, osIsDark: true), fallback: fallback,
            ),
            "Menlo", "Global overrides the active slot's per-theme font",
        )
    }
}
