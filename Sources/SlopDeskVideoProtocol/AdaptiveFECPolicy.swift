import Foundation

/// Adaptive FEC: picks the per-frame XOR-parity group size from the host's
/// measured loss and signals it on the wire so the client splits data/parity
/// identically. Two PURE concerns (value-type style, like `NetworkEstimate` /
/// `LiveCongestionController`):
///
///  A. WIRE CODEC — ``groupSize(forTier:default:)`` maps a 3-bit on-wire tier index
///     (in the spare bits of the fragment flags byte) to the group size BOTH ends
///     must use. Host packetizer AND client reassembler.
///  B. LOSS→TIER DECISION — ``tier(forLossRate:previousTier:)`` (host only) picks the
///     tier from the EWMA loss with hysteresis + a one-step clamp (anti-flap).
///
/// SIGNALLING INVARIANT: tier 0 means "use the endpoint's CONFIGURED default group
/// size" (NOT a hardcoded 5). Prod both ends run `XORParityFEC(5)`, so tier 0 is
/// byte-identical to today. With `SLOPDESK_ADAPTIVE_FEC` unset the host always sends
/// tier 0, so the spare flags bits stay zero and every frame is wire-identical to the
/// pre-adaptive path.
public enum AdaptiveFECPolicy {
    /// The default on-wire tier. Tier 0 routes to the endpoint's configured `fec.groupSize`
    /// on BOTH ends (5 in prod); its flags-byte bits are all-zero → byte-identical to the
    /// pre-adaptive path when the host always sends it.
    public static let defaultTier: UInt8 = 0

    // MARK: Multi-loss Reed-Solomon activation (SLOPDESK_FEC_M / SLOPDESK_FEC_K)

    /// Env-gated multi-loss FEC: the parity-shards-per-group `m` and the FIXED data-group size `k`
    /// the host packetizer + client reassembler both build from.
    ///
    /// DEFAULT `m == 1`: production XOR-equivalent / byte-identical wire. The whole adaptive path
    /// (per-frame tiers, loss→tier ladder, OFF/g10/g3/g2) is UNTOUCHED, golden vectors unchanged, and
    /// a mixed fleet interoperates (tier 0 frames decode on any host/client).
    ///
    /// `SLOPDESK_FEC_M >= 2` activates a true `[k + m, k]` Reed-Solomon code recovering up to `m`
    /// losses PER GROUP (which `m == 1`/XOR provably cannot). Safety constraint: the `m >= 2` Cauchy
    /// encode matrix has EXACTLY `k` columns and the codec clamps a per-call group size to `min(g, k)`,
    /// so for `m > 1` the per-frame group size MUST equal `k`. The host therefore forces a FIXED
    /// `(k, m)` with `group_size == k` for EVERY frame (sending tier 0, whose wire mapping resolves to
    /// the configured `fec.groupSize` = `k`) rather than the dynamic per-tier group sizes — see
    /// ``wireTier(adaptiveTier:)``.
    ///
    /// DEPLOY-TOGETHER: with `m > 1` the parity-fragment COUNT PER GROUP changes on the wire (`m`
    /// shards, not 1). Host and client MUST read the SAME `SLOPDESK_FEC_M` / `SLOPDESK_FEC_K` and
    /// deploy together — a host emitting `m` parity to a reassembler built for a different `m` mis-maps
    /// the parity boundary and fails to repair. Tier 0 / `m == 1` stays the mixed-fleet interop
    /// baseline; only flip `m > 1` on a host+client pair you control and ship as one unit.
    public enum MultiLossFEC {
        /// Allowed range for the parity-shard count `m` (per-group loss-recovery budget). Upper bound
        /// 8 is conservative (already heavy redundancy); the GF(2^8) bound `k + m <= 255` is enforced
        /// jointly below.
        public static let mRange = 1...8
        /// Allowed range for the fixed data-group size `k` (= the codec's column count when `m > 1`).
        /// Floored at 2 (a 1-data-shard group is degenerate), capped at 64 (well within MTU-bound
        /// fragment counts), with `k + m <= 255` enforced jointly.
        public static let kRange = 2...64
        /// Default fixed group size when multi-loss is active but `SLOPDESK_FEC_K` is unset (5 ⇒ prod
        /// default, 20% parity at `m == 1`; `m/k` overhead at `m > 1`).
        public static let defaultK = 5

