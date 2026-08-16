import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The host-pulse sampler's PURE core — tick math and the baseline / staleness / cache rules —
/// driven with INJECTED readings. No syscall, no sleeping (the hang-safety rule: `sample()` itself,
/// which reads Mach, is compiled + reviewed only, exactly like `HostMetadataProbe`).
///
/// Every behaviour has a test that FAILS on the un-fixed code:
/// - answer on the first call → the "first call primes" test gets a percent out of one snapshot;
/// - widen the tick subtraction instead of wrapping → the counter-wrap test reports a nonsense spike;
/// - average across a stale baseline → the poll-gap test reports the pre-gap machine;
/// - re-measure on a too-fresh repeat → the back-to-back test starves the window to noise.
final class HostVitalsSamplerTests: XCTestCase {
    private typealias Ticks = HostVitalsSampler.CPUTicks

    // MARK: - Tick math

    func testBusyPercentIsHundredMinusIdleShareOfTheWindow() {
        // 300 busy ticks (200 user + 50 system + 50 nice) against 700 idle → 30%.
        let previous = Ticks(user: 1000, system: 100, idle: 5000, nice: 10)
        let current = Ticks(user: 1200, system: 150, idle: 5700, nice: 60)
        XCTAssertEqual(HostVitalsSampler.busyPercent(previous: previous, current: current), 30)
    }

