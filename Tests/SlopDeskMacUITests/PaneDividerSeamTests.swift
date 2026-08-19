// PaneDividerSeamTests proves the three promises ``MacPaneDivider`` (docs/56 wave R, batch R6)
// carries across from its SwiftUI half that a compiler cannot check.
//
// 1. THE VERTICAL DRAG'S SIGN. SwiftUI's `DragGesture` reports `translation.height` positive
//    DOWNWARD, and `leadingWeight` grows the LEADING child — the TOP one of a stacked split, since
//    the solver's rects are top-left origin. AppKit reports `locationInWindow` y-UP, so the port has
//    to negate exactly one of the two arms. Both spellings compile, both run, and the wrong one
//    leaves a stacked seam running away from the cursor while the column seam beside it behaves —
//    which reads as "one divider is broken" rather than as an axis-convention bug.
//
// 2. THE ARROW TELLS THE TRUTH AT THE CLAMP. A seam whose neighbour sits on the solver's pixel
//    floor asks for the ONE-WAY arrow for the only direction it has left, and a seam that is dead
//    both ways keeps the TWO-WAY one — there is no "cannot resize" cursor, and a plain arrow over a
//    seam reads as a dead zone rather than as a seam sitting on its floor. The dead-both-ways arm is
//    the one a port drops, because it looks like a case that wants its own answer.
//
// 3. NOTHING INSIDE THE BAND SWALLOWS THE PRESS. The hairline is drawn down the middle of the hit
//    band — exactly where a user aims — and the ratio chip sits centred on it. Both are decorations
//    with `hitTest` overrides; without them the seam would only be grabbable BESIDE the line the
//    user is aiming at, which is the maddening version of this control.
//
// Headless: `NSCursor`'s class cursors, an `NSView`'s `hitTest` and a static function need no
// window (the hang-safety rule forbids an `NSWindow` in a test), so nothing here mounts one.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class PaneDividerSeamTests: XCTestCase {
    // MARK: The drag's sign

    /// A stacked (`.vertical`) split: dragging DOWN must grow the TOP child, so a lower window y
    /// has to come back POSITIVE.
    func testAStackedSeamReadsADownwardMoveAsPositive() {
        let down = MacPaneDivider.axisTranslation(
            axis: .vertical, from: NSPoint(x: 400, y: 300), to: NSPoint(x: 400, y: 260),
        )
        XCTAssertEqual(
            down, 40,
            "window y is UP and the solver's rects are not — a downward drag must grow the TOP pane",
        )
    }

    /// The mirror, so a fix that flips the sign cannot pass by flipping both arms.
    func testAStackedSeamReadsAnUpwardMoveAsNegative() {
        let up = MacPaneDivider.axisTranslation(
            axis: .vertical, from: NSPoint(x: 400, y: 300), to: NSPoint(x: 400, y: 355),
        )
        XCTAssertEqual(up, -55, "dragging up must shrink the top pane")
    }

    /// A side-by-side (`.horizontal`) split: x is the same way up in both frameworks, so this arm
    /// is NOT negated — pinned beside the one that is, because the bug is picking the wrong one.
    func testAColumnSeamReadsARightwardMoveAsPositive() {
        let right = MacPaneDivider.axisTranslation(
            axis: .horizontal, from: NSPoint(x: 400, y: 300), to: NSPoint(x: 470, y: 120),
        )
        XCTAssertEqual(right, 70, "dragging right must grow the LEADING (left) pane")
        // The off-axis travel is ignored outright: a seam moves along one axis and the cursor
        // wandering across it is not a resize.
        let acrossOnly = MacPaneDivider.axisTranslation(
            axis: .horizontal, from: NSPoint(x: 400, y: 300), to: NSPoint(x: 400, y: 120),
        )
        XCTAssertEqual(acrossOnly, 0, "travel across the seam's axis is not a resize")
    }

    // MARK: The arrow at the clamp

    func testAPinnedColumnSeamWearsTheOneWayArrow() {
        XCTAssertEqual(
            MacPaneDivider.cursor(for: .columnResize(toLeading: true, toTrailing: false)),
            .resizeLeft,
            "a seam that can only shrink the leading pane must say so",
        )
        XCTAssertEqual(
            MacPaneDivider.cursor(for: .columnResize(toLeading: false, toTrailing: true)),
            .resizeRight,
        )
    }

    func testAPinnedRowSeamWearsTheOneWayArrow() {
        // `toUp` is the LEADING (top) child — the arm most likely to be ported upside down.
        XCTAssertEqual(
            MacPaneDivider.cursor(for: .rowResize(toUp: true, toDown: false)),
            .resizeUp,
            "toUp is the leading (top) child of a stacked split",
        )
        XCTAssertEqual(
            MacPaneDivider.cursor(for: .rowResize(toUp: false, toDown: true)),
            .resizeDown,
        )
    }

    /// The arm a port drops: a WEDGED seam (neither direction lives) keeps the two-way arrow, the
    /// same glyph a fully-free seam wears. There is no "cannot resize" cursor, and a plain arrow
    /// over a seam reads as a dead zone rather than as a seam sitting on its floor.
    func testALiveSeamAndADeadSeamWearTheSameTwoWayArrow() {
        for axis in [SplitAxis.horizontal, .vertical] {
            let free = MacPaneDivider.cursor(
                for: PaneCanvasMetrics.resizePointer(axis: axis, toLeading: true, toTrailing: true),
            )
            let wedged = MacPaneDivider.cursor(
                for: PaneCanvasMetrics.resizePointer(axis: axis, toLeading: false, toTrailing: false),
            )
            XCTAssertEqual(
                free, wedged,
                "a wedged \(axis) seam lost its arrow — a bare pointer over a seam reads as a dead zone",
            )
        }
        XCTAssertEqual(
            MacPaneDivider.cursor(for: .columnResize(toLeading: true, toTrailing: true)),
            .resizeLeftRight,
        )
        XCTAssertEqual(
            MacPaneDivider.cursor(for: .rowResize(toUp: true, toDown: true)),
            .resizeUpDown,
        )
    }

    // MARK: The grab band

    /// Every decoration the divider carries is transparent to the pointer, so the WHOLE band grabs
    /// — including the hairline down its middle, which is the part the user aims at. Read off the
    /// live subview list rather than off two named types, so a decoration added later is covered by
    /// this test on the day it lands.
    func testEveryDecorationInsideTheBandIsTransparentToThePointer() {
        let divider = makeDivider(axis: .horizontal)
        XCTAssertFalse(
            divider.subviews.isEmpty, "the divider drew nothing — this test checks nothing",
        )
        for decoration in divider.subviews {
            XCTAssertNil(
                decoration.hitTest(NSPoint(x: 3, y: 40)),
                "\(type(of: decoration)) swallows the press — the seam is grabbable only beside itself",
            )
        }
    }

    /// And the band itself takes the press: a click anywhere across its width lands on the divider,
    /// not on whatever is under it.
    func testThePressLandsOnTheBandItself() {
        let divider = makeDivider(axis: .horizontal)
        for x in stride(from: CGFloat(0.5), to: divider.bounds.width, by: 1) {
            XCTAssertIdentical(
                divider.hitTest(NSPoint(x: x, y: 40)), divider,
                "a press at x=\(x) missed the seam — the grab band is not the whole handle rect",
            )
        }
    }

    /// A divider whose decorations COVER the whole band, so the two tests above ask the question
    /// they mean to.
    ///
    /// The frames are set by hand rather than by an Auto Layout pass: this hierarchy is detached and
    /// windowless (the hang-safety rule), so nothing would run the constraints and every decoration
    /// would sit at a zero rect — where the DEFAULT `hitTest` answers nil too and a port that
    /// deleted the overrides would go green. Each is un-hidden for the same reason: AppKit answers
    /// nil for a hidden view whatever its override says, and the ratio chip rests hidden.
    private func makeDivider(axis: SplitAxis) -> MacPaneDivider {
        let rect = NSRect(x: 0, y: 0, width: 6, height: 200)
        let divider = MacPaneDivider(handle: SplitDividerHandle(
            splitID: SplitNodeID(),
            childIndex: 0,
            axis: axis,
            rect: rect,
            parentSpan: 600,
            flexSum: 2,
            leadingWeight: 1,
            trailingWeight: 1,
        ))
        divider.frame = rect
        for decoration in divider.subviews {
            decoration.isHidden = false
            decoration.frame = divider.bounds
        }
        return divider
    }
}
#endif