        /// Resolved parity count `m` (clamped to ``mRange``; `1` = inactive / unchanged wire), read
        /// once from `SLOPDESK_FEC_M` at process start (env static — fixed for the lifetime, so host
        /// and client never disagree mid-session). Resolves through ``EnvConfig`` (ProcessInfo env →
        /// overlay) so a GUI setting can override it; an EMPTY overlay ⇒ ``configEnv`` byte-
        /// identical to `ProcessInfo.processInfo.environment` for these two keys, so this site (and the
        /// golden corpus pinning the defaults) is unchanged.
        public static let parityCount = resolveParityCount(env: configEnv)
        /// The resolved fixed group size `k` (clamped to ``kRange`` and to `255 - m`), read once from
        /// `SLOPDESK_FEC_K`. Only consulted when ``parityCount`` `>= 2`.
        public static let groupSize = resolveGroupSize(env: configEnv)

        /// The two FEC keys resolved through ``EnvConfig`` (ProcessInfo env → settings overlay), wrapped
        /// into the `[String: String]` shape the PURE resolvers consume — resolution law stays in the
        /// unit-testable pure functions while each key's *source* honours a GUI override. An empty
        /// overlay ⇒ exactly the two `ProcessInfo` entries (or none), so resolvers behave byte-
        /// identically to the old `ProcessInfo.processInfo.environment` read. `internal` (not `private`)
        /// so the reaches-consumer test can prove the overlay is consulted.
        static var configEnv: [String: String] {
            var env: [String: String] = [:]
            if let m = EnvConfig.string("SLOPDESK_FEC_M") { env["SLOPDESK_FEC_M"] = m }
            if let k = EnvConfig.string("SLOPDESK_FEC_K") { env["SLOPDESK_FEC_K"] = k }
            return env
        }

        /// Whether multi-loss recovery is active (`SLOPDESK_FEC_M >= 2`).
        public static var isActive: Bool { parityCount >= 2 }

        /// PURE resolution of `SLOPDESK_FEC_M` (testable without process state): parse, default 1,
        /// clamp to ``mRange``. A non-numeric / out-of-range value clamps to the nearest bound.
        public static func resolveParityCount(env: [String: String]) -> Int {
            guard let raw = env["SLOPDESK_FEC_M"], let m = Int(raw) else { return 1 }
            return min(max(m, mRange.lowerBound), mRange.upperBound)
        }

        /// PURE resolution of `SLOPDESK_FEC_K` (testable without process state): parse, default
        /// ``defaultK``, clamp to ``kRange``, then cap so `k + m <= 255` (the GF(2^8) field bound) for
        /// the resolved `m`. With `m == 1` the cap is inert (k <= 64 already satisfies k+1 <= 255).
        public static func resolveGroupSize(env: [String: String]) -> Int {
            let m = resolveParityCount(env: env)
            let raw = env["SLOPDESK_FEC_K"].flatMap { Int($0) } ?? defaultK
            let clamped = min(max(raw, kRange.lowerBound), kRange.upperBound)
            return min(clamped, 255 - m) // joint GF(2^8) bound k + m <= 255
        }
    }

    /// Builds the process's configured ``FECScheme``: the env-gated multi-loss Reed-Solomon codec when
    /// `SLOPDESK_FEC_M >= 2` (FIXED `[k + m, k]`, `k = SLOPDESK_FEC_K`), else the production `m == 1`
    /// default (XOR-equivalent, byte-identical wire). The DEFAULT-ARGUMENT for both the host
    /// packetizer's and client reassembler's `fec:`, so BOTH ends resolve the SAME env at the SAME
    /// site — no way to build one end multi-loss and the other single-loss within a process.
    ///
    /// `m == 1` returns `RustReedSolomonFEC(groupSize: 5, parityCount: 1)` — bit-for-bit the legacy
    /// default `XORParityFEC()`.
    public static func makeFECScheme() -> FECScheme {
        if MultiLossFEC.isActive {
            return RustReedSolomonFEC(groupSize: MultiLossFEC.groupSize, parityCount: MultiLossFEC.parityCount)
        }
        return RustReedSolomonFEC()
    }

    // MARK: Adaptive parity-count (`m`) ladder

