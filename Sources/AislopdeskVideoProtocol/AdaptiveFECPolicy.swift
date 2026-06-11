import Foundation

/// Adaptive FEC (WF-4): chooses the per-frame XOR-parity group size from the
/// host's measured loss, and signals that choice on the wire so the client splits
/// data/parity identically. Two clearly-separated, PURE concerns (mirroring the
/// `NetworkEstimate` / `LiveCongestionController` value-type style):
///
///  A. WIRE CODEC — ``groupSize(forTier:default:)`` maps a 3-bit on-wire tier index
///     (carried in the spare bits of the fragment flags byte) to the group size BOTH
///     ends must use. Used by the host packetizer AND the client reassembler.
///  B. LOSS→TIER DECISION — ``tier(forLossRate:previousTier:)`` (host only) picks the
///     tier from the EWMA loss with hysteresis + a one-step clamp (anti-flap).
///
/// SIGNALLING INVARIANT: tier 0 means "use the endpoint's CONFIGURED default group
/// size" (NOT a hardcoded 5). Production both ends run `XORParityFEC(5)`, so tier 0
/// is byte-identical to today. With `AISLOPDESK_ADAPTIVE_FEC` unset the host always sends
/// tier 0, so the spare flags bits stay zero and every frame is wire-identical to the
/// pre-WF-4 path.
public enum AdaptiveFECPolicy {
    /// The default on-wire tier. Tier 0 routes to the endpoint's configured `fec.groupSize`
    /// on BOTH ends (5 in prod), and its bits in the flags byte are all-zero → byte-identical
    /// to the pre-adaptive path when the host always sends it.
    public static let defaultTier: UInt8 = 0

    // MARK: A. Wire codec (host packetize + client reassemble)

    /// Maps a wire tier index to the FEC group size both ends must use, or `nil` for the
    /// OFF (no-parity) tier. TOTAL over EVERY `UInt8` value — a malformed/unknown tier read
    /// off a corrupt fragment can NEVER trap; unknown indices fall back to the default group
    /// size. The fragment flags byte only carries 3 bits (0..7), but this function is defined
    /// for all 256 values defensively.
    ///
    /// - tier 0 → `default` (g5 in prod): the "default" — off-path AND adaptive-medium. Bits 3-5 = 0.
    /// - tier 1 → `nil`  (OFF, no parity): clean link, FEC overhead removed.
    /// - tier 2 → 10  (light, ~10% overhead).
    /// - tier 3 → 3   (heavy, ~33% overhead).
    /// - tier 4 → 2   (severe, 50% overhead).
    /// - tier 5,6,7 and any other value → `default` (reserved → safe default, forward-compatible).
    public static func groupSize(forTier tier: UInt8, default defaultGroupSize: Int) -> Int? {
        switch tier {
        case 1: return nil            // OFF (clean link, no parity)
        case 2: return 10             // light (~10%)
        case 3: return 3              // heavy (~33%)
        case 4: return 2              // severe (50%)
        default: return defaultGroupSize // 0 + reserved 5,6,7 (+ any other) → safe default
        }
    }

    // MARK: B. Loss → tier decision (host only)

    /// Internal redundancy LEVEL, monotonic in loss (0 = least redundancy … 4 = most):
    ///  level 0 = OFF, 1 = g10, 2 = g5 (the default), 3 = g3, 4 = g2.
    /// Decisions step at most ONE level per call; the level↔tier maps below translate to/from
    /// the non-monotonic wire tier numbering (tier 0 must be g5 for byte-identity, so the wire
    /// order is NOT the redundancy order).
    private static func level(forTier tier: UInt8) -> Int {
        switch tier {
        case 1: return 0   // OFF
        case 2: return 1   // g10
        case 0: return 2   // g5 (default)
        case 3: return 3   // g3
        case 4: return 4   // g2
        default: return 2  // reserved → treat as the default/g5 level
        }
    }

    private static func tier(forLevel level: Int) -> UInt8 {
        switch level {
        case 0: return 1   // OFF
        case 1: return 2   // g10
        case 2: return 0   // g5 (default)
        case 3: return 3   // g3
        case 4: return 4   // g2
        default: return 0  // clamp → default
        }
    }

