import Foundation

/// PURE content/congestion-adaptive FPS governor (the regular-cadence successor of the retired
/// `AdaptiveFPSController`, 2026-06-11).
///
/// WHY: under a genuinely bandwidth-starved link, VideoToolbox can only coarsen QP so far — past the
/// QP51 entropy floor a dense (high-entropy scroll) stream's offered load exceeds whatever rate the
/// ABR actuated, and the queue/loss spiral starts. Parsec's answer (and now ours) is to drop the
/// FRAME RATE so each remaining frame gets a bigger byte budget (sharper) AND the aggregate rate
/// fits the actuated target. The retired controller did this with an alternating skip keyed on the
/// previous frame's size — delivering frames at irregular 16.7/33.3 ms intervals, which WAS the
/// measured primary cadence khựng. This governor instead picks a target fps from a clean-divisor
/// LADDER of the base fps and actuates it through a schedule-anchored ``EncodeCadenceGate`` — so a
/// governed 30 fps is a metronome-regular every-2nd-delivery cadence, never an alternating skip.
///
/// CONTROL LAW (one tick per folded NetworkStats report, ~50 ms — the same clock as
/// ``LiveCongestionController``):
///  - BUDGET TEST: `offeredBps = bytesPerFrameEWMA × 8 × currentFps` vs `targetBps × headroom`.
///    The EWMA folds only NON-ANCHOR encoded frames (keyframes/crisp are episodic 5-10× outliers —
///    folding them would fake over-budget right after every recovery IDR); LTR refreshes (~1.49× a
///    delta) ARE folded — they are steady-state stream cost.
///  - STEP DOWN needs `overBudget AND congested` sustained for ``stepDownTicks`` reports, one rung
///    per ``stepDownHoldTicks`` window (mirrors the ABR cut-cascade fix: one cut per spacing
///    window). Content-heavy on a CLEAN link NEVER steps down — fps reduction costs input-to-photon
///    latency, and a link that is carrying the bytes does not need the sacrifice. The `congested`
///    parameter of ``onTick(targetBps:congested:)`` is the explicit seam for a later
///    static-content phase (a future caller may pass a content-idleness signal instead).
///  - STEP UP is slow (one rung per ``stepUpTicks`` clean run, ~3 s — a step is a visible cadence
///    change) and additionally requires a STRICT projected fit at the next rung
///    (`bytesPerFrameEWMA × 8 × nextFps ≤ targetBps`, NO headroom). Projection conservatism:
///    `bytesPerFrameEWMA` measured at a LOWER fps over-estimates per-frame bytes at a higher fps
///    (smaller temporal deltas), so the fit test is biased safe.
///
/// PURE + DETERMINISTIC: no wall-clock, no I/O. "Time" is the count of folded reports (`ticks`).
/// Mirrors ``LiveCongestionController``'s discipline; env-overridable tunables (`AISLOPDESK_FPS_GOV_*`).
public struct FPSGovernor: Sendable, Equatable {
    // MARK: Tunables (env-overridable AISLOPDESK_FPS_GOV_*)

