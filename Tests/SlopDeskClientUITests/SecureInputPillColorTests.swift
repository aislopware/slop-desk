// SecureInputPillColorTests — pins the secure-input pill fill to the FIXED security-blue
// token, so it can never collapse into the app accent.
//
// The view and this test read the SAME source (`SecureInputPill.fillColor` → `Slate.Status.secureInput`),
// the `ToastStackView.tint(for:)` pattern, so the rendered colour can't drift from the asserted contract.
//
// Revert-to-confirm-fail: re-routing the fill back to the theme-derived `Slate.Status.info`
// makes `fillColor` equal the app accent (`info == accent`) → `testSecureInputPillIsFixedBlueNotAccent`
// fails on its `assertNotEqual(... accent)` leg. Headless / pure-token — no SCStream/VT/Metal touched.

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class SecureInputPillColorTests: XCTestCase {
    /// The pill fill is the FIXED security-blue token (#2D6FE8), not the palette-derived info colour — and
    /// it does NOT equal the app accent (where `info == accent`, the exact collapse that made a
    /// palette-derived security badge indistinguishable from the accent).
    func testSecureInputPillIsFixedBlueNotAccent() {
        XCTAssertEqual(
            SecureInputPill.fillColor, Slate.Status.secureInput,
            "the secure-input pill fills with the fixed security token, not a re-derived colour",
        )
        XCTAssertEqual(
            Slate.Status.secureInput, Color(slateHex: 0x2D6FE8),
            "the fixed security token is pinned to the spec royal-blue #2D6FE8",
        )
        XCTAssertNotEqual(
            SecureInputPill.fillColor, Slate.State.accent,
            "the security pill must NOT read as the app accent (the purple that info collapses to)",
        )
        XCTAssertNotEqual(
            SecureInputPill.fillColor, Slate.Status.info,
            "the security pill is INDEPENDENT of the palette — distinct from the derived info colour",
        )
    }
}
#endif
