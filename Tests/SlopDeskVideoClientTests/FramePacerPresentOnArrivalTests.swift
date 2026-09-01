import CoreVideo
import Synchronization
import XCTest
@testable import SlopDeskVideoClient

/// PRESENT-ON-ARRIVAL → PRESENT-ON-DECODE: a frame that lands in an EMPTY queue
/// and completes the live depth presents IMMEDIATELY instead of waiting for the next vsync
/// tick — every depth-1 frame, sparse or dense (the Parsec model). The original starved-only
/// gate (`underflowRun >= 1`) barely fired on HW (throttled ticks don't increment underflowRun)
/// and was dropped. The decision is a pure static (matrix-tested below); the behavioral test
/// drives the real submit → main-actor hop → render path through the run loop.
final class FramePacerPresentOnArrivalTests: XCTestCase {
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

    // MARK: Pure decision

    func testDecisionFiresOnEmptyQueueArrivalAtDepthOne() {
        // The canonical fire: arrival lands in an empty queue and completes depth 1 — present on
        // decode, regardless of how recently the display ticked (the old starved-only gate raced
        // throttled ticks and lost; see the FramePacer header HISTORY note).
        XCTAssertTrue(FramePacer.shouldPresentOnArrival(
            enabled: true,
            queueWasEmpty: true,
            queueCount: 1,
            liveDepth: 1,
        ))

        // Disabled (SLOPDESK_PRESENT_ON_ARRIVAL=0) → never.
        XCTAssertFalse(FramePacer.shouldPresentOnArrival(
            enabled: false,
            queueWasEmpty: true,
            queueCount: 1,
            liveDepth: 1,
        ))
        // Queue non-empty at arrival (display fell behind / burst) → vsync cadence owns presentation.
        XCTAssertFalse(FramePacer.shouldPresentOnArrival(
            enabled: true,
            queueWasEmpty: false,
            queueCount: 2,
            liveDepth: 1,
        ))
        // Depth ≥ 2: an empty-queue append yields count 1 < depth — priming still owns the hold.
        XCTAssertFalse(FramePacer.shouldPresentOnArrival(
            enabled: true,
            queueWasEmpty: true,
            queueCount: 1,
            liveDepth: 2,
        ))
    }

    // MARK: Behavioral (real submit → main hop → render)

    /// A depth-1 arrival presents WITHOUT a vsync tick: submit on a fresh depth-1 pacer — the
    /// render callback must fire from the main-actor hop alone (the test never calls
    /// tick()/frameForVSync()), and it must present THAT frame.
    func testArrivalPresentsWithoutWaitingForVSync() {
        final class RenderBox: Sendable {
            // A `CVImageBuffer` is not `Sendable`, so it cannot cross into the mutex's region on its
            // own. The wrapper carries it there unchecked — sound because the buffer is only ever
            // compared by identity, never read.
            private struct Held: @unchecked Sendable { let frame: CVImageBuffer }

            private let frames = Mutex<[Held]>([])
            func note(_ f: CVImageBuffer) { frames.withLock { $0.append(Held(frame: f)) } }
            var last: CVImageBuffer? { frames.withLock { $0.last }?.frame }
        }
        let box = RenderBox()
        let rendered = expectation(description: "render fired from the arrival hop")
        let pacer = FramePacer(targetDepth: 1, renderCallback: { frame in
            box.note(frame)
            rendered.fulfill()
        })
        let b = makePixelBuffer()
        pacer.submit(b) // depth 1 + empty queue → main-actor hop → presentNow() → renderCallback(b)
        wait(for: [rendered], timeout: 5)
        XCTAssertTrue(box.last === b, "the arrival-presented frame is the submitted one")
    }

    /// Negatives: disabled (SLOPDESK_PRESENT_ON_ARRIVAL=0) or depth ≥ 2 never fire the arrival
    /// hop — presentation stays vsync-paced. Run-loop spin proves no hop was scheduled.
    func testNoArrivalPresentWhenDisabledOrDeeper() {
        final class Flag: Sendable {
            private let v = Mutex(false)
            func set() { v.withLock { $0 = true } }
            var isSet: Bool { v.withLock { $0 } }
        }
        let disabledFlag = Flag()
        let disabled = FramePacer(targetDepth: 1, presentOnArrival: false, renderCallback: { _ in disabledFlag.set() })
        disabled.submit(makePixelBuffer())

        let deepFlag = Flag()
        let deep = FramePacer(targetDepth: 2, renderCallback: { _ in deepFlag.set() })
        deep.submit(makePixelBuffer()) // count 1 < depth 2 → priming owns the hold

        // Spin the main run loop briefly: if a hop HAD been scheduled it would run here.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(disabledFlag.isSet, "disabled ⇒ presentation stays vsync-paced")
        XCTAssertFalse(deepFlag.isSet, "depth ≥ 2 ⇒ priming owns the hold")
    }
}
