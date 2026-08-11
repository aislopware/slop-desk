// SlateGlassStatusInkTests — pins the ON-GLASS status pair to the profile's OWN ANSI red / green
// (user-reported 2026-08-09: the command ladder was drawing the SYSTEM status palette on the
// terminal, so a "clean" tick came out a saturated signal green next to Dracula Pro's mint cells).
//
// The invariant is not the hexes for their own sake: it is that anything saying "clean" or "failed"
// INSIDE the island is dealt the same two colours the cells around it are, so a future edit cannot
// quietly route the pair back through `Slate.Status` (the system palette) without this failing.

import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class SlateGlassStatusInkTests: XCTestCase {
    /// The Dracula Pro accent seven's red and green — slots 1 and 2 of the profile's ANSI set.
    private let proRed: UInt32 = 0xFF9580
    private let proGreen: UInt32 = 0x8AFF80

    /// ⚠️ THE GROUND IS ``Slate/Surface/field``, AND IT IS NOT ``Slate/Surface/ground``. The names
    /// invite exactly one mistake, it compiles, it renders, and it silently shows the OS's mid-grey
    /// aux backdrop instead of the app's authored cream — it cost the device panels a whole "third
    /// grey" round (docs/DECISIONS.md, TWO TONES) and every render in `SlateSnapshotRender` up to
    /// 2026-08-11. Pinned here so the distinction is executable rather than a comment: `ground` and
    /// `void` are the SAME system backdrop, and neither is what a column paints.
    func testTheAppsGroundIsFieldAndNotTheSystemBackdrop() {
        XCTAssertEqual(
            Slate.Surface.field, SlateTheme.app.ground,
            "the columns' ground is the profile's authored cream",
        )
        XCTAssertEqual(
            SlateTheme.app.ground, Color(slateHex: 0xFFFBEB),
            "ONE ISLAND law 4 — Alucard cream, in the app's one appearance",
        )
        XCTAssertNotEqual(
            Slate.Surface.field, Slate.Surface.ground,
            "`ground` is the OS aux-window backdrop; painting a column with it is the bug",
        )
        XCTAssertEqual(
            Slate.Surface.ground, Slate.Surface.void,
            "…and it is the SAME colour as `void`, which is why the name carries no information",
        )
    }

    func testGlassStatusInksAreTheProfilesOwnAnsiRedAndGreen() {
        XCTAssertEqual(Slate.Terminal.ok, Color(slateHex: proGreen))
        XCTAssertEqual(Slate.Terminal.err, Color(slateHex: proRed))
    }

    /// …and they are the very entries the terminal's cells are configured with, not a parallel pair
    /// that merely happens to match today.
    func testTheInksMatchTheAnsiPaletteSentToLibghostty() throws {
        let palette = SlateTheme.app.ansiPalette
        XCTAssertEqual(palette.count, 16)
        let red = try XCTUnwrap(UInt32(palette[1], radix: 16))
        let green = try XCTUnwrap(UInt32(palette[2], radix: 16))
        XCTAssertEqual(Slate.Terminal.err, Color(slateHex: red))
        XCTAssertEqual(Slate.Terminal.ok, Color(slateHex: green))
    }

    /// The status pair must NOT be the system one — the regression this file exists for.
    func testGlassStatusInksAreNotTheSystemStatusPalette() {
        XCTAssertNotEqual(Slate.Terminal.ok, Slate.Status.ok)
        XCTAssertNotEqual(Slate.Terminal.err, Slate.Status.err)
    }
}