    /// Wire FEC tiers carrying the adaptive-`m` ladder's three parity levels. From reserved tier
    /// slots 5/6/7, all of which ``groupSize(forTier:default:)`` maps to the endpoint default (`= k`)
    /// — the hard `m > 1` constraint (the RS Cauchy encoder has exactly `k` columns; group-size tiers
    /// 2/3/4 map to `g != k` and so can NOT carry `m > 1`). Each tier resolves to a fixed receive `m`
    /// (2 / 3 / 5), consumed by the client reassembler.
    public static let parityTierClean: UInt8 = 5 // m = 2 (least overhead, clean link)
    public static let parityTierNormal: UInt8 = 6 // m = 3 (baseline, == legacy fixed FEC_M=3)
    public static let parityTierBurst: UInt8 = 7 // m = 5 (heavy recovery on a loss burst)

    /// Whether the adaptive parity-count (`m`) ladder is active (`SLOPDESK_ADAPTIVE_FEC_M=1`),
    /// host-side. Default OFF.
    ///
    /// Requires a multi-loss codec (``MultiLossFEC/isActive``, `SLOPDESK_FEC_M >= 2`): the tier→`m`
    /// table is gated on `default_m >= 2`, so on the single-parity codec it is inert. The CLIENT needs
    /// no flag — its reassembler always honours the per-frame wire tier — but MUST run a matched
    /// `FEC_M >= 2` so its `default_m` activates the same table. Deploy host+client together.
    public static let adaptiveMEnabled = adaptiveMFromEnv(ProcessInfo.processInfo.environment)

    /// Pure env resolution for the adaptive-`m` gate (testable without process state): flag set AND
    /// the env resolves a multi-loss codec (`FEC_M >= 2`), the precondition for the tier→`m` table.
    static func adaptiveMFromEnv(_ env: [String: String]) -> Bool {
        env["SLOPDESK_ADAPTIVE_FEC_M"] == "1" && MultiLossFEC.resolveParityCount(env: env) >= 2
    }

    /// The wire FEC tier the host must stamp on EVERY frame, given the active scheme.
    ///
    /// Multi-loss active (`m >= 2`): FORCED to ``defaultTier`` (tier 0), whose wire mapping
    /// (``groupSize(forTier:default:)``) resolves to the configured `fec.groupSize` = exactly `k`.
    /// This pins the per-frame group size to `k` (the `m > 1` codec REQUIRES `group_size == k` — its
    /// Cauchy matrix has `k` columns and clamps `g` to `min(g, k)`); the dynamic tiers (g2/g3/g10/OFF)
    /// must NOT be used, as `group_size != k` feeds the decoder a window the matrix was never built
    /// for and silently fails to repair.
    ///
    /// `m == 1`: returns `adaptiveTier` unchanged, so the adaptive-FEC path is byte-identical.
    ///
    /// ADAPTIVE-`m` EXCEPTION: when ``adaptiveMEnabled``, the per-frame `m` ladder drives the tier and
    /// only ever emits the parity tiers 5/6/7 (``parityTierClean``/`Normal`/`Burst`), all of which map
    /// to group size `= k` — safe for the `m > 1` Cauchy code. So pass the chosen m-tier straight
    /// through instead of forcing tier 0 (which would pin a single fixed `m`).
    public static func wireTier(adaptiveTier: UInt8) -> UInt8 {
        if adaptiveMEnabled {
            return adaptiveTier
        }
        return MultiLossFEC.isActive ? defaultTier : adaptiveTier
    }

    // MARK: A. Wire codec (host packetize + client reassemble)

    /// Maps a wire tier index to the FEC group size both ends must use, or `nil` for the OFF
    /// (no-parity) tier. TOTAL over EVERY `UInt8` — a malformed/unknown tier off a corrupt fragment
    /// can NEVER trap; unknown indices fall back to the default group size. The flags byte carries
    /// only 3 bits (0..7), but this is defined for all 256 values defensively.
    ///
    /// - tier 0 → `default` (g5 in prod): the "default" — off-path AND adaptive-medium. Bits 3-5 = 0.
    /// - tier 1 → `nil`  (OFF, no parity): clean link, FEC overhead removed.
    /// - tier 2 → 10  (light, ~10% overhead).
    /// - tier 3 → 3   (heavy, ~33% overhead).
    /// - tier 4 → 2   (severe, 50% overhead).
    /// - tier 5,6,7 and any other value → `default` (reserved → safe default, forward-compatible).
    public static func groupSize(forTier tier: UInt8, default defaultGroupSize: Int) -> Int? {
        // Native Swift (single source of truth); TOTAL over every UInt8 — golden-vector
        // `adaptiveGroupSize` pins it, and a corrupt-fragment tier can NEVER trap.
        switch tier {
        case 1: nil // OFF (clean link, no parity)
        case 2: 10 // light (~10%)
        case 3: 3 // heavy (~33%)
        case 4: 2 // severe (50%)
        default: defaultGroupSize // 0 + reserved 5,6,7 (+ any other) → safe default
        }
    }

