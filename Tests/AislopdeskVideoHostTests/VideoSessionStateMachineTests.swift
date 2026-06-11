import XCTest
@testable import AislopdeskVideoHost
import AislopdeskVideoProtocol

/// PURE logic only — drives the host video session state machine with synthetic
/// control messages and asserts the transitions + emitted effects. NO live
/// SCStream / VTCompressionSession / socket is touched (hang-safety rule).
final class VideoSessionStateMachineTests: XCTestCase {
    private let bounds = VideoRect(x: 10, y: 20, width: 800, height: 600)
    private let acceptAll: (UInt32, VideoSize) -> (UInt16, UInt16)? = { _, _ in (800, 600) }

    func testStartGoesIdleToListening() {
        var sm = VideoSessionStateMachine()
        XCTAssertEqual(sm.state, .idle)
        let effects = sm.start()
        XCTAssertEqual(sm.state, .listening)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertFalse(sm.mediaFlowing)
    }

    func testValidHelloAcceptsAndStartsCapture() {
        var sm = VideoSessionStateMachine(nextStreamID: 7)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        let effects = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        XCTAssertEqual(sm.state, .streaming)
        XCTAssertTrue(sm.mediaFlowing)
        XCTAssertEqual(sm.windowID, 42)
        XCTAssertEqual(sm.captureWidth, 800)
        XCTAssertEqual(sm.captureHeight, 600)

        // Ack first, then start capture — in that order.
        XCTAssertEqual(effects.count, 2)
        guard case .sendControl(let ack) = effects[0] else { return XCTFail("expected sendControl first") }
        XCTAssertEqual(ack, .helloAck(accepted: true, streamID: 7, captureWidth: 800, captureHeight: 600, windowBoundsCG: bounds, fullRange: false))
        XCTAssertEqual(effects[1], .startCapture(windowID: 42, width: 800, height: 600))
    }

    func testFullRangeFlagStampedIntoAcceptAndReAckButNeverIntoReject() {
        // WF-6 (#8): a host configured full-range stamps fullRange=true into the accept ack AND the
        // duplicate re-ack (same value, the atomicity invariant), but a REJECT always sends false.
        var sm = VideoSessionStateMachine(nextStreamID: 1, fullRange: true)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        let accept = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(true, _, _, _, _, let frAccept)) = accept[0] else { return XCTFail("expected accept ack") }
        XCTAssertTrue(frAccept, "accept ack carries the host's full-range flag")

