// PaneStatusPillRenderTests proves the AppKit pane status chip (docs/56 wave R, batch R2) keeps the
// four promises its SwiftUI half makes that a compiler cannot check.
//
// 1. THE TWO RENDERERS INK THE VIVID PILLS IDENTICALLY. `PaneStatusPillInk` is a NAME in
//    `SlopDeskClientCore` precisely because its resolution is a colour and the token floor sits ABOVE
//    the logic floor — so the table is spelled twice, once per framework, and `check-supervisor.sh`
//    can only check that both halves ANSWER every case. It cannot check that they answer the SAME.
//    This does, in resolved sRGB, which is the half of the pair the ratchet structurally cannot see.
//
// 2. THE VIVID INKS ARE NOT THE THEME ACCENT. That is the whole argument for a fixed tone: the
//    shipped themes have `info == accent`, so a security badge derived from the palette goes
//    invisible against the accent it is warning on top of. A regression that "simplified" either
//    fill into `Slate.Native.accent` would compile, run, and look fine on the default theme.
//
// 3. THE `×` IS EXACTLY WHERE `dismissHelp` SAYS. Secure input carries none, and that is a decision
//    rather than an omission — it is a SAFETY indicator the user does not dismiss with a click, and
//    a `×` there would offer to turn off something the chip does not own. The plate is also the one
//    thing on the chip that DOES anything, so the press has to reach `onDismiss`.
//
// 4. THE COPY IS READ, NOT RESTATED. The label, the VoiceOver line and the hint are the shared
//    value's; a port that retyped "Read only" would drift from the SwiftUI half one edit later.
//
// Headless: an `NSView`'s layer, its accessibility attributes and `accessibilityPerformPress()` need
// no window (the hang-safety rule forbids an `NSWindow` in a test), so nothing here mounts one.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class PaneStatusPillRenderTests: XCTestCase {
    // MARK: - The pair

    // WHERE THE CROSS-RENDERER INK CHECK WENT, and why it is not here. The obvious test — resolve the
    // AppKit `NSColor` and the SwiftUI `Color` for each ink and compare the pixels — has to name BOTH
    // UI halves in one file, and a UI half's tests may not name the other half (docs/56 §3.5 step 5;
    // the ban carries exactly two tracked exceptions and did not want a third for a five-line check).
    //
    // So it is stated in two places that each stay on their own side. `check-supervisor.sh` pins that
    // the two tables name CORRESPONDING RUNGS — `.security` to `Slate.Status.secureInput` here and to
    // `Slate.Native.Status.secureInput` there — and `SlateNativeTokenTests` pins, from inside the
    // floor, that a corresponding rung resolves to the same colour in both appearances. Neither says
    // it alone; together they say all of it, and the gap they close is one the ink RATCHET
    // structurally could not see: "both halves answer every case" is satisfied by two tables that
    // answer every case differently.

    /// A fixed tone, never the palette's — see the file header, promise 2.
    func testTheVividInksNeverCollapseIntoTheThemeAccent() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard let resolved = NSAppearance(named: appearance) else { continue }
            resolved.performAsCurrentDrawingAppearance {
                let accent = Slate.Native.accent.cgColor
                XCTAssertNotEqual(
                    MacPaneStatusPillView.fillColor(.security).cgColor, accent,
                    "the secure-input pill has become the theme accent — it is invisible on a theme "
                        + "whose info tone IS the accent, which is why the ink is a name",
                )
                XCTAssertNotEqual(
                    MacPaneStatusPillView.fillColor(.sync).cgColor, accent,
                    "the sync-input pill has become the theme accent — a mode this dangerous never "
                        + "blends with the chrome",
                )
            }
        }
    }

    // MARK: - The plates

    /// Read through the LAYER, which is what actually ships: asserting the tokens against each other
    /// would pass while every chip painted one plate.
    func testEachChipStandsOnThePlateItsFillNames() throws {
        var plates: [PaneStatusPill: CGColor] = [:]
        for pill in PaneStatusPill.allCases {
            plates[pill] = try XCTUnwrap(
                MacPaneStatusPillView(pill: pill).layer?.backgroundColor,
                "the \(pill.rawValue) chip never painted its plate",
            )
        }
        XCTAssertEqual(
            plates[.secureInput], Slate.Native.Status.secureInput.cgColor,
            "the secure-input chip is no longer standing on its own fixed tone",
        )
        XCTAssertEqual(
            plates[.syncInput], Slate.Native.Status.syncInput.cgColor,
            "the sync-input chip is no longer standing on its own fixed tone",
        )
        XCTAssertNotEqual(
            plates[.readOnly], plates[.secureInput],
            "the read-only chip has gone vivid — it is the one that BLENDS with the chrome",
        )
        XCTAssertNotEqual(
            plates[.secureInput], plates[.syncInput],
            "the two vivid chips are one colour — a safety signal and a mode warning read as the same state",
        )
    }

    /// The chrome plate is the only one delineated; a vivid fill IS its own boundary.
    func testOnlyTheChromePlateCarriesAHairline() {
        XCTAssertEqual(
            MacPaneStatusPillView(pill: .readOnly).layer?.borderWidth, Slate.Metric.hairline,
            "the read-only chip lost its hairline — it is only a shade off the chrome behind it",
        )
        for pill in [PaneStatusPill.secureInput, .syncInput] {
            XCTAssertEqual(
                MacPaneStatusPillView(pill: pill).layer?.borderWidth, 0,
                "the \(pill.rawValue) chip grew a border its vivid fill only muddies",
            )
        }
    }

    // MARK: - The ×

    func testOnlyTheDismissiblePillsCarryAClosePlate() {
        for pill in PaneStatusPill.allCases {
            let plates = closePlates(in: MacPaneStatusPillView(pill: pill))
            XCTAssertEqual(
                plates.count, pill.isDismissible ? 1 : 0,
                "the \(pill.rawValue) chip's × does not match what PaneStatusPill.dismissHelp says",
            )
            XCTAssertEqual(
                plates.first?.toolTip, pill.dismissHelp,
                "the \(pill.rawValue) chip's × explains itself in its own words instead of the shared copy",
            )
        }
    }

    /// Secure input's missing `×` is a decision (a safety indicator the user does not click away), so
    /// it is pinned as one rather than left to the count above.
    func testSecureInputCannotBeDismissedFromTheChip() {
        XCTAssertTrue(
            closePlates(in: MacPaneStatusPillView(pill: .secureInput)).isEmpty,
            "the secure-input chip grew a × — it would offer to turn off something it does not own",
        )
    }

    func testPressingTheCloseGlyphFiresTheDismiss() throws {
        var fired = 0
        let chip = MacPaneStatusPillView(pill: .readOnly, onDismiss: { fired += 1 })
        let close = try XCTUnwrap(closePlates(in: chip).first, "the read-only chip has no × to press")
        XCTAssertTrue(close.accessibilityPerformPress(), "the × refused a press")
        XCTAssertEqual(fired, 1, "the × is not wired to onDismiss — the lock would have no exit")
    }

    // MARK: - The copy

    func testEachChipAnnouncesTheSharedCopy() {
        for pill in PaneStatusPill.allCases {
            let chip = MacPaneStatusPillView(pill: pill)
            XCTAssertEqual(
                chip.accessibilityLabel(), pill.accessibilityLabel,
                "the \(pill.rawValue) chip announces a label of its own",
            )
            XCTAssertEqual(
                chip.accessibilityHelp(), pill.accessibilityHint,
                "the \(pill.rawValue) chip drops the sentence that says what the mode DOES",
            )
        }
    }

    // MARK: - Helpers

    /// Every `×` plate in a chip's subtree. Recursive because the row is an `NSStackView`, and a
    /// direct-subviews walk would answer zero for every chip the day the row gains a wrapper.
    private func closePlates(in view: NSView) -> [MacPaneStatusPillCloseView] {
        view.subviews.flatMap { child -> [MacPaneStatusPillCloseView] in
            if let plate = child as? MacPaneStatusPillCloseView { return [plate] }
            return closePlates(in: child)
        }
    }
}
#endif
