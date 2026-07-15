import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

/// PURE client session state-machine transitions: hello on start, accept/reject of the
/// helloAck, idempotent duplicate ack, and bye/stop effects. No live component.
final class VideoClientStateMachineTests: XCTestCase {
    private func makeSM() -> VideoClientStateMachine {
        VideoClientStateMachine(requestedWindowID: 42, viewport: VideoSize(width: 1280, height: 800))
    }

    func testStartSendsCursorPrimeThenHelloAndMovesToConnecting() {
        var sm = makeSM()
        let effects = sm.start()
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(
            effects.first, .primeCursorFlow,
            "every hello rides with a cursor-flow prime (the cursor socket has no other client→host traffic)",
        )
        guard case let .sendControl(.hello(version, windowID, viewport)) = effects.last else {
            XCTFail("expected a hello effect, got \(effects)")
            return
        }
        XCTAssertEqual(version, SlopDeskVideoProtocol.version)
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
        // A full-range ack must carry fullRange:true through to the startDecodePipeline effect.
        let ack = VideoControlMessage.helloAck(
            accepted: true,
            streamID: 7,
            captureWidth: 1920,
            captureHeight: 1080,
            windowBoundsCG: VideoRect(x: 10, y: 20, width: 800, height: 600),
            fullRange: true,
        )
        let effects = sm.handleControl(ack)
        XCTAssertEqual(sm.state, .streaming)
        XCTAssertTrue(sm.mediaFlowing)
        XCTAssertEqual(sm.streamID, 7)
        XCTAssertEqual(sm.captureSize, VideoSize(width: 1920, height: 1080))
        XCTAssertEqual(sm.windowBoundsCG, VideoRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(
            effects,
            [.startDecodePipeline(
                captureSize: VideoSize(width: 1920, height: 1080),
                windowBoundsCG: VideoRect(x: 10, y: 20, width: 800, height: 600),
                fullRange: true,
            )],
        )
    }

    func testRejectedHelloAckGoesToRejectedAndSurfacesTerminalEffect() {
        var sm = makeSM()
        _ = sm.start()
        let reject = VideoControlMessage.helloAck(
            accepted: false,
            streamID: 0,
            captureWidth: 0,
            captureHeight: 0,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 0, height: 0),
            fullRange: false,
        )
        let effects = sm.handleControl(reject)
        XCTAssertEqual(sm.state, .rejected)
        XCTAssertFalse(sm.mediaFlowing)
        // `.rejected` must not be a DEAD END — zero effects would leave nothing up the stack
        // learning about it; retry correctly stops but the pane would freeze on a black surface
        // forever. The transition must surface `.sessionRejectedByHost` — a TERMINAL effect DISTINCT from
        // `.sessionEndedByHost` (whose pipeline handler auto-rebuilds and re-hellos: a rejection
        // entering that loop would re-send the same doomed hello forever). No decode pipeline was
        // ever started, so no `.stopDecodePipeline` rides along.
        XCTAssertEqual(effects, [.sessionRejectedByHost])
    }