    /// Offered-load overage tolerated before "over budget" (1.2 = +20%). The ABR's own cuts absorb
    /// ≤20% by trimming rate; fps only engages when VT cannot coarsen under budget (the QP51
    /// entropy floor), i.e. offered exceeds the actuated rate by more than this. `AISLOPDESK_FPS_GOV_HEADROOM`.
    public static let headroomFactor: Double = envDouble("AISLOPDESK_FPS_GOV_HEADROOM", 1.2, min: 1.0, max: 3.0)
    /// Consecutive over-budget+congested ticks (~150 ms) before a step-down — the same
    /// sustained-evidence bar as the ABR RTT path (`rttStreakTicks` = 3); one 50 ms report holds
    /// ~3 frames = quantization noise. `AISLOPDESK_FPS_GOV_DOWN_N`.
    public static let stepDownTicks: Int = envInt("AISLOPDESK_FPS_GOV_DOWN_N", 3, min: 1, max: 1000)
    /// Ticks (~400 ms) between step-downs — one rung per spacing window (mirrors the ABR
    /// `cutHoldTicks` cut-cascade fix), and the bytes-EWMA (~8-frame memory) re-converges to the
    /// new rung's frame sizes within ~270 ms at 30 fps before the next decision. `AISLOPDESK_FPS_GOV_DOWN_HOLD`.
    public static let stepDownHoldTicks: Int = envInt("AISLOPDESK_FPS_GOV_DOWN_HOLD", 8, min: 0, max: 100_000)
    /// Clean ticks (~3 s) per step-up rung — matches AdaptiveJitterController's 3 s shrink
    /// cooldown; a step-up is a visible cadence change, make it rare (full 15→60 ≈ 9 s). `AISLOPDESK_FPS_GOV_UP_N`.
    public static let stepUpTicks: Int = envInt("AISLOPDESK_FPS_GOV_UP_N", 60, min: 1, max: 100_000)
    /// Reports to fold before ANY action — the cold-start guard (~500 ms, = ABR warmup). `AISLOPDESK_FPS_GOV_WARMUP`.
    public static let warmupTicks: Int = envInt("AISLOPDESK_FPS_GOV_WARMUP", 10, min: 0, max: 100_000)
    /// Ladder floor fps — below this it is a slideshow; QP coarsening + the ABR floor cover the
    /// remainder. `AISLOPDESK_FPS_GOV_MIN`.
    public static let minFps: Int = envInt("AISLOPDESK_FPS_GOV_MIN", 15, min: 5, max: 240)
    /// EWMA weight for the per-frame bytes fold (matches the NetworkEstimate loss-EWMA discipline).
    public static let bytesAlpha: Double = 0.125

    // MARK: State (all value-type ⇒ auto Equatable / Sendable)

    /// The session's configured capture/encode fps — the ladder's top rung, never exceeded.
    public let baseFps: Int
    /// Clean-divisor rungs, descending (see ``ladder(baseFps:)``).
    public let ladder: [Int]
    /// The currently selected fps (starts at `baseFps`).
    public private(set) var currentFps: Int
    /// Folded-report count — the governor's "clock".
    public private(set) var ticks = 0
    /// Consecutive over-budget+congested ticks (the step-down streak).
    public private(set) var overBudgetRun = 0
    /// Consecutive clean (not over-budget) ticks (the step-up run).
    public private(set) var cleanRun = 0
    /// No step-down is permitted until `ticks` reaches this (set on every step-down).
    public private(set) var downHoldUntilTick = 0
    /// EWMA of non-anchor encoded frame bytes (0 = unseeded — the governor never acts unseeded).
    public private(set) var bytesPerFrameEWMA: Double = 0

    public init(baseFps: Int) {
        let base = max(1, baseFps)
        self.baseFps = base
        ladder = Self.ladder(baseFps: base)
        currentFps = ladder[0]
    }

    /// Clean-divisor ladder: divisors {1,2,3,4} of `baseFps`, floored at ``minFps``, dedup,
    /// descending. baseFps 60 → [60, 30, 20, 15]. Integer division; entries below `minFps` are
    /// dropped — but the ladder always contains `baseFps` itself, so it is never empty. Clean
    /// divisors matter: at a 16.7 ms delivery grid the governed intervals are exact multiples
    /// (2/3/4 slots), which is what makes the ``EncodeCadenceGate`` cadence metronome-regular.
    public static func ladder(baseFps: Int) -> [Int] {
        let base = max(1, baseFps)
        var rungs: Set<Int> = [base]
        for divisor in 2...4 {
            let f = base / divisor
            if f >= minFps { rungs.insert(f) }
        }
        return rungs.sorted(by: >)
    }

