import XCTest
@testable import AislopdeskVideoProtocol

/// Differential parity: every Rust-backed `AdaptiveFECPolicy` entry point must equal the prior
/// native computation. The existing `AdaptiveFECPolicyTests` pin the exact behavioural values
/// and keep passing through the swap (primary net); `adaptiveTier`/`adaptiveGroupSize` golden
/// vectors prove Swift-native == Rust-core at the core level. This file adds an inline native
/// oracle (the pre-swap pure logic) and fuzzes the public API against it over wide ranges,
/// since loss is an unbounded Double and tier/streak are unbounded integers.
final class RustAdaptiveFECParityTests: XCTestCase {
    // MARK: Native reference (verbatim pre-swap pure logic — the oracle)

    private static func nativeLevel(forTier tier: UInt8) -> Int {
        switch tier {
        case 1: 0
        case 2: 1
        case 0: 2
        case 3: 3
        case 4: 4
        default: 2
        }
    }

    private static func nativeTier(forLevel level: Int) -> UInt8 {
        switch level {
        case 0: 1
        case 1: 2
        case 2: 0
        case 3: 3
        case 4: 4
        default: 0
        }
    }

    private static func nativeRelaxFloor(_ allowOff: Bool) -> Int { allowOff ? 0 : 1 }

    private static func nativeTargetLevel(_ loss: Double, _ current: Int) -> Int {
        let up =
            if loss >= 0.10 { 4 } else if loss >= 0.05 { 3 } else if loss >= 0.02 { 2 } else if loss >= 0.005 { 1 }
            else { 0 }
        let down =
            if loss < 0.002 { 0 } else if loss < 0.012 { 1 } else if loss < 0.035 { 2 } else if loss < 0.08 { 3 }
            else { 4 }
        if up > current { return up }
        if down < current { return down }
        return current
    }

    private static func nativeGroupSize(forTier tier: UInt8, default def: Int) -> Int? {
        switch tier {
        case 1: nil
        case 2: 10
        case 3: 3
        case 4: 2
        default: def
        }
    }

    private static func nativeTier(_ loss: Double, _ prev: UInt8, _ allowOff: Bool) -> UInt8 {
        let current = nativeLevel(forTier: prev)
        let target = max(nativeTargetLevel(loss, current), nativeRelaxFloor(allowOff))
        let stepped = target > current ? current + 1 : (target < current ? current - 1 : current)
        return nativeTier(forLevel: stepped)
    }

    private struct NativeState: Equatable { var tier: UInt8
        var streak: Int
        var sticky: Int
    }

    private static func nativeNext(
        _ loss: Double,
        _ s: NativeState,
        _ dwell: Int,
        _ allowOff: Bool,
        _ unrec: Bool,
    ) -> NativeState {
        let sticky = unrec ? (2 * 24) : max(0, s.sticky - 1)
        let effective = sticky > 0 ? 2 * dwell : dwell
        let current = nativeLevel(forTier: s.tier)
        let target = max(nativeTargetLevel(loss, current), nativeRelaxFloor(allowOff))
        if target > current {
            return NativeState(tier: nativeTier(forLevel: current + 1), streak: 0, sticky: sticky)
        }
        if target < current {
            let streak = s.streak + 1
            if streak >= max(1, effective) {
                return NativeState(tier: nativeTier(forLevel: current - 1), streak: 0, sticky: sticky)
            }
            return NativeState(tier: s.tier, streak: streak, sticky: sticky)
        }
        return NativeState(tier: s.tier, streak: 0, sticky: sticky)
    }

    // MARK: group_size — TOTAL over every UInt8, every reasonable default

    func testGroupSizeParityOverAllTiers() {
        for tier in UInt8.min...UInt8.max {
            for def in [0, 1, 2, 3, 5, 7, 10, 99] {
                XCTAssertEqual(
                    AdaptiveFECPolicy.groupSize(forTier: tier, default: def),
                    Self.nativeGroupSize(forTier: tier, default: def),
                    "tier \(tier) default \(def)",
                )
            }
        }
    }

    // MARK: tier — fuzz loss across boundaries + every prev tier + both allowOff

    func testTierParityFuzz() {
        var losses: [Double] = [-1, -0.0, 0, 1, 2, .infinity, .greatestFiniteMagnitude]
        var l = 0.0
        while l <= 0.2 { losses.append(l)
            l += 0.0005
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 { losses.append(Double.random(in: 0...0.5, using: &rng)) }
        for loss in losses {
            for prev: UInt8 in 0...7 {
                for allowOff in [false, true] {
                    XCTAssertEqual(
                        AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: prev, allowOff: allowOff),
                        Self.nativeTier(loss, prev, allowOff),
                        "loss \(loss) prev \(prev) allowOff \(allowOff)",
                    )
                }
            }
        }
    }

    // MARK: nextTierState — fuzz state + report, single-step parity

    func testNextTierStateParityFuzz() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20000 {
            let loss = Double.random(in: 0...0.3, using: &rng)
            let prev = UInt8.random(in: 0...7, using: &rng)
            let streak = Int.random(in: 0...60, using: &rng)
            let sticky = Int.random(in: 0...96, using: &rng)
            let dwell = [1, 12, 24, 48].randomElement(using: &rng)!
            let allowOff = Bool.random(using: &rng)
            let unrec = Bool.random(using: &rng)
            let s = AdaptiveFECPolicy.TierState(tier: prev, relaxStreak: streak, stickyRelaxRemaining: sticky)
            let got = AdaptiveFECPolicy.nextTierState(
                forLossRate: loss, state: s, dwell: dwell, allowOff: allowOff, sawUnrecoveredLoss: unrec,
            )
            let want = Self.nativeNext(
                loss,
                NativeState(tier: prev, streak: streak, sticky: sticky),
                dwell,
                allowOff,
                unrec,
            )
            XCTAssertEqual(
                NativeState(tier: got.tier, streak: got.relaxStreak, sticky: got.stickyRelaxRemaining), want,
                "loss \(loss) state \(s) dwell \(dwell) allowOff \(allowOff) unrec \(unrec)",
            )
        }
    }

    // MARK: multi-report sequence parity (the real host loop)

    func testNextTierStateSequenceParity() {
        var swiftS = AdaptiveFECPolicy.TierState(tier: 1)
        var refS = NativeState(tier: 1, streak: 0, sticky: 0)
        let losses: [Double] = (0..<400).map { i in i % 30 < 3 ? 0.05 : 0.0 }
        for (i, loss) in losses.enumerated() {
            let unrec = i.isMultiple(of: 47)
            swiftS = AdaptiveFECPolicy.nextTierState(forLossRate: loss, state: swiftS, sawUnrecoveredLoss: unrec)
            refS = Self.nativeNext(loss, refS, AdaptiveFECPolicy.relaxDwellReports, false, unrec)
            XCTAssertEqual(
                NativeState(tier: swiftS.tier, streak: swiftS.relaxStreak, sticky: swiftS.stickyRelaxRemaining), refS,
                "report \(i)",
            )
        }
    }

    func testConstantsUnchanged() {
        XCTAssertEqual(AdaptiveFECPolicy.defaultTier, 0)
        XCTAssertEqual(AdaptiveFECPolicy.relaxDwellReports, 24)
        XCTAssertEqual(AdaptiveFECPolicy.stickyRelaxWindowReports, 48)
    }
}
