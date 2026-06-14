import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE host-clock RTT/loss/jitter math for the network-feedback channel. NO wall-clock, NO I/O —
/// every timestamp is injected — so the estimate is deterministic and headlessly testable. The
/// central correctness property is CLOCK-SKEW IMMUNITY: RTT is `(hostNow − latestHostSendTs) −
/// clientHoldMs`, all in the host's own clock, so the two machines' clocks are never subtracted.
final class NetworkEstimateTests: XCTestCase {
    // MARK: computeRTTMillis — the host-clock subtraction

    func testRTTSubtractsClientHold() {
        // host stamped at 1000ms, host now 1080ms → 80ms elapsed; client held 30ms → RTT 50ms.
        XCTAssertEqual(NetworkEstimate.computeRTTMillis(hostNowMs: 1080, latestHostSendTs: 1000, clientHoldMs: 30), 50)
    }

    func testRTTZeroHold() {
        XCTAssertEqual(NetworkEstimate.computeRTTMillis(hostNowMs: 1080, latestHostSendTs: 1000, clientHoldMs: 0), 80)
    }

    /// WRAP SAFETY: the UInt32 ms counter wrapped between stamp and now. A naive `now − stamp`
    /// would underflow to a huge value; the wrap-aware Int32(bitPattern:) subtraction yields the
    /// correct small positive elapsed.
    func testRTTWrapAround() {
        let stamp: UInt32 = .max - 20 // 20ms before wrap
        let now: UInt32 = 30 // 30ms after wrap → true elapsed 51ms
        XCTAssertEqual(NetworkEstimate.computeRTTMillis(hostNowMs: now, latestHostSendTs: stamp, clientHoldMs: 1), 50)
    }

    // MARK: reject paths (return nil — never poison the EWMA, never trap)

    func testRejectsTelemetryOff() {
        XCTAssertNil(
            NetworkEstimate.computeRTTMillis(hostNowMs: 1000, latestHostSendTs: 0, clientHoldMs: 0),
            "latestHostSendTs == 0 means telemetry off / never observed",
        )
    }

    func testRejectsNegativeElapsed() {
        // Stamp is "ahead" of now by a small amount (a stale stamp from a prior session, or future
        // skew) → wrap-aware delta is negative → reject.
        XCTAssertNil(NetworkEstimate.computeRTTMillis(hostNowMs: 1000, latestHostSendTs: 1005, clientHoldMs: 0))
    }

    func testRejectsNegativeRTT() {
        // Hold exceeds elapsed → negative RTT → reject.
        XCTAssertNil(NetworkEstimate.computeRTTMillis(hostNowMs: 1080, latestHostSendTs: 1000, clientHoldMs: 200))
    }

    func testRejectsImplausiblyLargeRTT() {
        XCTAssertNil(
            NetworkEstimate.computeRTTMillis(hostNowMs: 100_000, latestHostSendTs: 1, clientHoldMs: 0),
            "> 60s RTT is implausible — dropped rather than poisoning the EWMA",
        )
        // Boundary: exactly 60_000 ms RTT is the inclusive limit — accepted; one over is rejected.
        XCTAssertEqual(NetworkEstimate.computeRTTMillis(hostNowMs: 60001, latestHostSendTs: 1, clientHoldMs: 0), 60000)
        XCTAssertNil(NetworkEstimate.computeRTTMillis(hostNowMs: 60002, latestHostSendTs: 1, clientHoldMs: 0))
    }

    func testTotalOverAllInputsDoesNotTrap() {
        // Exhaustive-ish smoke over extreme combinations — must never trap (returns Int? always).
        let values: [UInt32] = [0, 1, 1000, .max - 1, .max]
        for now in values { for stamp in values { for hold in values {
            _ = NetworkEstimate.computeRTTMillis(hostNowMs: now, latestHostSendTs: stamp, clientHoldMs: hold)
        }}}
    }

    // MARK: fold — EWMA RTT, minRTT, lossRate, gradient