    /// Fold one ENCODED frame's byte size (the motion/entropy proxy). `isAnchor` (keyframe ||
    /// crisp) frames are EXCLUDED: anchors are episodic 5-10× outliers — folding them would fake
    /// over-budget right after every recovery IDR and step fps down exactly when recovering.
    /// LTR-refresh frames (≈1.49× a delta) ARE folded — they are steady-state stream cost, so the
    /// budget test self-accounts for the self-heal cadence.
    public mutating func noteEncodedFrame(bytes: Int, isAnchor: Bool) {
        guard !isAnchor, bytes > 0 else { return }
        bytesPerFrameEWMA = bytesPerFrameEWMA == 0
            ? Double(bytes)
            : bytesPerFrameEWMA * (1 - Self.bytesAlpha) + Double(bytes) * Self.bytesAlpha
    }

    /// One tick per folded NetworkStats report (~50 ms). `targetBps` is the host's
    /// `lastActuatedBitrate` (== the resolution-aware ceiling when the ABR is idle/off);
    /// `congested` is POSITIVE congestion evidence for THIS tick (see ``congestionEvidence``).
    /// Returns the (possibly unchanged) selected fps.
    @discardableResult
    public mutating func onTick(targetBps: Int, congested: Bool) -> Int {
        ticks += 1
        guard ticks >= Self.warmupTicks, bytesPerFrameEWMA > 0, targetBps > 0 else { return currentFps }
        let offeredBps = bytesPerFrameEWMA * 8 * Double(currentFps)
        let overBudget = offeredBps > Double(targetBps) * Self.headroomFactor
        if overBudget, congested {
            cleanRun = 0
            overBudgetRun += 1
            if overBudgetRun >= Self.stepDownTicks, ticks >= downHoldUntilTick,
               let next = ladder.first(where: { $0 < currentFps })
            { // ONE rung down
                currentFps = next
                overBudgetRun = 0
                downHoldUntilTick = ticks + Self.stepDownHoldTicks // one cut per window
            }
        } else if overBudget {
            // Content-heavy but the link is holding (no congestion evidence): NEVER step down on
            // content alone (the input-latency rule). Not clean either — freeze both runs.
            overBudgetRun = 0
            cleanRun = 0
        } else {
            overBudgetRun = 0
            cleanRun += 1
            if currentFps < baseFps, cleanRun >= Self.stepUpTicks,
               let next = ladder.last(where: { $0 > currentFps }), // one rung UP
               bytesPerFrameEWMA * 8 * Double(next) <= Double(targetBps)
            { // strict fit, NO headroom
                currentFps = next
                cleanRun = 0 // re-arm per rung
            }
        }
        return currentFps
    }

    /// PURE congestion-evidence predicate — the step-down gate's second AND-arm. Deliberately
    /// reuses the SAME RTT constants as the ABR (``LiveCongestionController/rttInflateFactor`` /
    /// ``LiveCongestionController/effectiveSlackMillis(minRTTMillis:)``) so the two controllers
    /// agree on what "congested" means — do NOT fork these constants. ABR-below-ceiling is
    /// included because that controller only cuts on positive evidence, making it a clean,
    /// already-debounced congestion proxy — and it automatically composes with any new ABR cut
    /// mechanism (anything that lowers `current` feeds this arm).
    public static func congestionEvidence(
        lastLossSample: Double,
        smoothedRTTMillis: Double,
        minRTTMillis: Double,
        abrCurrent: Int?,
        abrCeiling: Int?,
    ) -> Bool {
        if let cur = abrCurrent, let ceil = abrCeiling, cur < ceil { return true }
        if lastLossSample > LiveCongestionController.lossThreshold { return true }
        let slack = LiveCongestionController.effectiveSlackMillis(minRTTMillis: minRTTMillis)
        return minRTTMillis.isFinite
            && smoothedRTTMillis > minRTTMillis * LiveCongestionController.rttInflateFactor
            && smoothedRTTMillis > minRTTMillis + slack
    }

    // MARK: Env parsing helpers

    private static func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Int(s), v >= lo,
              v <= hi else { return fallback }
        return v
    }

    private static func envDouble(_ key: String, _ fallback: Double, min lo: Double, max hi: Double) -> Double {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Double(s), v >= lo,
              v <= hi else { return fallback }
        return v
    }
}

