import XCTest
@testable import AislopdeskVideoClient

/// DEADLINE PACER (2026-06-10 Parsec-smoothness research): presentation deadlines anchored to
/// the CONTENT rhythm (lastDeadline + interval), not arrival times — so ±network jitter cannot
/// modulate inter-presentation spacing (the "bunched frame" 8/8/17ms stutter). Pure-math tests;
/// the GUI tick wiring follows the same decision functions.
final class FramePacerDeadlineTests: XCTestCase {
    private let interval = 1.0 / 60.0
    private let playout = 0.020

    func testFirstFrameSchedulesArrivalPlusPlayout() {
        XCTAssertEqual(FramePacer.deadlineForArrival(arrival: 10.0, lastDeadline: 0, interval: interval, playoutDelay: playout),
                       10.020, accuracy: 1e-9)
    }

    func testSteadyStateExtendsContentRhythmIgnoringArrivalJitter() {
        // Frames arriving early/late by ±10ms get the SAME deadline: lastDeadline + interval.
        let last = 10.020
        for arrivalJitter in [-0.010, 0.0, 0.010] {
            let arrival = last + interval + arrivalJitter - playout
            XCTAssertEqual(FramePacer.deadlineForArrival(arrival: arrival, lastDeadline: last, interval: interval, playoutDelay: playout),
                           last + interval, accuracy: 1e-9,
                           "jitter \(arrivalJitter) must not move the deadline")
        }
    }

    func testBunchedPairKeepsFullSpacing() {
        // Two frames arriving 2ms apart (bunched after jitter) still get deadlines a FULL
        // interval apart — the exact anti-stutter property the arrival-driven pacer lacked.
        let d1 = FramePacer.deadlineForArrival(arrival: 5.000, lastDeadline: 4.990, interval: interval, playoutDelay: playout)
        let d2 = FramePacer.deadlineForArrival(arrival: 5.002, lastDeadline: d1, interval: interval, playoutDelay: playout)
        XCTAssertEqual(d2 - d1, interval, accuracy: 1e-9)
    }

    func testStallReanchorsInsteadOfFastForwarding() {
        // The rhythm fell 150ms behind (network stall): re-anchor at arrival + playout, do not
        // burn through the backlog at tick rate.
        let last = 10.0
        let arrivalAfterStall = last + 0.150
        XCTAssertEqual(FramePacer.deadlineForArrival(arrival: arrivalAfterStall, lastDeadline: last, interval: interval, playoutDelay: playout),
                       arrivalAfterStall + playout, accuracy: 1e-9)
        // Just-one-interval late is NOT a stall — the rhythm holds.
        XCTAssertEqual(FramePacer.deadlineForArrival(arrival: last + interval * 1.5, lastDeadline: last, interval: interval, playoutDelay: playout),
                       last + interval, accuracy: 1e-9)
    }

    func testDeadlineDueHalfTickLookahead() {
        let halfTick = 0.5 / 120.0
        XCTAssertTrue(FramePacer.deadlineDue(deadline: 1.000, now: 1.000, halfTick: halfTick))
        XCTAssertTrue(FramePacer.deadlineDue(deadline: 1.003, now: 1.000, halfTick: halfTick), "within lookahead → present this tick")
        XCTAssertFalse(FramePacer.deadlineDue(deadline: 1.006, now: 1.000, halfTick: halfTick), "beyond lookahead → wait")
    }

    func testDeadlineModeEndToEndThroughTicks() {
        // Behavioral: frames submitted with jitter present at EVEN spacing through tick().
        final class Times: @unchecked Sendable {
            private let lock = NSLock(); private var v: [Double] = []
            func add(_ t: Double) { lock.lock(); v.append(t); lock.unlock() }
            var all: [Double] { lock.lock(); defer { lock.unlock() }; return v }
        }
        _ = Times()
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        let rendered = Times()
        let pacer = FramePacer(maxFrameRate: 120, targetDepth: 1, deadlineMode: true, contentFps: 60, playoutDelayMs: 20) { _ in
            rendered.add(1)
        }
        // Submit one frame, then drive ticks past its deadline: exactly ONE render.
        pacer.submit(pb!)
        let start = FramePacer.currentHostTimeSeconds()
        var t = start
        for _ in 0..<10 { t += 1.0 / 120.0; pacer.tick(hostTimeSeconds: t) }
        XCTAssertEqual(rendered.all.count, 1, "one pending frame presents exactly once at its deadline")
    }
}
