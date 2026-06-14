import CoreVideo
import XCTest
@testable import AislopdeskVideoClient

/// PURE frame-pacer logic: most-recent-wins submit, show-last-frame on empty queue,
/// skip-late, and the GUI frame-rate cap throttle. NO display link is created here —
/// only `submit` / `frameForVSync` / `tick(hostTimeSeconds:)` / `shouldRender`, which
/// are pure. `CVPixelBufferCreate` is a plain CoreVideo allocation (no decode session,
/// no window-server) so it is hang-safe.
final class FramePacerTests: XCTestCase {
    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pb,
        )
        precondition(status == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate failed (\(status))")
        return pb!
    }

    // MARK: Jitter-buffer queue policy (pure)

    func testNilBeforeAnyFrame() {
        let pacer = FramePacer(targetDepth: 1, renderCallback: { _ in })
        XCTAssertNil(pacer.frameForVSync(), "no frame ever decoded → nil")
    }

    func testDepthOnePresentsImmediatelyThenReshowsLast() {
        // targetDepth 1 ⇒ primes on the first frame; present it, then re-show on empty.
        let pacer = FramePacer(targetDepth: 1, renderCallback: { _ in })
        let frame = makePixelBuffer()
        pacer.submit(frame)
        XCTAssertTrue(pacer.frameForVSync() === frame)
        XCTAssertTrue(pacer.frameForVSync() === frame, "empty buffer re-presents the last shown")
    }

    func testPrimingHoldsUntilTargetDepthThenPresentsInOrder() {
        // targetDepth 2 ⇒ hold (return nil) until two frames are buffered, then FIFO.
        let pacer = FramePacer(targetDepth: 2, maxDepth: 5, renderCallback: { _ in })
        let a = makePixelBuffer()
        let b = makePixelBuffer()
        pacer.submit(a)
        XCTAssertNil(pacer.frameForVSync(), "one frame < targetDepth ⇒ still priming, hold")
        pacer.submit(b)
        XCTAssertTrue(pacer.frameForVSync() === a, "primed ⇒ present OLDEST first (FIFO, not skip-late)")
        XCTAssertTrue(pacer.frameForVSync() === b, "then the next in order")
        XCTAssertTrue(pacer.frameForVSync() === b, "empty ⇒ re-present last")
    }

    func testHomeostasisCapsDepthAtTargetDepth() {
        // Homeostasis: at present time the buffer never carries MORE than targetDepth — the oldest
        // excess is dropped so steady-state latency settles at ~targetDepth/fps (not maxDepth/fps).
        // targetDepth 2, maxDepth 5: submit 5 (all < maxDepth, none dropped on submit) ⇒ first present
        // drops the 3 oldest beyond targetDepth (a,b,c) and shows `d`, then `e`.
        let pacer = FramePacer(targetDepth: 2, maxDepth: 5, renderCallback: { _ in })
        let f = (0..<5).map { _ in makePixelBuffer() }
        f.forEach { pacer.submit($0) }
        XCTAssertTrue(pacer.frameForVSync() === f[3], "homeostasis drops the oldest excess beyond targetDepth")
        XCTAssertTrue(pacer.frameForVSync() === f[4], "then the freshest")
    }

    func testSubmitOverflowDropsOldestAtMaxDepth() {
        // maxDepth is the submit-side hard backstop. targetDepth 3, maxDepth 3: submit 5 ⇒ submit drops
        // the 2 oldest (a,b) at the cap; present (count 3 == targetDepth, no homeostasis drop) shows `c`.
        let pacer = FramePacer(targetDepth: 3, maxDepth: 3, renderCallback: { _ in })
        let f = (0..<5).map { _ in makePixelBuffer() }
        f.forEach { pacer.submit($0) }
        XCTAssertTrue(pacer.frameForVSync() === f[2], "submit dropped a,b at maxDepth; present c")
        XCTAssertTrue(pacer.frameForVSync() === f[3])
        XCTAssertTrue(pacer.frameForVSync() === f[4])
    }

    func testReprimeAfterSustainedDrySpellRebuildsSlack() {
        // The key fix: after a real idle (buffer empty ≥ targetDepth vsyncs) the pacer re-primes, so a
        // single frame arriving at scroll-resume is HELD (slack rebuilt) instead of presented with none.
        let pacer = FramePacer(targetDepth: 2, maxDepth: 5, renderCallback: { _ in })
        let a = makePixelBuffer()
        let b = makePixelBuffer()
        pacer.submit(a)
        pacer.submit(b)
        XCTAssertTrue(pacer.frameForVSync() === a) // primed
        XCTAssertTrue(pacer.frameForVSync() === b)
        // Idle: drain underflows. underflowRun reaches targetDepth(2) ⇒ primed reset to false.
        XCTAssertTrue(pacer.frameForVSync() === b, "underflow 1 → re-show last")
        XCTAssertTrue(pacer.frameForVSync() === b, "underflow 2 → dry spell ⇒ re-prime armed")
        // Scroll resumes: ONE frame is not enough slack ⇒ held (re-show last), proving re-prime engaged.
        let c = makePixelBuffer()
        pacer.submit(c)
        XCTAssertTrue(pacer.frameForVSync() === b, "re-primed ⇒ hold the single new frame, rebuild slack")
        let d = makePixelBuffer()
        pacer.submit(d)
        XCTAssertTrue(pacer.frameForVSync() === c, "slack rebuilt to targetDepth ⇒ present in order")
    }

    func testTransientSingleDipDoesNotReprime() {
        // A single empty vsync during steady scroll must NOT re-prime (that would itself stutter):
        // underflowRun(1) < targetDepth(3), so the next frame is presented immediately, not held.
        let pacer = FramePacer(targetDepth: 3, maxDepth: 8, renderCallback: { _ in })
        let f = (0..<3).map { _ in makePixelBuffer() }
        f.forEach { pacer.submit($0) }
        XCTAssertTrue(pacer.frameForVSync() === f[0]) // primed
        XCTAssertTrue(pacer.frameForVSync() === f[1])
        XCTAssertTrue(pacer.frameForVSync() === f[2])
        XCTAssertTrue(pacer.frameForVSync() === f[2], "one empty vsync → re-show last (transient dip)")
        let g = makePixelBuffer()
        pacer.submit(g)
        XCTAssertTrue(pacer.frameForVSync() === g, "still primed after a single dip ⇒ present immediately")
    }

    // MARK: Frame-rate cap (pure)

    func testCapFirstTickAlwaysRenders() {
        XCTAssertTrue(FramePacer.shouldRender(now: 1234.0, lastRender: 0, maxFrameRate: 30))
    }

    func testCapThrottlesRefreshFasterThanCap() {
        // A 120 Hz display ticks every ~8.33ms; a 30fps cap allows ~33.3ms apart.
        // 10ms after the last render is too soon at a 30fps cap.
        XCTAssertFalse(FramePacer.shouldRender(now: 0.010, lastRender: 0.001, maxFrameRate: 30))
        // 34ms apart clears the 33.3ms interval.
        XCTAssertTrue(FramePacer.shouldRender(now: 0.044, lastRender: 0.010, maxFrameRate: 30))
    }

    func testCapDisabledWhenRateNonPositive() {
        XCTAssertTrue(FramePacer.shouldRender(now: 0.001, lastRender: 0.0005, maxFrameRate: 0))
    }

    func testTickHonoursCapAndRenders() {
        let counter = RenderCounter()
        // targetDepth 1 so the cap (not priming) is what gates rendering here.
        let pacer = FramePacer(maxFrameRate: 30, targetDepth: 1, renderCallback: { _ in counter.bump() })
        pacer.submit(makePixelBuffer())
        pacer.tick(hostTimeSeconds: 0.0) // first tick (lastRender==0) → renders
        pacer.submit(makePixelBuffer())
        pacer.tick(hostTimeSeconds: 1.000) // lastRender still 0 → renders
        pacer.submit(makePixelBuffer())
        pacer.tick(hostTimeSeconds: 1.005) // 5ms later, under the 33ms cap → throttled
        XCTAssertEqual(counter.count, 2, "two ticks cleared the cap; the third was throttled")
    }
}

/// Thread-safe render counter (the pacer's `@Sendable` render callback forbids
/// capturing a mutable local).
private final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int { lock.lock()
        defer { lock.unlock() }
        return value
    }
}
