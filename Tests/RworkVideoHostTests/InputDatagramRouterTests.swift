import XCTest
@testable import RworkVideoHost
import RworkVideoProtocol

/// PURE input-routing decision logic. Decides inject/drop/ignore + the raise latch
/// WITHOUT an `InputInjector` (which would post real CGEvents). No socket, no CGEvent.
final class InputDatagramRouterTests: XCTestCase {
    private let router = InputDatagramRouter()
    private let n = VideoPoint(x: 0.5, y: 0.5)

    func testIgnoresWhenNotStreaming() {
        let datagram = InputEvent.mouseMove(normalized: n, tag: 1).encode()
        XCTAssertEqual(router.route(datagram: datagram, mediaFlowing: false, needsRaise: true), .ignoreNotStreaming)
    }

    func testDropsUndecodableDatagram() {
        let garbage = Data([0xFF, 0x00, 0x01]) // unknown event type 0xFF
        let decision = router.route(datagram: garbage, mediaFlowing: true, needsRaise: false)
        guard case .drop = decision else { return XCTFail("expected drop, got \(decision)") }
    }

    func testInjectsDecodableEvent() {
        let event = InputEvent.text("hi", tag: 9)
        let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: false)
        guard case .inject(let decoded, let raiseFirst) = decision else { return XCTFail("expected inject") }
        XCTAssertEqual(decoded, event)
        XCTAssertFalse(raiseFirst, "text does not raise unless the latch is armed")
    }

    func testNeedsRaiseLatchForcesRaiseOnAnyEvent() {
        let event = InputEvent.key(keyCode: 0x24, down: true, modifiers: [], tag: 0)
        let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: true)
        guard case .inject(_, let raiseFirst) = decision else { return XCTFail("expected inject") }
        XCTAssertTrue(raiseFirst, "an armed latch raises even for a key event")
    }

    func testMouseDownAlwaysRaisesRegardlessOfLatch() {
        let event = InputEvent.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)
        let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: false)
        guard case .inject(_, let raiseFirst) = decision else { return XCTFail("expected inject") }
        XCTAssertTrue(raiseFirst, "a pointer button-down always raises+focuses first (doc 18 §A)")
    }

    func testMoveScrollKeyTextDoNotRaiseWithLatchClear() {
        let events: [InputEvent] = [
            .mouseMove(normalized: n, tag: 0),
            .mouseDrag(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0),
            .scroll(dx: 1, dy: -2, normalized: n, tag: 0),
            .key(keyCode: 1, down: true, modifiers: [], tag: 0),
            .text("x", tag: 0),
            .mouseUp(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0),
        ]
        for event in events {
            let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: false)
            guard case .inject(_, let raiseFirst) = decision else { return XCTFail("expected inject for \(event)") }
            XCTAssertFalse(raiseFirst, "\(event) must not raise when the latch is clear")
        }
    }

    func testRearmRaiseAfterMouseUpOnly() {
        XCTAssertTrue(InputDatagramRouter.rearmRaiseAfter(.mouseUp(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.mouseMove(normalized: n, tag: 0)))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.mouseDrag(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.text("x", tag: 0)))
    }

    /// Simulates a full click sequence's latch evolution as the actor would track it:
    /// initial event raises (armed), down raises, up re-arms, next event raises again.
    func testRaiseLatchEvolutionAcrossClickSequence() {
        var needsRaise = true // actor starts armed
        func step(_ event: InputEvent) -> Bool {
            let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: needsRaise)
            guard case .inject(_, let raiseFirst) = decision else { XCTFail(); return false }
            needsRaise = InputDatagramRouter.rearmRaiseAfter(event)
            return raiseFirst
        }
        XCTAssertTrue(step(.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)), "first event raises (armed) + is a button-down")
        XCTAssertFalse(step(.mouseMove(normalized: n, tag: 0)), "mid-drag move does not re-raise (latch cleared after the down)")
        XCTAssertFalse(step(.mouseUp(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)), "the up itself does not raise; it RE-ARMS the latch for the NEXT event")
        // The up re-armed the latch → the next event raises (and is also a button-down).
        XCTAssertTrue(step(.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)), "next click raises again (latch re-armed by the prior up)")
    }
}
