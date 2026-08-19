// SecureInputPillColorTests — pins the two VIVID pane chips to their FIXED tokens, so neither can
// collapse into the app accent.
//
// The chip's fill is a KIND now (``PaneStatusPillFill``, `SlopDeskClientCore`) rather than a `Color`, and
// this suite tests the seam between the two halves of that: that the VALUE names the fixed ink, and that
// THIS renderer's ink ladder resolves that name to the fixed token. The view fills with
// `PaneStatusPillView.fillColor(_:)` and this test reads the same function, the `ToastStackView.tint(for:)`
// pattern, so the rendered colour cannot drift from the asserted contract.
//
// Revert-to-confirm-fail: re-routing either fill to a theme-derived token (`Slate.Status.info`) makes it
// equal the app accent (`info == accent` on every shipped theme) → the `assertNotEqual(… accent)` legs
// fail. Headless / pure-token — no SCStream/VT/Metal touched.

#if canImport(SwiftUI) && canImport(AppKit)
import SlopDeskClientCore
import SlopDeskSlate
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class SecureInputPillColorTests: XCTestCase {
    /// The secure-input chip names the SECURITY ink, and this renderer resolves that to the fixed
    /// royal-blue token (#2D6FE8) — not the palette-derived info colour, and NOT the app accent. That
    /// collapse is the exact failure the fixed token exists for: `secure-input.png` is the green-accent
    /// Paper theme and the chip is still the same blue.
    func testSecureInputPillIsFixedBlueNotAccent() {
        XCTAssertEqual(
            PaneStatusPill.secureInput.fill, .fixed(.security),
            "the secure-input chip is filled by NAME, so an AppKit half reads the same decision",
        )
        XCTAssertEqual(
            PaneStatusPillView.fillColor(.security), Slate.Status.secureInput,
            "the secure-input chip fills with the fixed security token, not a re-derived colour",
        )
        XCTAssertEqual(
            Slate.Status.secureInput, Color(slateHex: 0x2D6FE8),
            "the fixed security token is pinned to the spec royal-blue #2D6FE8",
        )
        XCTAssertNotEqual(
            PaneStatusPillView.fillColor(.security), Slate.State.accent,
            "the security chip must NOT read as the app accent (the purple that info collapses to)",
        )
        XCTAssertNotEqual(
            PaneStatusPillView.fillColor(.security), Slate.Status.info,
            "the security chip is INDEPENDENT of the palette — distinct from the derived info colour",
        )
    }

    /// The sync-input chip is the same contract on the other fixed tone. It got no `fillColor` hatch of
    /// its own before the three chips became one value, which is why it had no test either — a mode this
    /// dangerous blending into the chrome is the failure, and it was untested.
    func testSyncInputPillIsFixedAmberNotAccent() {
        XCTAssertEqual(PaneStatusPill.syncInput.fill, .fixed(.sync))
        XCTAssertEqual(PaneStatusPillView.fillColor(.sync), Slate.Status.syncInput)
        XCTAssertNotEqual(PaneStatusPillView.fillColor(.sync), Slate.State.accent)
        XCTAssertNotEqual(PaneStatusPillView.fillColor(.sync), Slate.Status.info)
    }

    /// The two vivid tones are DISTINCT from each other. They are the app's two "this mode is dangerous"
    /// signals and they mean opposite things — one says your keystrokes are protected, the other says
    /// they are going somewhere else.
    func testTheTwoFixedTonesAreNotTheSameColour() {
        XCTAssertNotEqual(PaneStatusPillView.fillColor(.security), PaneStatusPillView.fillColor(.sync))
    }

    /// The QUIET chip is not filled by a fixed tone at all — it wears the chrome plate, which is what
    /// makes it blend rather than shout.
    func testReadOnlyChipWearsTheChromePlate() {
        XCTAssertEqual(PaneStatusPill.readOnly.fill, .chrome)
    }
}
#endif
