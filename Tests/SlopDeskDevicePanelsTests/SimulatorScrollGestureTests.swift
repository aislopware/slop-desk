// The scroll machine, pinned against the measurement that produced it: `swipe` occupies the server
// for 275 ms an envelope and `touch1-move` for 0.03 ms, so a scroll has to be ONE contact that moves,
// never a run of flicks. These tests are about that shape — one down, many moves, exactly one up —
// because it is the shape, not the arithmetic, that the panel was getting wrong.

#if os(macOS)
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorScrollGestureTests: XCTestCase {
    private let fitted = CGRect(x: 0, y: 0, width: 400, height: 800)

    // MARK: The shape of a gesture

    func testATrackpadGestureIsOneContactThatMovesAndThenLifts() {
        var gesture = SimulatorScrollGesture()
        let opening = accept(&gesture, delta: CGSize(width: 0, height: -20), phase: .began)
        XCTAssertEqual(types(opening), ["touch1-down", "touch1-move"])

        let middle = accept(&gesture, delta: CGSize(width: 0, height: -20), phase: .changed)
        XCTAssertEqual(types(middle), ["touch1-move"])

        let close = accept(&gesture, delta: .zero, phase: .ended)
        XCTAssertEqual(types(close), ["touch1-up"])
        XCTAssertNil(gesture.finger)
    }

    func testNoSwipeEverGoesOnTheWire() {
        // The whole point. A `swipe` costs 275 ms of the server's main actor — measured 2026-08-04
        // against `baguette input` — and a flick's worth of them is seconds of backlog.
        var gesture = SimulatorScrollGesture()
        var emitted: [String] = []
        for _ in 0..<40 {
            emitted += types(accept(&gesture, delta: CGSize(width: 0, height: -12), phase: .changed))
        }
        emitted += types(accept(&gesture, delta: .zero, phase: .ended))
        XCTAssertFalse(emitted.contains("swipe"))
        XCTAssertFalse(emitted.contains("tap"))
    }

    func testEveryEventMovesTheFingerRatherThanBankingAgainstAStep() {
        // The old path banked travel until it cleared 24 points and only then sent anything, which
        // is why a slow scroll did nothing at all. A contact that is already down has no slop to
        // clear: one point of travel is one point of travel.
        var gesture = SimulatorScrollGesture()
        _ = accept(&gesture, delta: CGSize(width: 0, height: -1), phase: .began)
        let start = gesture.finger
        _ = accept(&gesture, delta: CGSize(width: 0, height: -1), phase: .changed)
        XCTAssertEqual(gesture.finger?.y, (start?.y ?? 0) - 1)
    }

    func testTheContactIsPlantedUnderTheCursor() {
        // A scroll acts on whatever is under the pointer, exactly as it does on a Mac — the device
        // has several scrollable regions on screen at once and the cursor is how you pick one.
        var gesture = SimulatorScrollGesture()
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -4), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 120, y: 300), fitted: fitted, orientation: .portrait,
        )
        XCTAssertEqual(gesture.finger?.x, 120)
    }

    // MARK: The wheel, which has no phases

    func testAClassicWheelOpensOnItsFirstNotchAndIsClosedByTheCaller() {
        // A wheel reports no phase at all, so nothing on the wire says the user stopped. The view
        // arms an idle timer and calls `lift`; without it the device would be left with a finger
        // permanently down.
        var gesture = SimulatorScrollGesture()
        XCTAssertEqual(
            types(accept(&gesture, delta: CGSize(width: 0, height: -1), phase: .wheel, isPrecise: false)),
            ["touch1-down", "touch1-move"],
        )
        XCTAssertEqual(
            types(accept(&gesture, delta: CGSize(width: 0, height: -1), phase: .wheel, isPrecise: false)),
            ["touch1-move"],
        )
        XCTAssertEqual(types(gesture.lift(in: fitted)), ["touch1-up"])
        XCTAssertEqual(gesture.lift(in: fitted).count, 0, "a second lift has nothing to lift")
    }

    func testAnEndedPhaseWithNoContactSendsNothing() {
        // Momentum and stray `.ended`s arrive after the view has already lifted; an unmatched `up`
        // would land on the device as a phantom release.
        var gesture = SimulatorScrollGesture()
        XCTAssertTrue(accept(&gesture, delta: .zero, phase: .ended).isEmpty)
    }

    // MARK: Running out of screen

    func testAGestureLongerThanTheDeviceRegripsRatherThanStalling() {
        // A trackpad flick can travel further than the device is tall, and a finger cannot leave the
        // screen and keep scrolling. Lifting at the boundary and planting again at the far side is
        // what a hand does.
        var gesture = SimulatorScrollGesture()
        _ = accept(&gesture, delta: CGSize(width: 0, height: -100), phase: .began)
        var sawRegrip = false
        for _ in 0..<20 {
            let step = types(accept(&gesture, delta: CGSize(width: 0, height: -100), phase: .changed))
            if step == ["touch1-move", "touch1-up", "touch1-down"] { sawRegrip = true }
        }
        XCTAssertTrue(sawRegrip, "a gesture longer than the screen must re-grip")
        XCTAssertNotNil(gesture.finger, "and must still be holding a contact afterwards")
    }

    func testAReGripLandsOffTheEdgeItJustLeft() {
        // Planting ON the boundary would put the next contact inside iOS's own system-gesture band,
        // so a long scroll would summon the app switcher instead of continuing.
        let landing = SimulatorScrollGesture.regrip(
            travel: CGSize(width: 0, height: -300), in: fitted,
        )
        XCTAssertEqual(landing.y, fitted.height - SimulatorScrollGesture.edgeMargin)
        let downward = SimulatorScrollGesture.regrip(
            travel: CGSize(width: 0, height: 300), in: fitted,
        )
        XCTAssertEqual(downward.y, SimulatorScrollGesture.edgeMargin)
    }

    func testAFrameTooSmallForTwoMarginsStillProducesAPoint() {
        // A sidebar dragged narrow is not a reason to put NaN on the wire.
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
        let planted = SimulatorScrollGesture.planted(CGPoint(x: 5, y: 5), in: tiny)
        XCTAssertEqual(planted, CGPoint(x: 5, y: 5))
    }

    func testAnEmptyFrameSendsNothingAtAll() {
        // Before the first frame decodes there is no screen to touch.
        var gesture = SimulatorScrollGesture()
        XCTAssertTrue(gesture.accept(
            delta: CGSize(width: 0, height: -10), isPrecise: true, phase: .began,
            pointer: .zero, fitted: .zero, orientation: .portrait,
        ).isEmpty)
    }

    func testAbandonDropsTheContactWithoutSendingAnUp() {
        // The socket went away — an `up` has nowhere to go, and the device's touch state died with
        // the stream.
        var gesture = SimulatorScrollGesture()
        _ = accept(&gesture, delta: CGSize(width: 0, height: -10), phase: .began)
        gesture.abandon()
        XCTAssertNil(gesture.finger)
        XCTAssertTrue(gesture.lift(in: fitted).isEmpty)
    }

    // MARK: Helpers

    private func accept(
        _ gesture: inout SimulatorScrollGesture, delta: CGSize,
        phase: SimulatorScrollGesture.Phase, isPrecise: Bool = true,
    ) -> [SimulatorInputEnvelope] {
        gesture.accept(
            delta: delta, isPrecise: isPrecise, phase: phase,
            pointer: CGPoint(x: 200, y: 400), fitted: fitted, orientation: .portrait,
        )
    }

    /// The `type` field of each envelope, which is the only thing these tests are about.
    private func types(_ envelopes: [SimulatorInputEnvelope]) -> [String] {
        envelopes.compactMap { $0.fields["type"] as? String }
    }
}
#endif
