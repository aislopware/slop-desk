#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// USER BITRATE CEILING override on the pure AIMD controller (wire `streamSettings`): the
/// override layers UNDER the policy ceiling — the current target clamps down IMMEDIATELY when
/// the override lands, every additive climb caps at the effective ceiling, and clearing (nil/0)
/// restores the pure policy ceiling (climbed back through the ordinary probe, never jumped).
/// Deterministic injected estimates, same discipline as ``LiveCongestionControllerTests``.
final class LiveCongestionUserCeilingTests: XCTestCase {
    private let ceiling = 45_000_000

    /// A clean (no-loss, flat-RTT) estimate the additive-increase path acts on.
    private func cleanEstimate() -> NetworkEstimate {
        var est = NetworkEstimate()
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        return est
    }

    /// Drive the controller past warmup with neutral reports so subsequent reports act.
    private func warmedController(ceiling: Int) -> LiveCongestionController {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        let clean = cleanEstimate()
        for _ in 0..<LiveCongestionController.warmupTicks { _ = ctrl.onReport(clean) }
        return ctrl
    }

    func testNoOverrideKeepsEffectiveCeilingAtPolicyCeiling() {
        let ctrl = LiveCongestionController(ceiling: ceiling)
        XCTAssertNil(ctrl.userCeilingBps)
        XCTAssertEqual(ctrl.effectiveCeiling, ceiling, "auto = the pure policy ceiling")
    }

    func testOverrideClampsCurrentTargetImmediately() {
        var ctrl = warmedController(ceiling: ceiling)
        XCTAssertEqual(ctrl.current, ceiling, "open-loop start pins at the ceiling")
        ctrl.setUserCeilingBps(20_000_000)
        XCTAssertEqual(ctrl.effectiveCeiling, 20_000_000)
        XCTAssertEqual(ctrl.current, 20_000_000, "a current above the new ceiling clamps down on the spot")
    }

    func testClimbNeverExceedsTheUserCeiling() {
        var ctrl = warmedController(ceiling: ceiling)
        ctrl.setUserCeilingBps(20_000_000)
        let clean = cleanEstimate()
        for _ in 0..<200 {
            let target = ctrl.onReport(clean)
            XCTAssertLessThanOrEqual(target, 20_000_000, "no clean tick may probe past the user ceiling")
        }
        XCTAssertEqual(ctrl.current, 20_000_000, "the climb saturates AT the user ceiling, not above")
    }

    func testClearingRestoresThePolicyCeilingViaTheAdditiveProbe() {
        var ctrl = warmedController(ceiling: ceiling)
        ctrl.setUserCeilingBps(20_000_000)
        XCTAssertEqual(ctrl.current, 20_000_000)
        // 0/nil = auto: the ceiling is restored, but the RATE climbs back additively (never jumps).
        ctrl.setUserCeilingBps(nil)
        XCTAssertNil(ctrl.userCeilingBps)
        XCTAssertEqual(ctrl.effectiveCeiling, ceiling)
        XCTAssertEqual(ctrl.current, 20_000_000, "clearing must not jump the rate — the probe reclaims headroom")
        let clean = cleanEstimate()
        var last = ctrl.current
        for _ in 0..<200 {
            let target = ctrl.onReport(clean)
            XCTAssertGreaterThanOrEqual(target, last, "clean ticks climb monotonically after the clear")
            XCTAssertLessThanOrEqual(target, ceiling)
            last = target
        }
        XCTAssertEqual(ctrl.current, ceiling, "the probe reaches the restored policy ceiling")
    }

    func testOverrideAbovePolicyCeilingIsANoOpOnTheClamp() {
        var ctrl = warmedController(ceiling: ceiling)
        ctrl.setUserCeilingBps(999_000_000)
        XCTAssertEqual(ctrl.effectiveCeiling, ceiling, "the policy ceiling still bounds a too-high override")
        XCTAssertEqual(ctrl.current, ceiling)
    }

    func testOverrideBelowFloorClampsToTheFloorInvariant() {
        // floor = 25% of 45M = 11.25M; an override below it must not starve the encoder under
        // the controller's usable minimum — the [floor, ceiling] invariant survives.
        var ctrl = warmedController(ceiling: ceiling)
        ctrl.setUserCeilingBps(1_000_000)
        XCTAssertEqual(ctrl.effectiveCeiling, ctrl.floor)
        XCTAssertEqual(ctrl.current, ctrl.floor)
        XCTAssertGreaterThan(ctrl.current, 0, "never 0")
    }

    func testZeroAndNegativeOverridesMeanAuto() {
        var ctrl = warmedController(ceiling: ceiling)
        ctrl.setUserCeilingBps(0)
        XCTAssertNil(ctrl.userCeilingBps, "0 = auto (the wire's clear sentinel)")
        XCTAssertEqual(ctrl.effectiveCeiling, ceiling)
        ctrl.setUserCeilingBps(-5)
        XCTAssertNil(ctrl.userCeilingBps, "a negative override is nonsense — treated as auto")
    }
}
#endif
