import CoreVideo
import XCTest
@testable import AislopdeskVideoClient
@testable import AislopdeskVideoProtocol

/// Client-side fold of the `streamCadence` control message (FPS governor, 2026-06-11): the pure
/// state machine emits `.applyStreamCadence` only while streaming, and `FramePacer.setContentFps`
/// rebases the deadline-mode rhythm + the adaptive jitter controller (preserving live depth).
final class StreamCadenceClientTests: XCTestCase {
    // MARK: Session-logic fold

    private func streamingSM() -> VideoClientStateMachine {
        var sm = VideoClientStateMachine(requestedWindowID: 7, viewport: VideoSize(width: 800, height: 600))
        _ = sm.start()
        _ = sm.handleControl(.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        ))
        return sm
    }

    func testStreamCadenceWhileStreamingEmitsApplyEffect() {
        var sm = streamingSM()
        XCTAssertEqual(sm.handleControl(.streamCadence(fps: 30)), [.applyStreamCadence(30)])
        // Duplicate delivery (host dup-sends ×2) folds again — idempotent at the apply site.
        XCTAssertEqual(sm.handleControl(.streamCadence(fps: 30)), [.applyStreamCadence(30)])
    }

    func testStreamCadenceIgnoredWhenNotStreaming() {
        var idle = VideoClientStateMachine(requestedWindowID: 7, viewport: VideoSize(width: 800, height: 600))
        XCTAssertEqual(idle.handleControl(.streamCadence(fps: 30)), [], "idle ⇒ inert")

        var connecting = VideoClientStateMachine(requestedWindowID: 7, viewport: VideoSize(width: 800, height: 600))
        _ = connecting.start()
        XCTAssertEqual(connecting.handleControl(.streamCadence(fps: 30)), [], "connecting ⇒ inert")

        var stopped = streamingSM()
        _ = stopped.stop()
        XCTAssertEqual(stopped.handleControl(.streamCadence(fps: 30)), [], "stopped ⇒ a stray/late cadence is inert")
    }

    func testStreamCadenceFpsZeroDropped() {
        var sm = streamingSM()
        XCTAssertEqual(sm.handleControl(.streamCadence(fps: 0)), [], "fps 0 is nonsense — dropped defensively")
    }

    // MARK: FramePacer.setContentFps

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

    /// Deadline-mode rhythm rebases to the governed interval: after `setContentFps(30)` the second
    /// frame's deadline sits one 33.3 ms CONTENT interval past the first present's deadline — a
    /// tick at the old 16.7 ms spacing must NOT present it yet. (Extends FramePacerDeadlineTests
    /// to the live instance: submit reads the real clock, so assertions bracket it with
    /// before/after timestamps — the bracket is sub-ms in-process.)
    func testSetContentFpsRebasesDeadlineRhythm() {
        let presents = PresentCounter()
        let pacer = FramePacer(
            maxFrameRate: 60,
            targetDepth: 1,
            maxDepth: 5,
            deadlineMode: true,
            contentFps: 60,
            playoutDelayMs: 20,
            renderCallback: { _ in presents.bump() },
        )
        pacer.setContentFps(30)
        let halfTick = 0.5 / 60.0

        let t0 = FramePacer.currentHostTimeSeconds()
        pacer.submit(makePixelBuffer()) // d1 ∈ [t0, t1] + 0.020
        let t1 = FramePacer.currentHostTimeSeconds()
        XCTAssertLessThan(t1 - t0, 0.01, "submit bracket must be tight for the deadline bounds below")
        pacer.tick(hostTimeSeconds: t1 + 0.020 + halfTick) // d1 is due → presents, anchors the rhythm at d1
        XCTAssertEqual(presents.count, 1)

        pacer.submit(makePixelBuffer()) // d2 = d1 + 1/30 (the REBASED interval)
        pacer.tick(hostTimeSeconds: t0 + 0.020 + 1.0 / 60.0) // old 60 fps spacing: d2 ≥ d1 + 1/30 > this + halfTick
        XCTAssertEqual(presents.count, 1, "a 16.7 ms tick must NOT present — the rhythm is 33.3 ms now")
        pacer.tick(hostTimeSeconds: t1 + 0.020 + 1.0 / 30.0 + halfTick) // ≥ d2 → due
        XCTAssertEqual(presents.count, 2, "presented exactly one content interval (1/30) after the first")
    }

    /// The adaptive jitter controller is RECREATED at the new fps preserving its live target
    /// depth: the first post-rebase low-jitter fold must still read the carried depth (a
    /// recreation that lost it would recommend the floor immediately).
    func testSetContentFpsPreservesAdaptiveDepth() {
        let pacer = FramePacer(
            maxFrameRate: 60,
            targetDepth: 3,
            maxDepth: 8,
            adaptiveJitter: true,
            renderCallback: { _ in },
        )
        XCTAssertEqual(pacer.currentDepth, 3)
        pacer.setContentFps(30)
        // One clean submit folds jitter ≈ 0 through the REBUILT controller: shrink is slow
        // (cooldown 180), so a preserved-depth controller stays at 3; a reset one would return 1.
        pacer.submit(makePixelBuffer())
        XCTAssertEqual(pacer.currentDepth, 3, "cadence rebase must not dump the jitter buffer depth")
    }

    /// FPS-UNIT PIN: the adaptive controller's fps (its seconds→frames conversion unit) is the
    /// CONTENT fps from construction — NOT the display tick rate — so the first `streamCadence`
    /// rebase stays in the SAME unit. (Constructing with the 120 Hz tick rate made the unit flip
    /// 120→60 on the first rebase, silently halving every depth recommendation mid-session.)
    func testAdaptiveControllerFpsUnitIsContentFps() {
        let pacer = FramePacer(
            maxFrameRate: 120,
            targetDepth: 1,
            maxDepth: 8,
            adaptiveJitter: true,
            contentFps: 60,
            renderCallback: { _ in },
        )
        XCTAssertEqual(
            pacer.controllerFpsForTest,
            60,
            "construction uses the content fps, not the 120 Hz display tick rate",
        )
        pacer.setContentFps(30)
        XCTAssertEqual(pacer.controllerFpsForTest, 30, "a streamCadence rebase stays in the content unit")
        pacer.setContentFps(60)
        XCTAssertEqual(pacer.controllerFpsForTest, 60)
    }

    /// Adaptive OFF: setContentFps must not invent a controller (fixed-depth path stays inert).
    func testSetContentFpsNoOpOnFixedDepthPath() {
        let pacer = FramePacer(maxFrameRate: 60, targetDepth: 2, maxDepth: 5, renderCallback: { _ in })
        pacer.setContentFps(20)
        pacer.submit(makePixelBuffer())
        XCTAssertEqual(pacer.currentDepth, 2, "fixed depth pinned regardless of cadence rebase")
    }
}

/// Lock-boxed present counter — the render callback is `@Sendable` (the RenderCounter pattern
/// from FramePacerTests).
private final class PresentCounter: @unchecked Sendable {
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
