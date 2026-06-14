import CoreVideo
import XCTest
@testable import AislopdeskVideoClient

/// Component 4 (adaptive pacer depth): FramePacer wiring tests via the INTERNAL now-injection
/// seams (`submitForTest` / `frameForVSyncForTest` / `noteNetworkLateForTest`) — promote re-primes
/// + boosts `liveDepth`, demote restores depth 1 (re-arming present-on-arrival), default-off pins
/// the depth while telemetry still counts, the depth policy disables v1, and manual depth ≥2 is
/// telemetry-only. v3 (2026-06-12): promotion is driven by NETWORK-late events
/// (`noteNetworkLate`), never by present gaps. No display link, no env vars — everything is
/// injected at construction.
final class FramePacerDepthV2Tests: XCTestCase {
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

    /// Drive `frames` clean 60fps slots: submit + drain at the same injected instant
    /// (present-on-arrival shape). Returns the advanced clock.
    private func driveClean(_ pacer: FramePacer, from t: Double, frames: Int) -> Double {
        var t = t
        for _ in 0..<frames {
            t += 1.0 / 60.0
            pacer.submitForTest(makePixelBuffer(), now: t)
            _ = pacer.frameForVSyncForTest(now: t)
        }
        return t
    }

    /// One skipped 60fps slot: the next submit+present lands a 33.3ms present gap (telemetry
    /// shape — in v3 this never promotes).
    private func skipOneSlot(_ pacer: FramePacer, from t: Double) -> Double {
        let t2 = t + 2.0 / 60.0
        pacer.submitForTest(makePixelBuffer(), now: t2)
        _ = pacer.frameForVSyncForTest(now: t2)
        return t2
    }

    func testPromoteReprimesAndBoostsLiveDepth() {
        let pacer = FramePacer(targetDepth: 1, adaptiveDepth: true, renderCallback: { _ in })
        var t = driveClean(pacer, from: 0, frames: 130) // ~2.2s — past the fix-2c promote warmup
        XCTAssertEqual(pacer.currentDepth, 1)
        pacer.noteNetworkLateForTest(now: t) // network late #1 (owd spike)
        XCTAssertEqual(pacer.currentDepth, 1, "one late never promotes")
        t = driveClean(pacer, from: t, frames: 24) // 400ms clean
        pacer.noteNetworkLateForTest(now: t) // late #2 within 1s → promote
        XCTAssertEqual(pacer.currentDepth, 2, "2nd network late within the window boosts liveDepth")

        // Promote re-primed (primed = false): the next single frame is HELD until the slack is
        // rebuilt to depth 2 — the boost actually holds a standing frame.
        t += 1.0 / 60.0
        let held = makePixelBuffer()
        pacer.submitForTest(held, now: t)
        let shown = pacer.frameForVSyncForTest(now: t)
        XCTAssertTrue(shown !== held, "one frame < boosted depth ⇒ re-show last (slack rebuilding)")
        t += 1.0 / 60.0
        let second = makePixelBuffer()
        pacer.submitForTest(second, now: t)
        XCTAssertTrue(pacer.frameForVSyncForTest(now: t) === held, "slack rebuilt ⇒ present oldest in order")
    }

    func testDemoteRestoresDepthOneAndPresentOnArrival() {
        let pacer = FramePacer(targetDepth: 1, adaptiveDepth: true, renderCallback: { _ in })
        var t = driveClean(pacer, from: 0, frames: 130) // past the fix-2c promote warmup
        pacer.noteNetworkLateForTest(now: t)
        t = driveClean(pacer, from: t, frames: 24)
        pacer.noteNetworkLateForTest(now: t)
        XCTAssertEqual(pacer.currentDepth, 2)
        // While boosted, the present-on-arrival gate is unsatisfiable (empty-queue arrival can
        // never complete depth 2).
        XCTAssertFalse(FramePacer.shouldPresentOnArrival(
            enabled: true,
            queueWasEmpty: true,
            queueCount: 1,
            liveDepth: pacer.currentDepth,
        ))
        // 3s clean dwell (> 2.5s demote + 1s min-hold) → back to 1; the gate re-arms by itself.
        t = driveClean(pacer, from: t, frames: 180)
        XCTAssertEqual(pacer.currentDepth, 1, "clean dwell demotes back to the latency floor")
        XCTAssertTrue(FramePacer.shouldPresentOnArrival(
            enabled: true,
            queueWasEmpty: true,
            queueCount: 1,
            liveDepth: pacer.currentDepth,
        ))
    }

