// PaneChromeArtTests — the pane chrome's artwork, pinned where BOTH renderers read it (docs/56 stage
// F, batch P6).
//
// Three things landed on the floor in that batch and each is pinned here for a different reason.
//
// THE GRAB PILL'S CLAMP is the only one with arithmetic in it, and the arithmetic is the point: the
// canvas handle asks it per leaf and the satellite strip takes its ceiling outright, so the two pills
// a user compares while dragging a detached pane home are one drawing only as long as the bounds
// agree. The NaN row is not a curiosity — it is what `CLAUDE.md`'s "`Double.minimum`/`.maximum`,
// never a `<`/`>` ternary" rule BUYS: a degenerate size falls back to the floor instead of
// propagating a NaN into a frame, and the ternary spelling this file forbids would do the opposite.
//
// THE TWO MINTED RUNGS are pinned by their LADDER POSITION rather than by their value alone. A rung
// asserted only against its own number is a test that agrees with whatever the constant says; what
// can actually go wrong is a rung drifting into the neighbour it was minted to be distinct from.
//
// THE STATUS PILL'S GLYPH TABLE is pinned as a total, injective map. Totality is the compiler's
// already; what it cannot see is two pills answering with the SAME mark, which is how a pane ends up
// reporting one mode with another's symbol after a fourth case is added below.

import SFSafeSymbols
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskSlate

final class PaneChromeArtTests: XCTestCase {
    // MARK: - The grab pill's strip

    /// A leaf too narrow for the share keeps a GRABBABLE strip rather than a proportional one — the
    /// pill is a pointer target before it is a decoration.
    func testNarrowLeafTakesTheFloorExactly() {
        for width in [CGFloat.zero, 1, 40, 100] {
            XCTAssertEqual(
                Slate.GrabPill.stripWidth(forLeafWidth: width), Slate.GrabPill.stripWidthMin,
                "a \(width)pt leaf must still offer a strip a pointer can find",
            )
        }
    }

    /// A negative size is not a real leaf, and the answer is the floor rather than a negative frame.
    func testDegenerateWidthTakesTheFloor() {
        XCTAssertEqual(
            Slate.GrabPill.stripWidth(forLeafWidth: -400), Slate.GrabPill.stripWidthMin,
            "a negative leaf width must never resolve to a negative strip",
        )
    }

    /// THE ROW THE `Double.minimum`/`.maximum` SPELLING EXISTS FOR. A `<`/`>` ternary propagates a
    /// NaN straight into `frame(width:)`; the ladder's spelling folds it to the floor, which is the
    /// same answer a zero-width leaf gets and the only one a drawing can act on.
    func testNaNWidthFoldsToTheFloorRatherThanPropagating() {
        let width = Slate.GrabPill.stripWidth(forLeafWidth: CGFloat.nan)
        XCTAssertFalse(width.isNaN, "a NaN leaf width must not reach a frame")
        XCTAssertEqual(width, Slate.GrabPill.stripWidthMin)
    }

    /// Between the bounds the strip is the leaf's share, and nothing else.
    func testMidLeafTakesTheShare() {
        XCTAssertEqual(
            Double(Slate.GrabPill.stripWidth(forLeafWidth: 300)),
            300 * Slate.GrabPill.stripWidthShare, accuracy: 1e-9,
        )
        XCTAssertGreaterThan(Slate.GrabPill.stripWidth(forLeafWidth: 300), Slate.GrabPill.stripWidthMin)
        XCTAssertLessThan(Slate.GrabPill.stripWidth(forLeafWidth: 300), Slate.GrabPill.stripWidthMax)
    }

    /// A wide leaf stops at the ceiling — a strip that kept growing would eventually reach the
    /// dividers either side of the pane, which is the one place it must never be.
    func testWideLeafTakesTheCeilingExactly() {
        for width in [CGFloat(400), 1000, 4000] {
            XCTAssertEqual(Slate.GrabPill.stripWidth(forLeafWidth: width), Slate.GrabPill.stripWidthMax)
        }
    }

    /// THE SATELLITE'S OWN WIDTH IS THAT CEILING. The satellite's strip names `stripWidthMax` directly
    /// instead of asking the clamp, and this is the assertion that keeps the shortcut honest: the two
    /// spellings must resolve to one number, because the drag that starts on one pill ends on the
    /// other and the user sees both.
    func testTheSatelliteStripIsTheClampsCeiling() {
        XCTAssertEqual(
            Slate.GrabPill.stripWidth(forLeafWidth: .greatestFiniteMagnitude),
            Slate.GrabPill.stripWidthMax,
            "the satellite strip's fixed width and the canvas clamp's top are one number",
        )
    }

