import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// PURE delay-gradient detector (component 3): windowed OLS slope over per-frame delay variation,
/// libwebrtc smoothing + adaptive threshold + sustained-overuse detection, idle-gap reset, UInt32
/// sendTs wrap handling — plus the one-sample-per-frame ``TrendSampler`` gate and the wire packing
/// helpers. Every input is injected (no wall-clock), so every test is a deterministic replay.
///
/// These tests assume the production default tunables (no `AISLOPDESK_TREND_*` set in the test
/// environment), mirroring `LiveCongestionControllerTests`.
final class TrendlineEstimatorTests: XCTestCase {
    /// Seeds the estimator then feeds `count` samples at a constant cadence (arrival step /
    /// host-stamp step in ms), returning the updated cursor for follow-on phases.
    private func feed(
        _ est: inout TrendlineEstimator,
        count: Int,
        arrival: inout Double,
        ts: inout UInt32,
        arrivalStepMs: Double = 16,
        sendStepMs: UInt32 = 16,
    ) {
        for _ in 0..<count {
            arrival += arrivalStepMs
            ts &+= sendStepMs
            est.note(arrivalMs: arrival, sendTs: ts)
        }
    }

    // MARK: Detector states

    func testFlatDelayStaysNormal() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        for _ in 0..<200 {
            arrival += 16
            ts &+= 16
            est.note(arrivalMs: arrival, sendTs: ts)
            XCTAssertEqual(est.state, .normal, "constant inter-arrival == inter-send ⇒ zero slope ⇒ normal")
        }
        XCTAssertEqual(est.modifiedTrend, 0, accuracy: 0.0001)
    }

    /// THE latency claim's unit evidence (MEASURED onsets, deterministic): a steady stream then a
    /// linear owd ramp signals OVERUSING in a steepness-scaled handful of per-frame samples —
    /// +25ms/frame (the real bottleneck-step shape: demand ~2.5× capacity) detects in 5 samples
    /// (~83ms at 60fps, matching the closed-loop [G] run exactly); a gentle +1.5ms/frame creep
    /// still detects, in 14 (~235ms) — both far inside the smoothed-RTT path's ~3-report floor.
    func testLinearRampSignalsOveruse() {
        func onset(rampMsPerFrame: Double) -> Int? {
            var est = TrendlineEstimator()
            var arrival = 1000.0
            var ts: UInt32 = 5000
            est.note(arrivalMs: arrival, sendTs: ts)
            feed(&est, count: 60, arrival: &arrival, ts: &ts)
            XCTAssertEqual(est.state, .normal, "steady pre-fill must not signal")
            for i in 1...40 {
                arrival += 16 + rampMsPerFrame
                ts &+= 16
                est.note(arrivalMs: arrival, sendTs: ts)
                if est.state == .overusing { return i }
            }
            return nil
        }
        let steep = onset(rampMsPerFrame: 25) // the [G] capacity-step shape
        XCTAssertNotNil(steep, "a bottleneck-step ramp must signal overuse")
        XCTAssertLessThanOrEqual(
            steep ?? .max,
            6,
            "steep-onset detection within ≤6 ramp samples (~100ms; got \(steep ?? -1))",
        )
        let gentle = onset(rampMsPerFrame: 1.5) // a slow creep
        XCTAssertNotNil(gentle, "even a gentle sustained ramp must signal overuse")
        XCTAssertLessThanOrEqual(
            gentle ?? .max,
            16,
            "gentle-creep detection within ≤16 ramp samples (got \(gentle ?? -1))",
        )
    }

    func testRampThenPlateauReturnsToNormal() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        feed(&est, count: 60, arrival: &arrival, ts: &ts)
        feed(&est, count: 15, arrival: &arrival, ts: &ts, arrivalStepMs: 17.5)
        XCTAssertEqual(est.state, .overusing, "precondition: the ramp signalled")
        // The queue stops growing (a standing plateau — the PROPORTIONAL path's job, not ours):
        // as the window refills with flat samples the slope collapses and the verdict clears.
        feed(&est, count: TrendlineEstimator.windowSize + 5, arrival: &arrival, ts: &ts)
        XCTAssertEqual(est.state, .normal, "overuse clears within ~one window of plateau samples")
    }

    func testDrainSignalsUnderusingNeverOverusing() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        feed(&est, count: 60, arrival: &arrival, ts: &ts)
        var sawUnderusing = false
        for _ in 0..<40 {
            arrival += 14.5 // −1.5ms owd per frame: the queue is draining
            ts &+= 16
            est.note(arrivalMs: arrival, sendTs: ts)
            XCTAssertNotEqual(est.state, .overusing, "a draining queue must never read overusing")
            if est.state == .underusing { sawUnderusing = true }
        }
        XCTAssertTrue(sawUnderusing, "a sustained negative ramp signals underusing")
    }

    /// The rate-independent path texture that falsified two fixed-threshold delay designs: a ±8ms
    /// owd saw with ZERO net ramp must never signal overuse (the adaptive threshold rides above it).
    func testAlternatingJitterNeverOverusing() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        for i in 0..<500 {
            arrival += i.isMultiple(of: 2) ? 24 : 8 // owd alternates +8 / −8 around the same level
            ts &+= 16
            est.note(arrivalMs: arrival, sendTs: ts)
            XCTAssertNotEqual(est.state, .overusing, "zero-net-ramp jitter must never read overusing (sample \(i))")
        }
    }

    func testSingleStepSpikeDoesNotLatchOveruse() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        feed(&est, count: 60, arrival: &arrival, ts: &ts)
        // One-off +30ms owd step (a single late frame), then flat at the new level.
        arrival += 46
        ts &+= 16
        est.note(arrivalMs: arrival, sendTs: ts)
        // The smoothed-delay EWMA chases the step for a few samples (a transient verdict is
        // acceptable); within ~one window of flat samples the slope is gone — it must NOT latch.
        feed(&est, count: TrendlineEstimator.windowSize + 5, arrival: &arrival, ts: &ts)
        XCTAssertEqual(est.state, .normal, "a step spike un-latches within one window of flat samples")
        feed(&est, count: 10, arrival: &arrival, ts: &ts)
        XCTAssertEqual(est.state, .normal)
    }

    // MARK: Wrap / reorder / idle robustness

    func testSendTsWrapContinuity() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts = UInt32.max - 100 // wraps inside the run
        est.note(arrivalMs: arrival, sendTs: ts)
        for _ in 0..<200 {
            arrival += 16
            ts &+= 16 // wrap-aware &+ — crosses UInt32.max
            est.note(arrivalMs: arrival, sendTs: ts)
            XCTAssertEqual(est.state, .normal, "the wrap must not read as a delay cliff")
            XCTAssertLessThan(
                abs(est.modifiedTrend),
                TrendlineEstimator.thresholdMin,
                "no slope spike across the UInt32 wrap",
            )
        }
    }

    func testIdleGapResetsWindow() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        feed(&est, count: 60, arrival: &arrival, ts: &ts)
        XCTAssertGreaterThan(est.numDeltas, 0)
        // A 300ms arrival gap (> resetGapMs): the queue context is stale — window cleared.
        arrival += 300
        ts &+= 300
        est.note(arrivalMs: arrival, sendTs: ts)
        XCTAssertEqual(est.numDeltas, 0, "the idle gap resets the regression context")
        XCTAssertEqual(est.state, .normal)
        // A steep post-gap ramp may NOT signal until the window refills (no two-cluster
        // regression artifact) …
        for _ in 0..<(TrendlineEstimator.windowSize - 1) {
            arrival += 21 // +5ms owd per frame — would scream overuse in a full window
            ts &+= 16
            est.note(arrivalMs: arrival, sendTs: ts)
            XCTAssertEqual(est.state, .normal, "no verdict while the post-reset window refills")
        }
        // … and once it has refilled, the same ramp DOES signal (only the warm-up gated it).
        var fired = false
        for _ in 0..<25 {
            arrival += 21
            ts &+= 16
            est.note(arrivalMs: arrival, sendTs: ts)
            if est.state == .overusing { fired = true
                break
            }
        }
        XCTAssertTrue(fired, "the refilled window detects the ramp normally")
    }

    /// STALE-TREND GATE: a latched overuse verdict goes STALE after an idle gap WITHOUT a new
    /// arrival. State only mutates in `note()` and the idle reset fires on the NEXT arrival
    /// (≥ resetGapMs later), so in between the report path must consult `isStale` and ship
    /// neutral/zero trend fields instead of riding the dead verdict on every 50 ms report.
    func testVerdictGoesStaleAcrossIdleGapWithoutNewArrival() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        feed(&est, count: 60, arrival: &arrival, ts: &ts)
        feed(&est, count: 15, arrival: &arrival, ts: &ts, arrivalStepMs: 17.5)
        XCTAssertEqual(est.state, .overusing, "precondition: the ramp signalled")
        XCTAssertFalse(est.isStale(nowMs: arrival), "report co-incident with the last sample is fresh")
        XCTAssertFalse(
            est.isStale(nowMs: arrival + TrendlineEstimator.resetGapMs),
            "at exactly the reset gap it is still fresh (mirrors note()'s strict >)",
        )
        XCTAssertTrue(
            est.isStale(nowMs: arrival + TrendlineEstimator.resetGapMs + 1),
            "past the reset gap the verdict is stale — NO new arrival was needed",
        )
        XCTAssertEqual(
            est.state,
            .overusing,
            "the estimator state itself is untouched — the gate is report-side",
        )
        XCTAssertNotEqual(
            est.wireTrendFlags & 0x3,
            0,
            "the raw wire flags would still carry the dead verdict — which is exactly why the report must zero them when stale",
        )
        XCTAssertTrue(TrendlineEstimator().isStale(nowMs: 0), "no samples yet ⇒ stale")
    }

    func testNegativeSendDeltaIgnored() {
        var est = TrendlineEstimator()
        var arrival = 1000.0
        var ts: UInt32 = 5000
        est.note(arrivalMs: arrival, sendTs: ts)
        feed(&est, count: 30, arrival: &arrival, ts: &ts)
        let before = est
        // A reordered OLDER stamp slips through (TrendSampler normally rejects this upstream).
        est.note(arrivalMs: arrival + 16, sendTs: ts &- 100)
        XCTAssertEqual(est, before, "a negative send delta is ignored entirely (state untouched)")
    }

    func testDeterministicReplayEquatable() {
        func drive(_ est: inout TrendlineEstimator) {
            var arrival = 1000.0
            var ts: UInt32 = 5000
            est.note(arrivalMs: arrival, sendTs: ts)
            for i in 0..<150 {
                arrival += i.isMultiple(of: 3) ? 18.5 : 15.0
                ts &+= 16
                est.note(arrivalMs: arrival, sendTs: ts)
            }
        }
        var a = TrendlineEstimator()
        var b = TrendlineEstimator()
        drive(&a)
        drive(&b)
        XCTAssertEqual(a, b, "same input ⇒ Equatable-identical state (deterministic replay)")
        XCTAssertEqual(a.wireTrendMilli, b.wireTrendMilli)
        XCTAssertEqual(a.wireTrendFlags, b.wireTrendFlags)
    }

    // MARK: Wire packing

    func testWireFieldClamping() {
        // ±1e9-milli clamp at magnitudes the estimator cannot reach organically.
        XCTAssertEqual(TrendlineEstimator.packTrendMilli(2_000_000), UInt32(bitPattern: 1_000_000_000))
        XCTAssertEqual(TrendlineEstimator.packTrendMilli(-2_000_000), UInt32(bitPattern: -1_000_000_000))
        XCTAssertEqual(TrendlineEstimator.packTrendMilli(12.5), UInt32(bitPattern: 12500))
        XCTAssertEqual(TrendlineEstimator.packTrendMilli(-0.5), UInt32(bitPattern: -500))
        XCTAssertEqual(TrendlineEstimator.packTrendMilli(0), 0)
    }

    func testWireFlagsPackAndReportAccessorsRoundTrip() {
        let flags = TrendlineEstimator.packTrendFlags(state: .overusing, numDeltas: 300)
        let report = NetworkStatsReport(
            framesReceived: 0, fecRecovered: 0, unrecovered: 0, latestHostSendTs: 0,
            clientHoldMs: 0, owdJitterMicros: 0,
            owdTrendMilli: TrendlineEstimator.packTrendMilli(-42.5), owdTrendFlags: flags,
        )
        XCTAssertEqual(report.owdTrendStateRaw, TrendlineEstimator.State.overusing.rawValue)
        XCTAssertEqual(report.owdTrendDeltas, 255, "numDeltas saturates at the 8-bit wire cap")
        XCTAssertEqual(report.owdTrendModifiedMilliSigned, -42500)
        let normal = TrendlineEstimator.packTrendFlags(state: .underusing, numDeltas: 7)
        XCTAssertEqual(UInt8(truncatingIfNeeded: normal) & 0x3, TrendlineEstimator.State.underusing.rawValue)
        XCTAssertEqual(Int((normal >> 8) & 0xFF), 7)
    }

    // MARK: TrendSampler — the one-sample-per-frame admission gate

    func testSamplerAdmitsFirstFragmentOfEachNewFrameOnly() {
        var gate = TrendSampler()
        XCTAssertTrue(gate.shouldSample(frameID: 5, sendTs: 100), "first fragment of the first frame samples")
        XCTAssertFalse(gate.shouldSample(frameID: 5, sendTs: 100), "later fragments of the same frame do not")
        XCTAssertFalse(gate.shouldSample(frameID: 5, sendTs: 100), "kfDup duplicates (same frameID re-sent) do not")
        XCTAssertTrue(gate.shouldSample(frameID: 6, sendTs: 116), "the next frame's first fragment samples")
    }

    func testSamplerRejectsReorderedOlderFrame() {
        var gate = TrendSampler()
        XCTAssertTrue(gate.shouldSample(frameID: 10, sendTs: 100))
        XCTAssertFalse(gate.shouldSample(frameID: 9, sendTs: 84), "a reordered older frame is rejected")
        XCTAssertFalse(gate.shouldSample(frameID: 10, sendTs: 100), "the frontier did not regress")
        XCTAssertTrue(gate.shouldSample(frameID: 11, sendTs: 116))
    }

    func testSamplerNeverSamplesTsZero() {
        var gate = TrendSampler()
        XCTAssertFalse(gate.shouldSample(frameID: 1, sendTs: 0), "ts==0 = telemetry off — never sample")
        // …and a ts==0 fragment must not latch the frameID either.
        XCTAssertTrue(gate.shouldSample(frameID: 1, sendTs: 50), "the same frame with a real stamp still samples")
    }

    func testSamplerWrapAwareFrameIDContinuity() {
        var gate = TrendSampler()
        XCTAssertTrue(gate.shouldSample(frameID: .max, sendTs: 100))
        XCTAssertTrue(gate.shouldSample(frameID: 0, sendTs: 116), "frameID 0 is strictly newer across the wrap")
        XCTAssertFalse(gate.shouldSample(frameID: .max, sendTs: 100), "pre-wrap id is now older")
    }
}
