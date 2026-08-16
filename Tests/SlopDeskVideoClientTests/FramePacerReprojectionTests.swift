import CoreVideo
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

/// SCROLL-HINT REPROJECTION (default-OFF, client-only): the pacer integrates the local scroll
/// velocity into a UV offset on its BETWEEN-CONTENT ticks (the would-be identity-skip re-shows) and
/// re-presents the last frame with it; it resets the offset the instant a real decoded frame is
/// presented (so the new frame's own scrolled content is never double-counted). These tests drive
/// the tick path headlessly and assert (a) gate-OFF is unchanged, (b) the offset grows between
/// frames, (c) a real frame resets it. The GPU application of the offset is the GUI-only / HW step.
final class FramePacerReprojectionTests: XCTestCase {
    /// Records every (offset, present) the pacer applies, plus how many renderCallback presents fire.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var offsets: [SIMD2<Float>] = []
        private var presents = 0
        func noteOffset(_ o: SIMD2<Float>) { lock.lock()
            offsets.append(o)
            lock.unlock()
        }

        func notePresent() { lock.lock()
            presents += 1
            lock.unlock()
        }

        var appliedOffsets: [SIMD2<Float>] { lock.lock()
            defer { lock.unlock() }
            return offsets
        }

        var presentCount: Int { lock.lock()
            defer { lock.unlock() }
            return presents
        }
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        return try XCTUnwrap(pb)
    }

    /// Gate OFF (no reprojector): the between-content ticks stay identity-skips — exactly ONE present
    /// for one submitted frame, no offset ever applied. This is the byte-identical default path.
    func testGateOffIsIdentitySkipUnchanged() throws {
        let sink = Sink()
        let pacer = FramePacer(
            maxFrameRate: 120,
            targetDepth: 1,
            deadlineMode: true,
            contentFps: 60,
            playoutDelayMs: 20,
            // reprojector + applyReprojection default to nil ⇒ feature off.
        ) { _ in sink.notePresent() }
        let pb = try makePixelBuffer()
        pacer.submit(pb)
        var t = FramePacer.currentHostTimeSeconds()
        for _ in 0..<12 { t += 1.0 / 120.0
            pacer.tick(hostTimeSeconds: t)
        }
        XCTAssertEqual(sink.presentCount, 1, "one frame presents once; spare ticks stay identity-skips")
        XCTAssertTrue(sink.appliedOffsets.isEmpty, "no reproject offset is ever applied when off")
    }

    /// Gate ON: with an active scroll velocity, the between-content ticks re-present the last frame
    /// with a GROWING offset (vel*elapsed), and a freshly submitted+presented frame RESETS the
    /// applied offset to zero (the no-double-count invariant).
    func testBetweenContentTicksReprojectThenRealFrameResets() throws {
        let sink = Sink()
        // A wide band + an active downward velocity so the offset grows visibly across ticks.
        let reprojector = ScrollReprojector(maxBand: 0.5, decaySeconds: 0.12)
        reprojector.noteVelocity(vx: 0.0, vy: 2.0, phase: .active) // 2 frames/sec downward
        let pacer = FramePacer(
            maxFrameRate: 120,
            targetDepth: 1,
            deadlineMode: true,
            contentFps: 60,
            playoutDelayMs: 0, // present the first frame immediately at its deadline
            reprojector: reprojector,
            applyReprojection: { offset in sink.noteOffset(offset) },
        ) { _ in sink.notePresent() }

        let pb = try makePixelBuffer()
        pacer.submit(pb)
        // Tick once at/after the deadline → the real frame presents (and resets the hint to 0).
        var t = FramePacer.currentHostTimeSeconds()
        t += 1.0 / 120.0
        pacer.tick(hostTimeSeconds: t)
        XCTAssertEqual(sink.presentCount, 1, "the real frame presents once")
        // Now drive several BETWEEN-CONTENT ticks (no new frame submitted) at 120Hz.
        let presentsBefore = sink.presentCount
        for _ in 0..<4 { t += 1.0 / 120.0
            pacer.tick(hostTimeSeconds: t)
        }
        // Each between-content tick re-presents the last frame with a NON-DECREASING positive offset.
        let ys = sink.appliedOffsets.map(\.y)
        XCTAssertFalse(ys.isEmpty, "between-content ticks applied a reproject offset")
        XCTAssertTrue(ys.allSatisfy { $0 >= 0 }, "downward velocity ⇒ non-negative offset")
        XCTAssertGreaterThan(ys.last ?? 0, 0, "the offset grew while scrolling between frames")
        XCTAssertGreaterThan(sink.presentCount, presentsBefore, "the spare ticks re-presented the frame")

        // A real frame arrives + presents → the offset the pacer applies resets to exactly zero.
        let pb2 = try makePixelBuffer()
        pacer.submit(pb2)
        t += 1.0 / 60.0 // past the next content deadline
        pacer.tick(hostTimeSeconds: t)
        XCTAssertEqual(
            sink.appliedOffsets.last, .zero,
            "presenting a real codec frame resets the hint offset to exactly 0 (no double-count)",
        )
    }

    /// The scroll/momentum phase mapping the pipeline uses to drive the reprojector, through the door.
    func testReprojectionPhaseMapping() {
        // Active drag (CGScrollPhase changed = 2, no momentum).
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 2, momentumPhase: 0), .active)
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 1, momentumPhase: 0), .active)
        // Momentum coast (CGMomentumScrollPhase begin = 1, continue = 2).
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 0, momentumPhase: 1), .momentum)
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 0, momentumPhase: 2), .momentum)
        // Either ended arms the decay (finger end = 4 / cancelled = 8 / momentum end = 3).
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 4, momentumPhase: 0), .ended)
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 8, momentumPhase: 0), .ended)
        XCTAssertEqual(ScrollReprojector.Phase(scrollPhase: 0, momentumPhase: 3), .ended)
    }

    /// A host-measured shift crosses out as ten-thousandths and comes back as a velocity + a band.
    func testScrollHintEncodesAndDecodesOneEncoding() {
        let hint = ScrollReprojector.Hint(
            shift: 48, confidenceMilli: 900, bandTopRow: 100, bandBottomRow: 899, height: 960,
        )
        XCTAssertEqual(hint.dy, 500, "48 rows of 960 is a twentieth of the frame")
        XCTAssertEqual(hint.dx, 0, "the v1 host measures the vertical axis only")
        let sample = hint.velocity(contentFps: 60.0)
        XCTAssertEqual(sample.vy, 3.0, accuracy: 1e-12, "one frame of shift, sixty frames a second")
        XCTAssertEqual(sample.phase, .active)
        XCTAssertEqual(hint.band()?.bottom, 0.9375, "the inclusive bottom row became an exclusive edge")

        // An unconfident measurement is not a scroll; a still frame arms the decay and carries no band.
        let still = ScrollReprojector.Hint(
            shift: 48, confidenceMilli: 499, bandTopRow: 100, bandBottomRow: 899, height: 960,
        )
        XCTAssertEqual(still.dy, 0)
        XCTAssertNil(still.band(), "no band is absent, not an empty span at the top of the frame")
        XCTAssertEqual(still.velocity(contentFps: 60.0).phase, .ended)
    }
}
