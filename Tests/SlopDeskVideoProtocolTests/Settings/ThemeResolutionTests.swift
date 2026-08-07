import XCTest
@testable import SlopDeskVideoProtocol

/// The PURE dual-slot follow-OS resolver. Headless (no `NSApp`): `osIsDark` is injected,
/// so every toggle × OS-appearance combination is exercised deterministically.
final class ThemeResolutionTests: XCTestCase {
    // MARK: Single / primary slot (useSeparateDarkTheme OFF or unset)

    /// The all-`nil` default appearance (FRESH INSTALL) FOLLOWS the OS (whole-app theme,
    /// user-directed 2026-08-07): OS light → Alucard (all-light app), OS dark → Dracula
    /// (all-dark app) — never the split-tone half-and-half.
    func testDefaultAppearanceFollowsOS() {
        let def = AppearancePreferences()
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: def, osIsDark: false), "alucard",
            "fresh install in LIGHT mode → the light Alucard default",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: def, osIsDark: true), "dracula",
            "fresh install in DARK mode → the dark Dracula default",
        )
    }

    /// A concrete single-slot choice (separate-dark OFF) applies for EVERY OS appearance — it does NOT follow
    /// the OS. Revert-to-confirm: a `"dark"`-only resolver that ignored the toggle would still pass,
    /// so the dual-slot tests below carry the real follow-OS proof.
    func testSingleSlotConcreteChoiceIgnoresOS() {
        let prefs = AppearancePreferences(theme: .alucard)
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: false), "alucard",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "alucard",
        )
    }

    /// The legacy `.system` single choice follows the OS like the unset default — the per-OS built-in
    /// pair (whole-app theme, user-directed 2026-08-07).
    func testSystemChoiceResolvesToDefault() {
        let prefs = AppearancePreferences(theme: .system)
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "dracula",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: false), "alucard",
        )
    }

    // MARK: Dual slot (useSeparateDarkTheme ON)

    /// With separate-dark ON the OS appearance SELECTS the slot: light → primary `theme`, dark → `themeDark`.
    /// This is the load-bearing follow-OS proof (the single-slot tests above would pass without it).
    func testSeparateDarkSelectsSlotByOS() {
        let prefs = AppearancePreferences(
            theme: .alucard, themeDark: .dracula, useSeparateDarkTheme: true,
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: false), "alucard",
            "OS light → the primary/light slot",
        )
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "dracula",
            "OS dark → the dark slot",
        )
    }

    /// Separate-dark ON with an UNSET dark slot (no `themeDark`) falls back to the
    /// compile-time default Dracula in dark mode.
    func testSeparateDarkWithUnsetDarkSlotUsesDefault() {
        let prefs = AppearancePreferences(theme: .alucard, useSeparateDarkTheme: true)
        XCTAssertEqual(
            ThemeResolution.activeBuiltinID(appearance: prefs, osIsDark: true), "dracula",
        )
    }

    // MARK: builtinID mapping

    func testBuiltinIDMapping() {
        // An unset slot (nil) resolves like `.system` (the picker shows it as "System") — the
        // per-OS built-in pair (whole-app theme, user-directed 2026-08-07).
        XCTAssertEqual(ThemeResolution.builtinID(for: nil, osIsDark: true), "dracula")
        XCTAssertEqual(ThemeResolution.builtinID(for: nil, osIsDark: false), "alucard")
        XCTAssertEqual(ThemeResolution.builtinID(for: .system, osIsDark: true), "dracula")
        XCTAssertEqual(ThemeResolution.builtinID(for: .system, osIsDark: false), "alucard")
        XCTAssertEqual(ThemeResolution.builtinID(for: .dracula, osIsDark: true), "dracula")
        XCTAssertEqual(ThemeResolution.builtinID(for: .alucard, osIsDark: true), "alucard")
        XCTAssertEqual(ThemeResolution.builtinID(for: .dracula, osIsDark: false), "dracula")
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
