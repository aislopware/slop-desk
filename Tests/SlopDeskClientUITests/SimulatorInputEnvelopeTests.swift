// SimulatorInputEnvelopeTests — pins the client→host JSON dialect. Whole-string assertions are
// possible because the encoder sorts keys; they are used deliberately, since a silently renamed or
// dropped field here produces a gesture the server ignores with no error anywhere.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class SimulatorInputEnvelopeTests: XCTestCase {
    private let surface = SimulatorInputEnvelope.Surface(width: 400, height: 800)

    func testTapCarriesItsPointAndTheSurfaceItWasMeasuredIn() {
        // The surface travels with EVERY positional envelope — the host rescales to the device's real
        // framebuffer, which is what lets this side send view-space points with no DPI maths and stay
        // correct across a resize mid-gesture.
        // The duration reads as 0.050000000000000003 because 0.05 has no exact binary form and
        // `JSONSerialization` prints full precision rather than the shortest round-trip. Harmless —
        // it parses back to the same double server-side — and pinned verbatim so the next reader
        // does not "fix" it into a mismatch.
        XCTAssertEqual(
            SimulatorInputEnvelope.tap(x: 10, y: 20, in: surface).json,
            #"{"duration":0.050000000000000003,"height":800,"type":"tap","width":400,"x":10,"y":20}"#,
        )
    }

    func testALongPressIsATapWithADuration() {
        // There is no separate long-press verb on this wire; getting that wrong means reaching for a
        // message the server has no case for.
        XCTAssertEqual(
            SimulatorInputEnvelope.tap(x: 1, y: 2, duration: 1.5, in: surface).json,
            #"{"duration":1.5,"height":800,"type":"tap","width":400,"x":1,"y":2}"#,
        )
    }

    func testSwipeUsesStartEndNamesRatherThanAPointPair() {
        XCTAssertEqual(
            SimulatorInputEnvelope.swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, in: surface).json,
            #"{"duration":0.25,"endX":3,"endY":4,"height":800,"startX":1,"startY":2,"type":"swipe","width":400}"#,
        )
    }

    func testEachTouchPhaseGetsItsOwnTypeName() {
        for phase in [SimulatorInputEnvelope.TouchPhase.down, .move, .up] {
            let json = SimulatorInputEnvelope.touch(phase, x: 5, y: 6, in: surface).json
            XCTAssertEqual(json, #"{"height":800,"type":"touch1-\#(phase.rawValue)","width":400,"x":5,"y":6}"#)
        }
    }

    func testTheEdgeHintIsOmittedUnlessTheGestureStartedOffScreen() {
        // Its presence is what distinguishes a bezel swipe (home, app switcher, notification centre)
        // from a content swipe. Sending it always would make every drag a system gesture.
        XCTAssertFalse(SimulatorInputEnvelope.touch(.down, x: 5, y: 6, in: surface).json?.contains("edge") ?? true)
        XCTAssertEqual(
            SimulatorInputEnvelope.touch(.down, x: 5, y: 6, edge: "bottom", in: surface).json,
            #"{"edge":"bottom","height":800,"type":"touch1-down","width":400,"x":5,"y":6}"#,
        )
    }

    func testTwoFingerTouchNamesItsPointsSeparately() {
        XCTAssertEqual(
            SimulatorInputEnvelope.touch2(.move, x1: 1, y1: 2, x2: 3, y2: 4, in: surface).json,
            #"{"height":800,"type":"touch2-move","width":400,"x1":1,"x2":3,"y1":2,"y2":4}"#,
        )
    }

    func testAButtonPressCarriesNoDurationUnlessItIsHeld() {
        // A held side button summons the power slider; a tapped one locks. Emitting `duration: 0`
        // would ask the server to interpret a zero-length hold.
        XCTAssertEqual(SimulatorInputEnvelope.button("home").json, #"{"button":"home","type":"button"}"#)
        XCTAssertEqual(
            SimulatorInputEnvelope.button("lock", hold: 2).json,
            #"{"button":"lock","duration":2,"type":"button"}"#,
        )
    }

    func testAKeyCarriesModifiersOnlyWhenThereAreSome() {
        XCTAssertEqual(SimulatorInputEnvelope.key("KeyA").json, #"{"code":"KeyA","type":"key"}"#)
        XCTAssertEqual(
            SimulatorInputEnvelope.key("KeyA", modifiers: [.command, .shift]).json,
            #"{"code":"KeyA","modifiers":["command","shift"],"type":"key"}"#,
        )
    }

    func testTextVerbsAreDistinctBecauseTheirReachIs() {
        // `type` synthesizes keystrokes and is US-ASCII only; `paste` goes via the pasteboard and is
        // the only path that carries emoji or CJK. Collapsing them silently drops characters.
        XCTAssertEqual(SimulatorInputEnvelope.type("hi").json, #"{"text":"hi","type":"type"}"#)
        XCTAssertEqual(SimulatorInputEnvelope.paste("😀").json, #"{"text":"😀","type":"paste"}"#)
        XCTAssertEqual(SimulatorInputEnvelope.copy().json, #"{"type":"copy"}"#)
    }

    func testTextIsJSONEscapedRatherThanInterpolated() {
        // The one field carrying arbitrary user input. Hand-building the JSON string instead of
        // serializing would break the message on the first quote someone types.
        XCTAssertEqual(
            SimulatorInputEnvelope.type("say \"hi\"\n").json,
            #"{"text":"say \"hi\"\n","type":"type"}"#,
        )
    }
}
#endif