    /// The redundancy level the loss demands, given the current level. Hysteretic:
    /// asymmetric up/down thresholds create a dead-band so a loss oscillating around a
    /// boundary does NOT flap the tier. Within the dead-band the current level holds.
    ///
    /// Up-thresholds (raise redundancy):  ≥0.005→L1, ≥0.02→L2, ≥0.05→L3, ≥0.10→L4.
    /// Down-thresholds (must fall well below to relax): <0.002→L0, <0.012→L1, <0.035→L2, <0.08→L3.
    /// For every adjacent pair the up-threshold strictly exceeds the down-threshold (dead-band),
    /// so `upLevel <= downLevel` always and the two `if`s below are mutually exclusive.
    private static func targetLevel(forLossRate loss: Double, currentLevel current: Int) -> Int {
        let upLevel: Int
        if loss >= 0.10 { upLevel = 4 }
        else if loss >= 0.05 { upLevel = 3 }
        else if loss >= 0.02 { upLevel = 2 }
        else if loss >= 0.005 { upLevel = 1 }
        else { upLevel = 0 }

        let downLevel: Int
        if loss < 0.002 { downLevel = 0 }
        else if loss < 0.012 { downLevel = 1 }
        else if loss < 0.035 { downLevel = 2 }
        else if loss < 0.08 { downLevel = 3 }
        else { downLevel = 4 }

        if upLevel > current { return upLevel }     // loss has risen → demand more redundancy
        if downLevel < current { return downLevel } // loss low enough → relax
        return current                              // dead-band → hold
    }

    /// Picks the next wire tier from the EWMA loss and the previous tier, with hysteresis and a
    /// strict one-level-per-call clamp (anti-flap). The clamp means relaxation toward OFF on a
    /// sustained clean link is GRADUAL (g5→g10→OFF over successive reports) and a loss spike never
    /// jumps multiple levels at once — so it can never "prematurely" jump straight to OFF, and the
    /// host only ever calls this on a real netstats report (inert with no data).
    public static func tier(forLossRate loss: Double, previousTier: UInt8) -> UInt8 {
        let current = level(forTier: previousTier)
        let target = targetLevel(forLossRate: loss, currentLevel: current)
        let stepped: Int
        if target > current { stepped = current + 1 }
        else if target < current { stepped = current - 1 }
        else { stepped = current }
        return tier(forLevel: stepped)
    }

    // MARK: Relax dwell (2026-06-11, 4G burst-flap fix)

    /// How many CONSECUTIVE relax-demanding reports must accumulate before the tier steps DOWN one
    /// level. Escalation stays immediate (one step per report, as before).
    ///
    /// WHY: on the real 4G path the first adaptive-FEC deployment FLAPPED — 224 tier changes in one
    /// session, cycling OFF→g10→g5→g10→OFF every ~8s. Mobile loss arrives in BURSTS seconds apart;
    /// the loss EWMA decays below the relax thresholds between bursts, so the one-step-per-report
    /// relax walked back to OFF in ~1s and EVERY burst landed on an unprotected stream (118
    /// unrecovered frames ≈ 1%, almost all inside OFF windows). Requiring ~12s of consecutively
    /// clean reports (24 at the ~2/s netstats cadence) keeps g10 armed BETWEEN bursts while a
    /// genuinely clean path (home WiFi) still relaxes to OFF — just ~12s per step slower, a
    /// one-time cost against a standing 10-20% overhead saving.
    public static let relaxDwellReports = 24

    /// Tier decision state for the dwell-gated variant: the current wire tier plus the count of
    /// consecutive reports that demanded relaxation. Value type, host-session owned — same
    /// "pure decider beside the actor" shape as `LTRController`/`StaticIDRDecider`.
    public struct TierState: Equatable, Sendable {
        public var tier: UInt8
        public var relaxStreak: Int
        public init(tier: UInt8 = AdaptiveFECPolicy.defaultTier, relaxStreak: Int = 0) {
            self.tier = tier
            self.relaxStreak = relaxStreak
        }
    }

    /// Dwell-gated tier step — the production entry point (plain ``tier(forLossRate:previousTier:)``
    /// stays for tests/tools). Escalation: immediate one-step, resets the relax streak. Relaxation:
    /// counted across consecutive relax-demanding reports and applied only when the streak reaches
    /// `dwell`; any report that does NOT demand relaxation (hold or escalate) resets the streak, so
    /// a burst arriving mid-dwell re-arms the full wait.
    public static func nextTierState(forLossRate loss: Double, state: TierState, dwell: Int = relaxDwellReports) -> TierState {
        let current = level(forTier: state.tier)
        let target = targetLevel(forLossRate: loss, currentLevel: current)
        if target > current {
            return TierState(tier: tier(forLevel: current + 1), relaxStreak: 0)
        }
        if target < current {
            let streak = state.relaxStreak + 1
            if streak >= max(1, dwell) {
                return TierState(tier: tier(forLevel: current - 1), relaxStreak: 0)
            }
            return TierState(tier: state.tier, relaxStreak: streak)
        }
        return TierState(tier: state.tier, relaxStreak: 0)
    }
}
