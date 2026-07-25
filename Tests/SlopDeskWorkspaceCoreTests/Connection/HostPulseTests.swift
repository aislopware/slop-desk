import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``HostPulse`` — what the sidebar footer's pulse line actually shows, which deliberately is not
/// every sample the host sends. The rail has no animation by design, so a metric only redraws once
/// it has moved by ``HostPulse/deadband`` points; below that the row holds still.
///
/// Every behaviour has a test that FAILS on the un-fixed code:
/// - show every sample → the jitter test redraws for ±2 points;
/// - smooth/average instead of snapping → the climb test shows a number the host never reported;
/// - deadband the pressure level too → the pressure test swallows a state change.
final class HostPulseTests: XCTestCase {
    private func sample(cpu: UInt8, mem: UInt8, pressure: MetadataCodec.MemoryPressure = .normal)
        -> MetadataCodec.HostVitals
    {
        .init(cpuPercent: cpu, memoryPercent: mem, pressure: pressure)
    }

    func testFirstSampleIsShownExactly() {
        let pulse = HostPulse.settled(previous: nil, sample: sample(cpu: 34, mem: 61))
        XCTAssertEqual(pulse, HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal))
    }

    func testJitterUnderTheDeadbandDoesNotMoveTheRow() {
        let shown = HostPulse(cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal)
        // ±2 points is the idle twitch the row must ignore, on BOTH metrics and in both directions.
        XCTAssertEqual(HostPulse.settled(previous: shown, sample: sample(cpu: 32, mem: 58)), shown)
        XCTAssertEqual(HostPulse.settled(previous: shown, sample: sample(cpu: 28, mem: 62)), shown)
    }

    func testAMoveOfTheDeadbandSnapsToTheSampleExactly() {
        let shown = HostPulse(cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal)
        let moved = HostPulse.settled(previous: shown, sample: sample(cpu: 33, mem: 57))
        XCTAssertEqual(moved.cpuPercent, 33, "the shown number is always one the host really reported")
        XCTAssertEqual(moved.memoryPercent, 57)
    }

    func testMetricsAreHeldIndependently() {
        let shown = HostPulse(cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal)
        let mixed = HostPulse.settled(previous: shown, sample: sample(cpu: 90, mem: 61))
        XCTAssertEqual(mixed.cpuPercent, 90, "a real climb lands within one poll")
        XCTAssertEqual(mixed.memoryPercent, 60, "…while the quiet metric stays put")
    }

    func testASlowClimbStillTracksInDeadbandSteps() {
        var pulse = HostPulse.settled(previous: nil, sample: sample(cpu: 10, mem: 50))
        for cpu in stride(from: UInt8(11), through: 40, by: 1) {
            pulse = HostPulse.settled(previous: pulse, sample: sample(cpu: cpu, mem: 50))
        }
        XCTAssertEqual(pulse.cpuPercent, 40, "the deadband delays a redraw, it never loses the trend")
    }

    func testPressureIsNeverDeadbandedBecauseAStateChangeIsNotNoise() {
        let shown = HostPulse(cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal)
        let pressured = HostPulse.settled(previous: shown, sample: sample(cpu: 31, mem: 61, pressure: .critical))
        XCTAssertEqual(pressured.memoryPressure, .critical)
        XCTAssertEqual(pressured.memoryPercent, 60, "…even while the percent itself holds still")
    }
}