    func testBusyPercentRoundsHalfUpAndSaturatesAtTheEnds() {
        // 1 busy of 1000 → 0.1% → 0. 5 of 1000 → 0.5% → 1 (round half UP).
        let base = Ticks(user: 0, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(
            HostVitalsSampler.busyPercent(previous: base, current: Ticks(user: 1, system: 0, idle: 999, nice: 0)), 0,
        )
        XCTAssertEqual(
            HostVitalsSampler.busyPercent(previous: base, current: Ticks(user: 5, system: 0, idle: 995, nice: 0)), 1,
        )
        // Fully idle / fully pegged are the exact ends, never 1 / 99.
        XCTAssertEqual(
            HostVitalsSampler.busyPercent(previous: base, current: Ticks(user: 0, system: 0, idle: 400, nice: 0)), 0,
        )
        XCTAssertEqual(
            HostVitalsSampler.busyPercent(previous: base, current: Ticks(user: 400, system: 0, idle: 0, nice: 0)), 100,
        )
    }

    func testIdenticalSnapshotsHaveNoWindowAndReportNothing() {
        let ticks = Ticks(user: 5, system: 5, idle: 5, nice: 5)
        XCTAssertNil(HostVitalsSampler.busyPercent(previous: ticks, current: ticks))
    }

    func testCounterWrapMeasuresTheWindowNotTheRollover() {
        // Mach's counters are 32-bit and roll over on a long-lived host. Across the wrap the window
        // is still 100 busy / 300 idle → 25%; a widened subtraction would compute a ~4-billion spike.
        let previous = Ticks(user: .max - 40, system: .max - 10, idle: .max - 100, nice: .max)
        let current = Ticks(user: 9, system: 29, idle: 199, nice: 9)
        XCTAssertEqual(HostVitalsSampler.busyPercent(previous: previous, current: current), 25)
    }

    // MARK: - Memory + pressure

    func testMemoryPercentRoundsAndGuardsTheImpossibleMachine() {
        XCTAssertEqual(HostVitalsSampler.memoryPercent(usedBytes: 32, totalBytes: 64), 50)
        XCTAssertEqual(HostVitalsSampler.memoryPercent(usedBytes: 5, totalBytes: 8), 63, "round half up")
        XCTAssertEqual(HostVitalsSampler.memoryPercent(usedBytes: 99, totalBytes: 64), 100, "clamped, never >100")
        XCTAssertEqual(HostVitalsSampler.memoryPercent(usedBytes: 1, totalBytes: 0), 0, "no divide by zero")
    }

    func testPressureLadderMapsTheSparseKernelLevels() {
        XCTAssertEqual(HostVitalsSampler.pressure(sysctlLevel: 1), .normal)
        XCTAssertEqual(HostVitalsSampler.pressure(sysctlLevel: 2), .warn)
        XCTAssertEqual(HostVitalsSampler.pressure(sysctlLevel: 4), .critical)
        // Unreadable sysctl (0) and any future level read normal — never an alarm we cannot justify.
        XCTAssertEqual(HostVitalsSampler.pressure(sysctlLevel: 0), .normal)
        XCTAssertEqual(HostVitalsSampler.pressure(sysctlLevel: 8), .normal)
    }

    // MARK: - Disk

    func testFreeMiBConvertsBlocksAndRefusesANonsenseBlockSize() {
        // APFS reports 4 KiB blocks: 256 blocks = 1 MiB.
        XCTAssertEqual(HostVitalsSampler.freeMiB(blocksAvailable: 256, blockSize: 4096), 1)
        XCTAssertEqual(HostVitalsSampler.freeMiB(blocksAvailable: 62_914_560, blockSize: 4096), 245_760)
        XCTAssertEqual(HostVitalsSampler.freeMiB(blocksAvailable: 255, blockSize: 4096), 0, "a full disk is 0, not nil")
        XCTAssertNil(HostVitalsSampler.freeMiB(blocksAvailable: 100, blockSize: 0), "no divide by a zero block")
    }

    func testFreeMiBSaturatesBelowTheUnknownSentinel() {
        // An overflowing (torn/garbage) pair must saturate rather than trap — and must never land ON
        // the sentinel, which would silently blank the metric instead of showing an absurd number.
        let huge = HostVitalsSampler.freeMiB(blocksAvailable: .max, blockSize: 4096)
        XCTAssertEqual(huge, MetadataCodec.diskFreeUnknown - 1)
        XCTAssertNotEqual(huge, MetadataCodec.diskFreeUnknown)
    }

    // MARK: - Baseline / staleness / cache

    func testFirstCallPrimesTheBaselineAndAnswersNothing() {
        let sampler = HostVitalsSampler()
        let start = ContinuousClock.now
        XCTAssertNil(
            sampler.vitals(
                cpuTicks: Ticks(user: 100, system: 0, idle: 900, nice: 0),
                memoryPercent: 61, pressure: .normal, diskFreeMiB: nil, now: start,
            ),
            "one snapshot is not a rate — the verb answers .error and the client asks again",
        )
        let second = sampler.vitals(
            cpuTicks: Ticks(user: 300, system: 0, idle: 1700, nice: 0),
            memoryPercent: 61, pressure: .normal, diskFreeMiB: nil, now: start.advanced(by: .seconds(4)),
        )
        XCTAssertEqual(second, MetadataCodec.HostVitals(cpuPercent: 20, memoryPercent: 61, pressure: .normal))
    }

    func testStaleBaselineIsRebankedNotAveragedAcrossTheGap() {
        let sampler = HostVitalsSampler()
        let start = ContinuousClock.now
        _ = sampler.vitals(
            cpuTicks: Ticks(user: 0, system: 0, idle: 0, nice: 0),
            memoryPercent: 50,
            pressure: .normal,
            diskFreeMiB: nil,
            now: start,
        )
        _ = sampler.vitals(
            cpuTicks: Ticks(user: 100, system: 0, idle: 900, nice: 0),
            memoryPercent: 50,
            pressure: .normal,
            diskFreeMiB: nil,
            now: start.advanced(by: .seconds(4)),
        )
        // …the client goes away for a while (asleep / disconnected) and comes back.
        let afterGap = start.advanced(by: .seconds(4)) + HostVitalsSampler.maxBaselineAge + .seconds(1)
        XCTAssertNil(
            sampler.vitals(
                cpuTicks: Ticks(user: 9000, system: 0, idle: 1000, nice: 0),
                memoryPercent: 50,
                pressure: .normal,
                diskFreeMiB: nil,
                now: afterGap,
            ),
            "a window that spans the gap describes a machine that no longer exists — rebank, stay silent",
        )
        // The very next normal poll measures the fresh window only.
        let fresh = sampler.vitals(
            cpuTicks: Ticks(user: 9100, system: 0, idle: 1900, nice: 0),
            memoryPercent: 50, pressure: .normal, diskFreeMiB: nil, now: afterGap.advanced(by: .seconds(4)),
        )
        XCTAssertEqual(fresh?.cpuPercent, 10)
    }

    func testBackToBackCallRepeatsTheCachedCPUWithFreshMemoryAndKeepsTheBaseline() {
        let sampler = HostVitalsSampler()
        let start = ContinuousClock.now
        _ = sampler.vitals(
            cpuTicks: Ticks(user: 0, system: 0, idle: 0, nice: 0),
            memoryPercent: 40,
            pressure: .normal,
            diskFreeMiB: nil,
            now: start,
        )
        _ = sampler.vitals(
            cpuTicks: Ticks(user: 500, system: 0, idle: 500, nice: 0),
            memoryPercent: 40,
            pressure: .normal,
            diskFreeMiB: nil,
            now: start.advanced(by: .seconds(4)),
        )
        // A second caller arrives right behind the first: too soon to re-measure CPU, but memory IS
        // instantaneous, so the row refreshes the half that can be trusted.
        let immediate = sampler.vitals(
            cpuTicks: Ticks(user: 501, system: 0, idle: 501, nice: 0),
            memoryPercent: 44, pressure: .warn, diskFreeMiB: nil, now: start.advanced(by: .milliseconds(4200)),
        )
        XCTAssertEqual(immediate, MetadataCodec.HostVitals(cpuPercent: 50, memoryPercent: 44, pressure: .warn))
        // The baseline did NOT move to the too-fresh snapshot: the next real poll still measures a
        // full window from t=4s (1000 busy of 2000 → 50), not from t=4.2s.
        let next = sampler.vitals(
            cpuTicks: Ticks(user: 1500, system: 0, idle: 1500, nice: 0),
            memoryPercent: 44, pressure: .normal, diskFreeMiB: nil, now: start.advanced(by: .seconds(8)),
        )
        XCTAssertEqual(next?.cpuPercent, 50)
    }

    func testDiskRidesEveryAnswerIncludingTheTooFreshRepeat() {
        // Free space needs no window either, so both the measured answer and the cached-CPU repeat
        // must carry the CURRENT figure — a stale disk reading is exactly the one that would still
        // say "plenty of room" while a build fills the volume.
        let sampler = HostVitalsSampler()
        let start = ContinuousClock.now
        _ = sampler.vitals(
            cpuTicks: Ticks(user: 0, system: 0, idle: 0, nice: 0),
            memoryPercent: 40, pressure: .normal, diskFreeMiB: 245_760, now: start,
        )
        let measured = sampler.vitals(
            cpuTicks: Ticks(user: 500, system: 0, idle: 500, nice: 0),
            memoryPercent: 40, pressure: .normal, diskFreeMiB: 200_000,
            now: start.advanced(by: .seconds(4)),
        )
        XCTAssertEqual(measured?.diskFreeMiB, 200_000)
        let repeated = sampler.vitals(
            cpuTicks: Ticks(user: 501, system: 0, idle: 501, nice: 0),
            memoryPercent: 40, pressure: .normal, diskFreeMiB: 199_000,
            now: start.advanced(by: .milliseconds(4200)),
        )
        XCTAssertEqual(repeated?.diskFreeMiB, 199_000, "instantaneous halves refresh even on a repeat")
        XCTAssertEqual(repeated?.cpuPercent, 50, "…while the CPU half stays the cached measurement")
    }

    func testResetDropsBaselineAndCache() {
        let sampler = HostVitalsSampler()
        let start = ContinuousClock.now
        _ = sampler.vitals(
            cpuTicks: Ticks(user: 0, system: 0, idle: 0, nice: 0),
            memoryPercent: 10,
            pressure: .normal,
            diskFreeMiB: nil,
            now: start,
        )
        sampler.reset()
        XCTAssertNil(
            sampler.vitals(
                cpuTicks: Ticks(user: 100, system: 0, idle: 900, nice: 0),
                memoryPercent: 10,
                pressure: .normal,
                diskFreeMiB: nil,
                now: start.advanced(by: .seconds(4)),
            ),
            "after a reset the next call is a first call again",
        )
    }
}
