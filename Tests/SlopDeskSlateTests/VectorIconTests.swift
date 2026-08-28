// VectorIconTests — pins the SVG path reader that carries otty's non-system artwork into the rail.
// The point of the reader is FIDELITY: the icons are otty's exact `d` strings, so the only way they
// can go wrong is the transcription. These are headless VALUE assertions on the resulting `CGPath`
// (bounding box, emptiness, equivalence between spellings) — geometry a render can only confirm,
// never establish.

import CoreGraphics
import XCTest
@testable import SlopDeskSlate

final class VectorIconTests: XCTestCase {
    // MARK: - The grammar

    /// The straight-line commands, absolute and relative, describe the SAME square — which is the
    /// whole of what "relative" means and the first thing a hand-rolled reader gets wrong.
    func testRelativeAndAbsoluteAgree() {
        let absolute = SVGPath.cgPath("M2 2 L12 2 L12 12 L2 12 Z")
        let relative = SVGPath.cgPath("m2 2 l10 0 l0 10 l-10 0 z")
        XCTAssertEqual(absolute.boundingBoxOfPath, CGRect(x: 2, y: 2, width: 10, height: 10))
        XCTAssertEqual(relative.boundingBoxOfPath, absolute.boundingBoxOfPath)
    }

    /// `H`/`V` hold the other axis, and a repeated coordinate pair repeats the command — with the
    /// ⚠️ special case that a repeated `M` is a LINE, not another jump. otty's data leans on both.
    func testShorthandAxesAndImplicitRepeats() {
        XCTAssertEqual(
            SVGPath.cgPath("M0 0H10V10H0Z").boundingBoxOfPath,
            CGRect(x: 0, y: 0, width: 10, height: 10),
        )
        // "M0 0 10 0 10 10" — one moveto, then two implicit LINES.
        let implicit = SVGPath.cgPath("M0 0 10 0 10 10")
        let explicit = SVGPath.cgPath("M0 0 L10 0 L10 10")
        XCTAssertEqual(implicit.boundingBoxOfPath, explicit.boundingBoxOfPath)
        XCTAssertFalse(implicit.isEmpty)
    }

