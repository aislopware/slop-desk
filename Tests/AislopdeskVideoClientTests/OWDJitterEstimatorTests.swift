import XCTest
@testable import AislopdeskVideoClient
import AislopdeskVideoProtocol

/// PURE client-clock-only inter-arrival jitter (the network-feedback channel). RFC3550 2nd-difference
/// form — uses ONLY the client's own relative arrival deltas, so it is clock-skew-immune. The caller
/// injects each arrival time, so there is no wall-clock and the math is deterministic.
final class OWDJitterEstimatorTests: XCTestCase {

    func testSteadyCadenceYieldsNearZeroJitter() {
        var est = OWDJitterEstimator()
        // Perfectly even 16ms arrivals → zero 2nd-difference → ~0 jitter.
        var t = 0.0
        for _ in 0 ..< 50 { est.note(arrival: t); t += 0.016 }
        XCTAssertEqual(est.jitterSeconds, 0, accuracy: 1e-9, "even cadence → no jitter")
        XCTAssertEqual(est.jitterMicros(), 0)
    }

    func testFirstSamplesSeedWithoutSpike() {
        var est = OWDJitterEstimator()
        // First arrival: only seeds lastArrival — no interval yet.
        est.note(arrival: 100.0)
        XCTAssertEqual(est.jitterSeconds, 0, "first sample cannot emit jitter")
        // Second arrival: seeds the first interval — still no 2nd-difference.
        est.note(arrival: 100.05)
        XCTAssertEqual(est.jitterSeconds, 0, "second sample only seeds the first interval — no spike")
        // Third arrival: now a 2nd-difference exists and jitter can move.
        est.note(arrival: 100.2)   // interval jumped 50ms → 150ms
        XCTAssertGreaterThan(est.jitterSeconds, 0, "an interval change finally produces jitter")
    }

    func testVariableArrivalsRaiseJitter() {
        var est = OWDJitterEstimator()
        // Wildly uneven intervals → jitter climbs above a steady stream's.
        let arrivals = [0.0, 0.01, 0.05, 0.055, 0.2, 0.21, 0.5]
        for a in arrivals { est.note(arrival: a) }
        XCTAssertGreaterThan(est.jitterMicros(), 0, "variable arrivals produce nonzero jitter")

        var steady = OWDJitterEstimator()
        var t = 0.0
        for _ in 0 ..< arrivals.count { steady.note(arrival: t); t += 0.05 }
        XCTAssertGreaterThan(est.jitterSeconds, steady.jitterSeconds, "uneven jitter exceeds steady jitter")
    }

    func testJitterMicrosClampsNonNegativeAndSaturates() {
        // A fresh estimator is 0 → 0 micros (no trap on the UInt32(Double) init).
        XCTAssertEqual(OWDJitterEstimator().jitterMicros(), 0)
        // Drive a large but finite jitter and confirm it stays within UInt32 (never traps).
        var est = OWDJitterEstimator()
        est.note(arrival: 0)
        est.note(arrival: 1)        // 1s interval
        est.note(arrival: 1000)     // 999s interval — a huge 2nd-difference
        let micros = est.jitterMicros()
        XCTAssertLessThanOrEqual(micros, UInt32.max)
        XCTAssertGreaterThan(micros, 0)
    }
}
