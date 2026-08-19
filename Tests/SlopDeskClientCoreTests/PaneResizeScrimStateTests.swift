// PaneResizeScrimStateTests — "is this pane mid-resize", pinned as a reducer.
//
// It was four `@State` flags and three `.onChange`/`.task` handlers inside the pane container, which
// is to say it was a state machine with no name and no test. The two regressions it exists to stop
// are both visible-at-launch defects rather than subtle ones:
//   • MOUNT IS NOT A RESIZE — a `.zero → real` first layout must not flash the scrim over every pane
//     on the workspace's first frame;
//   • A PAUSED DRAG must not flash through the gap — the geometry timer clears after 200 ms but the
//     host send is deferred to release, so nothing else is holding the scrim up in between.
//
// Headless values only — the `.task(id:)` sleep stays in the view, so nothing here waits.

import CoreGraphics
import XCTest
@testable import SlopDeskClientCore

final class PaneResizeScrimStateTests: XCTestCase {
    private let small = CGSize(width: 400, height: 300)
    private let large = CGSize(width: 800, height: 300)

    /// THE MOUNT RULE, at the level it is decided. A transition to or from `.zero` is the initial
    /// layout settling or a teardown; only a change between two REAL sizes is a resize.
    func testOnlyAChangeBetweenTwoRealSizesIsAResize() {
        XCTAssertTrue(PaneResizeScrimState.isResize(from: small, to: large))
        XCTAssertFalse(PaneResizeScrimState.isResize(from: nil, to: large), "the first observation is a mount")
        XCTAssertFalse(PaneResizeScrimState.isResize(from: .zero, to: large), "…and so is `.zero → real`")
        XCTAssertFalse(PaneResizeScrimState.isResize(from: large, to: .zero), "`real → .zero` is a teardown")
        XCTAssertFalse(PaneResizeScrimState.isResize(from: large, to: large), "an identical size changed nothing")
    }

    /// THE LAUNCH REGRESSION, end to end: a pane that mounts and is laid out once shows no scrim, and
    /// asks for no settle timer either.
    func testAFreshMountNeitherDimsNorArmsATimer() {
        var scrim = PaneResizeScrimState()

        XCTAssertFalse(scrim.noteSize(large, isDragging: false), "nothing armed ⇒ no timer to start")
        XCTAssertFalse(scrim.isVisible(staticMirror: false, isDragging: false, awaitingReflow: false))
    }

    /// The ordinary resize: the scrim comes up on the size change and goes down when the size has
    /// held steady for the settle.
    func testARealResizeRaisesTheScrimUntilTheSizeSettles() {
        var scrim = PaneResizeScrimState()
        scrim.noteSize(small, isDragging: false)

        XCTAssertTrue(scrim.noteSize(large, isDragging: false), "a real resize arms the settle wait")
        XCTAssertTrue(scrim.isVisible(staticMirror: false, isDragging: false, awaitingReflow: false))

        scrim.noteSettled()
        XCTAssertFalse(scrim.isVisible(staticMirror: false, isDragging: false, awaitingReflow: false))
    }

    /// THE PAUSED-DRAG REGRESSION: the geometry signal clears on its own after the settle, but a drag
    /// that is still held has not sent anything to the host yet, so nothing else would be holding the
    /// scrim up. The drag hold is sticky for the whole gesture and clears with it.
    func testAHeldDragKeepsTheScrimUpAcrossTheSettle() {
        var scrim = PaneResizeScrimState()
        scrim.noteSize(small, isDragging: true)
        scrim.noteSize(large, isDragging: true)
        scrim.noteSettled()

        XCTAssertTrue(
            scrim.isVisible(staticMirror: false, isDragging: true, awaitingReflow: false),
            "the cursor is still down — the reflow has not even been requested yet",
        )

        scrim.noteDragEnded()
        XCTAssertFalse(scrim.isVisible(staticMirror: false, isDragging: false, awaitingReflow: false))
    }

    /// The drag hold is gated on THIS pane having changed size, so dragging a divider somewhere else
    /// in the tab never dims the panes it does not touch.
    func testADragThatNeverResizedThisPaneLeavesItAlone() {
        var scrim = PaneResizeScrimState()
        scrim.noteSize(large, isDragging: false)
        scrim.noteSize(large, isDragging: true) // the drag moved a seam elsewhere

        XCTAssertFalse(scrim.isVisible(staticMirror: false, isDragging: true, awaitingReflow: false))
    }

    /// The REFLOW hold outlasts both of the others: on a slow link the host round trip lands the
    /// fresh pixels well after the 200 ms timer, and the scrim has to still be there when it does.
    func testTheReflowHoldOutlastsTheTimerAndTheDrag() {
        var scrim = PaneResizeScrimState()
        scrim.noteSize(small, isDragging: true)
        scrim.noteSize(large, isDragging: true)
        scrim.noteSettled()
        scrim.noteDragEnded()

        XCTAssertTrue(
            scrim.isVisible(staticMirror: false, isDragging: false, awaitingReflow: true),
            "the release committed; the host has not answered yet",
        )
        XCTAssertFalse(scrim.isVisible(staticMirror: false, isDragging: false, awaitingReflow: false))
    }

    /// The static-mirror snapshot path renders no live chrome, whatever the reducer thinks — an
    /// `ImageRenderer` capture of a mid-resize workspace must not bake a scrim into the picture.
    func testTheStaticMirrorNeverDims() {
        var scrim = PaneResizeScrimState()
        scrim.noteSize(small, isDragging: true)
        scrim.noteSize(large, isDragging: true)

        XCTAssertFalse(scrim.isVisible(staticMirror: true, isDragging: true, awaitingReflow: true))
    }
}
