import XCTest
@testable import AislopdeskVideoClient

/// Depth v3 owd-spike detector. All samples injected; clocks are plain doubles (client ms) and
/// UInt32 host stamps — the cross-machine offset is arbitrary and must cancel.
final class OwdLateDetectorTests: XCTestCase {
    /// 60 fps interval used by most tests.
    private let interval = 1000.0 / 60.0

    /// Feeds `n` clean steady samples at 60 fps starting from (arrival0, send0) with a constant
    /// owd offset, asserting none classify late. Returns the next (arrival, send) pair.
    @discardableResult
    private func warm(
        _ d: inout OwdLateDetector,
        n: Int = 30,
        arrival0: Double = 5000,
        send0: UInt32 = 91000,
    ) -> (Double, UInt32) {
        var arrival = arrival0
        var send = send0
        for _ in 0..<n {
            XCTAssertNil(d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval))
            arrival += 16.7
            send &+= 17
        }
        return (arrival, send)
    }

    func testCleanSteadyStreamNeverLate() {
        var d = OwdLateDetector()
        warm(&d, n: 200)
    }

    func testWarmupSuppressesEarlyVerdicts() {
        var d = OwdLateDetector()
        var arrival = 1000.0
        var send: UInt32 = 50000
        // Huge spikes during the first warmupSamples-1 samples must stay silent.
        for _ in 0..<(OwdLateDetector.Config().warmupSamples - 1) {
            XCTAssertNil(d.note(arrivalMs: arrival + 500, sendTs: send, intervalMs: interval))
            arrival += 16.7
            send &+= 17
        }
    }

    func testSpikePastThresholdIsLate() {
        var d = OwdLateDetector()
        var (arrival, send) = warm(&d)
        // One frame delayed by +40ms over the established baseline (threshold = max(25, 1.25×16.7)=25).
        arrival += 16.7 + 40
        send &+= 17
        let over = d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)
        XCTAssertNotNil(over)
        XCTAssertGreaterThan(over ?? 0, 10) // 40 − threshold(25) = 15
    }

    /// THE MEASURED FALSE-LATE BAND (2026-06-12 live): packetize-stamped frames pick up 10-20ms
    /// of VideoSendLane pacing wobble during dense scroll — that band must never classify late
    /// (at the first deploy's 10ms floor it produced 153 lates/90s and depth flapping).
    func testPacingWobbleBandNeverLate() {
        var d = OwdLateDetector()
        var (arrival, send) = warm(&d)
        for i in 0..<50 {
            arrival += 16.7 + (i.isMultiple(of: 3) ? 18 : (i % 3 == 1 ? -18 : 0))
            send &+= 17
            XCTAssertNil(
                d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval),
                "±18ms pacing wobble sits under the 25ms floor",
            )
        }
    }

    func testSpikesDoNotRaiseBaseline() {
        var d = OwdLateDetector()
        var (arrival, send) = warm(&d)
        // A burst of late frames (queue builds: each arrival lags its send by +30 more)...
        for _ in 0..<5 {
            arrival += 16.7 + 30
            send &+= 17
            _ = d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)
        }
        // ...then the queue DRAINS: frames arrive bunched (1ms apart) while sends stay at
        // cadence, walking owd back down to the baseline.
        var verdictAtBaseline: Double? = .infinity
        for _ in 0..<12 {
            arrival += 1
            send &+= 17
            verdictAtBaseline = d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)
        }
        // The last drained frame is back at (slightly below) baseline owd: must be clean —
        // the burst can't have dragged the min-baseline up.
        XCTAssertNil(verdictAtBaseline)
    }

    func testStandingQueueRebasesAfterRotation() {
        var d = OwdLateDetector()
        var (arrival, send) = warm(&d)
        // The path's delay steps up +50ms PERMANENTLY (route change / standing queue).
        arrival += 16.7 + 50
        send &+= 17
        XCTAssertNotNil(d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)) // the step itself spikes
        // After two full bucket rotations (2 × bucketMs of arrivals at the new level), the new
        // level IS the baseline — steady frames are clean again (variation, not level). The
        // transition itself may flag a few lates; only the end state matters.
        for _ in 0..<260 { // 260 × 16.7ms ≈ 4.3s > 2 buckets
            arrival += 16.7
            send &+= 17
            _ = d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)
        }
        arrival += 16.7
        send &+= 17
        XCTAssertNil(
            d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval),
            "steady post-rebase frame must be clean",
        )
    }

    func testContentGapsHarmless() {
        var d = OwdLateDetector()
        var (arrival, send) = warm(&d)
        // Host idle 2s (no frames) — send and arrival advance together; owd unchanged.
        arrival += 2000
        send &+= 2000
        XCTAssertNil(d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval))
        // Resume at cadence: still clean.
        for _ in 0..<10 {
            arrival += 16.7
            send &+= 17
            XCTAssertNil(d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval))
        }
    }

    func testSendStampWrapIsContinuous() {
        var d = OwdLateDetector()
        // Start close to the UInt32 wrap so the stamp wraps mid-warm.
        var (arrival, send) = warm(&d, n: 30, arrival0: 5000, send0: UInt32.max - 200)
        for _ in 0..<30 {
            arrival += 16.7
            send &+= 17 // wraps through 0
            XCTAssertNil(
                d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval),
                "wrap must not fabricate an owd discontinuity",
            )
        }
    }

    func testThresholdScalesWithInterval() {
        var d = OwdLateDetector()
        var arrival = 5000.0
        var send: UInt32 = 91000
        let slow = 1000.0 / 15.0 // governed-down stream: 15 fps → threshold 0.75×66.7 = 50ms
        for _ in 0..<30 {
            XCTAssertNil(d.note(arrivalMs: arrival, sendTs: send, intervalMs: slow))
            arrival += 66.7
            send &+= 67
        }
        // +30ms spike: late at 60fps (>12.5) but NOT at 15fps (≤50) — one missed slot is rarer.
        arrival += 66.7 + 30
        send &+= 67
        XCTAssertNil(d.note(arrivalMs: arrival, sendTs: send, intervalMs: slow))
    }

    func testEnvConfigClamps() {
        let c = OwdLateDetector.Config.fromEnvironment([
            "AISLOPDESK_OWD_LATE_FLOOR_MS": "0.2", // below min → clamp to 1
            "AISLOPDESK_OWD_LATE_FRAC_PCT": "9999", // above max → clamp to 400%
            "AISLOPDESK_OWD_LATE_WARMUP": "0", // below min → clamp to 1
        ])
        XCTAssertEqual(c.thresholdFloorMs, 1)
        XCTAssertEqual(c.thresholdIntervalFraction, 4.0)
        XCTAssertEqual(c.warmupSamples, 1)
        let d = OwdLateDetector.Config.fromEnvironment([:])
        XCTAssertEqual(d, OwdLateDetector.Config())
    }
}