/// PURE schedule-anchored encode-cadence gate — the governor's actuator at the capture→encode
/// hand-off (NOT the retired alternating skip). The SCStream delivery rate stays untouched (the
/// 2× capture ceiling exists because ceiling==content-rate produced the measured ~30 ms slot-beat
/// gaps); this gate admits deliveries on a drift-free schedule at the governed interval:
///  - an admitted frame advances `nextDue` by EXACTLY `interval` (drift-free metronome);
///  - a content stall (`now − nextDue > interval`) re-anchors from `now` (no burst catch-up);
///  - admit when `now + tolerance ≥ nextDue` — the tolerance soaks capture-slot scheduling jitter
///    without slipping a slot (call sites pass half a delivery slot);
///  - `forced` (recovery latch pending / first frame) admits AND re-anchors (`nextDue = now +
///    interval`) so cadence stays regular around forced frames — recovery latency is unchanged
///    (≤1 DELIVERY interval, because deliveries continue at full rate and the next callback sees
///    the latch), NOT 1 governed interval.
public struct EncodeCadenceGate: Sendable, Equatable {
    private var nextDueSeconds: Double = 0

    public init() {}

    /// GATED-TAIL FLUSH seam: the anchored next-due boundary (0 = unanchored — nothing admitted
    /// yet, or the gate is inert). On a REJECTED ``admit(now:targetIntervalSeconds:toleranceSeconds:forced:)``
    /// this is the slot boundary at which the rejected content becomes admissible — the
    /// `WindowCapturer` one-shot tail flush schedules against it so a gated LAST frame of a motion
    /// burst ships at the next governed slot instead of waiting for the ~1 s static crisp refresh.
    /// Rejections never move it, so repeated gated deliveries re-arm against the SAME boundary.
    public var nextDue: Double { nextDueSeconds }

    /// One delivered-frame admission decision. `targetIntervalSeconds ≤ 0` is inert (always
    /// admit — the ungoverned/base-fps case never consults the schedule). The first call admits
    /// and anchors the schedule.
    public mutating func admit(
        now: Double,
        targetIntervalSeconds: Double,
        toleranceSeconds: Double,
        forced: Bool,
    ) -> Bool {
        guard targetIntervalSeconds > 0 else { return true }
        if forced || nextDueSeconds == 0 {
            nextDueSeconds = now + targetIntervalSeconds
            return true
        }
        guard now + toleranceSeconds >= nextDueSeconds else { return false }
        if now - nextDueSeconds > targetIntervalSeconds {
            nextDueSeconds = now + targetIntervalSeconds // stall: re-anchor, no burst catch-up
        } else {
            nextDueSeconds += targetIntervalSeconds // drift-free schedule advance
        }
        return true
    }
}

/// PURE time-equivalent self-heal cadence at a governed fps. The self-heal K (`AISLOPDESK_SELF_HEAL`,
/// default 6) was tuned at 60 fps ⇒ ~100 ms wall-clock heal latency. Counting K ENCODED frames at
/// a governed 15 fps would stretch that to 400 ms — NOT acceptable: fps is only governed down
/// during congestion, precisely when whole-frame loss is most likely and recovery round-trips are
/// most expensive. Keep the WALL-CLOCK latency ≈ constant instead: scale K by the fps ratio,
/// clamp ≥ 2 (a refresh-every-frame stream would be all-refresh). 60→6, 30→3, 20→2, 15→2.
/// Cost: a refresh ≈1.49× a delta ⇒ +16% stream bytes at K=3, +25% at K=2 — but the governed-down
/// stream already fits the actuated budget with headroom, and the refreshes ARE folded into the
/// governor's bytes-EWMA, so the budget test self-accounts for them.
public enum SelfHealCadence {
    public static func effectiveEvery(baseEvery: Int, baseFps: Int, governedFps: Int) -> Int {
        guard baseEvery > 0 else { return 0 } // 0 = disabled, passthrough
        return max(2, Int((Double(baseEvery) * Double(governedFps) / Double(max(1, baseFps))).rounded()))
    }
}
