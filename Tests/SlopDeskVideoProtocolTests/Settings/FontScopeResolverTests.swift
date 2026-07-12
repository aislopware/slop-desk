import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// The pure ``FontScopeResolver`` that computes the "Computed" Font-Family scope value from the
/// Global / per-theme / default layers. Pins the precedence (an explicitly-set active-slot per-theme font >
/// Global > bundled default — `scopeFont ?? globalFont ?? bundled`; see the resolver doc for WHY scope wins
/// over Global in slopdesk), headlessly. Each case checks the resolved family against the INDEPENDENTLY-known
/// precedence rule (not the resolver's own derivation), so every case FAILS on a resolver with the wrong
/// precedence.
final class FontScopeResolverTests: XCTestCase {
    private let fallback = "SF Mono"

    /// An explicitly-set ACTIVE-slot per-theme font WINS over a non-empty Global value (so the
    /// non-empty Global DEFAULT can no longer silently shadow a per-scope font).
    func testExplicitPerScopeFontWinsOverGlobal() {
        let resolved = FontScopeResolver.resolvedFamily(
            global: "JetBrains Mono", // the non-empty Global default
            themeFonts: ["monokai-classic": "IBM Plex Mono"], // an explicit per-scope override
            slug: "monokai-classic",
            fallback: fallback,
        )
        XCTAssertEqual(resolved, "IBM Plex Mono", "an explicit per-scope font wins over the Global value")
    }

    /// Regression guard: Global sits at its non-empty bundled DEFAULT (the caller passes the same
    /// value as both `global` and `fallback`), the user sets a Dark-scope font, and the active appearance is
    /// dark. The resolved family MUST be the Dark-scope font, not the Global default. FAILS on the old
    /// "Global wins everywhere" resolver (which returned the Global default ⇒ the Dark-scope font did nothing).
    func testDarkScopeFontWinsWhileGlobalAtDefaultUnderDarkAppearance() {
        let globalDefault = "JetBrains Mono"
        let appearance = AppearancePreferences(
            theme: .paper, themeDark: .dark, useSeparateDarkTheme: true,
            themeFonts: [FontScopeResolver.darkSlotSlug(AppearancePreferences(themeDark: .dark)): "Fira Code"],
        )
        let resolved = FontScopeResolver.resolvedFamily(
            global: globalDefault,
            themeFonts: appearance.themeFonts,
            slug: FontScopeResolver.activeSlotSlug(appearance, osIsDark: true),
            fallback: globalDefault, // the live path passes `terminal.fontFamily` as both global AND fallback
        )
        XCTAssertEqual(resolved, "Fira Code", "the explicit Dark-scope font wins over the non-empty Global default")
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

    // MARK: - Per-slot slug resolution (scope tabs)

    /// The Light Theme tab keys `themeFonts` by the built-in id the light slot's `theme` resolves to under
    /// OS-light (`.system` → the OS-light default).
    func testLightSlotSlugResolvesBuiltinLightID() {
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
    }

    /// The Dark Theme tab always targets the DARK slot's own theme — independent of the separate-dark toggle.
    func testDarkSlotSlugIsIndependentOfSeparateDarkToggle() {
        let off = AppearancePreferences(themeDark: .dark, useSeparateDarkTheme: false)
        XCTAssertEqual(FontScopeResolver.darkSlotSlug(off), "dark", "off ⇒ still the dark slot's theme")
        let on = AppearancePreferences(themeDark: .dark, useSeparateDarkTheme: true)
        XCTAssertEqual(FontScopeResolver.darkSlotSlug(on), "dark", "on ⇒ the dark slot's theme")
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
        // And an explicit active-slot per-theme font wins EVEN when Global is also set — scope
        // wins over Global, so the non-empty Global default can't shadow it.
        XCTAssertEqual(
            FontScopeResolver.resolvedFamily(
                global: "Menlo", themeFonts: dual.themeFonts,
                slug: FontScopeResolver.activeSlotSlug(dual, osIsDark: true), fallback: fallback,
            ),
            "JetBrains Mono", "the active slot's per-theme font wins over a set Global",
        )
    }
}