    /// `Z` returns the pen to the SUBPATH's start, not to the origin — so what follows a close
    /// continues from where that subpath began.
    func testCloseReturnsToTheSubpathStart() {
        // Close the square, then draw a line 10 further right: it must start from (5,5), so the
        // box runs to x=15 — not from (0,0), which would end at x=10.
        let path = SVGPath.cgPath("M5 5H10V10H5Z l10 0")
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 15, accuracy: 1e-9)
    }

    /// Elliptical arcs — the command lucide's rounded joints are built from, and the only one that
    /// needs real conversion (endpoint form → centre form → cubics). Two half-circle arcs make one
    /// circle whichever way they sweep, so this pins the geometry without pinning a direction.
    func testArcsBuildATrueCircle() {
        let circle = SVGPath.cgPath("M10 0A10 10 0 0 1 -10 0A10 10 0 0 1 10 0")
        let box = circle.boundingBoxOfPath
        XCTAssertEqual(box.minX, -10, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 10, accuracy: 0.01)
        XCTAssertEqual(box.minY, -10, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 10, accuracy: 0.01)
    }

    /// ⚠️ An arc's two flags are ONE CHARACTER each. Minified data is allowed to pack them straight
    /// against the coordinate that follows, and a number-shaped read would swallow the lot — which
    /// is silent: it yields a path, just the wrong one.
    func testArcFlagsMayBePackedAgainstTheNextNumber() {
        let spaced = SVGPath.cgPath("M0 0a10 10 0 0 1 10 10")
        let packed = SVGPath.cgPath("M0 0a10 10 0 0110 10")
        XCTAssertFalse(spaced.isEmpty)
        XCTAssertEqual(packed.boundingBoxOfPath, spaced.boundingBoxOfPath)
    }

    /// A degenerate radius is a straight line by definition (SVG 1.1 §F.6.2), not an error — and an
    /// arc that goes nowhere draws nothing rather than dividing by zero.
    func testDegenerateArcsDegradeToLines() {
        XCTAssertEqual(
            SVGPath.cgPath("M0 0A0 0 0 0 1 10 10").boundingBoxOfPath,
            CGRect(x: 0, y: 0, width: 10, height: 10),
        )
        // An arc whose endpoints coincide has no extent at all (the pen never leaves the point) —
        // as opposed to sweeping a whole ellipse, which is what a centre-form arc would do here.
        let stationary = SVGPath.cgPath("M4 4A2 2 0 0 1 4 4").boundingBoxOfPath
        XCTAssertEqual(stationary.width, 0, accuracy: 1e-9)
        XCTAssertEqual(stationary.height, 0, accuracy: 1e-9)
    }

    /// Smooth curves reflect the previous control point; with no previous curve the reflection is
    /// the current point, which degenerates the command into an ordinary one. Both spellings of the
    /// same arc of a curve must land in the same place.
    func testSmoothCurvesReflectTheirControlPoint() {
        let smooth = SVGPath.cgPath("M0 0 C0 5 5 10 10 10 S20 5 20 0")
        let spelled = SVGPath.cgPath("M0 0 C0 5 5 10 10 10 C15 10 20 5 20 0")
        XCTAssertEqual(smooth.boundingBoxOfPath.maxX, spelled.boundingBoxOfPath.maxX, accuracy: 1e-9)
        XCTAssertEqual(smooth.boundingBoxOfPath.maxY, spelled.boundingBoxOfPath.maxY, accuracy: 1e-9)
    }

    /// Numbers may be signed, may start at the decimal point, and may carry an exponent — all
    /// without a separator, which is why the scan can't be a `split`. otty's own data uses the
    /// leading-dot form (`-.86`).
    func testNumbersParseWithoutSeparators() {
        XCTAssertEqual(SVGPath.cgPath("M0 0h1e1").boundingBoxOfPath.maxX, 10, accuracy: 1e-9)
        XCTAssertEqual(SVGPath.cgPath("M0 0h.5").boundingBoxOfPath.maxX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(SVGPath.cgPath("M0 0h-.5").boundingBoxOfPath.minX, -0.5, accuracy: 1e-9)
        XCTAssertEqual(SVGPath.cgPath("M0,0 L10,0").boundingBoxOfPath.maxX, 10, accuracy: 1e-9)
    }

    /// Garbage terminates rather than spinning: this reads artwork COMPILED INTO the binary, so a
    /// bad glyph must degrade to a shape and never to a hang or a trap.
    func testMalformedDataTerminates() {
        XCTAssertTrue(SVGPath.cgPath("").isEmpty)
        XCTAssertTrue(SVGPath.cgPath("?!@").isEmpty)
        XCTAssertFalse(SVGPath.cgPath("M0 0 L10 10 X 5 5").isEmpty)
    }

    // MARK: - The artwork

    /// Every stroke of otty's hand parses, and the whole glyph sits INSIDE its 24-unit viewBox —
    /// the check that catches a mistyped coordinate, which is otherwise invisible until it clips.
    func testTheHandFillsItsViewBoxAndNoMore() {
        var union = CGRect.null
        for outline in OttyIcon.hand.outlines {
            let path = SVGPath.cgPath(outline)
            XCTAssertFalse(path.isEmpty, "every stroke of the hand must parse")
            union = union.union(path.boundingBoxOfPath)
        }
        // Lucide authors to a 24 box with a 2-unit stroke, so the CENTRELINES sit a stroke's half
        // inside it. Anything outside means a transcription slip.
        XCTAssertGreaterThanOrEqual(union.minX, 0)
        XCTAssertGreaterThanOrEqual(union.minY, 0)
        XCTAssertLessThanOrEqual(union.maxX, OttyIcon.hand.viewBox)
        XCTAssertLessThanOrEqual(union.maxY, OttyIcon.hand.viewBox)
        // …and it actually fills the box rather than collapsing into a corner.
        XCTAssertGreaterThan(union.width, 12)
        XCTAssertGreaterThan(union.height, 16)
    }

    /// The cup's two duotone layers both parse and share a centre — the body sits BEHIND the
    /// outline, which is what a Material duotone is; two layers that didn't overlap would be two
    /// icons stacked, not one.
    func testTheCupsDuotoneLayersOverlap() {
        let boxes = OttyIcon.coffee.fills.map { SVGPath.cgPath($0.data).boundingBoxOfPath }
        XCTAssertEqual(boxes.count, 2)
        for box in boxes {
            XCTAssertFalse(box.isNull)
            XCTAssertGreaterThanOrEqual(box.minX, 0)
            XCTAssertLessThanOrEqual(box.maxX, OttyIcon.coffee.viewBox)
        }
        XCTAssertTrue(boxes[0].intersects(boxes[1]), "the body must sit inside the outline")
        XCTAssertTrue(boxes[1].contains(boxes[0]), "…entirely inside it")
    }

    /// Fitting into a rect is UNIFORM and CENTRED: an icon never stretches, and every glyph in the
    /// column shares one optical centre however wide the box it is handed.
    func testFittingIsUniformAndCentred() {
        let square = CGRect(x: 0, y: 0, width: 48, height: 48)
        let wide = CGRect(x: 0, y: 0, width: 96, height: 48)
        let data = "M0 0H24V24H0Z"
        XCTAssertEqual(
            SVGPath.cgPath(data, viewBox: 24, in: square).boundingBoxOfPath,
            CGRect(x: 0, y: 0, width: 48, height: 48),
        )
        let fitted = SVGPath.cgPath(data, viewBox: 24, in: wide).boundingBoxOfPath
        XCTAssertEqual(fitted.width, fitted.height, accuracy: 1e-9, "uniform — never stretched")
        XCTAssertEqual(fitted.midX, wide.midX, accuracy: 1e-9, "centred in the box it was handed")
        XCTAssertEqual(fitted.midY, wide.midY, accuracy: 1e-9)
    }
}
