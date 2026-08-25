import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``HostPulse`` — the CROSSING, not the deadband. How far a percent must move before the row
/// redraws, that it snaps to the sample rather than to a midpoint, and that pressure is exempt are
/// `slopdesk_workspace::connection`'s and pinned there; restating the thresholds here would be the
/// same rule in two languages.
///
/// What only Swift can get wrong is the packing: the sample's two percents in, the held pair back,
/// and the disk figure whose ABSENCE is a presence flag rather than a zero.
final class HostPulseTests: XCTestCase {
    private func sample(
        cpu: UInt8, mem: UInt8, pressure: MetadataCodec.MemoryPressure = .normal,
        disk: UInt32? = nil,
    ) -> MetadataCodec.HostVitals {
        .init(cpuPercent: cpu, memoryPercent: mem, pressure: pressure, diskFreeMiB: disk)
    }

    func testTheFirstSampleCrossesBackWholeAndAJitteringOneDoesNot() {
        let first = HostPulse.settled(previous: nil, sample: sample(cpu: 34, mem: 61))
        XCTAssertEqual(first, HostPulse(cpuPercent: 34, memoryPercent: 61, memoryPressure: .normal))
        let held = HostPulse.settled(previous: first, sample: sample(cpu: 35, mem: 60))
        XCTAssertEqual(held, first, "a move under the deadband leaves both shown figures alone")
    }

    /// Each metric is held on its own, so a mixed sample proves both halves of the pair survived the
    /// crossing rather than one being copied over the other.
    func testTheTwoPercentsCrossIndependently() {
        let shown = HostPulse(cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal)
        let mixed = HostPulse.settled(previous: shown, sample: sample(cpu: 90, mem: 61))
        XCTAssertEqual(mixed.cpuPercent, 90)
        XCTAssertEqual(mixed.memoryPercent, 60)
    }

    /// Zero free bytes is the loudest real reading there is, so absence crosses as a FLAG. A door
    /// that packed `nil` as `0` would report a full disk on the volume it could not read.
    func testAnUnreadableVolumeCrossesBackAbsentAndNotEmpty() {
        let shown = HostPulse(
            cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal, diskFreeMiB: 245_760,
        )
        XCTAssertEqual(
            HostPulse.settled(previous: shown, sample: sample(cpu: 31, mem: 61, disk: 0)).diskFreeMiB, 0,
        )
        XCTAssertNil(HostPulse.settled(previous: shown, sample: sample(cpu: 31, mem: 61)).diskFreeMiB)
    }

    /// Pressure crosses untouched, which is only visible while the percent beside it is being held.
    func testThePressureLevelCrossesEvenWhileThePercentHolds() {
        let shown = HostPulse(cpuPercent: 30, memoryPercent: 60, memoryPressure: .normal)
        let pressured = HostPulse.settled(
            previous: shown, sample: sample(cpu: 31, mem: 61, pressure: .critical),
        )
        XCTAssertEqual(pressured.memoryPressure, .critical)
        XCTAssertEqual(pressured.memoryPercent, 60)
    }
}