    /// Widening a leaf never narrows its strip.
    func testStripWidthNeverShrinksAsTheLeafGrows() {
        var previous = CGFloat.zero
        for width in stride(from: CGFloat.zero, through: 1200, by: 17) {
            let strip = Slate.GrabPill.stripWidth(forLeafWidth: width)
            XCTAssertGreaterThanOrEqual(strip, previous, "the strip narrowed as the leaf at \(width) grew")
            previous = strip
        }
    }

    // MARK: - The grab pill's silhouette

    /// The contrast plate is the bar's GROUND, so it has to be bigger on both axes — a plate the bar
    /// overhangs reads as a second pill behind the first rather than as the thing making it legible.
    func testThePlateContainsTheBarOnBothAxes() {
        XCTAssertGreaterThan(Slate.GrabPill.plateWidth, Slate.GrabPill.barWidth)
        XCTAssertGreaterThan(Slate.GrabPill.plateHeight, Slate.GrabPill.barHeight)
    }

    /// And the strip contains the plate: the hit area is never smaller than the ink inside it, or the
    /// pill would be visible in places a click does not reach.
    func testTheStripContainsThePlate() {
        XCTAssertGreaterThanOrEqual(Slate.GrabPill.stripWidthMin, Slate.GrabPill.plateWidth)
        XCTAssertGreaterThanOrEqual(Slate.GrabPill.stripHeight, Slate.GrabPill.plateHeight)
    }

    /// Hover GROWS the pill. The direction is the whole cue — the affordance is announcing itself,
    /// and a scale at or under 1 would make the reveal say nothing.
    func testHoverGrowsThePill() {
        XCTAssertGreaterThan(Slate.GrabPill.hoverScale, 1)
    }

    // MARK: - The two rungs minted with it

    /// A glyph plate is a target INSIDE a chip, so it has to be smaller than the control plate a
    /// chip is measured by — and bigger than the state dot, which is punctuation rather than a
    /// target. Those two neighbours are the rung's whole justification.
    func testGlyphPlateSitsBetweenTheDotAndTheControlPlate() {
        XCTAssertEqual(Slate.Metric.glyphPlate, 16)
        XCTAssertLessThan(Slate.Metric.glyphPlate, Slate.Metric.plate)
        XCTAssertGreaterThan(Slate.Metric.glyphPlate, Slate.Metric.dot)
    }

    /// The accent ring is an OUTLINE on a plate that is already an accent wash: at ``dim`` or below
    /// it stops separating a lit chip from an idle one, and at ``muted`` or above it reads as a
    /// second object drawn over the wash. The rung is that band, and the band is the assertion.
    func testAccentRingSitsBetweenDimAndMuted() {
        XCTAssertEqual(Slate.Opacity.accentRing, 0.5)
        XCTAssertGreaterThan(Slate.Opacity.accentRing, Slate.Opacity.dim)
        XCTAssertLessThan(Slate.Opacity.accentRing, Slate.Opacity.muted)
    }

    // MARK: - The status pill's mark

    /// The three pairings, said once. Each carries an argument the glyph alone cannot — see the
    /// table's own doc comment — and this is where a re-spelling of it in a renderer would show up.
    func testEveryStatusPillDrawsItsOwnMark() {
        XCTAssertEqual(PaneStatusPill.readOnly.symbol, .lockFill)
        XCTAssertEqual(PaneStatusPill.secureInput.symbol, .lockShieldFill)
        XCTAssertEqual(PaneStatusPill.syncInput.symbol, .rectangle3Group)
    }

    /// INJECTIVE, which the compiler cannot check for us. A fourth pill added below that reuses a
    /// mark already spoken for is a pane reporting one mode with another's symbol, and nothing on
    /// screen says which of the two it means.
    func testNoTwoStatusPillsShareAMark() {
        let marks = Set(PaneStatusPill.allCases.map(\.symbol))
        XCTAssertEqual(
            marks.count, PaneStatusPill.allCases.count,
            "two status pills answer with the same SF Symbol",
        )
    }
}
