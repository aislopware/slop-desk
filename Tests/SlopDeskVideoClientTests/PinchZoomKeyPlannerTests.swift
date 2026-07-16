import XCTest
@testable import SlopDeskVideoClient

/// Pins the pinch→⌘=/⌘− step accumulator: threshold stepping, residual carry, the per-event
/// step cap, begin() reset, and defensive non-finite handling.
final class PinchZoomKeyPlannerTests: XCTestCase {
    func testBelowThresholdAccumulatesThenSteps() {
        var p = PinchZoomKeyPlanner()
        p.begin()
        XCTAssertEqual(p.ingest(magnification: 0.1), 0)
        XCTAssertEqual(p.ingest(magnification: 0.05), 0)
        XCTAssertEqual(p.ingest(magnification: 0.05), 1) // Σ = 0.2 → one zoom-in step
        XCTAssertEqual(p.ingest(magnification: 0.0), 0) // residual back to 0 — no free step
    }

    func testZoomOutDirection() {
        var p = PinchZoomKeyPlanner()
        p.begin()
        XCTAssertEqual(p.ingest(magnification: -0.45), -2) // 2 steps out, residual ≈ −0.05
        // −0.16 (not −0.15): binary fp makes the −0.45 residual a hair ABOVE −0.05, so an exact
        // −0.20 sum would miss the threshold by 1 ulp — the planner self-corrects next event, but
        // the pin must not sit on an unrepresentable boundary.
        XCTAssertEqual(p.ingest(magnification: -0.16), -1)
    }

    func testPerEventStepCapAndResidualCarry() {
        var p = PinchZoomKeyPlanner()
        p.begin()
        // One giant delta: capped at 3 steps; the excess stays as residual for the next event.
        XCTAssertEqual(p.ingest(magnification: 1.0), 3)
        XCTAssertEqual(p.ingest(magnification: 0.0), 2) // the carried 0.4 drains as 2 more steps
    }

    func testBeginResetsResidual() {
        var p = PinchZoomKeyPlanner()
        p.begin()
        XCTAssertEqual(p.ingest(magnification: 0.19), 0)
        p.begin() // new pinch — the 0.19 must not leak
        XCTAssertEqual(p.ingest(magnification: 0.19), 0)
        XCTAssertEqual(p.ingest(magnification: 0.01), 1)
    }

    func testDirectionReversalWithinGesture() {
        var p = PinchZoomKeyPlanner()
        p.begin()
        XCTAssertEqual(p.ingest(magnification: 0.15), 0)
        XCTAssertEqual(p.ingest(magnification: -0.15), 0) // net 0 — reversal cancels, no step
        XCTAssertEqual(p.ingest(magnification: -0.2), -1)
    }

    func testNonFiniteDeltasAreDropped() {
        var p = PinchZoomKeyPlanner()
        p.begin()
        XCTAssertEqual(p.ingest(magnification: .nan), 0)
        XCTAssertEqual(p.ingest(magnification: .infinity), 0)
        XCTAssertEqual(p.ingest(magnification: 0.2), 1) // accumulator unpoisoned
    }
}
