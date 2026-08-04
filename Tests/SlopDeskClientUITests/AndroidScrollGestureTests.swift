// AndroidScrollGestureTests — a trackpad becomes ONE finger on the device.
//
// The invariant these exist to hold is the negative one: `INJECT_SCROLL_EVENT` must never appear in a
// gesture's output. It would work — Android delivers it as `ACTION_SCROLL` — and it would cost the
// scroll every piece of feedback the platform gives: no over-scroll stretch, no edge glow, and no
// fling, because momentum is computed by `VelocityTracker` from the touch history at the moment of
// lift and a stream of wheel notches has no history.
//
// The second shape here is the RE-GRIP. A trackpad gesture travels further than the device is tall,
// and a finger cannot leave the screen and keep scrolling; the machine lifts at the edge and plants
// again at the far side, which is what a hand does.

#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class AndroidScrollGestureTests: XCTestCase {
    private let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)

    /// The action byte of each emitted touch message, which is the only thing about them these tests
    /// are asserting on.
    private func actions(_ messages: [Data]) -> [UInt8] {
        messages.map { $0[$0.index($0.startIndex, offsetBy: 1)] }
    }

    private func types(_ messages: [Data]) -> [UInt8] {
        messages.map { $0[$0.startIndex] }
    }

    // MARK: The shape of a gesture

    func testATrackpadGestureIsOneContactThatMovesAndThenLifts() {
        var gesture = AndroidScrollGesture()
        let opening = gesture.accept(
            delta: CGSize(width: 0, height: -20), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        )
        XCTAssertEqual(
            actions(opening), [AndroidMotionAction.down.rawValue, AndroidMotionAction.move.rawValue],
        )

        let middle = gesture.accept(
            delta: CGSize(width: 0, height: -20), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        )
        XCTAssertEqual(actions(middle), [AndroidMotionAction.move.rawValue])

        let close = gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        )
        XCTAssertEqual(actions(close), [AndroidMotionAction.up.rawValue])
        XCTAssertNil(gesture.finger)
    }

    func testNoWheelNotchEverGoesOnTheWire() {
        // THE assertion in this file: everything a gesture emits is `INJECT_TOUCH_EVENT` (2), never
        // `INJECT_SCROLL_EVENT` (3).
        var gesture = AndroidScrollGesture()
        var emitted: [UInt8] = []
        for _ in 0..<60 {
            emitted += types(gesture.accept(
                delta: CGSize(width: 0, height: -12), isPrecise: true, phase: .changed,
                pointer: CGPoint(x: 100, y: 200), fitted: fitted,
            ))
        }
        emitted += types(gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        ))
        XCTAssertFalse(emitted.contains(AndroidControlMessage.injectScrollEvent))
        XCTAssertTrue(emitted.allSatisfy { $0 == AndroidControlMessage.injectTouchEvent })
    }

    func testTheContactIsPlantedUnderTheCursor() {
        // A scroll acts on whatever is under the pointer, exactly as it does on a Mac.
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 140, y: 300), fitted: fitted,
        )
        XCTAssertEqual(gesture.finger?.x, 140)
        XCTAssertEqual(gesture.finger?.y, 299)
    }

    func testEveryEventMovesTheFingerRatherThanBankingAgainstAStep() {
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        )
        let start = try? XCTUnwrap(gesture.finger)
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        )
        XCTAssertEqual(gesture.finger?.y, (start?.y ?? 0) - 1)
    }

    // MARK: The edge

    func testTheFingerIsNeverPlantedInAndroidsGestureNavigationBand() {
        // The outermost band belongs to the platform: Back on the left and right edges, Home along
        // the bottom. A contact planted there starts a system gesture instead of a scroll.
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 0, y: 400), fitted: fitted,
        )
        let finger = gesture.finger
        XCTAssertEqual(finger?.x, AndroidScrollGesture.edgeMargin)
        XCTAssertEqual(finger?.y, fitted.height - AndroidScrollGesture.edgeMargin)
    }

    func testRunningOutOfScreenLiftsAndPlantsAgainAtTheFarEnd() {
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 40), fitted: fitted,
        )
        let regrip = gesture.accept(
            delta: CGSize(width: 0, height: -300), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 100, y: 40), fitted: fitted,
        )
        XCTAssertEqual(actions(regrip), [
            AndroidMotionAction.move.rawValue, // to the boundary
            AndroidMotionAction.up.rawValue, // lift
            AndroidMotionAction.down.rawValue, // and plant again
        ])
        // Planted at the far end of the axis it was travelling along, so the next stretch of the
        // same gesture has the whole height to move through.
        XCTAssertEqual(gesture.finger?.y, fitted.height - AndroidScrollGesture.edgeMargin)
        XCTAssertEqual(gesture.finger?.x, fitted.width / 2)
    }

    func testAHorizontalRegripUsesTheHorizontalAxis() {
        let landing = AndroidScrollGesture.regrip(
            travel: CGSize(width: 500, height: 0), in: fitted,
        )
        XCTAssertEqual(landing.x, AndroidScrollGesture.edgeMargin)
        XCTAssertEqual(landing.y, fitted.height / 2)
    }

    func testAPanelTooNarrowToScrollInCollapsesToItsCentreRatherThanSendingNaN() {
        let sliver = CGRect(x: 0, y: 0, width: 10, height: 10)
        let point = AndroidScrollGesture.planted(CGPoint(x: 4, y: 4), in: sliver)
        XCTAssertEqual(point, CGPoint(x: 5, y: 5))
    }

    // MARK: Teardown

    func testALiftWithNoContactDownSendsNothing() {
        var gesture = AndroidScrollGesture()
        XCTAssertTrue(gesture.lift(in: fitted).isEmpty)
        XCTAssertTrue(gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 1, y: 1), fitted: fitted,
        ).isEmpty)
    }

    func testAbandonForgetsTheContactWithoutSendingAnUp() {
        // The socket went away, so the `up` has nowhere to go and the device's touch state is moot.
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), fitted: fitted,
        )
        gesture.abandon()
        XCTAssertNil(gesture.finger)
        XCTAssertTrue(gesture.lift(in: fitted).isEmpty)
    }

    func testADegenerateFrameProducesNothing() {
        var gesture = AndroidScrollGesture()
        XCTAssertTrue(gesture.accept(
            delta: CGSize(width: 0, height: -10), isPrecise: true, phase: .began,
            pointer: .zero, fitted: .zero,
        ).isEmpty)
    }
}
#endif
