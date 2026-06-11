import XCTest
@testable import AislopdeskVideoProtocol

/// WF-4 adaptive FEC. The policy is two PURE concerns: a wire codec (tier → group size, used by
/// BOTH ends) and a host-only loss → tier decision (hysteretic, one-step-clamped). These tests pin
/// the wire-codec totality + byte-identity invariants and the decision's hysteresis/anti-flap.
final class AdaptiveFECPolicyTests: XCTestCase {

    // MARK: A. Wire codec (tier → group size)

    /// TOTAL over all 8 tiers: explicit groups for 1-4, default for 0 + reserved 5-7, and OFF → nil.
    /// Defensive over out-of-3-bit values too (a corrupt byte can never trap).
    func testGroupSizeTableIsTotalOverAllTiers() {
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 0, default: 5), 5, "tier 0 = configured default")
        XCTAssertNil(AdaptiveFECPolicy.groupSize(forTier: 1, default: 5), "tier 1 = OFF (no parity)")
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 2, default: 5), 10, "tier 2 = light")
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 3, default: 5), 3, "tier 3 = heavy")
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 4, default: 5), 2, "tier 4 = severe")
        // Reserved tiers 5,6,7 → safe default, never trap.
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 5, default: 5), 5)
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 6, default: 5), 5)
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 7, default: 5), 5)
        // Out-of-range (a malformed value beyond 3 bits) still lands on the default — totality.
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 200, default: 9), 9)
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 255, default: 4), 4)
    }

    /// Tier 0 ↔ default is self-consistent for ANY configured default, so a non-prod default stays
    /// agreed across both ends (the byte-identity / signalling invariant).
    func testTierZeroRoundTripsToConfiguredDefault() {
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 0, default: 5), 5)
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 0, default: 7), 7)
        XCTAssertEqual(AdaptiveFECPolicy.groupSize(forTier: 0, default: 3), 3)
        XCTAssertEqual(AdaptiveFECPolicy.defaultTier, 0)
    }

    /// The 3-bit tier round-trips through the flags byte and coexists with keyframe/parity/crisp
    /// (disjoint masks) — incl. through full encode/decode. Reserved tiers survive verbatim.
    func testFlagsTierRoundTripCoexistsWithOtherFlags() throws {
        for t: UInt8 in 0...7 {
            var flags: FrameFragmentHeader.Flags = [.keyframe, .crisp]
            flags.setFECTier(t)
            XCTAssertEqual(flags.fecTier, t)
            XCTAssertTrue(flags.contains(.keyframe), "tier bits must not disturb keyframe")
            XCTAssertTrue(flags.contains(.crisp), "tier bits must not disturb crisp")
            XCTAssertFalse(flags.contains(.parity))
            // parity is independent of the tier bits.
            flags.insert(.parity)
            XCTAssertEqual(flags.fecTier, t, "setting parity must not change the tier")
            XCTAssertTrue(flags.contains(.parity))

            let header = FrameFragmentHeader(streamSeq: 1, frameID: 2, fragIndex: 0, fragCount: 1, flags: flags, payloadLength: 0)
            let decoded = try FrameFragment.decode(FrameFragment(header: header, payload: Data()).encode())
            XCTAssertEqual(decoded.header.flags.fecTier, t, "tier survives wire round-trip")
            XCTAssertTrue(decoded.header.flags.contains(.keyframe))
            XCTAssertTrue(decoded.header.flags.contains(.parity))
        }
    }

    /// Tier 0 leaves the spare bits zero → the flags byte is the pre-WF-4 byte (byte-identity gate-off).
    func testTierZeroLeavesFlagsBitsUntouched() {
        var flags: FrameFragmentHeader.Flags = [.keyframe]
        let before = flags.rawValue
        flags.setFECTier(0)
        XCTAssertEqual(flags.rawValue, before, "tier 0 must not set any bit")
        XCTAssertEqual(flags.fecTier, 0)
    }

    // MARK: B. Loss → tier decision (hysteresis + one-step clamp)

    /// Sustained high loss ramps the tier UP exactly one redundancy level per call (anti-flap),
    /// from the resting default (tier 0 = g5) up to the severe tier (tier 4 = g2), then saturates.
    func testTierRampsUpOneLevelPerCallUnderSustainedLoss() {
        var tier = AdaptiveFECPolicy.defaultTier // tier 0 = g5 = level 2
        let loss = 0.5 // demands the maximum level
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier)
        XCTAssertEqual(tier, 3, "level 2 → 3 (g3)")
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier)
        XCTAssertEqual(tier, 4, "level 3 → 4 (g2)")
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier)
        XCTAssertEqual(tier, 4, "saturated at the most-redundant level")
    }

    /// Sustained clean link relaxes DOWN one level per call, all the way to OFF (tier 1), then
    /// saturates. This is the whole point of adaptive FEC: drop the wasted parity on a clean LAN.
    func testTierRampsDownOneLevelPerCallUnderCleanLink() {
        var tier: UInt8 = 4 // start at the most-redundant level (g2)
        let loss = 0.0
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier); XCTAssertEqual(tier, 3, "g2 → g3")
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier); XCTAssertEqual(tier, 0, "g3 → g5 (tier 0)")
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier); XCTAssertEqual(tier, 2, "g5 → g10 (tier 2)")
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier); XCTAssertEqual(tier, 1, "g10 → OFF (tier 1)")
        tier = AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: tier); XCTAssertEqual(tier, 1, "saturated at OFF")
    }

    /// A loss sitting inside the dead-band between two levels HOLDS the current tier from EITHER side
    /// (no flapping). 0.015 is in [0.012, 0.02) — the band between level 1 (g10/tier2) and level 2
    /// (g5/tier0).
    func testHysteresisDeadBandHoldsTierFromEitherSide() {
        let deadband = 0.015
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: deadband, previousTier: 2), 2, "stays at g10")
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: deadband, previousTier: 0), 0, "stays at g5")
        // A second dead-band higher up: 0.04 in [0.035, 0.05) between level 2 (g5/tier0) and level 3 (g3/tier3).
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: 0.04, previousTier: 0), 0, "stays at g5")
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: 0.04, previousTier: 3), 3, "stays at g3")
    }

    /// A loss spike that DEMANDS several levels of jump still moves only ONE level per call.
    func testOneStepClampNeverJumpsMultipleLevels() {
        // From tier 0 (level 2) a huge loss demands level 4 → may only step to level 3 (tier 3).
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: 0.9, previousTier: 0), 3)
        // From OFF (tier 1, level 0) a huge loss steps to level 1 (g10/tier 2), not straight to g2.
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: 0.9, previousTier: 1), 2)
    }

    /// A perfectly clean report from the resting default relaxes only ONE level (to g10/tier 2) — it
    /// must NOT jump straight to OFF (tier 1). Reaching OFF requires sustained clean reports (one
    /// level per call), so a momentary clean sample can never prematurely strip all parity.
    func testCleanReportDoesNotJumpStraightToOff() {
        let relaxed = AdaptiveFECPolicy.tier(forLossRate: 0.0, previousTier: 0)
        XCTAssertEqual(relaxed, 2, "tier 0 (g5) relaxes one level to tier 2 (g10)")
        XCTAssertNotEqual(relaxed, 1, "must NOT jump straight to OFF in one report")
    }

    /// Mild loss just over the first up-threshold raises from OFF toward more redundancy, again one
    /// step at a time — proving the up path also respects the clamp from the OFF floor.
    func testTierRaisesFromOffUnderEmergingLoss() {
        // loss 0.03 ≥ 0.02 demands level 2 (g5). From OFF (level 0) step to level 1 (g10/tier 2).
        XCTAssertEqual(AdaptiveFECPolicy.tier(forLossRate: 0.03, previousTier: 1), 2)
    }

    // MARK: Relax dwell (2026-06-11, 4G burst-flap fix)

    /// Escalation through the dwell-gated entry point stays IMMEDIATE — one level per report,
    /// exactly like the plain function — and resets the relax streak.
    func testDwellEscalationIsImmediate() {
        var s = AdaptiveFECPolicy.TierState(tier: 1, relaxStreak: 10) // OFF, mid-dwell
        s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.03, state: s)
        XCTAssertEqual(s.tier, 2, "OFF escalates to g10 on the FIRST lossy report")
        XCTAssertEqual(s.relaxStreak, 0, "escalation resets the relax streak")
        s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.03, state: s)
        XCTAssertEqual(s.tier, 0, "next lossy report escalates g10 → g5")
    }

    /// Relaxation fires only after `dwell` CONSECUTIVE relax-demanding reports.
    func testDwellRelaxRequiresConsecutiveCleanReports() {
        var s = AdaptiveFECPolicy.TierState(tier: 0) // g5
        for i in 1..<AdaptiveFECPolicy.relaxDwellReports {
            s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.0, state: s)
            XCTAssertEqual(s.tier, 0, "still g5 after \(i) clean reports (< dwell)")
            XCTAssertEqual(s.relaxStreak, i)
        }
        s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.0, state: s)
        XCTAssertEqual(s.tier, 2, "relaxes g5 → g10 exactly at the dwell")
        XCTAssertEqual(s.relaxStreak, 0, "streak resets after the applied relax step")
    }

    /// THE 4G FLAP SCENARIO (measured live: bursts of ~3-6% loss every ~6-10s, EWMA decaying to
    /// ~0 between bursts). With the dwell the tier must NEVER fall below g10 between bursts —
    /// the OFF windows that let every burst land unprotected are gone.
    func testDwellHoldsProtectionBetweenFourGBursts() {
        var s = AdaptiveFECPolicy.TierState(tier: 1) // start OFF (clean path)
        var sawOFFAfterFirstBurst = false
        for _ in 0..<6 { // 6 burst cycles
            // Burst: 3 lossy reports at ~5%.
            for _ in 0..<3 { s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.05, state: s) }
            // Between bursts: ~16 clean reports (~8s at 2 reports/s) — SHORTER than the dwell.
            for _ in 0..<16 {
                s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.0, state: s)
                if s.tier == 1 { sawOFFAfterFirstBurst = true }
            }
        }
        XCTAssertFalse(sawOFFAfterFirstBurst, "tier must never relax to OFF inside the 8s burst gaps")
        XCTAssertNotEqual(s.tier, 1, "still protected at the end of the bursty period")
    }

    /// A genuinely clean path still reaches OFF — just one level per dwell window (g5 → g10 → OFF
    /// over 2·dwell consecutive clean reports), preserving the standing-overhead saving.
    func testDwellCleanPathStillReachesOff() {
        var s = AdaptiveFECPolicy.TierState(tier: 0) // g5
        for _ in 0..<(2 * AdaptiveFECPolicy.relaxDwellReports) {
            s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.0, state: s)
        }
        XCTAssertEqual(s.tier, 1, "sustained clean reports relax g5 → g10 → OFF")
    }

    /// A hold report (loss inside the dead-band — neither escalate nor relax) RESETS the streak:
    /// dwell means CONSECUTIVE relax demands, so an ambiguous report re-arms the full wait.
    func testDwellHoldReportResetsStreak() {
        var s = AdaptiveFECPolicy.TierState(tier: 0, relaxStreak: 20)
        // 0.02 from g5/level-2: up demands L2 (hold), down demands L2 (hold) → dead-band hold.
        s = AdaptiveFECPolicy.nextTierState(forLossRate: 0.02, state: s)
        XCTAssertEqual(s.tier, 0)
        XCTAssertEqual(s.relaxStreak, 0, "dead-band hold resets the consecutive-clean streak")
    }
}