    func testFoldSeedsThenSmoothsRTT() {
        var est = NetworkEstimate()
        est.fold(rttMillis: 100, framesReceived: 10, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertEqual(est.smoothedRTTMillis, 100, accuracy: 0.001, "first sample seeds the EWMA exactly")
        est.fold(rttMillis: 200, framesReceived: 10, unrecovered: 0, owdJitterMicros: 0)
        // 100*0.875 + 200*0.125 = 112.5
        XCTAssertEqual(est.smoothedRTTMillis, 112.5, accuracy: 0.001)
    }

    func testFoldTracksMinRTT() {
        var est = NetworkEstimate()
        est.fold(rttMillis: 80, framesReceived: 1, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertEqual(est.minRTTMillis, 80, accuracy: 0.001)
        est.fold(rttMillis: 50, framesReceived: 1, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertEqual(est.minRTTMillis, 50, accuracy: 0.001, "a lower sample lowers the baseline immediately")
        est.fold(rttMillis: 90, framesReceived: 1, unrecovered: 0, owdJitterMicros: 0)
        // Higher sample only slowly re-baselines (+1% of the gap): 50 + (90-50)*0.01 = 50.4
        XCTAssertEqual(est.minRTTMillis, 50.4, accuracy: 0.001)
    }

    func testFoldNilRTTStillFoldsLoss() {
        var est = NetworkEstimate()
        // Telemetry-off report (rtt nil) still folds loss + jitter, leaving RTT at its 0 seed.
        est.fold(rttMillis: nil, framesReceived: 100, unrecovered: 10, owdJitterMicros: 500)
        XCTAssertEqual(est.smoothedRTTMillis, 0, "no RTT sample → RTT untouched")
        XCTAssertGreaterThan(est.lossRate, 0, "loss still folds when RTT is rejected")
    }

    func testLossRateEWMAAndDivideByZeroGuard() {
        var est = NetworkEstimate()
        // framesReceived == 0 must NOT divide-by-zero — it contributes a 0 loss sample.
        est.fold(rttMillis: 10, framesReceived: 0, unrecovered: 5, owdJitterMicros: 0)
        XCTAssertEqual(est.lossRate, 0, accuracy: 0.0001, "0 frames received → 0 loss sample (no div-by-zero)")
        // 50% loss sample, EWMA toward it: 0*0.875 + 0.5*0.125 = 0.0625
        est.fold(rttMillis: 10, framesReceived: 100, unrecovered: 50, owdJitterMicros: 0)
        XCTAssertEqual(est.lossRate, 0.0625, accuracy: 0.0001)
    }

    // MARK: Component 3 (delay-gradient) — raw-sample freshness + trend folding

    /// The gradient cut's LEVEL corroboration must be per-report fresh: a fold stores its raw RTT
    /// sample, and a fold whose sample was REJECTED explicitly NILs it (never reuse stale evidence).
    func testFoldStoresRawRTTSampleAndNilsOnReject() {
        var est = NetworkEstimate()
        XCTAssertNil(est.lastRTTSampleMillis)
        est.fold(rttMillis: 80, framesReceived: 10, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertEqual(est.lastRTTSampleMillis, 80)
        est.fold(rttMillis: 35, framesReceived: 10, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertEqual(est.lastRTTSampleMillis, 35, "the raw sample is the MOST RECENT fold's, not a max/EWMA")
        est.fold(rttMillis: nil, framesReceived: 10, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertNil(est.lastRTTSampleMillis, "a rejected sample NILs the level evidence (freshness contract)")
    }

    func testFoldTrendFields() {
        var est = NetworkEstimate()
        XCTAssertFalse(est.owdTrendOverusing)
        est.fold(
            rttMillis: 10,
            framesReceived: 1,
            unrecovered: 0,
            owdJitterMicros: 0,
            owdTrendState: 1,
            owdTrendModifiedMilli: 42500,
        )
        XCTAssertTrue(est.owdTrendOverusing)
        XCTAssertEqual(est.owdTrendModified, 42.5, accuracy: 0.0001)
        est.fold(
            rttMillis: 10,
            framesReceived: 1,
            unrecovered: 0,
            owdJitterMicros: 0,
            owdTrendState: 2,
            owdTrendModifiedMilli: -500,
        )
        XCTAssertFalse(est.owdTrendOverusing, "underusing (2) is not overusing")
        XCTAssertEqual(est.owdTrendModified, -0.5, accuracy: 0.0001)
        est.fold(rttMillis: 10, framesReceived: 1, unrecovered: 0, owdJitterMicros: 0)
        XCTAssertFalse(est.owdTrendOverusing, "defaulted params read state 0 = normal (per-report fresh)")
        XCTAssertEqual(est.owdTrendModified, 0)
    }

    /// The defaulted trend params are the blast-radius cap: a pre-trend fold sequence and the same
    /// sequence with explicit zeros produce Equatable-identical estimates.
    func testDefaultedTrendParamsPreserveOldFoldBehavior() {
        var a = NetworkEstimate()
        var b = NetworkEstimate()
        for i in 0..<20 {
            a.fold(rttMillis: 50 + i, framesReceived: 100, unrecovered: UInt32(i % 3), owdJitterMicros: UInt32(i * 10))
            b.fold(
                rttMillis: 50 + i,
                framesReceived: 100,
                unrecovered: UInt32(i % 3),
                owdJitterMicros: UInt32(i * 10),
                owdTrendState: 0,
                owdTrendModifiedMilli: 0,
            )
        }
        XCTAssertEqual(a, b)
    }

    func testOWDGradientWarmupThenRising() {
        var est = NetworkEstimate()
        // Warmup: the first two folds must NOT flip the gradient (no predecessor to compare yet).
        est.fold(rttMillis: 10, framesReceived: 1, unrecovered: 0, owdJitterMicros: 100)
        XCTAssertFalse(est.owdGradientRising)
        est.fold(rttMillis: 10, framesReceived: 1, unrecovered: 0, owdJitterMicros: 9999)
        XCTAssertFalse(est.owdGradientRising, "still in warmup — no spurious rising flag")
        // 3rd fold: 200 > 9999? no → falling.
        est.fold(rttMillis: 10, framesReceived: 1, unrecovered: 0, owdJitterMicros: 200)
        XCTAssertFalse(est.owdGradientRising, "jitter fell vs previous")
        // 4th fold: 500 > 200 → rising.
        est.fold(rttMillis: 10, framesReceived: 1, unrecovered: 0, owdJitterMicros: 500)
        XCTAssertTrue(est.owdGradientRising, "jitter rose vs previous")
    }
}
