// SecureInputPillColorTests — pins the E17 / ES-E17-4 secure-input pill fill to the FIXED security-blue
// token, theme-INDEPENDENT, so it can never collapse into the theme accent (the cluster-1 fidelity fix).
//
// The view and this test read the SAME source (`SecureInputPill.fillColor` → `Otty.Status.secureInput`),
// the `ToastStackView.tint(for:)` pattern, so the rendered colour can't drift from the asserted contract.
//
// Revert-to-confirm-fail: re-routing the fill back to the theme-derived `Otty.Status.info` (the old bug)
// makes `fillColor` equal the Monokai accent under the default theme → `testSecureInputPillIsFixedBlueNotAccent`
// fails on its `assertNotEqual(... accent)` leg. Headless / pure-token — no SCStream/VT/Metal touched.

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class SecureInputPillColorTests: XCTestCase {
    /// The pill fill is the FIXED security-blue token (#2D6FE8), not the theme-derived info colour — and it
    /// does NOT equal the Monokai accent under the shipped default theme (where `info == accent == cyan`, the
    /// exact collapse that made a theme-derived security badge indistinguishable from the accent).
    func testSecureInputPillIsFixedBlueNotAccent() {
        ThemeStore.shared.apply(.monokaiProClassic) // the shipped default seed: info == accent == 0x78DCE8

        XCTAssertEqual(
            SecureInputPill.fillColor, Otty.Status.secureInput,
            "the secure-input pill fills with the fixed security token, not a re-derived colour",
        )
        XCTAssertEqual(
            Otty.Status.secureInput, Color(ottyHex: 0x2D6FE8),
            "the fixed security token is pinned to the spec royal-blue #2D6FE8",
        )
        XCTAssertNotEqual(
            SecureInputPill.fillColor, Otty.State.accent,
            "the security pill must NOT read as the Monokai accent (the cyan that info collapses to)",
        )
        XCTAssertNotEqual(
            SecureInputPill.fillColor, Otty.Status.info,
            "the security pill is theme-INDEPENDENT — distinct from the theme-derived info colour under Monokai",
        )
    }

    /// Theme-INDEPENDENT: the fixed token holds its value across a theme switch (so the badge is the same
    /// royal-blue on every theme), unlike the theme-derived `Otty.Status.info`, which moves with the theme.
    func testSecureInputTokenIsThemeIndependent() {
        ThemeStore.shared.apply(.monokaiProClassic)
        let darkValue = Otty.Status.secureInput
        ThemeStore.shared.apply(.monokaiProClassicLight)
        let lightValue = Otty.Status.secureInput
        XCTAssertEqual(darkValue, lightValue, "the security token does not move with the theme")
        XCTAssertEqual(lightValue, Color(ottyHex: 0x2D6FE8), "still the fixed royal-blue on the light theme")
    }
}
#endif