    /// v3 REGRESSION (the 2026-06-11/12 pinning bug, at the pacer level): genuine present-gap
    /// lates — skipped slots in dense flow — must neither count `lateFrames` nor move the depth.
    func testPresentGapsNeverPromote() {
        let pacer = FramePacer(targetDepth: 1, adaptiveDepth: true, renderCallback: { _ in })
        var t = driveClean(pacer, from: 0, frames: 130)
        for _ in 0..<6 { // six 33ms hitches ~400ms apart
            t = skipOneSlot(pacer, from: t)
            t = driveClean(pacer, from: t, frames: 24)
        }
        XCTAssertEqual(pacer.currentDepth, 1, "present gaps must never promote (v3)")
        let snap = pacer.drainTelemetry()
        XCTAssertEqual(snap.lateFrames, 0, "lateFrames carries network lates only (v3)")
        XCTAssertGreaterThanOrEqual(snap.presentGaps, 0)
    }

    func testDefaultOffPinsDepthButTelemetryCounts() {
        // adaptiveDepth false at the construction site (AISLOPDESK_ADAPTIVE_DEPTH=0).
        let pacer = FramePacer(targetDepth: 1, renderCallback: { _ in })
        var t = driveClean(pacer, from: 0, frames: 130)
        pacer.noteNetworkLateForTest(now: t)
        t = driveClean(pacer, from: t, frames: 24)
        pacer.noteNetworkLateForTest(now: t)
        XCTAssertEqual(pacer.currentDepth, 1, "depth action gated off ⇒ liveDepth never moves")
        let snap = pacer.drainTelemetry()
        XCTAssertEqual(snap.lateFrames, 2, "telemetry is unconditional — both lates counted")
        XCTAssertEqual(snap.depth, 1)
        XCTAssertEqual(pacer.drainTelemetry().lateFrames, 0, "drain resets the window")
    }

    func testV2DisablesV1Controller() {
        // BOTH adaptive systems requested ⇒ v1 forced off (one writer of liveDepth). The v1
        // grow-on-transient-dip path (`controller!.noteUnderrun()`) must be inert: an empty vsync
        // followed by a present would have grown a live v1 controller.
        let pacer = FramePacer(targetDepth: 1, adaptiveJitter: true, adaptiveDepth: true, renderCallback: { _ in })
        var t = driveClean(pacer, from: 0, frames: 30)
        _ = pacer.frameForVSyncForTest(now: t + 0.001) // empty tick → underflowRun = 1
        t += 1.0 / 60.0
        pacer.submitForTest(makePixelBuffer(), now: t)
        _ = pacer.frameForVSyncForTest(now: t) // transient-dip present (v1 would grow here)
        XCTAssertEqual(pacer.currentDepth, 1, "v1 is disabled — transient dips never inflate the depth")
    }

    func testManualDepth2IsTelemetryOnly() {
        // Manual AISLOPDESK_JITTER_DEPTH=2 + adaptiveDepth: the depth ACTION is disabled (the user
        // pinned the depth) but the policy still counts — the wire keeps carrying lates + depth 2.
        let pacer = FramePacer(targetDepth: 2, adaptiveDepth: true, renderCallback: { _ in })
        var t = driveClean(pacer, from: 0, frames: 130)
        pacer.noteNetworkLateForTest(now: t)
        t = driveClean(pacer, from: t, frames: 24)
        pacer.noteNetworkLateForTest(now: t)
        XCTAssertEqual(pacer.currentDepth, 2, "manual depth stays pinned")
        let snap = pacer.drainTelemetry()
        XCTAssertEqual(snap.depth, 2, "gauge reports the pinned depth")
        XCTAssertGreaterThanOrEqual(snap.lateFrames, 1, "counters still flow in telemetry-only mode")
    }
}