    func testDuplicateRejectedAckAfterRejectionIsInert() {
        // UDP can deliver the refusal more than once (and the host re-refuses each retried hello
        // that raced the first refusal) — only the FIRST rejection may surface the terminal effect,
        // or the pane model would be told to fall back repeatedly.
        var sm = makeSM()
        _ = sm.start()
        let reject = VideoControlMessage.helloAck(
            accepted: false,
            streamID: 0,
            captureWidth: 0,
            captureHeight: 0,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 0, height: 0),
            fullRange: false,
        )
        _ = sm.handleControl(reject)
        XCTAssertEqual(sm.state, .rejected)
        XCTAssertTrue(sm.handleControl(reject).isEmpty, "a duplicate refusal emits nothing")
        XCTAssertEqual(sm.state, .rejected)
    }

    func testDuplicateAckWhileStreamingIsIgnored() {
        var sm = makeSM()
        _ = sm.start()
        let ack = VideoControlMessage.helloAck(
            accepted: true,
            streamID: 7,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        )
        _ = sm.handleControl(ack)
        // A retransmitted ack (UDP) must NOT restart the pipeline.
        let again = sm.handleControl(ack)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(sm.state, .streaming)
    }

    func testByeWhileStreamingStopsPipeline() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        let effects = sm.handleControl(.bye)
        XCTAssertEqual(sm.state, .stopped)
        // RECONNECT-WEDGE FIX: a HOST-initiated bye also surfaces `.sessionEndedByHost` so the
        // pipeline rebuilds (fresh lane + hello); a LOCAL stop() must not (see the stop tests).
        XCTAssertEqual(effects, [.stopDecodePipeline, .sessionEndedByHost])
    }

    func testByeWhileConnectingAlsoSurfacesSessionEndedByHost() {
        var sm = makeSM()
        _ = sm.start()
        let effects = sm.handleControl(.bye)
        XCTAssertEqual(sm.state, .stopped)
        XCTAssertEqual(
            effects,
            [.stopDecodePipeline, .sessionEndedByHost],
            "a bye that races the connect (host draining for restart) must still trigger the rebuild",
        )
    }

    func testLocalStopNeverSurfacesSessionEndedByHost() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        XCTAssertFalse(
            sm.stop().contains(.sessionEndedByHost),
            "a local stop (pane closed) must NOT trigger a pipeline rebuild",
        )
    }

    // MARK: Hello retry (reconnect-wedge fix)

    func testResendHelloWhileConnectingReEmitsThePrimeAndTheSameHello() {
        // THE STUCK-DEFAULT-CURSOR REGRESSION: a host daemon restart mid-`.connecting` loses the
        // lane's one-shot cursor prime; the retried hello re-mints the session on the fresh daemon,
        // but without a re-prime the host never learns the cursor reply flow — video and input work
        // while every cursor update is silently dropped (`send` has no flow → drop, no log), so the
        // pointer shape stays the default arrow for the pane's whole life. The retry MUST re-prime.
        var sm = makeSM()
        _ = sm.start()
        let effects = sm.resendHello()
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(effects.first, .primeCursorFlow, "a retried hello re-primes the cursor flow")
        guard case let .sendControl(.hello(version, windowID, viewport)) = effects.last else {
            XCTFail("expected a re-emitted hello, got \(effects)")
            return
        }
        XCTAssertEqual(version, SlopDeskVideoProtocol.version)
        XCTAssertEqual(windowID, 42)
        XCTAssertEqual(viewport, VideoSize(width: 1280, height: 800))
        XCTAssertEqual(sm.state, .connecting, "a retry never moves the state")
    }

    func testResendHelloIsInertOutsideConnecting() {
        var idle = makeSM()
        XCTAssertTrue(idle.resendHello().isEmpty, "no retry before start()")

        var streaming = makeSM()
        _ = streaming.start()
        _ = streaming.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        XCTAssertTrue(streaming.resendHello().isEmpty, "an acked session never re-hellos")

        var rejected = makeSM()
        _ = rejected.start()
        _ = rejected.handleControl(.helloAck(
            accepted: false,
            streamID: 0,
            captureWidth: 0,
            captureHeight: 0,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 0, height: 0),
            fullRange: false,
        ))
        XCTAssertTrue(rejected.resendHello().isEmpty, "a rejected session must not retry-spam the host")

        var stopped = makeSM()
        _ = stopped.start()
        _ = stopped.stop()
        XCTAssertTrue(stopped.resendHello().isEmpty, "a stopped session never re-hellos")
    }

    func testHelloRetryPolicyBacksOffExponentiallyToTheCap() {
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: 0), 0.5)
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: 1), 1.0)
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: 2), 2.0)
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: 3), 4.0)
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: 4), 5.0, "capped at maxDelay")
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: 100), 5.0, "stays capped (no overflow)")
        XCTAssertEqual(HelloRetryPolicy.delay(attempt: -3), 0.5, "negative attempt clamps to the first delay")
    }

    func testStopWhileStreamingSendsByeAndStopsPipeline() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
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
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        XCTAssertEqual(sm.state, .streaming)

        let ack = VideoControlMessage.resizeAck(captureWidth: 1280, captureHeight: 800, epoch: 3)
        let effects = sm.handleControl(ack)
        XCTAssertEqual(
            effects,
            [.updateCaptureSize(VideoSize(width: 1280, height: 800))],
            "a resizeAck while streaming stages the new capture size for frame-gated adoption",
        )
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
        _ = stopped.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        _ = stopped.handleControl(.bye)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertTrue(stopped.handleControl(.resizeAck(captureWidth: 1280, captureHeight: 800, epoch: 1)).isEmpty)
        XCTAssertEqual(stopped.state, .stopped)
    }

    // MARK: Content mask — host→client transparency rects

    func testContentMaskWhileStreamingEmitsApplyContentMask() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        let rects = [
            MaskRect(x: 0, y: 0, width: 800, height: 600),
            MaskRect(x: 10, y: 590, width: 100, height: 80),
        ]
        XCTAssertEqual(sm.handleControl(.contentMask(rects)), [.applyContentMask(rects)])
        XCTAssertEqual(sm.state, .streaming, "a content mask does not change session state")
        // An empty mask (contract → clear) still emits the effect so the renderer drops the mask.
        XCTAssertEqual(sm.handleControl(.contentMask([])), [.applyContentMask([])])
    }

    func testContentMaskIgnoredWhenNotStreaming() {
        // While connecting (pre-streaming) a stray content mask is inert.
        var sm = makeSM()
        _ = sm.start()
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(sm.handleControl(.contentMask([MaskRect(x: 0, y: 0, width: 1, height: 1)])).isEmpty)
    }

    // MARK: Display max — host→client resize-ceiling report (host-window-resize feature)

    func testDisplayMaxWhileStreamingEmitsApplyDisplayMax() {
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        XCTAssertEqual(
            sm.handleControl(.displayMax(width: 1920, height: 1080)),
            [.applyDisplayMax(VideoSize(width: 1920, height: 1080))],
        )
        XCTAssertEqual(sm.state, .streaming, "a display-max report does not change session state")
    }

    func testDisplayMaxIgnoredWhenNotStreamingOrDegenerate() {
        var sm = makeSM()
        _ = sm.start()
        // Pre-streaming: a stray display-max is inert.
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(sm.handleControl(.displayMax(width: 1920, height: 1080)).isEmpty)
        // Streaming but a degenerate zero dimension is dropped (never pin the popover cap to 0).
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        XCTAssertTrue(sm.handleControl(.displayMax(width: 0, height: 1080)).isEmpty)
    }

    func testResizeRequestNeverActedOnByClient() {
        // The client never RECEIVES a resizeRequest (host→client only is resizeAck) — defensive.
        var sm = makeSM()
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        XCTAssertTrue(sm.handleControl(.resizeRequest(desired: VideoSize(width: 1, height: 1), epoch: 1)).isEmpty)
        XCTAssertEqual(sm.state, .streaming)
    }

    func testClientIgnoresHelloAndStrayAckWhenNotConnecting() {
        var sm = makeSM()
        // Before start: a stray ack does nothing (still idle).
        XCTAssertTrue(sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 1,
            captureHeight: 1,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 1, height: 1),
            fullRange: false,
        )).isEmpty)
        XCTAssertEqual(sm.state, .idle)
        // A hello (host→client only) is never acted on.
        _ = sm.start()
        XCTAssertTrue(sm.handleControl(.hello(
            protocolVersion: 1,
            requestedWindowID: 1,
            viewport: VideoSize(width: 1, height: 1),
        )).isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }
}