    // MARK: B. Loss → tier decision (host only)

    /// FEC LADDER FLOOR: the relax path FLOORS at level 1 (g10, ~10% overhead) and never selects OFF
    /// by default. On the live FPT↔Viettel path (169 s, baseline loss 0.1–0.6%), letting relax reach
    /// OFF produced 158 tier transitions incl. 18 to OFF, 102 unrecovered frame losses (1.1%) vs 186
    /// FEC-recovered → 65 client decode-fails ≈ 1 per 2.6 s, each a blip risk. On a NONZERO-baseline-
    /// loss path OFF is never safe — the dwell only slows the walk there, not stops it.
    /// `SLOPDESK_FEC_ALLOW_OFF=1` re-enables relax-to-OFF (a genuinely loss-free LAN/loopback can
    /// reclaim the standing ~10%). The WIRE CODEC for tier 1 is untouched — an OFF-tier frame from an
    /// old/flagged host still decodes.
    public static let allowOffTierDefault = allowOffTier(env: ProcessInfo.processInfo.environment)

    /// Pure env resolution for the OFF-tier escape hatch (testable without process state).
    public static func allowOffTier(env: [String: String]) -> Bool {
        env["SLOPDESK_FEC_ALLOW_OFF"] == "1"
    }

    /// Picks the next wire tier from the EWMA loss and previous tier, with hysteresis and a strict
    /// one-level-per-call clamp (anti-flap): relaxation on a sustained clean link is GRADUAL (one
    /// level per report) and a loss spike never jumps multiple levels. Relaxation floors at level 1
    /// (g10) unless `allowOff` (see ``allowOffTierDefault``); from a pre-existing OFF state with the
    /// floor active, the first call steps UP to g10 (defensive — unreachable in production, where the
    /// env gate is fixed for the process lifetime). The host only calls this on a real netstats report
    /// (inert with no data).
    public static func tier(
        forLossRate loss: Double,
        previousTier: UInt8,
        allowOff: Bool = allowOffTierDefault,
    ) -> UInt8 {
        // Native Swift (single source of truth); golden-vector `adaptiveTier` pins bit-exact parity.
        let current = levelForTier(previousTier)
        let target = max(
            targetLevel(forLossRate: loss, currentLevel: current),
            relaxFloorLevel(allowOff: allowOff),
        )
        let stepped: Int = if target > current { current + 1 } else if target < current { current - 1 } else { current }
        return tierForLevel(stepped)
    }

    // MARK: Group-size ladder internals (level ↔ wire-tier translation + hysteretic target)

    /// The lowest redundancy LEVEL the relax path may land on: 1 (g10) by default, 0 (OFF) only
    /// behind the escape hatch. Escalation is unaffected (it only ever raises the level).
    private static func relaxFloorLevel(allowOff: Bool) -> Int { allowOff ? 0 : 1 }

    /// Internal redundancy LEVEL, monotonic in loss (0 = least redundancy … 4 = most):
    ///  level 0 = OFF, 1 = g10, 2 = g5 (the default), 3 = g3, 4 = g2.
    /// The wire tier numbering is NOT the redundancy order (tier 0 must be g5 for byte-identity),
    /// so these maps translate between them.
    private static func levelForTier(_ tier: UInt8) -> Int {
        switch tier {
        case 1: 0 // OFF
        case 2: 1 // g10
        case 0: 2 // g5 (default)
        case 3: 3 // g3
        case 4: 4 // g2
        default: 2 // reserved → treat as the default/g5 level
        }
    }

    private static func tierForLevel(_ level: Int) -> UInt8 {
        switch level {
        case 0: 1 // OFF
        case 1: 2 // g10
        case 2: 0 // g5 (default)
        case 3: 3 // g3
        case 4: 4 // g2
        default: 0 // clamp → default
        }
    }

