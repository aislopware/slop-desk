// SimulatorScrollGestureTests — the FACE, not the machine.
//
// The machine — one contact that moves, the re-grip at the edge, the margin, what a phase means — is
// `slopdesk_devicepanel::scroll` and is pinned there. What these hold is the half that stays on this
// side and is invisible from Rust: that a contact becomes the `touch1-*` envelope carrying the fitted
// rect's own size, that the handle really does carry the finger between events (a value type holding
// one would not), and that a count of zero comes back as no envelopes rather than a stray `up`.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorScrollGestureTests: XCTestCase {
    private let fitted = CGRect(x: 0, y: 0, width: 400, height: 800)

    /// Every contact becomes a `touch1-*` envelope measured in the fitted rect's own space, with that
    /// rect's size beside it — the host rescales from the space the coordinates were taken in, so a
    /// surface that did not travel with the point is a tap on the wrong pixel.
    func testEachContactBecomesATouchEnvelopeCarryingTheSurfaceItWasMeasuredIn() throws {
        let gesture = SimulatorScrollGesture()
        let opening = gesture.accept(
            delta: CGSize(width: 0, height: -20), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 120, y: 300), fitted: fitted, orientation: .portrait,
        )
        XCTAssertEqual(try types(opening), ["touch1-down", "touch1-move"])

        let down = try XCTUnwrap(try fields(XCTUnwrap(opening.first)))
        XCTAssertEqual(down["x"] as? Double, 120)
        XCTAssertEqual(down["width"] as? Double, 400)
        XCTAssertEqual(down["height"] as? Double, 800)

        XCTAssertEqual(try types(gesture.lift(in: fitted)), ["touch1-up"])
    }

    /// The handle is what carries the contact between events, which is the whole reason this is a
    /// class: a struct holding the pointer would free it once per copy while every copy still used it,
    /// and a struct holding the STATE would put the half that decides where the next plant lands back
    /// on this side of the boundary.
    func testTheFingerSurvivesBetweenEventsAndReadsBackThroughTheDoor() {
        let gesture = SimulatorScrollGesture()
        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 200, y: 400), fitted: fitted, orientation: .portrait,
        )
        XCTAssertEqual(gesture.finger, CGPoint(x: 200, y: 399))

        _ = gesture.accept(
            delta: CGSize(width: 0, height: -1), isPrecise: true, phase: .changed,
            pointer: CGPoint(x: 200, y: 400), fitted: fitted, orientation: .portrait,
        )
        XCTAssertEqual(gesture.finger, CGPoint(x: 200, y: 398))
    }

    /// A door answering zero contacts must come back as NO envelopes. An off-by-one in the delivery
    /// walk here would put a phantom release on the wire — a tap the user did not make.
    func testNoContactsComesBackAsNoEnvelopes() {
        let gesture = SimulatorScrollGesture()
        XCTAssertTrue(gesture.lift(in: fitted).isEmpty)

        _ = gesture.accept(
            delta: CGSize(width: 0, height: -10), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 200, y: 400), fitted: fitted, orientation: .portrait,
        )
        gesture.abandon()
        XCTAssertNil(gesture.finger)
        XCTAssertTrue(gesture.lift(in: fitted).isEmpty)
    }

    // MARK: Helpers

    private func fields(_ envelope: SimulatorInputEnvelope) throws -> [String: Any] {
        let json = try XCTUnwrap(envelope.json)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
        )
    }

    private func types(_ envelopes: [SimulatorInputEnvelope]) throws -> [String] {
        try envelopes.map { try XCTUnwrap(fields($0)["type"] as? String) }
    }
}
#endif
