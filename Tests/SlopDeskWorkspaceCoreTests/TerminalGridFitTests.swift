import CoreGraphics
import SlopDeskWorkspaceCore
import XCTest

/// A phone places a grid it did not choose (docs/45 §8.3): iOS is size-passive HOST-side, so the
/// resolved grid is whatever the Macs on the pane folded to, and the phone's job is to place it
/// honestly rather than reflow it.
///
/// The letterbox is a pure value, so it carries the tests the iOS view itself cannot: the iOS gate
/// proves the SwiftUI path type-checks under that triple, and these prove it places the right
/// rectangle. What the pane SAYS about the grid is the roster's third join and is tested in
/// `slopdesk_workspace::grid_readout`, beside the two joins it shares its shape with.
final class TerminalGridFitTests: XCTestCase {
    /// A grid too wide for the container shrinks to fit and centres, leaving equal bars. The scale
    /// is the WIDTH ratio because that is the tighter constraint.
    func testAGridWiderThanTheContainerShrinksAndCentres() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 120, rows: 40,
            cellWidth: 8, cellHeight: 16,
            in: CGSize(width: 480, height: 1280),
        ))
        // natural 960×640; width ratio 0.5, height ratio 2 → 0.5 wins.
        XCTAssertEqual(fit.scale, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.width, 480, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.height, 320, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.y, 480, accuracy: 1e-9, "centred: (1280 − 320) / 2")
        XCTAssertTrue(fit.isLetterboxed)
    }

    /// A grid SMALLER than the container is NOT magnified. The renderer draws at its natural cell
    /// size and the remainder is bars — blowing a terminal up past its cell metrics is blur, and a
    /// scaled-up glyph grid is exactly the thing a coding tool must not ship.
    func testASmallGridIsCentredRatherThanMagnified() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 40, rows: 12,
            cellWidth: 8, cellHeight: 16,
            in: CGSize(width: 800, height: 600),
        ))
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.width, 320, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.height, 192, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.x, 240, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect.origin.y, 204, accuracy: 1e-9)
        XCTAssertTrue(fit.isLetterboxed, "bars on all four sides")
    }

    /// An exact fit has no bars — the letterbox must not draw one for a pane that is already right,
    /// or every Mac pane would gain a hairline it did not ask for.
    func testAnExactFitIsNotLetterboxed() throws {
        let fit = try XCTUnwrap(TerminalLetterbox.fit(
            cols: 100, rows: 30,
            cellWidth: 8, cellHeight: 16,
            in: CGSize(width: 800, height: 480),
        ))
        XCTAssertEqual(fit.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.contentRect, CGRect(x: 0, y: 0, width: 800, height: 480))
        XCTAssertFalse(fit.isLetterboxed)
    }

    /// Degenerate inputs place NOTHING rather than a zero-area or infinite rect: a pre-layout pass,
    /// a headless surface with no cell metrics, and a pane whose grid the host has not resolved all
    /// arrive here, and the honest answer is "render as you always did".
    func testDegenerateInputsPlaceNothing() {
        let container = CGSize(width: 480, height: 800)
        XCTAssertNil(TerminalLetterbox.fit(cols: 0, rows: 40, cellWidth: 8, cellHeight: 16, in: container))
        XCTAssertNil(TerminalLetterbox.fit(cols: 120, rows: 0, cellWidth: 8, cellHeight: 16, in: container))
        XCTAssertNil(TerminalLetterbox.fit(cols: 120, rows: 40, cellWidth: 0, cellHeight: 16, in: container))
        XCTAssertNil(TerminalLetterbox.fit(cols: 120, rows: 40, cellWidth: 8, cellHeight: 0, in: container))
        XCTAssertNil(TerminalLetterbox.fit(
            cols: 120, rows: 40, cellWidth: 8, cellHeight: 16, in: CGSize(width: 0, height: 800),
        ))
        XCTAssertNil(TerminalLetterbox.fit(
            cols: 120, rows: 40, cellWidth: 8, cellHeight: 16, in: CGSize(width: 480, height: 0),
        ))
    }
}
