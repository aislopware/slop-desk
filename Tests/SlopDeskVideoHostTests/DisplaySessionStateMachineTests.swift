// DisplaySessionStateMachineTests — pins the host SM's `helloDisplay` arm (the full-desktop pane):
// same accept/reject/duplicate discipline as the window `hello`, resolved through the DISPLAY
// closure; a display session REJECTS in-session resizes (the display's size is fixed — the client
// letterboxes); the two hello kinds never cross-re-ack.

import XCTest
@testable import SlopDeskVideoHost
@testable import SlopDeskVideoProtocol

final class DisplaySessionStateMachineTests: XCTestCase {
    private let bounds = VideoRect(x: 0, y: 0, width: 2560, height: 1440)

    private func helloDisplay(_ id: UInt32 = 1) -> VideoControlMessage {
        .helloDisplay(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedDisplayID: id,
            viewport: VideoSize(width: 1280, height: 800),
        )
    }

    private let resolveDisplay: (UInt32, VideoSize) -> (UInt16, UInt16)? = { _, _ in (2560, 1440) }

    func testHelloDisplayAcceptsThroughTheDisplayResolver() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let effects = sm.handleControl(
            helloDisplay(), windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in nil }, // the WINDOW resolver must not be consulted
            resolveDisplayCaptureSize: resolveDisplay,
        )
        XCTAssertEqual(effects.count, 2)
        guard case let .sendControl(.helloAck(accepted, _, cw, ch, ackBounds, _)) = effects[0] else {
            XCTFail("first effect is the ack")
            return
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(cw, 2560)
        XCTAssertEqual(ch, 1440)
        XCTAssertEqual(ackBounds, bounds, "the ack carries the DISPLAY's CG bounds")
        guard case .startCapture = effects[1] else {
            XCTFail("second effect starts capture")
            return
        }
        XCTAssertTrue(sm.isDisplayTarget)
        XCTAssertEqual(sm.state, .streaming)
    }

    /// The default (nil-returning) display resolver rejects — a WINDOW session never accepts a
    /// display hello.
    func testWindowSessionRejectsHelloDisplayByDefault() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let effects = sm.handleControl(
            helloDisplay(), windowBoundsCG: bounds, resolveCaptureSize: { _, _ in (800, 600) },
        )
        guard case let .sendControl(.helloAck(accepted, _, _, _, _, _)) = effects.first else {
            XCTFail("a refusal ack is sent")
            return
        }
        XCTAssertFalse(accepted)
        XCTAssertEqual(sm.state, .listening, "a refusal leaves the session re-armable")
    }

    /// A duplicate helloDisplay while streaming re-acks idempotently; a WINDOW hello naming the
    /// SAME numeric id does NOT (id spaces differ — kind is part of the match).
    func testDuplicateReAckMatchesOnIdAndKind() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        _ = sm.handleControl(
            helloDisplay(1), windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in nil }, resolveDisplayCaptureSize: resolveDisplay,
        )
        let dup = sm.handleControl(
            helloDisplay(1), windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in nil }, resolveDisplayCaptureSize: resolveDisplay,
        )
        XCTAssertEqual(dup.count, 1, "a duplicate re-acks without restarting capture")
        guard case .sendControl(.helloAck(true, _, _, _, _, _)) = dup[0] else {
            XCTFail("the duplicate answer is an accepted re-ack")
            return
        }
        let windowHello = VideoControlMessage.hello(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedWindowID: 1, // same number, different id space
            viewport: VideoSize(width: 1280, height: 800),
        )
        let crossed = sm.handleControl(
            windowHello, windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in (800, 600) }, resolveDisplayCaptureSize: resolveDisplay,
        )
        XCTAssertTrue(crossed.isEmpty, "a window hello never re-acks a display session")
    }

    /// A display session rejects `resizeRequest` outright — the display never resizes.
    func testDisplaySessionRejectsResize() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        _ = sm.handleControl(
            helloDisplay(), windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in nil }, resolveDisplayCaptureSize: resolveDisplay,
        )
        let effects = sm.handleControl(
            .resizeRequest(desired: VideoSize(width: 640, height: 480), epoch: 1),
            windowBoundsCG: bounds,
            resolveCaptureSize: { _, _ in nil },
            resolveResizeSize: { _, _ in (640, 480) }, // even a willing resolver is never consulted
            resolveDisplayCaptureSize: resolveDisplay,
        )
        XCTAssertTrue(effects.isEmpty, "a display target never resizes (the client letterboxes)")
        XCTAssertEqual(sm.captureWidth, 2560, "the negotiated size is untouched")
    }
}
