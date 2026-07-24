// WorkingShimmerTests — pins the stepped title shimmer's PURE phase math (`WorkingShimmer`): the
// sweep/rest duty cycle, the discrete band quantization (mechanical ticks, never a glide), the full
// enter/exit travel, and the clamped, non-decreasing gradient profile. Headless value assertions —
// no SwiftUI render, no clocks read (dates are constructed, the math is clock-in/value-out).

import XCTest
@testable import SlopDeskClientUI

final class WorkingShimmerTests: XCTestCase {
    /// A date `t` seconds into the cycle (the epoch is a fixed reference, so absolute offsets pin
    /// phase exactly; any whole number of cycles later is the same phase).
    private func at(_ t: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: t)
    }

    // MARK: - duty cycle

    /// The band exists exactly during the sweep and is `nil` for the whole rest beat — the pause is
    /// what keeps the motion deliberate instead of a continuous loop.
    func testRestBeatHasNoBand() {
        XCTAssertNotNil(WorkingShimmer.bandCenter(at: at(0)))
        XCTAssertNotNil(WorkingShimmer.bandCenter(at: at(WorkingShimmer.sweepDuration - 0.01)))
        XCTAssertNil(WorkingShimmer.bandCenter(at: at(WorkingShimmer.sweepDuration)))
        XCTAssertNil(WorkingShimmer.bandCenter(
            at: at(WorkingShimmer.sweepDuration + WorkingShimmer.restDuration - 0.01),
        ))
    }

    /// Phase wraps at the cycle boundary: one full cycle later is the same reading.
    func testPhaseWrapsAtCycle() {
        let cycle = WorkingShimmer.sweepDuration + WorkingShimmer.restDuration
        XCTAssertEqual(WorkingShimmer.bandCenter(at: at(0.5)), WorkingShimmer.bandCenter(at: at(0.5 + cycle)))
        XCTAssertNil(WorkingShimmer.bandCenter(at: at(cycle + WorkingShimmer.sweepDuration + 0.1)))
    }

    // MARK: - quantization (the mechanical tick)

    /// Two dates inside the SAME step share one band position — the band jumps between discrete
    /// positions, it never glides.
    func testBandPositionIsQuantizedPerStep() throws {
        let step = WorkingShimmer.sweepDuration / Double(WorkingShimmer.sweepSteps)
        let early = try XCTUnwrap(WorkingShimmer.bandCenter(at: at(step * 3 + 0.001)))
        let late = try XCTUnwrap(WorkingShimmer.bandCenter(at: at(step * 4 - 0.001)))
        XCTAssertEqual(early, late, "one step ⇒ one position (hard cut at the boundary)")
        let next = try XCTUnwrap(WorkingShimmer.bandCenter(at: at(step * 4 + 0.001)))
        XCTAssertNotEqual(late, next, "the boundary advances the band")
    }

    /// The sweep travels the FULL enter/exit range: the first step starts with the band entirely
    /// off the leading edge, and the final step reaches past the trailing edge — the band never
    /// pops in or vanishes mid-glyph.
    func testBandTravelsFullyAcross() throws {
        let first = try XCTUnwrap(WorkingShimmer.bandCenter(at: at(0)))
        XCTAssertEqual(first, -WorkingShimmer.bandHalfWidth, "sweep enters from off-edge")
        let lastStepStart = WorkingShimmer.sweepDuration
            * Double(WorkingShimmer.sweepSteps - 1) / Double(WorkingShimmer.sweepSteps)
        let last = try XCTUnwrap(WorkingShimmer.bandCenter(at: at(lastStepStart + 0.001)))
        XCTAssertGreaterThan(last, 1.0 - WorkingShimmer.bandHalfWidth, "sweep reaches the trailing edge")
    }

    // MARK: - gradient profile

    /// The profile is clamped to the unit interval and non-decreasing — a partially off-edge band
    /// clips at the edge instead of folding the gradient back on itself.
    func testProfileIsClampedAndMonotone() {
        for center in [-WorkingShimmer.bandHalfWidth, 0.0, 0.3, 0.97, 1.0 + WorkingShimmer.bandHalfWidth] {
            let profile = WorkingShimmer.bandProfile(center: center)
            XCTAssertEqual(profile.first?.location, 0)
            XCTAssertEqual(profile.last?.location, 1)
            for (a, b) in zip(profile, profile.dropFirst()) {
                XCTAssertLessThanOrEqual(a.location, b.location, "locations sorted at center \(center)")
            }
            for stop in profile {
                XCTAssertGreaterThanOrEqual(stop.location, 0)
                XCTAssertLessThanOrEqual(stop.location, 1)
            }
        }
    }

    /// Exactly ONE dim stop, sitting at the (clamped) band center — the band darkens the ink; the
    /// resting ink carries every other stop.
    func testProfileDimsOnlyTheBandCenter() {
        let profile = WorkingShimmer.bandProfile(center: 0.5)
        XCTAssertEqual(profile.filter(\.dim).count, 1)
        XCTAssertEqual(profile.first(where: \.dim)?.location, 0.5)
        // Off-edge center clamps its dim stop to the edge rather than dropping it.
        XCTAssertEqual(WorkingShimmer.bandProfile(center: -0.1).first(where: \.dim)?.location, 0)
    }

    /// The `TimelineView` cadence matches the band's step length — one repaint per jump, never
    /// per-vsync (the repaint-cap rationale).
    func testTickMatchesStepLength() {
        XCTAssertEqual(
            WorkingShimmer.tick,
            WorkingShimmer.sweepDuration / Double(WorkingShimmer.sweepSteps),
        )
    }
}