        // Duplicate hello while streaming → re-ack must echo the SAME range.
        let again = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(true, _, _, _, _, let frReAck)) = again[0] else { return XCTFail("expected re-ack") }
        XCTAssertTrue(frReAck, "re-ack echoes the same full-range value")

        // A reject (here: a wrong-window resolveCaptureSize → nil) always sends fullRange:false.
        var rej = VideoSessionStateMachine(nextStreamID: 1, fullRange: true)
        _ = rej.start()
        let reject = rej.handleControl(hello, windowBoundsCG: bounds) { _, _ in nil }
        guard case .sendControl(.helloAck(false, _, _, _, _, let frReject)) = reject[0] else { return XCTFail("expected reject ack") }
        XCTAssertFalse(frReject, "a reject never advertises full-range")
    }

    func testDefaultStateMachineIsVideoRange() {
        // WF-6 (#8): the default (no fullRange arg) is video-range — the OFF path the wire-byte-identity
        // guard depends on.
        var sm = VideoSessionStateMachine(nextStreamID: 1)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        let accept = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(_, _, _, _, _, let fr)) = accept[0] else { return XCTFail("expected ack") }
        XCTAssertFalse(fr, "default host is video-range (OFF)")
    }

    func testFocusWindowIsAStateMachineNoOp() {
        // `focusWindow` (the raise-the-focused-pane's-window model) is actioned at the ACTOR level
        // (AislopdeskVideoHostSession raises the captured window); the pure SM must treat it as an inert
        // no-op in BOTH listening and streaming — no effects, no state change, no capture churn.
        var sm = VideoSessionStateMachine(nextStreamID: 7)
        _ = sm.start()
        XCTAssertTrue(sm.handleControl(.focusWindow, windowBoundsCG: bounds, resolveCaptureSize: acceptAll).isEmpty,
                      "focusWindow yields no effects while listening")
        XCTAssertEqual(sm.state, .listening)

        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .streaming)
        XCTAssertTrue(sm.handleControl(.focusWindow, windowBoundsCG: bounds, resolveCaptureSize: acceptAll).isEmpty,
                      "focusWindow yields no effects while streaming")
        XCTAssertEqual(sm.state, .streaming, "focusWindow must not perturb the streaming state")
        XCTAssertTrue(sm.mediaFlowing)
    }

    func testWrongProtocolVersionRejected() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let badVersion: UInt16 = AislopdeskVideoProtocol.version &+ 1
        let hello = VideoControlMessage.hello(protocolVersion: badVersion, requestedWindowID: 1, viewport: VideoSize(width: 100, height: 100))
        let effects = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        XCTAssertEqual(sm.state, .listening) // stayed listening — no accept
        XCTAssertFalse(sm.mediaFlowing)
        XCTAssertEqual(effects.count, 1)
        guard case .sendControl(.helloAck(let accepted, _, _, _, _, _)) = effects[0] else { return XCTFail("expected reject ack") }
        XCTAssertFalse(accepted)
    }

    func testResolveCaptureSizeNilRejects() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 99, viewport: VideoSize(width: 1, height: 1))
        let effects = sm.handleControl(hello, windowBoundsCG: bounds) { _, _ in nil } // host rejects this window

        XCTAssertEqual(sm.state, .listening)
        XCTAssertEqual(effects.count, 1)
        guard case .sendControl(.helloAck(let accepted, _, _, _, _, _)) = effects[0] else { return XCTFail("expected reject") }
        XCTAssertFalse(accepted)
    }

    func testDuplicateHelloWhileStreamingReAcksWithoutRestartingCapture() {
        var sm = VideoSessionStateMachine(nextStreamID: 3)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        // Client retransmits the (unreliable UDP) hello for the SAME window.
        let again = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .streaming)
        // Re-ack only — NO second startCapture.
        XCTAssertEqual(again.count, 1)
        guard case .sendControl(.helloAck(let accepted, let streamID, _, _, _, _)) = again[0] else { return XCTFail("expected re-ack") }
        XCTAssertTrue(accepted)
        XCTAssertEqual(streamID, 3, "re-ack keeps the same streamID, does not mint a new one")
    }

    func testByeStopsCapture() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        let effects = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        // Bye re-arms (intended behavior change for #8): state returns to .listening
        // — NOT terminal .stopped — so a fresh hello can reconnect. Capture still tears
        // down because it was streaming.
        XCTAssertEqual(sm.state, .listening)
        XCTAssertFalse(sm.mediaFlowing)
        XCTAssertEqual(effects, [.stopCapture])
    }

    func testByeReturnsToListeningNotStopped() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .streaming)

        _ = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .listening, "bye must re-arm to .listening, not go terminal")
        XCTAssertFalse(sm.mediaFlowing)
    }

    func testHelloAfterByeReArmsCaptureWithFreshStreamID() {
        var sm = VideoSessionStateMachine(nextStreamID: 5)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        let first = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(_, let firstStreamID, _, _, _, _)) = first[0] else { return XCTFail("expected first ack") }
        XCTAssertEqual(firstStreamID, 5)

        // Client says bye, then reconnects with a fresh hello — no daemon restart.
        _ = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .listening)

        let reconnect = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .streaming)
        XCTAssertTrue(sm.mediaFlowing)
        XCTAssertEqual(sm.windowID, 42)
        XCTAssertEqual(sm.captureWidth, 800)
        XCTAssertEqual(sm.captureHeight, 600)

        // Ack (with an ADVANCED streamID) first, then a fresh startCapture.
        XCTAssertEqual(reconnect.count, 2)
        guard case .sendControl(.helloAck(let accepted, let streamID, let w, let h, _, _)) = reconnect[0] else { return XCTFail("expected reconnect ack") }
        XCTAssertTrue(accepted)
        XCTAssertEqual(streamID, 6, "the second hello mints a fresh, advanced streamID")
        XCTAssertEqual(w, 800)
        XCTAssertEqual(h, 600)
        XCTAssertEqual(reconnect[1], .startCapture(windowID: 42, width: 800, height: 600))
    }

    func testByeWhileListeningIsIdempotentNoStopCapture() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        XCTAssertEqual(sm.state, .listening)

        // A bye arriving while merely listening (no stream up) re-arms harmlessly: no
        // stopCapture (nothing was running) and state stays .listening.
        let effects = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .listening)
        XCTAssertTrue(effects.isEmpty, "no capture was running, so no stopCapture")
        XCTAssertFalse(sm.mediaFlowing)
    }

    func testByeWhileIdleStaysIdleNoEffects() {
        var sm = VideoSessionStateMachine()
        // No start() — sockets not bound; a bye must not transition or emit anything.
        let effects = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertFalse(sm.mediaFlowing)
    }

    func testLocalStopRemainsTerminalAfterFix() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        // Local stop() closes the UDP sockets — it MUST stay terminal (.stopped), unlike
        // a client bye. A hello after a local stop is rejected (no re-arm).
        XCTAssertEqual(sm.stop(), [.stopCapture])
        XCTAssertEqual(sm.state, .stopped)
        let afterStop = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .stopped, "local stop() is terminal — a hello must not re-arm it")
        XCTAssertTrue(afterStop.isEmpty)
        XCTAssertFalse(sm.mediaFlowing)
    }

    func testMultipleByeHelloCyclesEachGetFreshStreamID() {
        var sm = VideoSessionStateMachine(nextStreamID: 1)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))

        var seenStreamIDs: [UInt32] = []
        for _ in 0..<4 {
            let accept = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
            XCTAssertEqual(sm.state, .streaming)
            guard case .sendControl(.helloAck(let accepted, let streamID, _, _, _, _)) = accept[0] else { return XCTFail("expected ack") }
            XCTAssertTrue(accepted)
            seenStreamIDs.append(streamID)
            XCTAssertEqual(accept[1], .startCapture(windowID: 42, width: 800, height: 600))

            _ = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
            XCTAssertEqual(sm.state, .listening)
        }

        // Every reconnect cycle minted a fresh, monotonically advancing streamID.
        XCTAssertEqual(seenStreamIDs, [1, 2, 3, 4])
    }

    func testStopWhileStreamingEmitsStopCapture() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.stop(), [.stopCapture])
        XCTAssertEqual(sm.state, .stopped)
        // A second stop is a no-op.
        XCTAssertTrue(sm.stop().isEmpty)
    }

    func testStopWhileMerelyListeningEmitsNothing() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        XCTAssertTrue(sm.stop().isEmpty)
        XCTAssertEqual(sm.state, .stopped)
    }

    func testHelloIgnoredBeforeStart() {
        var sm = VideoSessionStateMachine()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 1, viewport: VideoSize(width: 1, height: 1))
        // No start() — state is .idle, a hello must not accept.
        let effects = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(effects.isEmpty)
    }

    func testEachAcceptedSessionGetsAFreshStreamID() {
        var a = VideoSessionStateMachine(nextStreamID: 1)
        _ = a.start()
        let hello = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 5, viewport: VideoSize(width: 10, height: 10))
        let e1 = a.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(_, let s1, _, _, _, _)) = e1[0] else { return XCTFail() }
        XCTAssertEqual(s1, 1)

        var b = VideoSessionStateMachine(nextStreamID: 2)
        _ = b.start()
        let e2 = b.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(_, let s2, _, _, _, _)) = e2[0] else { return XCTFail() }
        XCTAssertEqual(s2, 2)
    }
}
