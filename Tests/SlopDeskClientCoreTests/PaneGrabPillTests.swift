// Pins the grab strip's two BEHAVIOURAL rungs — which input reveals the pill, and how far a press has
// to travel before it is a move rather than a tap.
//
// Both were inline in the renderers until the phone's turned out to be reading a hover a finger cannot
// produce: `hovering || isDragging`, with `.onHover` the only writer, so the pill the pane-move drag
// starts from was never drawn on a touch device and the whole gesture had no door. The drag machinery
// under it was fine. Three renderers in two frameworks draw this strip and no compiler can see two of
// them at once, so the rules are asserted here rather than trusted to stay in step.

import XCTest
@testable import SlopDeskClientCore

final class PaneGrabPillTests: XCTestCase {
    // MARK: The reveal

    /// A finger produces no hover ever, so touch reveals unconditionally — the defect this rule was
    /// minted for.
    func testTouchRevealsWithoutHover() {
        XCTAssertTrue(PaneGrabPill.isRevealed(input: .touch, hovering: false, isDragging: false))
        XCTAssertTrue(PaneGrabPill.isRevealed(input: .touch, hovering: false, isDragging: true))
    }

    /// A pointer keeps exactly the reveal it always had: hidden until the cursor is over the strip, or
    /// the drag it started is still live.
    func testPointerStillRevealsOnHoverOrDragOnly() {
        XCTAssertFalse(PaneGrabPill.isRevealed(input: .pointer, hovering: false, isDragging: false))
        XCTAssertTrue(PaneGrabPill.isRevealed(input: .pointer, hovering: true, isDragging: false))
        XCTAssertTrue(
            PaneGrabPill.isRevealed(input: .pointer, hovering: false, isDragging: true),
            "a drag whose pointer has left the strip must not lose its pill mid-move",
        )
    }

    // MARK: The slop

    /// A finger's slop is larger than a mouse's, and that ordering is the whole point: the pointer's
    /// 2pt applied to touch turns nearly every tap on the strip into a drag, which costs the pane its
    /// tap-to-focus.
    func testTouchSlopExceedsPointerSlop() {
        let pointer = PaneGrabPill.minimumDragDistance(.pointer)
        let touch = PaneGrabPill.minimumDragDistance(.touch)
        XCTAssertEqual(pointer, 2, "the mouse's slop is unchanged — this was never the Mac's bug")
        XCTAssertGreaterThan(touch, pointer)
    }
}
