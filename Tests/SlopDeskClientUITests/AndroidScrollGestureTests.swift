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
    /// A 1:1 surface, so the cases below can go on reading the finger's position in the same numbers
    /// they plant it with. The panel is almost never at 1:1 — that conversion is pinned on its own,
    /// in ``testTheWireCarriesVideoPixelsAndTheVideosSize``.
    private var surface: AndroidScreenLayout.Surface {
        AndroidScreenLayout.Surface(fitted: fitted, video: fitted.size)
    }

    private let degenerate = AndroidScreenLayout.Surface(fitted: .zero, video: .zero)

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
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        XCTAssertEqual(
            actions(opening), [AndroidMotionAction.down.rawValue, AndroidMotionAction.move.rawValue],
        )

        let middle = gesture.accept(
            delta: CGSize(width: 0, height: -20), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        XCTAssertEqual(actions(middle), [AndroidMotionAction.move.rawValue])

        let close = gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
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
                pointer: CGPoint(x: 100, y: 200), surface: surface,
            ))
        }
        emitted += types(gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        ))
        XCTAssertFalse(emitted.contains(AndroidControlMessage.injectScrollEvent))
        XCTAssertTrue(emitted.allSatisfy { $0 == AndroidControlMessage.injectTouchEvent })
    }

    func testTheContactIsPlantedUnderTheCursor() {
        // A scroll acts on whatever is under the pointer, exactly as it does on a Mac.
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 140, y: 300), surface: surface,
        )
        XCTAssertEqual(gesture.finger?.x, 140)
        XCTAssertEqual(gesture.finger?.y, 299)
    }

    func testEveryEventMovesTheFingerRatherThanBankingAgainstAStep() {
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        let start = try? XCTUnwrap(gesture.finger)
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
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
            pointer: CGPoint(x: 0, y: 400), surface: surface,
        )
        let finger = gesture.finger
        XCTAssertEqual(finger?.x, AndroidScrollGesture.edgeMargin)
        XCTAssertEqual(finger?.y, fitted.height - AndroidScrollGesture.edgeMargin)
    }

    func testRunningOutOfScreenLiftsAndPlantsAgainAtTheFarEnd() {
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 40), surface: surface,
        )
        let regrip = gesture.accept(
            delta: CGSize(width: 0, height: -300), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 100, y: 40), surface: surface,
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
        XCTAssertTrue(gesture.lift(in: surface).isEmpty)
        XCTAssertTrue(gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 1, y: 1), surface: surface,
        ).isEmpty)
    }

    func testAbandonForgetsTheContactWithoutSendingAnUp() {
        // The socket went away, so the `up` has nowhere to go and the device's touch state is moot.
        var gesture = AndroidScrollGesture()
        _ = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        gesture.abandon()
        XCTAssertNil(gesture.finger)
        XCTAssertTrue(gesture.lift(in: surface).isEmpty)
    }

    // MARK: What actually goes on the wire

    /// THE regression this file exists for as much as the no-wheel-notch one.
    ///
    /// The gesture is tracked in the panel's points and must be SENT in the video's pixels, paired
    /// with the video's own size — `scrcpy`'s `PositionMapper` compares that pair against the size it
    /// is encoding and drops the event on any difference, with no error the client can see. The panel
    /// first shipped pairing panel points with the panel's size, and every scroll, drag and tap was
    /// silently discarded while the toolbar's keycodes (which carry no geometry) kept working.
    func testTheWireCarriesVideoPixelsAndTheVideosSize() {
        let scaled = AndroidScreenLayout.Surface(
            fitted: CGRect(x: 0, y: 0, width: 200, height: 400),
            video: CGSize(width: 460, height: 1024),
        )
        var gesture = AndroidScrollGesture()
        let opening = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), surface: scaled,
        )
        let down = try? XCTUnwrap(opening.first)
        let bytes = [UInt8](down ?? Data())
        XCTAssertEqual(bytes.count, 32)
        // The contact is still tracked in panel points…
        XCTAssertEqual(gesture.finger, CGPoint(x: 100, y: 200))
        // …and reported in the video's grid: half the width, half the height.
        XCTAssertEqual(readInt32(bytes, at: 10), 230)
        XCTAssertEqual(readInt32(bytes, at: 14), 512)
        XCTAssertEqual(readUInt16(bytes, at: 18), 460)
        XCTAssertEqual(readUInt16(bytes, at: 20), 1024)
    }

    /// The last addressable pixel, not the size itself: a frame's rows are `0..<height`, so a contact
    /// dragged onto the bottom edge must not name a row that does not exist.
    func testAContactAtTheFarEdgeStopsOneShortOfTheSize() {
        let scaled = AndroidScreenLayout.Surface(
            fitted: CGRect(x: 0, y: 0, width: 200, height: 400),
            video: CGSize(width: 460, height: 1024),
        )
        let corner = scaled.pixels(CGPoint(x: 200, y: 400))
        XCTAssertEqual(corner, CGPoint(x: 459, y: 1023))
    }

    private func readInt32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3]))
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    func testADegenerateFrameProducesNothing() {
        var gesture = AndroidScrollGesture()
        XCTAssertTrue(gesture.accept(
            delta: CGSize(width: 0, height: -10), isPrecise: true, phase: .began,
            pointer: .zero, surface: degenerate,
        ).isEmpty)
    }
}
#endif
