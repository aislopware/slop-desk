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

    // MARK: Multi-loss Reed-Solomon activation (AISLOPDESK_FEC_M / AISLOPDESK_FEC_K)

    /// The env-gated multi-loss FEC configuration: the parity-shards-per-group `m` and the
    /// FIXED data-group size `k` the host packetizer + client reassembler both build from.
    ///
    /// DEFAULT `m == 1`: the production XOR-equivalent / byte-identical wire. The whole adaptive
    /// path (per-frame tiers, the loss→tier ladder, OFF/g10/g3/g2) is UNTOUCHED — every method below
    /// behaves exactly as before, the golden vectors are unchanged, and a mixed fleet interoperates
    /// (tier 0 frames decode on any host/client).
    ///
    /// When `AISLOPDESK_FEC_M >= 2` it activates a true `[k + m, k]` Reed-Solomon code that recovers up
    /// to `m` losses PER GROUP (which `m == 1`/XOR provably cannot). The constraint that makes this
    /// safe: the `m >= 2` Cauchy encode matrix has EXACTLY `k` columns and the codec clamps a per-call
    /// group size to `min(g, k)`, so for `m > 1` the per-frame group size MUST equal `k`. The host
    /// therefore forces a FIXED `(k, m)` with `group_size == k` for EVERY frame (it sends the
    /// today-default tier 0, whose wire mapping resolves to the endpoint's configured `fec.groupSize`,
    /// which is `k`) instead of the dynamic per-tier adaptive group sizes — see ``wireTier(adaptiveTier:)``.
    ///
    /// DEPLOY-TOGETHER: with `m > 1` the parity-fragment COUNT PER GROUP changes on the wire (a group
    /// now carries `m` parity shards, not 1). The host and the client MUST read the SAME
    /// `AISLOPDESK_FEC_M` / `AISLOPDESK_FEC_K` and be deployed together — a host emitting `m` parity to
    /// a client reassembler built for a different `m` mis-maps the parity boundary and fails to repair.
    /// Tier 0 / default `m == 1` stays the mixed-fleet interop baseline; only flip `m > 1` on a
    /// host+client pair you control and ship as one unit.
    public enum MultiLossFEC {
        /// Allowed range for the parity-shard count `m` (the per-group loss-recovery budget). The
        /// upper bound is conservative (8 parity shards is already heavy redundancy); the GF(2^8)
        /// field bound `k + m <= 255` is enforced jointly below.
        public static let mRange = 1...8
        /// Allowed range for the fixed data-group size `k` (= the codec's column count when `m > 1`).
        /// Floored at 2 (a 1-data-shard group is degenerate) and capped at 64 (well within MTU-bound
        /// fragment counts), with `k + m <= 255` enforced jointly.
        public static let kRange = 2...64
        /// The default fixed group size when multi-loss is active but `AISLOPDESK_FEC_K` is unset (5 ⇒
        /// the prod default, 20% parity at `m == 1`; `m/k` overhead at `m > 1`).
        public static let defaultK = 5

        /// The resolved parity count `m` (clamped to ``mRange``; `1` = inactive / unchanged wire),
        /// read once from `AISLOPDESK_FEC_M` at process start (env static — fixed for the lifetime, so
        /// host and client never disagree mid-session).
        public static let parityCount = resolveParityCount(env: ProcessInfo.processInfo.environment)
        /// The resolved fixed group size `k` (clamped to ``kRange`` and to `255 - m`), read once from
        /// `AISLOPDESK_FEC_K`. Only consulted when ``parityCount`` `>= 2`.
        public static let groupSize = resolveGroupSize(env: ProcessInfo.processInfo.environment)
        /// Whether multi-loss recovery is active (`AISLOPDESK_FEC_M >= 2`).
        public static var isActive: Bool { parityCount >= 2 }

        /// PURE resolution of `AISLOPDESK_FEC_M` (testable without process state): parse, default 1,
        /// clamp to ``mRange``. A non-numeric / out-of-range value clamps to the nearest bound.
        public static func resolveParityCount(env: [String: String]) -> Int {
            guard let raw = env["AISLOPDESK_FEC_M"], let m = Int(raw) else { return 1 }
            return min(max(m, mRange.lowerBound), mRange.upperBound)
        }

        /// PURE resolution of `AISLOPDESK_FEC_K` (testable without process state): parse, default
        /// ``defaultK``, clamp to ``kRange``, then cap so `k + m <= 255` (the GF(2^8) field bound) for
        /// the resolved `m`. With `m == 1` the cap is inert (k <= 64 already satisfies k+1 <= 255).
        public static func resolveGroupSize(env: [String: String]) -> Int {
            let m = resolveParityCount(env: env)
            let raw = env["AISLOPDESK_FEC_K"].flatMap { Int($0) } ?? defaultK
            let clamped = min(max(raw, kRange.lowerBound), kRange.upperBound)
            return min(clamped, 255 - m) // joint GF(2^8) bound k + m <= 255
        }
    }

    /// Builds the process's configured ``FECScheme``: the env-gated multi-loss Reed-Solomon codec when
    /// `AISLOPDESK_FEC_M >= 2` (a FIXED `[k + m, k]` with `k = AISLOPDESK_FEC_K`), else the production
    /// `m == 1` default (XOR-equivalent, byte-identical wire). The DEFAULT-ARGUMENT for the host
    /// packetizer's and the client reassembler's `fec:` so BOTH ends resolve the SAME env at the SAME
    /// site — there is no way to build one end multi-loss and the other single-loss within a process.
    ///
    /// `m == 1` returns `RustReedSolomonFEC(groupSize: 5, parityCount: 1)` — bit-for-bit the legacy
    /// default `XORParityFEC()`.
    public static func makeFECScheme() -> FECScheme {
        if MultiLossFEC.isActive {
            return RustReedSolomonFEC(groupSize: MultiLossFEC.groupSize, parityCount: MultiLossFEC.parityCount)
        }
        return RustReedSolomonFEC()
    }

    /// The wire FEC tier the host must stamp on EVERY frame given the active scheme.
    ///
    /// When multi-loss is active (`m >= 2`) this is FORCED to ``defaultTier`` (tier 0), whose wire
    /// mapping (``groupSize(forTier:default:)``) resolves to the endpoint's configured `fec.groupSize`
    /// — i.e. exactly `k`. This pins the per-frame group size to `k` for every frame (the `m > 1`
    /// codec REQUIRES `group_size == k`, since its Cauchy matrix has `k` columns and clamps `g` to
    /// `min(g, k)`); the dynamic adaptive tiers (g2/g3/g10/OFF) must NOT be used, as a `group_size != k`
    /// would feed the decoder a window the matrix was never built for and silently fail to repair.
    ///
    /// When `m == 1` this returns `adaptiveTier` unchanged, so the adaptive-FEC path is byte-identical.
    public static func wireTier(adaptiveTier: UInt8) -> UInt8 {
        MultiLossFEC.isActive ? defaultTier : adaptiveTier
    }

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
        // Delegates to the Rust `aislopdesk-core` policy (single source of truth shared with the
        // Android client) — byte-identical to the former native table (golden-vector
        // `adaptiveGroupSize` + `AdaptiveFECPolicyTests` + `RustAdaptiveFECParityTests`). TOTAL.
        RustVideoFFI.adaptiveFECGroupSize(tier: tier, defaultGroupSize: defaultGroupSize)
    }

    // MARK: B. Loss → tier decision (host only)

    /// FEC LADDER FLOOR (2026-06-11, telemetry round). The relax path FLOORS at level 1 (g10,
    /// ~10% overhead) and never selects the OFF tier by default. MEASURED on the live FPT↔Viettel
    /// path (169 s, baseline loss 0.1–0.6%): 158 tier transitions including 18 visits to OFF;
    /// 102 unrecovered frame losses (1.1%) vs 186 FEC-recovered → 65 client decode-fails ≈ 1 per
    /// 2.6 s, each a blip risk. On a path with NONZERO baseline loss the OFF tier is never safe —
    /// the dwell only slows the walk there, it does not stop it. `AISLOPDESK_FEC_ALLOW_OFF=1`
    /// re-enables the old relax-to-OFF behaviour (a genuinely loss-free LAN/loopback can reclaim
    /// the standing ~10%). The WIRE CODEC for tier 1 is untouched — an OFF-tier frame from an
    /// old/flagged host still decodes.
    public static let allowOffTierDefault = allowOffTier(env: ProcessInfo.processInfo.environment)

    /// Pure env resolution for the OFF-tier escape hatch (testable without process state).
    public static func allowOffTier(env: [String: String]) -> Bool {
        env["AISLOPDESK_FEC_ALLOW_OFF"] == "1"
    }

    /// The lowest redundancy LEVEL the relax path may land on: 1 (g10) by default, 0 (OFF) only
    /// behind the escape hatch. Escalation is unaffected (it only ever raises the level).
    private static func relaxFloorLevel(allowOff: Bool) -> Int { allowOff ? 0 : 1 }

    /// Internal redundancy LEVEL, monotonic in loss (0 = least redundancy … 4 = most):
    ///  level 0 = OFF, 1 = g10, 2 = g5 (the default), 3 = g3, 4 = g2.
    /// Decisions step at most ONE level per call; the level↔tier maps below translate to/from
    /// the non-monotonic wire tier numbering (tier 0 must be g5 for byte-identity, so the wire
    /// order is NOT the redundancy order).
    private static func level(forTier tier: UInt8) -> Int {
        switch tier {
        case 1: 0 // OFF
        case 2: 1 // g10
        case 0: 2 // g5 (default)
        case 3: 3 // g3
        case 4: 4 // g2
        default: 2 // reserved → treat as the default/g5 level
        }
    }

    private static func tier(forLevel level: Int) -> UInt8 {
        switch level {
        case 0: 1 // OFF
        case 1: 2 // g10
        case 2: 0 // g5 (default)
        case 3: 3 // g3
        case 4: 4 // g2
        default: 0 // clamp → default
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
        let upLevel =
            if loss >= 0.10 { 4 } else if loss >= 0.05 { 3 } else if loss >= 0.02 { 2 } else if loss >= 0.005 { 1 }
            else { 0 }

        let downLevel =
            if loss < 0.002 { 0 } else if loss < 0.012 { 1 } else if loss < 0.035 { 2 } else if loss < 0.08 { 3 }
            else { 4 }

        if upLevel > current { return upLevel } // loss has risen → demand more redundancy
        if downLevel < current { return downLevel } // loss low enough → relax
        return current // dead-band → hold
    }

    /// Picks the next wire tier from the EWMA loss and the previous tier, with hysteresis and a
    /// strict one-level-per-call clamp (anti-flap). The clamp means relaxation on a sustained clean
    /// link is GRADUAL (one level per report) and a loss spike never jumps multiple levels at once.
    /// Relaxation floors at level 1 (g10) unless `allowOff` (see ``allowOffTierDefault``); from a
    /// pre-existing OFF state with the floor active, the first call steps UP to g10 (defensive —
    /// unreachable in production, where the env gate is fixed for the process lifetime). The host
    /// only ever calls this on a real netstats report (inert with no data).
    public static func tier(
        forLossRate loss: Double,
        previousTier: UInt8,
        allowOff: Bool = allowOffTierDefault,
    ) -> UInt8 {
        // Delegates to the Rust core (golden-vector `adaptiveTier` proves bit-exact parity with
        // the former native ladder). Env stays Swift-side: `allowOff` crosses as a byte.
        RustVideoFFI.adaptiveFECTier(loss: loss, previousTier: previousTier, allowOff: allowOff)
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

    /// STICKY RELAX (2026-06-11, telemetry round): a report carrying UNRECOVERED frame loss proves
    /// the CURRENT redundancy was insufficient — relaxing soon after is exactly the measured
    /// blip-per-2.6s failure mode. For this many reports after any `unrecovered > 0` report the
    /// relax dwell is DOUBLED (escalation stays immediate). Cheap: one countdown `Int` on
    /// ``TierState``. The window is `2 × dwell` BY CONSTRUCTION: a shorter window would close
    /// before a streak could ever reach the doubled dwell, reducing the whole mechanism to a
    /// one-report delay.
    public static let stickyRelaxWindowReports = 2 * relaxDwellReports

    /// Tier decision state for the dwell-gated variant: the current wire tier, the count of
    /// consecutive reports that demanded relaxation, and the sticky-relax countdown (reports left
    /// in the doubled-dwell window after an unrecovered loss). Value type, host-session owned —
    /// same "pure decider beside the actor" shape as `LTRController`/`StaticIDRDecider`.
    public struct TierState: Equatable, Sendable {
        public var tier: UInt8
        public var relaxStreak: Int
        /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive. Re-armed to
        /// ``stickyRelaxWindowReports`` by any report with unrecovered loss, decays by 1 per report.
        public var stickyRelaxRemaining: Int
        public init(
            tier: UInt8 = AdaptiveFECPolicy.defaultTier,
            relaxStreak: Int = 0,
            stickyRelaxRemaining: Int = 0,
        ) {
            self.tier = tier
            self.relaxStreak = relaxStreak
            self.stickyRelaxRemaining = stickyRelaxRemaining
        }
    }

    /// Dwell-gated tier step — the production entry point (plain ``tier(forLossRate:previousTier:allowOff:)``
    /// stays for tests/tools). Escalation: immediate one-step, resets the relax streak. Relaxation:
    /// counted across consecutive relax-demanding reports and applied only when the streak reaches
    /// the EFFECTIVE dwell (`dwell`, doubled while the sticky window from a recent unrecovered loss
    /// is open — see ``stickyRelaxWindowReports``); any report that does NOT demand relaxation
    /// (hold or escalate) resets the streak, so a burst arriving mid-dwell re-arms the full wait.
    /// Relaxation floors at level 1 (g10) unless `allowOff` (see ``allowOffTierDefault``).
    public static func nextTierState(
        forLossRate loss: Double,
        state: TierState,
        dwell: Int = relaxDwellReports,
        allowOff: Bool = allowOffTierDefault,
        sawUnrecoveredLoss: Bool = false,
    ) -> TierState {
        // Delegates to the Rust core: marshal the value-type state through the flat
        // `AisdTierState` and rebuild a Swift `TierState` from the result. The whole
        // hysteresis/dwell/sticky decision lives in `aislopdesk-core::adaptive_fec`, the single
        // source of truth shared with the Android host. Env stays Swift-side (`dwell` + `allowOff`
        // cross as params). Public API unchanged.
        let next = RustVideoFFI.adaptiveFECNextTierState(
            loss: loss, tier: state.tier, relaxStreak: state.relaxStreak,
            stickyRelaxRemaining: state.stickyRelaxRemaining,
            dwell: dwell, allowOff: allowOff, sawUnrecoveredLoss: sawUnrecoveredLoss,
        )
        return TierState(
            tier: next.tier,
            relaxStreak: next.relaxStreak,
            stickyRelaxRemaining: next.stickyRelaxRemaining,
        )
    }
}
