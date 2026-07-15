import CoreVideo
import XCTest
@testable import SlopDeskVideoHost

/// CAPTURE-DEATH regression: `SCStreamDelegate`'s `stream(_:didStopWithError:)` must not ONLY log
/// — if the IDR heartbeat timer kept re-encoding the stale `cachedPixelBuffer` as synthetic crisp
/// IDRs forever (window closed / display unplugged / TCC revoked / WindowServer reset), the
/// session would stay `.streaming` (1 s heartbeat kept the client's stall scrim disarmed), and the
/// pane would freeze permanently and silently.
///
/// A real SCStream can NEVER exist under XCTest (hang-safety), so these tests drive the
/// frameQueue-confined failure path through `WindowCapturer`'s headless test seams
/// (`handleCaptureFailure` is exactly what the delegate callback invokes) and pin the session's
/// pure teardown gate (`shouldDisconnectOnCaptureFailure`) the actor consults before reusing the
/// last-rung bye+stop teardown.
final class CaptureFailureTeardownTests: XCTestCase {
    /// Thread-safe counter for the `@Sendable` frame-handler / failure-callback closures.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// A tiny NV12 pixel buffer standing in for the live path's cached `.complete`-frame copy.
    /// Plain CoreVideo — no SCStream / VT / Metal (hang-safety).
    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 8, 8,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &buf,
        )
        guard status == kCVReturnSuccess, let buf else {
            XCTFail("CVPixelBufferCreate failed: \(status)")
            throw XCTSkip("no pixel buffer")
        }
        return buf
    }

    private func makeCapturer(frames: Counter) -> WindowCapturer {
        WindowCapturer { _, _, _, _, _, _, _ in frames.increment() }
    }

    /// Baseline (proves the rig is not vacuous): with a cached frame, an IDR-timer tick DOES
    /// re-encode it as a synthetic frame — this is exactly the machinery that kept "streaming"
    /// a frozen frame after the SCStream died.
    func testSeededTickEmitsSyntheticFrame() throws {
        let frames = Counter()
        let capturer = makeCapturer(frames: frames)
        try capturer.seedCachedPixelBufferForTesting(makePixelBuffer())
        capturer.runIDRTimerTickForTesting()
        capturer.drainEncodeQueueForTesting() // emit is async through the decoupled encode queue (default-ON)
        XCTAssertEqual(frames.value, 1, "seeded static-IDR tick must hand the cached frame to the encoder")
    }

    /// (a) After the capture-failure signal, the synthetic-frame path is DEAD: the cache is
    /// cleared, so a tick — even with a latched client recovery request (`requestKeyframe`,
    /// which forces past the heartbeat cadence) — re-encodes nothing.
    func testCaptureFailureQuiescesSyntheticTicks() throws {
        let frames = Counter()
        let capturer = makeCapturer(frames: frames)
        try capturer.seedCachedPixelBufferForTesting(makePixelBuffer())
        capturer.runIDRTimerTickForTesting()
        capturer.drainEncodeQueueForTesting() // emit is async through the decoupled encode queue (default-ON)
        XCTAssertEqual(frames.value, 1)

        capturer.handleCaptureFailure()
        capturer.drainFrameQueueForTesting()

        capturer.requestKeyframe() // a frozen client's recovery request must NOT resurrect the stale frame
        capturer.runIDRTimerTickForTesting()
        capturer.drainEncodeQueueForTesting() // drain so a would-be async emit can't hide behind the sync check
        XCTAssertEqual(
            frames.value, 1,
            "post-failure tick must be a no-op — the stale cached frame may never be re-encoded",
        )
    }

    /// (b) `onCaptureFailed` fires exactly ONCE, even when the delegate failure is signalled twice.
    func testCaptureFailureFiresCallbackExactlyOnce() throws {
        let frames = Counter()
        let callbacks = Counter()
        let capturer = makeCapturer(frames: frames)
        let fired = expectation(description: "onCaptureFailed")
        capturer.onCaptureFailed = {
            callbacks.increment()
            fired.fulfill()
        }
        try capturer.seedCachedPixelBufferForTesting(makePixelBuffer())

        capturer.handleCaptureFailure()
        wait(for: [fired], timeout: 5)

        capturer.handleCaptureFailure() // duplicate delegate fire
        capturer.drainFrameQueueForTesting()
        XCTAssertEqual(callbacks.value, 1, "a duplicate didStopWithError must not double-tear the session")
    }

    /// (c) A deliberate `stop()` AFTER a failure is safe: no crash, no second callback, no frames.
    func testDeliberateStopAfterFailureIsIdempotent() async throws {
        let frames = Counter()
        let callbacks = Counter()
        let capturer = makeCapturer(frames: frames)
        let fired = expectation(description: "onCaptureFailed")
        capturer.onCaptureFailed = {
            callbacks.increment()
            fired.fulfill()
        }
        try capturer.seedCachedPixelBufferForTesting(makePixelBuffer())

        capturer.handleCaptureFailure()
        await fulfillment(of: [fired], timeout: 5)

        await capturer.stop() // the session's teardown path calls this — must be a clean no-op
        capturer.drainFrameQueueForTesting()
        XCTAssertEqual(callbacks.value, 1, "stop() after a failure must not re-fire onCaptureFailed")

        capturer.requestKeyframe()
        capturer.runIDRTimerTickForTesting()
        capturer.drainEncodeQueueForTesting() // a real emit would be async — drain so ==0 can't pass vacuously
        XCTAssertEqual(frames.value, 0, "no synthetic frame may be emitted after failure + stop")
    }

    /// (c′) The reverse race: a failure signalled AFTER a deliberate `stop()` must be swallowed —
    /// the session tore the capturer down on purpose (a bye / resize supersede), so firing the
    /// callback would double-teardown the successor.
    func testFailureAfterDeliberateStopDoesNotFireCallback() async throws {
        let frames = Counter()
        let callbacks = Counter()
        let capturer = makeCapturer(frames: frames)
        capturer.onCaptureFailed = { callbacks.increment() }
        try capturer.seedCachedPixelBufferForTesting(makePixelBuffer())

        await capturer.stop() // deliberate stop first (also clears the cached frame)
        capturer.handleCaptureFailure() // late didStopWithError from the dying stream
        capturer.drainFrameQueueForTesting()

        XCTAssertEqual(callbacks.value, 0, "a failure trailing a deliberate stop() must not fire the callback")
        capturer.requestKeyframe()
        capturer.runIDRTimerTickForTesting()
        capturer.drainEncodeQueueForTesting() // a real emit would be async — drain so ==0 can't pass vacuously
        XCTAssertEqual(frames.value, 0, "stop() must have cleared the cache — no synthetic frame")
    }

    /// The session actor's PURE teardown gate (the actor itself needs a real `SCWindow`, so the
    /// decision is pinned headlessly — the `CaptureRegionFailureRecovery` pattern): tear down
    /// ONLY when media is still flowing AND the dead capturer is the currently-installed one.
    func testSessionCaptureFailurePolicy() {
        XCTAssertTrue(
            SlopDeskVideoHostSession.shouldDisconnectOnCaptureFailure(mediaFlowing: true, failedIsCurrent: true),
            "live session + current capturer died ⇒ bye + stop (visible disconnect beats silent freeze)",
        )
        XCTAssertFalse(
            SlopDeskVideoHostSession.shouldDisconnectOnCaptureFailure(mediaFlowing: false, failedIsCurrent: true),
            "a deliberate stop/bye teardown already ran — must not double-teardown",
        )
        XCTAssertFalse(
            SlopDeskVideoHostSession.shouldDisconnectOnCaptureFailure(mediaFlowing: true, failedIsCurrent: false),
            "a superseded (resize/region) capturer's death must not kill the successor's session",
        )
        XCTAssertFalse(
            SlopDeskVideoHostSession.shouldDisconnectOnCaptureFailure(mediaFlowing: false, failedIsCurrent: false),
        )
    }
}
