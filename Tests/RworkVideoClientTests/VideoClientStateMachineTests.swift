import XCTest
@testable import RworkVideoClient
import RworkVideoProtocol

/// PURE client session state-machine transitions: hello on start, accept/reject of the
/// helloAck, idempotent duplicate ack, and bye/stop effects. No live component.
final class VideoClientStateMachineTests: XCTestCase {

    private func makeSM() -> VideoClientStateMachine {
        VideoClientStateMachine(requestedWindowID: 42, viewport: VideoSize(width: 1280, height: 800))
    }

    func testStartSendsHelloAndMovesToConnecting() {
        var sm = makeSM()
        let effects = sm.start()
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertEqual(effects.count, 1)
        guard case .sendControl(.hello(let version, let windowID, let viewport)) = effects.first else {
            return XCTFail("expected a hello effect, got \(effects)")
        }
        XCTAssertEqual(version, RworkVideoProtocol.version)
        XCTAssertEqual(windowID, 42)
        XCTAssertEqual(viewport, VideoSize(width: 1280, height: 800))
    }

    func testStartIsIdempotent() {
        var sm = makeSM()
        _ = sm.start()
        XCTAssertTrue(sm.start().isEmpty, "a second start while connecting emits nothing")
    }

    func testAcceptedHelloAckStartsPipelineAndStreams() {
        var sm = makeSM()
        _ = sm.start()
        let ack = VideoControlMessage.helloAck(accepted: true, streamID: 7, captureWidth: 1920, captureHeight: 1080, windowBoundsCG: VideoRect(x: 10, y: 20, width: 800, height: 600))
        let effects = sm.handleControl(ack)
        XCTAssertEqual(sm.state, .streaming)
        XCTAssertTrue(sm.mediaFlowing)
        XCTAssertEqual(sm.streamID, 7)
        XCTAssertEqual(sm.captureSize, VideoSize(width: 1920, height: 1080))
        XCTAssertEqual(sm.windowBoundsCG, VideoRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(effects, [.startDecodePipeline(captureSize: VideoSize(width: 1920, height: 1080), windowBoundsCG: VideoRect(x: 10, y: 20, width: 800, height: 600))])
    }

    func testRejectedHelloAckGoesToRejectedNoPipeline() {
        var sm = makeSM()
        _ = sm.start()
        let reject = VideoControlMessage.helloAck(accepted: false, streamID: 0, captureWidth: 0, captureHeight: 0, windowBoundsCG: VideoRect(x: 0, y: 0, width: 0, height: 0))
        let effects = sm.handleControl(reject)
        XCTAssertEqual(sm.state, .rejected)
        XCTAssertFalse(sm.mediaFlowing)
        XCTAssertTrue(effects.isEmpty)
    }

    func testDuplicateAckWhileStreamingIsIgnored() {
        var sm = makeSM()
        _ = sm.start()
        let ack = VideoControlMessage.helloAck(accepted: true, streamID: 7, captureWidth: 800, captureHeight: 600, windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600))
        _ = sm.handleControl(ack)
        // A retransmitted ack (UDP) must NOT restart the pipeline.
        let again = sm.handleControl(ack)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(sm.state, .streaming)
    }

    func testByeWhileStreamingStopsPipeline() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(accepted: true, streamID: 1, captureWidth: 800, captureHeight: 600, windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600)))
        let effects = sm.handleControl(.bye)
        XCTAssertEqual(sm.state, .stopped)
        XCTAssertEqual(effects, [.stopDecodePipeline])
    }

    func testStopWhileStreamingSendsByeAndStopsPipeline() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(accepted: true, streamID: 1, captureWidth: 800, captureHeight: 600, windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600)))
        let effects = sm.stop()
        XCTAssertEqual(sm.state, .stopped)
        XCTAssertEqual(effects, [.sendControl(.bye), .stopDecodePipeline])
    }

    func testStopWhileConnectingSendsByeOnly() {
        var sm = makeSM()
        _ = sm.start()
        let effects = sm.stop()
        XCTAssertEqual(sm.state, .stopped)
        XCTAssertEqual(effects, [.sendControl(.bye)])
    }

    // MARK: In-session resize — resizeAck → updateCaptureSize effect

    func testResizeAckWhileStreamingEmitsUpdateCaptureSize() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(accepted: true, streamID: 1, captureWidth: 800, captureHeight: 600, windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertEqual(sm.state, .streaming)

        let ack = VideoControlMessage.resizeAck(captureWidth: 1280, captureHeight: 800, epoch: 3)
        let effects = sm.handleControl(ack)
        XCTAssertEqual(effects, [.updateCaptureSize(VideoSize(width: 1280, height: 800))],
                       "a resizeAck while streaming stages the new capture size for frame-gated adoption")
        XCTAssertEqual(sm.state, .streaming, "a resize does not change the session state")
        XCTAssertTrue(sm.mediaFlowing)
    }

    func testResizeAckIgnoredWhenNotStreaming() {
        // Before streaming (connecting): a stray resizeAck is inert (nothing to re-base yet).
        var sm = makeSM()
        _ = sm.start()
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(sm.handleControl(.resizeAck(captureWidth: 1280, captureHeight: 800, epoch: 1)).isEmpty)

        // After bye/stop: a late resizeAck must not resurrect anything.
        var stopped = makeSM()
        _ = stopped.start()
        _ = stopped.handleControl(.helloAck(accepted: true, streamID: 1, captureWidth: 800, captureHeight: 600, windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600)))
        _ = stopped.handleControl(.bye)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertTrue(stopped.handleControl(.resizeAck(captureWidth: 1280, captureHeight: 800, epoch: 1)).isEmpty)
        XCTAssertEqual(stopped.state, .stopped)
    }

    func testResizeRequestNeverActedOnByClient() {
        // The client never RECEIVES a resizeRequest (host→client only is resizeAck) — defensive.
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(accepted: true, streamID: 1, captureWidth: 800, captureHeight: 600, windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertTrue(sm.handleControl(.resizeRequest(desired: VideoSize(width: 1, height: 1), epoch: 1)).isEmpty)
        XCTAssertEqual(sm.state, .streaming)
    }

    func testClientIgnoresHelloAndStrayAckWhenNotConnecting() {
        var sm = makeSM()
        // Before start: a stray ack does nothing (still idle).
        XCTAssertTrue(sm.handleControl(.helloAck(accepted: true, streamID: 1, captureWidth: 1, captureHeight: 1, windowBoundsCG: VideoRect(x: 0, y: 0, width: 1, height: 1))).isEmpty)
        XCTAssertEqual(sm.state, .idle)
        // A hello (host→client only) is never acted on.
        _ = sm.start()
        XCTAssertTrue(sm.handleControl(.hello(protocolVersion: 1, requestedWindowID: 1, viewport: VideoSize(width: 1, height: 1))).isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }
}