    /// The redundancy level the loss demands, given the current level. Hysteretic: asymmetric
    /// up/down thresholds create a dead-band so a loss oscillating around a boundary does NOT flap.
    ///
    /// Up-thresholds (raise redundancy):  ≥0.005→L1, ≥0.02→L2, ≥0.05→L3, ≥0.10→L4.
    /// Down-thresholds (relax):  <0.002→L0, <0.012→L1, <0.035→L2, <0.08→L3.
    private static func targetLevel(forLossRate loss: Double, currentLevel current: Int) -> Int {
        let upLevel =
            if loss >= 0.10 { 4 } else if loss >= 0.05 { 3 } else if loss >= 0.02 { 2 }
            else if loss >= 0.005 { 1 } else { 0 }

        let downLevel =
            if loss < 0.002 { 0 } else if loss < 0.012 { 1 } else if loss < 0.035 { 2 }
            else if loss < 0.08 { 3 } else { 4 }

        if upLevel > current { return upLevel } // loss has risen → demand more redundancy
        if downLevel < current { return downLevel } // loss low enough → relax
        return current // dead-band → hold
    }

    // MARK: Relax dwell (4G burst-flap fix)

    /// How many CONSECUTIVE relax-demanding reports must accumulate before the tier steps DOWN one
    /// level. Escalation stays immediate (one step per report).
    ///
    /// WHY: naive one-step-per-report relax flaps badly on a real 4G path — mobile loss arrives in
    /// BURSTS seconds apart, and the loss EWMA decays below the relax thresholds between bursts, so
    /// relax walks back to OFF in ~1s and EVERY burst then lands on an unprotected stream (measured:
    /// 224 tier changes in one session, cycling OFF→g10→g5→g10→OFF every ~8s, 118 unrecovered frames
    /// ≈ 1%, almost all in OFF windows). Requiring ~12s of consecutively clean reports keeps g10 armed
    /// BETWEEN bursts while a genuinely clean path (home WiFi) still relaxes to OFF — just ~12s per step
    /// slower, a one-time cost against a standing 10-20% overhead saving.
    ///
    /// ⚠️ CADENCE-COUPLED: the host steps this once per client NetworkStats report, and that timer fires
    /// every 50 ms (`SlopDeskVideoClientSession` networkStatsTask, ~20/s) — NOT the ~2/s an earlier
    /// version assumed. So ~12s = 240 reports, not 24. (The original 24 gave a 1.2s dwell — 10× too fast,
    /// defeating the anti-flap entirely; every ~8s burst still relaxed to OFF between bursts.) If that
    /// 50 ms cadence ever changes, re-derive this: `relaxDwellReports ≈ 12s / reportInterval`.
    public static let relaxDwellReports = 240

    /// STICKY RELAX: a report carrying UNRECOVERED frame loss proves the CURRENT redundancy was
    /// insufficient — relaxing soon after is exactly the measured blip-per-2.6s failure mode (see
    /// ``allowOffTierDefault``). For this many reports after any `unrecovered > 0` report the relax
    /// dwell is DOUBLED (escalation stays immediate). Cheap: one countdown `Int` on ``TierState``. The
    /// window is `2 × dwell` BY CONSTRUCTION — a shorter window would close before a streak could reach
    /// the doubled dwell, reducing the mechanism to a one-report delay.
    public static let stickyRelaxWindowReports = 2 * relaxDwellReports

    /// Tier decision state for the dwell-gated variant: current wire tier, count of consecutive
    /// relax-demanding reports, and the sticky-relax countdown (reports left in the doubled-dwell
    /// window after an unrecovered loss). Value type, host-session owned — same "pure decider beside
    /// the actor" shape as `LTRController`/`StaticIDRDecider`.
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
    /// counted across consecutive relax-demanding reports, applied only when the streak reaches the
    /// EFFECTIVE dwell (`dwell`, doubled while the sticky window from a recent unrecovered loss is open
    /// — see ``stickyRelaxWindowReports``); any report that does NOT demand relaxation (hold/escalate)
    /// resets the streak, so a burst mid-dwell re-arms the full wait. Relaxation floors at level 1
    /// (g10) unless `allowOff` (see ``allowOffTierDefault``).
    public static func nextTierState(
        forLossRate loss: Double,
        state: TierState,
        dwell: Int = relaxDwellReports,
        allowOff: Bool = allowOffTierDefault,
        sawUnrecoveredLoss: Bool = false,
    ) -> TierState {
        // Native Swift (single source of truth). The whole hysteresis/dwell/sticky decision lives
        // here; `dwell` + `allowOff` stay Swift-side env-derived params. Public API unchanged.
        let sticky = sawUnrecoveredLoss ? stickyRelaxWindowReports : max(0, state.stickyRelaxRemaining - 1)
        let effectiveDwell = sticky > 0 ? 2 * dwell : dwell
        let current = levelForTier(state.tier)
        let target = max(
            targetLevel(forLossRate: loss, currentLevel: current),
            relaxFloorLevel(allowOff: allowOff),
        )
        if target > current {
            return TierState(tier: tierForLevel(current + 1), relaxStreak: 0, stickyRelaxRemaining: sticky)
        }
        if target < current {
            let streak = state.relaxStreak + 1
            if streak >= max(1, effectiveDwell) {
                return TierState(tier: tierForLevel(current - 1), relaxStreak: 0, stickyRelaxRemaining: sticky)
            }
            return TierState(tier: state.tier, relaxStreak: streak, stickyRelaxRemaining: sticky)
        }
        return TierState(tier: state.tier, relaxStreak: 0, stickyRelaxRemaining: sticky)
    }

