// DisplayClientStateMachineTests — pins the client SM's DISPLAY target (the full-desktop pane):
// `.display` sends the wire `helloDisplay` (never `hello`), the retry re-emits the same message,
// and everything downstream of the ack (pipeline bring-up) is target-agnostic.

import XCTest
@testable import SlopDeskVideoClient
@testable import SlopDeskVideoProtocol

final class DisplayClientStateMachineTests: XCTestCase {
    func testDisplayTargetSendsHelloDisplay() {
        var sm = VideoClientStateMachine(
            target: .display(0), viewport: VideoSize(width: 1280, height: 800),
        )
        let effects = sm.start()
        XCTAssertEqual(effects, [.primeCursorFlow, .sendControl(.helloDisplay(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedDisplayID: 0,
            viewport: VideoSize(width: 1280, height: 800),
        ))])
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertEqual(sm.requestedWindowID, 0, "a display target has no window id")
    }

    func testResendHelloReEmitsHelloDisplay() {
        var sm = VideoClientStateMachine(
            target: .display(7), viewport: VideoSize(width: 640, height: 480),
        )
        _ = sm.start()
        let retry = sm.resendHello()
        // The re-prime matters MOST here: the desktop pane that sat `.connecting` across a host
        // daemon restart reconnects via this retry — without the prime its cursor channel is dead
        // (shape stuck on the default arrow) even though video and input recover.
        XCTAssertEqual(retry, [.primeCursorFlow, .sendControl(.helloDisplay(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedDisplayID: 7,
            viewport: VideoSize(width: 640, height: 480),
        ))])
    }

    /// The window-init convenience is byte-identical to the old shape — a `.window` target still
    /// sends the classic `hello`.
    func testWindowConvenienceInitStillSendsHello() {
        var sm = VideoClientStateMachine(
            requestedWindowID: 42, viewport: VideoSize(width: 100, height: 100),
        )
        XCTAssertEqual(sm.target, .window(42))
        let effects = sm.start()
        XCTAssertEqual(effects, [.primeCursorFlow, .sendControl(.hello(
            protocolVersion: SlopDeskVideoProtocol.version,
            requestedWindowID: 42,
            viewport: VideoSize(width: 100, height: 100),
        ))])
    }

    /// An accepted ack starts the pipeline exactly like a window session — the bounds carry the
    /// display's CG rect and the capture size its point size.
    func testAcceptedAckStartsPipelineForDisplayTarget() {
        var sm = VideoClientStateMachine(
            target: .display(0), viewport: VideoSize(width: 1280, height: 800),
        )
        _ = sm.start()
        let bounds = VideoRect(x: 0, y: 0, width: 2560, height: 1440)
        let effects = sm.handleControl(.helloAck(
            accepted: true, streamID: 9, captureWidth: 2560, captureHeight: 1440,
            windowBoundsCG: bounds, fullRange: false,
        ))
        XCTAssertEqual(effects, [.startDecodePipeline(
            captureSize: VideoSize(width: 2560, height: 1440),
            windowBoundsCG: bounds,
            fullRange: false,
        )])
        XCTAssertEqual(sm.state, .streaming)
    }

    /// `VideoWindowConnection.streamTarget`: a set displayID wins over the window id.
    func testConnectionStreamTargetPrefersDisplay() {
        let windowConn = VideoWindowConnection(host: "h", mediaPort: 1, cursorPort: 2, windowID: 42)
        XCTAssertEqual(windowConn.streamTarget, .window(42))
        let displayConn = VideoWindowConnection(
            host: "h", mediaPort: 1, cursorPort: 2, windowID: 0, displayID: 3,
        )
        XCTAssertEqual(displayConn.streamTarget, .display(3))
    }
}
