import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE logic only — drives the host video state machine with `resizeRequest` control
/// messages and asserts the in-session resize transition + emitted `.resizeCapture`
/// effect. NO live SCStream / AX / socket (hang-safety rule).
final class ResizeStateMachineTests: XCTestCase {
    private let bounds = VideoRect(x: 10, y: 20, width: 800, height: 600)
    private let acceptAll: (UInt32, VideoSize) -> (UInt16, UInt16)? = { _, _ in (800, 600) }
    // Resize resolver: clamp to a [320..3840]×[240..2160] window for the streaming windowID 42.
    private let resolveResize: (UInt32, VideoSize) -> (UInt16, UInt16)? = { windowID, desired in
        guard windowID == 42 else { return nil }
        return SizeNegotiation.clamp(
            desired: desired,
            min: VideoSize(width: 320, height: 240),
            max: VideoSize(width: 3840, height: 2160),
        )
    }

    private let windowID: UInt32 = 42

    /// Brings a fresh SM up to `.streaming` for `windowID` 42 at 800×600.
    private func streamingMachine(nextStreamID: UInt32 = 7) -> VideoSessionStateMachine {
        var sm = VideoSessionStateMachine(nextStreamID: nextStreamID)
        _ = sm.start()
        let hello = VideoControlMessage.hello(
            protocolVersion: AislopdeskVideoProtocol.version,
            requestedWindowID: windowID,
            viewport: VideoSize(width: 800, height: 600),
        )
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .streaming)
        return sm
    }

    func testResizeWhileStreamingEmitsResizeCaptureClampedWithEpoch() {
        var sm = streamingMachine()
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1)
        let effects = sm.handleControl(
            req,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        )

        XCTAssertEqual(sm.state, .streaming, "resize stays in .streaming (same session)")
        XCTAssertTrue(sm.mediaFlowing)
        XCTAssertEqual(effects, [.resizeCapture(width: 1280, height: 800, epoch: 1)])
        XCTAssertEqual(sm.captureWidth, 1280, "SM tracks the new clamped capture size")
        XCTAssertEqual(sm.captureHeight, 800)
        XCTAssertEqual(sm.lastResizeEpoch, 1)
    }

    func testResizeClampsBelowMinAndAboveMax() {
        var sm = streamingMachine()
        let tooSmall = VideoControlMessage.resizeRequest(desired: VideoSize(width: 10, height: 10), epoch: 1)
        XCTAssertEqual(
            sm.handleControl(
                tooSmall,
                windowBoundsCG: bounds,
                resolveCaptureSize: acceptAll,
                resolveResizeSize: resolveResize,
            ),
            [.resizeCapture(width: 320, height: 240, epoch: 1)],
        )

        let tooBig = VideoControlMessage.resizeRequest(desired: VideoSize(width: 99999, height: 99999), epoch: 2)
        XCTAssertEqual(
            sm.handleControl(
                tooBig,
                windowBoundsCG: bounds,
                resolveCaptureSize: acceptAll,
                resolveResizeSize: resolveResize,
            ),
            [.resizeCapture(width: 3840, height: 2160, epoch: 2)],
        )
    }

    func testResizeDoesNotMintNewStreamID() {
        var sm = streamingMachine(nextStreamID: 7)
        // The accept above consumed streamID 7 → next would be 8. A resize must NOT mint one.
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1)
        _ = sm.handleControl(
            req,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        )

        // A subsequent fresh hello (after a bye/re-arm) would take streamID 8 — proving the
        // resize did not advance the counter. Re-arm via bye, then a hello.
        _ = sm.handleControl(
            .bye,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        )
        let hello = VideoControlMessage.hello(
            protocolVersion: AislopdeskVideoProtocol.version,
            requestedWindowID: windowID,
            viewport: VideoSize(width: 800, height: 600),
        )
        let reconnect = sm.handleControl(
            hello,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        )
        guard case let .sendControl(.helloAck(_, streamID, _, _, _, _)) = reconnect[0]
        else { XCTFail("expected reconnect ack")
            return
        }
        XCTAssertEqual(streamID, 8, "the resize between hello and bye did NOT consume a streamID")
    }

    func testStaleEpochIgnored() {
        var sm = streamingMachine()
        let first = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 5)
        XCTAssertEqual(
            sm.handleControl(
                first,
                windowBoundsCG: bounds,
                resolveCaptureSize: acceptAll,
                resolveResizeSize: resolveResize,
            ),
            [.resizeCapture(width: 1280, height: 800, epoch: 5)],
        )
        XCTAssertEqual(sm.lastResizeEpoch, 5)

        // A reordered/duplicate request with an OLDER (and equal) epoch is dropped.
        let stale = VideoControlMessage.resizeRequest(desired: VideoSize(width: 640, height: 480), epoch: 3)
        XCTAssertTrue(sm.handleControl(
            stale,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        ).isEmpty)
        let dup = VideoControlMessage.resizeRequest(desired: VideoSize(width: 640, height: 480), epoch: 5)
        XCTAssertTrue(sm.handleControl(
            dup,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        ).isEmpty)
        // Capture size unchanged by the dropped stale/dup requests.
        XCTAssertEqual(sm.captureWidth, 1280)
        XCTAssertEqual(sm.captureHeight, 800)
        XCTAssertEqual(sm.lastResizeEpoch, 5)

        // A fresh higher epoch still applies.
        let fresh = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1920, height: 1080), epoch: 6)
        XCTAssertEqual(
            sm.handleControl(
                fresh,
                windowBoundsCG: bounds,
                resolveCaptureSize: acceptAll,
                resolveResizeSize: resolveResize,
            ),
            [.resizeCapture(width: 1920, height: 1080, epoch: 6)],
        )
    }

    func testResizeEpochResetsOnFreshHelloAccept() {
        // A reconnecting client mints its own epochs from 1 again (its ResizeDebounce is
        // per-connection). If lastResizeEpoch carried over from the prior session, the new
        // session's first resizes would all look stale and silently drop. Verify a fresh
        // hello-accept re-arms lastResizeEpoch to 0 so the new session's epoch-1 request wins.
        var sm = streamingMachine()
        // Drive the first session's epoch high.
        let high = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1920, height: 1080), epoch: 9)
        XCTAssertEqual(
            sm.handleControl(
                high,
                windowBoundsCG: bounds,
                resolveCaptureSize: acceptAll,
                resolveResizeSize: resolveResize,
            ),
            [.resizeCapture(width: 1920, height: 1080, epoch: 9)],
        )
        XCTAssertEqual(sm.lastResizeEpoch, 9)

        // Client disconnects + reconnects (bye → fresh hello).
        _ = sm.handleControl(
            .bye,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        )
        let hello = VideoControlMessage.hello(
            protocolVersion: AislopdeskVideoProtocol.version,
            requestedWindowID: windowID,
            viewport: VideoSize(width: 800, height: 600),
        )
        _ = sm.handleControl(
            hello,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        )
        XCTAssertEqual(sm.state, .streaming)
        XCTAssertEqual(sm.lastResizeEpoch, 0, "a fresh hello-accept re-arms lastResizeEpoch to 0")

        // The reconnected client's FIRST resize (epoch 1, < the old 9) must now WIN, not drop.
        let firstAfterReconnect = VideoControlMessage.resizeRequest(
            desired: VideoSize(width: 1280, height: 800),
            epoch: 1,
        )
        XCTAssertEqual(
            sm.handleControl(
                firstAfterReconnect,
                windowBoundsCG: bounds,
                resolveCaptureSize: acceptAll,
                resolveResizeSize: resolveResize,
            ),
            [.resizeCapture(width: 1280, height: 800, epoch: 1)],
            "the reconnected session's epoch-1 resize is NOT treated as stale",
        )
        XCTAssertEqual(sm.lastResizeEpoch, 1)
    }

    func testResizeIgnoredWhileListening() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        XCTAssertEqual(sm.state, .listening)
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1)
        XCTAssertTrue(sm.handleControl(
            req,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        ).isEmpty)
        XCTAssertEqual(sm.state, .listening)
        XCTAssertEqual(sm.lastResizeEpoch, 0, "no resize applied while listening")
    }

    func testResizeIgnoredWhileIdle() {
        var sm = VideoSessionStateMachine()
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1)
        XCTAssertTrue(sm.handleControl(
            req,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        ).isEmpty)
        XCTAssertEqual(sm.state, .idle)
    }

    func testResizeIgnoredAfterStop() {
        var sm = streamingMachine()
        _ = sm.stop()
        XCTAssertEqual(sm.state, .stopped)
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1)
        XCTAssertTrue(sm.handleControl(
            req,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: resolveResize,
        ).isEmpty)
        XCTAssertEqual(sm.state, .stopped)
    }

    func testResizeForWrongWindowRejectedByResolver() {
        // The resolver returns nil for any windowID != 42; simulate the session having a
        // different windowID by streaming a different window, then a resize whose resolver
        // says "wrong/gone window". Here we stream windowID 42 but the resolver only ever
        // accepts windowID 99 → reject.
        var sm = streamingMachine()
        let rejectResolver: (UInt32, VideoSize) -> (UInt16, UInt16)? = { wid, _ in wid == 99 ? (640, 480) : nil }
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1)
        XCTAssertTrue(sm.handleControl(
            req,
            windowBoundsCG: bounds,
            resolveCaptureSize: acceptAll,
            resolveResizeSize: rejectResolver,
        ).isEmpty)
        XCTAssertEqual(sm.state, .streaming)
        XCTAssertEqual(
            sm.lastResizeEpoch,
            0,
            "rejected resize does NOT advance the epoch (a later valid request still wins)",
        )
        XCTAssertEqual(sm.captureWidth, 800, "capture stays at the hello-negotiated size")
        XCTAssertEqual(sm.captureHeight, 600)
    }

    func testResizeResolverReceivesSessionWindowID() {
        var sm = streamingMachine()
        var seenWindowID: UInt32?
        let spy: (UInt32, VideoSize) -> (UInt16, UInt16)? = { wid, _ in seenWindowID = wid
            return (1024, 768)
        }
        let req = VideoControlMessage.resizeRequest(desired: VideoSize(width: 1024, height: 768), epoch: 1)
        _ = sm.handleControl(req, windowBoundsCG: bounds, resolveCaptureSize: acceptAll, resolveResizeSize: spy)
        XCTAssertEqual(seenWindowID, windowID, "the resolver is handed the streaming session's windowID")
    }
}
