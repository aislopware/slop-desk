// SlateGlassStatusInkTests — pins the ON-GLASS status pair to the profile's OWN ANSI red / green
// (user-reported 2026-08-09: the command ladder was drawing the SYSTEM status palette on the
// terminal, so a "clean" tick came out a saturated signal green next to Dracula Pro's mint cells).
//
// The invariant is not the hexes for their own sake: it is that anything saying "clean" or "failed"
// INSIDE the island is dealt the same two colours the cells around it are, so a future edit cannot
// quietly route the pair back through `Slate.Native.Status` (the system palette) without this
// failing.

import XCTest
@testable import SlopDeskSlate

@MainActor
final class SlateGlassStatusInkTests: XCTestCase {
    /// The Dracula Pro accent seven's red and green — slots 1 and 2 of the profile's ANSI set.
    private let proRed: UInt32 = 0xFF9580
    private let proGreen: UInt32 = 0x8AFF80

    /// ⚠️ THE GROUND IS ``Slate/Native/Surface/field``, AND IT IS NOT ``Slate/Native/Surface/ground``.
    /// The names invite exactly one mistake, it compiles, it renders, and it silently shows the OS's
    /// mid-grey aux backdrop instead of the app's authored cream — it cost the device panels a whole
    /// "third grey" round (docs/DECISIONS.md, TWO TONES) and every render in `SlateSnapshotRender` to
    /// 2026-08-11. Pinned here so the distinction is executable rather than a comment: `ground` and
    /// `void` are the SAME system backdrop, and neither is what a column paints.
    func testTheAppsGroundIsFieldAndNotTheSystemBackdrop() {
        XCTAssertEqual(
            Slate.Native.Surface.field, SlateNativeColor(slateHex: SlateTheme.app.groundHexValue),
            "the columns' ground is the profile's authored cream",
        )
        XCTAssertEqual(
            SlateTheme.app.groundHexValue, 0xFFFBEB,
            "ONE ISLAND law 4 — Alucard cream, in the app's one appearance",
        )
        XCTAssertNotEqual(
            Slate.Native.Surface.field, Slate.Native.Surface.ground,
            "`ground` is the OS aux-window backdrop; painting a column with it is the bug",
        )
        XCTAssertEqual(
            Slate.Native.Surface.ground, Slate.Native.Surface.void,
            "…and it is the SAME colour as `void`, which is why the name carries no information",
        )
    }

    func testGlassStatusInksAreTheProfilesOwnAnsiRedAndGreen() {
        XCTAssertEqual(Slate.Native.Terminal.ok, SlateNativeColor(slateHex: proGreen))
        XCTAssertEqual(Slate.Native.Terminal.err, SlateNativeColor(slateHex: proRed))
    }

    /// …and they are the very entries the terminal's cells are painted with, not a parallel pair
    /// that merely happens to match today. The 24-bit literals themselves, which is what crosses to
    /// the renderer — the 6-hex spelling this used to read died with the terminal config text.
    func testTheInksMatchTheAnsiPaletteSentToLibghostty() {
        let palette = SlateTheme.app.ansi
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(Slate.Native.Terminal.err, SlateNativeColor(slateHex: palette[1]))
        XCTAssertEqual(Slate.Native.Terminal.ok, SlateNativeColor(slateHex: palette[2]))
    }

    /// The status pair must NOT be the system one — the regression this file exists for.
    func testGlassStatusInksAreNotTheSystemStatusPalette() {
        XCTAssertNotEqual(Slate.Native.Terminal.ok, Slate.Native.Status.ok)
        XCTAssertNotEqual(Slate.Native.Terminal.err, Slate.Native.Status.err)
    }
}
