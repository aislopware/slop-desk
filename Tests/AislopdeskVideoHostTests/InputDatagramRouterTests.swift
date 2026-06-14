import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

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
        guard case .drop = decision else { XCTFail("expected drop, got \(decision)")
            return
        }
    }

    func testInjectsDecodableEvent() {
        let event = InputEvent.text("hi", tag: 9)
        let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: false)
        guard case let .inject(decoded, raiseFirst) = decision else { XCTFail("expected inject")
            return
        }
        XCTAssertEqual(decoded, event)
        XCTAssertFalse(raiseFirst, "text does not raise unless the latch is armed")
    }

    func testArmedLatchRaisesKeyButExemptsScroll() {
        // A key with the latch armed raises (it needs key focus)...
        let key = InputEvent.key(keyCode: 0x24, down: true, modifiers: [], tag: 0)
        guard case let .inject(_, keyRaises) = router
            .route(datagram: key.encode(), mediaFlowing: true, needsRaise: true)
        else {
            XCTFail("expected inject for key")
            return
        }
        XCTAssertTrue(keyRaises, "an armed latch raises a key event (it needs key focus)")

        // ...but a SCROLL is exempt: it goes to the window under the cursor regardless of focus, so it
        // never pays the expensive AX raise even when the post-click latch is armed (the scroll-latency fix).
        let scroll = InputEvent.scroll(dx: 0, dy: -3, normalized: n, tag: 0)
        guard case let .inject(_, scrollRaises) = router.route(
            datagram: scroll.encode(),
            mediaFlowing: true,
            needsRaise: true,
        ) else {
            XCTFail("expected inject for scroll")
            return
        }
        XCTAssertFalse(scrollRaises, "an armed latch must NOT raise a scroll (latch-exempt)")
    }

    func testScrollIsTheOnlyLatchExemptEvent() {
        XCTAssertTrue(InputDatagramRouter.latchExemptFromRaise(.scroll(dx: 1, dy: 1, normalized: n, tag: 0)))
        XCTAssertFalse(InputDatagramRouter.latchExemptFromRaise(.mouseMove(normalized: n, tag: 0)))
        XCTAssertFalse(InputDatagramRouter.latchExemptFromRaise(.mouseDown(
            button: .left,
            normalized: n,
            clickCount: 1,
            modifiers: [],
            tag: 0,
        )))
        XCTAssertFalse(InputDatagramRouter.latchExemptFromRaise(.mouseUp(
            button: .left,
            normalized: n,
            clickCount: 1,
            modifiers: [],
            tag: 0,
        )))
        XCTAssertFalse(InputDatagramRouter.latchExemptFromRaise(.key(keyCode: 1, down: true, modifiers: [], tag: 0)))
        XCTAssertFalse(InputDatagramRouter.latchExemptFromRaise(.text("x", tag: 0)))
    }

    func testMouseDownAlwaysRaisesRegardlessOfLatch() {
        let event = InputEvent.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)
        let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: false)
        guard case let .inject(_, raiseFirst) = decision else { XCTFail("expected inject")
            return
        }
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
            guard case let .inject(_, raiseFirst) = decision else { XCTFail("expected inject for \(event)")
                return
            }
            XCTAssertFalse(raiseFirst, "\(event) must not raise when the latch is clear")
        }
    }

    func testRearmRaiseAfterMouseUpOnly() {
        XCTAssertTrue(InputDatagramRouter.rearmRaiseAfter(.mouseUp(
            button: .left,
            normalized: n,
            clickCount: 1,
            modifiers: [],
            tag: 0,
        )))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.mouseDown(
            button: .left,
            normalized: n,
            clickCount: 1,
            modifiers: [],
            tag: 0,
        )))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.mouseMove(normalized: n, tag: 0)))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.mouseDrag(
            button: .left,
            normalized: n,
            clickCount: 1,
            modifiers: [],
            tag: 0,
        )))
        XCTAssertFalse(InputDatagramRouter.rearmRaiseAfter(.text("x", tag: 0)))
    }

    /// Simulates a full click sequence's latch evolution as the actor would track it:
    /// initial event raises (armed), down raises, up re-arms, next event raises again.
    func testRaiseLatchEvolutionAcrossClickSequence() {
        var needsRaise = true // actor starts armed
        func step(_ event: InputEvent) -> Bool {
            let decision = router.route(datagram: event.encode(), mediaFlowing: true, needsRaise: needsRaise)
            guard case let .inject(_, raiseFirst) = decision else { XCTFail()
                return false
            }
            needsRaise = InputDatagramRouter.rearmRaiseAfter(event)
            return raiseFirst
        }
        XCTAssertTrue(
            step(.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)),
            "first event raises (armed) + is a button-down",
        )
        XCTAssertFalse(
            step(.mouseMove(normalized: n, tag: 0)),
            "mid-drag move does not re-raise (latch cleared after the down)",
        )
        XCTAssertFalse(
            step(.mouseUp(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)),
            "the up itself does not raise; it RE-ARMS the latch for the NEXT event",
        )
        // The up re-armed the latch → the next event raises (and is also a button-down).
        XCTAssertTrue(
            step(.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)),
            "next click raises again (latch re-armed by the prior up)",
        )
    }

    /// The canonical "click a pane, then scroll, then type" gesture, modelled with the EXACT actor
    /// latch logic (`AislopdeskVideoHostSession.inject` clears the latch only when it actually raises, and
    /// re-arms after a mouse-up). Proves the scroll-latency fix: the post-click scroll is exempt (no
    /// AX raise) AND does not consume the latch, so a key arriving after it still re-raises.
    func testPostClickScrollIsExemptButLeavesLatchForFollowingKey() {
        var needsRaise = true // actor starts armed
        func step(_ event: InputEvent) -> Bool {
            let raiseFirst = InputDatagramRouter.raiseFirst(for: event, needsRaise: needsRaise)
            if raiseFirst { needsRaise = false } // actor clears the latch before raising
            if InputDatagramRouter.rearmRaiseAfter(event) { needsRaise = true } // a mouse-up re-arms it
            return raiseFirst
        }
        XCTAssertTrue(
            step(.mouseDown(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)),
            "click raises (button-down)",
        )
        XCTAssertFalse(
            step(.mouseUp(button: .left, normalized: n, clickCount: 1, modifiers: [], tag: 0)),
            "the up re-arms the latch",
        )
        XCTAssertFalse(
            step(.scroll(dx: 0, dy: -5, normalized: n, tag: 0)),
            "the post-click scroll is latch-exempt → NO AX raise (the fix)",
        )
        XCTAssertTrue(
            step(.key(keyCode: 0x24, down: true, modifiers: [], tag: 0)),
            "a key after the scroll still raises (the exempt scroll did not consume the armed latch)",
        )
    }
}
