import XCTest
@testable import SlopDeskVideoProtocol

/// The PURE dual-slot follow-OS resolver. Headless (no `NSApp`): `osIsDark` is injected,
/// so every toggle × OS-appearance combination is exercised deterministically.
final class ThemeResolutionTests: XCTestCase {
    // MARK: Single / primary slot (useSeparateDarkTheme OFF or unset)

    /// The all-`nil` default appearance (FRESH INSTALL) FOLLOWS the OS — the picker presents an unset light slot
    /// as "System", so the resolver must render the light default in light mode and the dark default in dark
    /// mode, NOT a fixed dark theme regardless of OS appearance. The old
    /// `builtinID(for: nil)` returning a fixed `defaultDarkID` fails the light-mode case below.
    func testDefaultAppearanceFollowsOSForBothAppearances() {
        let def = AppearancePreferences()
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: def, osIsDark: false), "monokai-classic-light",
            "fresh install in LIGHT mode → the light default",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: def, osIsDark: true), "monokai-classic",
            "fresh install in DARK mode → the dark default",
        )
    }

    /// A concrete single-slot choice (separate-dark OFF) applies for EVERY OS appearance — it does NOT follow
    /// the OS. Revert-to-confirm: a `"dark"`-only resolver that ignored the toggle would still pass,
    /// so the dual-slot tests below carry the real follow-OS proof.
    func testSingleSlotConcreteChoiceIgnoresOS() {
        let prefs = AppearancePreferences(theme: .paper)
        XCTAssertEqual(ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: false), "paper")
        XCTAssertEqual(ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "paper")
    }

    /// The legacy `.system` single choice STILL follows the OS by construction (dark → Classic, light → Light)
    /// even with separate-dark OFF.
    func testSystemChoiceFollowsOS() {
        let prefs = AppearancePreferences(theme: .system)
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "monokai-classic",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: false), "monokai-classic-light",
        )
    }

    // MARK: Dual slot (useSeparateDarkTheme ON)

    /// With separate-dark ON the OS appearance SELECTS the slot: light → primary `theme`, dark → `themeDark`.
    /// This is the load-bearing follow-OS proof (the single-slot tests above would pass without it).
    func testSeparateDarkSelectsSlotByOS() {
        let prefs = AppearancePreferences(theme: .paper, themeDark: .dark, useSeparateDarkTheme: true)
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: false), "paper",
            "OS light → the primary/light slot",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "dark",
            "OS dark → the dark slot",
        )
    }

    /// Separate-dark ON with an UNSET dark slot (no `themeDark`) falls back to the
    /// compile-time default Monokai Pro Classic in dark mode.
    func testSeparateDarkWithUnsetDarkSlotUsesDefault() {
        let prefs = AppearancePreferences(theme: .paper, useSeparateDarkTheme: true)
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "monokai-classic",
        )
    }

    // MARK: builtinID mapping

    func testBuiltinIDMapping() {
        // An unset slot (nil) follows the OS, exactly like `.system` (the picker shows it as "System").
        XCTAssertEqual(ThemeResolution.builtinID(for: nil, osIsDark: true), "monokai-classic")
        XCTAssertEqual(ThemeResolution.builtinID(for: nil, osIsDark: false), "monokai-classic-light")
        XCTAssertEqual(ThemeResolution.builtinID(for: .system, osIsDark: true), "monokai-classic")
        XCTAssertEqual(ThemeResolution.builtinID(for: .system, osIsDark: false), "monokai-classic-light")
        XCTAssertEqual(ThemeResolution.builtinID(for: .monokaiProSpectrum, osIsDark: true), "monokai-spectrum")
        XCTAssertEqual(ThemeResolution.builtinID(for: .paper, osIsDark: true), "paper")
        XCTAssertEqual(ThemeResolution.builtinID(for: .dark, osIsDark: false), "dark")
    }

    /// Every concrete (non-`.system`) ``ThemeChoice`` exposes a stable `builtinID`; only `.system` is `nil`
    /// (it follows the OS). Guards a future enum case being added without a mapping.
    func testEveryConcreteChoiceHasABuiltinID() {
        for choice in ThemeChoice.allCases {
            if choice == .system {
                XCTAssertNil(choice.builtinID, ".system follows the OS, so it has no fixed id")
            } else {
                XCTAssertNotNil(choice.builtinID, "\(choice) must map to a stable SlateTheme id")
            }
        }
    }
}