    /// Dwell-gated PARITY-tier step — the m-adaptive counterpart of ``nextTierState(forLossRate:state:dwell:allowOff:sawUnrecoveredLoss:)``.
    ///
    /// Steps the per-frame parity multiplicity `m` (over ``parityTierClean``/`Normal`/`Burst` → `m`
    /// 2/3/5) with the same hysteresis + dwell + sticky-relax: escalation immediate on a loss burst,
    /// relaxation waits out the (sticky-doubled) dwell, floor is the CLEAN level (`m == 2`) — no OFF
    /// tier on this path, so unlike the group-size ladder it takes no `allowOff`.
    public static func nextParityTierState(
        forLossRate loss: Double,
        state: TierState,
        dwell: Int = relaxDwellReports,
        sawUnrecoveredLoss: Bool = false,
    ) -> TierState {
        // Native Swift (single source of truth). Asymmetric FAST-ATTACK / slow-decay over the
        // 3-level parity-m ladder (clean/normal/burst → m 2/3/5), no OFF tier (floor = CLEAN).
        let sticky = sawUnrecoveredLoss ? stickyRelaxWindowReports : max(0, state.stickyRelaxRemaining - 1)
        let effectiveDwell = sticky > 0 ? 2 * dwell : dwell
        let current = mLevelForTier(state.tier)
        // Fast-attack: a real dropped frame floors the demand at NORMAL even before the EWMA reacts.
        let target = sawUnrecoveredLoss
            ? max(mTargetLevel(forLossRate: loss, currentLevel: current), 1)
            : mTargetLevel(forLossRate: loss, currentLevel: current)

        if target > current {
            // Jump straight to the demanded level (not one step) — full parity by the next frame.
            return TierState(tier: tierForMLevel(target), relaxStreak: 0, stickyRelaxRemaining: sticky)
        }
        if target < current {
            let streak = state.relaxStreak + 1
            if streak >= max(1, effectiveDwell) {
                return TierState(tier: tierForMLevel(current - 1), relaxStreak: 0, stickyRelaxRemaining: sticky)
            }
            return TierState(tier: state.tier, relaxStreak: streak, stickyRelaxRemaining: sticky)
        }
        return TierState(tier: state.tier, relaxStreak: 0, stickyRelaxRemaining: sticky)
    }

    // MARK: Parity-m ladder internals (level ↔ parity-tier translation + hysteretic target)

    /// Internal redundancy LEVEL for the parity-count ladder (0 = least `m` … 2 = most): 0=clean
    /// (m2, tier 5), 1=normal (m3, tier 6), 2=burst (m5, tier 7). Any other tier (a corrupt read,
    /// or a group-size tier) maps to the NORMAL baseline.
    private static func mLevelForTier(_ tier: UInt8) -> Int {
        switch tier {
        case parityTierClean: 0
        case parityTierBurst: 2
        default: 1 // parityTierNormal and any other → baseline
        }
    }

    private static func tierForMLevel(_ level: Int) -> UInt8 {
        switch level {
        case 0: parityTierClean
        case 2: parityTierBurst
        default: parityTierNormal // 1 and any clamp → baseline
        }
    }

    /// The parity redundancy level the loss demands, given the current level. Hysteretic dead-band.
    ///
    /// Up-thresholds (raise `m`): ≥0.005 → L1, ≥0.03 → L2.
    /// Down-thresholds (relax `m`): <0.002 → L0, <0.02 → L1.
    private static func mTargetLevel(forLossRate loss: Double, currentLevel current: Int) -> Int {
        let upLevel = if loss >= 0.03 { 2 } else if loss >= 0.005 { 1 } else { 0 }

        let downLevel = if loss < 0.002 { 0 } else if loss < 0.02 { 1 } else { 2 }

        if upLevel > current { return upLevel }
        if downLevel < current { return downLevel }
        return current
    }
}
