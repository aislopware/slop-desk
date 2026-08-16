import CSlopDeskFFI
import Foundation

/// PURE content/congestion-adaptive FPS governor with a regular-cadence actuation model.
///
/// WHY: under a genuinely bandwidth-starved link, VideoToolbox can only coarsen QP so far — past the
/// QP51 entropy floor a dense (high-entropy scroll) stream's offered load exceeds whatever rate the
/// ABR actuated, and the queue/loss spiral starts. Parsec's answer (and ours) is to drop the FRAME
/// RATE so each remaining frame gets a bigger byte budget (sharper) AND the aggregate rate fits the
/// actuated target. An alternating skip keyed on the previous frame's size is avoided because it
/// delivers frames at irregular 16.7/33.3 ms intervals, which is a primary cadence-stutter source.
/// This governor instead picks a target fps from a clean-divisor LADDER of the base fps and actuates
/// it through a schedule-anchored ``EncodeCadenceGate`` — so a governed 30 fps is a metronome-regular
/// every-2nd-delivery cadence, never an alternating skip.
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
///
/// THE LAW LIVES BEHIND THE DOOR — this is the face over `rust/slopdesk-video`'s `fps_governor`,
/// reached through `frame_rate`. The state crosses BY VALUE, whole, on every call, because this is a
/// `struct` its owner copies. The LADDER does not cross with it: it is a function of the base rate
/// and the floor, so it is asked for once at construction and kept here for the call sites that read
/// it. What else stays is the `SLOPDESK_FPS_GOV_*` resolution, which is the host's own.
public struct FPSGovernor: Sendable, Equatable {
    // MARK: Tunables (env-overridable SLOPDESK_FPS_GOV_*)

    /// The defaults, spelled ONCE — on the far side, next to the law that reads them.
    private static let defaults = slopdesk_fps_config_default()

    /// Offered-load overage tolerated before "over budget" (1.2 = +20%). The ABR's own cuts absorb
    /// ≤20% by trimming rate; fps only engages when VT cannot coarsen under budget (the QP51
    /// entropy floor), i.e. offered exceeds the actuated rate by more than this. `SLOPDESK_FPS_GOV_HEADROOM`.
    public static let headroomFactor: Double = envDouble(
        "SLOPDESK_FPS_GOV_HEADROOM",
        defaults.headroom_factor,
        min: 1.0,
        max: 3.0,
    )
    /// Consecutive over-budget+congested ticks (~150 ms) before a step-down — the same
    /// sustained-evidence bar as the ABR RTT path (`rttStreakTicks` = 3); one 50 ms report holds
    /// ~3 frames = quantization noise. `SLOPDESK_FPS_GOV_DOWN_N`.
    public static let stepDownTicks: Int = envInt(
        "SLOPDESK_FPS_GOV_DOWN_N",
        Int(defaults.step_down_ticks),
        min: 1,
        max: 1000,
    )
    /// Ticks (~400 ms) between step-downs — one rung per spacing window (mirrors the ABR
    /// `cutHoldTicks` cut-cascade fix), and the bytes-EWMA (~8-frame memory) re-converges to the
    /// new rung's frame sizes within ~270 ms at 30 fps before the next decision. `SLOPDESK_FPS_GOV_DOWN_HOLD`.
    public static let stepDownHoldTicks: Int = envInt(
        "SLOPDESK_FPS_GOV_DOWN_HOLD",
        Int(defaults.step_down_hold_ticks),
        min: 0,
        max: 100_000,
    )
    /// Clean ticks (~3 s) per step-up rung — matches AdaptiveJitterController's 3 s shrink
    /// cooldown; a step-up is a visible cadence change, make it rare (full 15→60 ≈ 9 s). `SLOPDESK_FPS_GOV_UP_N`.
    public static let stepUpTicks: Int = envInt(
        "SLOPDESK_FPS_GOV_UP_N",
        Int(defaults.step_up_ticks),
        min: 1,
        max: 100_000,
    )
    /// Reports to fold before ANY action — the cold-start guard (~500 ms, = ABR warmup). `SLOPDESK_FPS_GOV_WARMUP`.
    public static let warmupTicks: Int = envInt(
        "SLOPDESK_FPS_GOV_WARMUP",
        Int(defaults.warmup_ticks),
        min: 0,
        max: 100_000,
    )
    /// Ladder floor fps — below this it is a slideshow; QP coarsening + the ABR floor cover the
    /// remainder. `SLOPDESK_FPS_GOV_MIN`.
    public static let minFps: Int = envInt("SLOPDESK_FPS_GOV_MIN", Int(defaults.min_fps), min: 5, max: 240)
    /// EWMA weight for the per-frame bytes fold (matches the NetworkEstimate loss-EWMA discipline).
    public static let bytesAlpha: Double = defaults.bytes_alpha

    /// The resolved tunables, as the law reads them.
    static let config: SlopDeskFpsConfig = {
        var c = defaults
        c.headroom_factor = headroomFactor
        c.step_down_ticks = UInt32(stepDownTicks)
        c.step_down_hold_ticks = UInt32(stepDownHoldTicks)
        c.step_up_ticks = UInt32(stepUpTicks)
        c.warmup_ticks = UInt32(warmupTicks)
        c.min_fps = Int64(minFps)
        c.bytes_alpha = bytesAlpha
        return c
    }()

    // MARK: State (one record, crossing whole)

    private var state: SlopDeskFpsGovernor

    /// Clean-divisor rungs, descending (see ``ladder(baseFps:)``). Derived once at construction:
    /// the record that crosses carries the base rate and the floor it comes from, never the rungs.
    public let ladder: [Int]

    /// The session's configured capture/encode fps — the ladder's top rung, never exceeded.
    public var baseFps: Int { Int(state.base_fps) }
    /// The currently selected fps (starts at `baseFps`).
    public var currentFps: Int { Int(state.current_fps) }
    /// Folded-report count — the governor's "clock".
    public var ticks: Int { Int(state.ticks) }
    /// Consecutive over-budget+congested ticks (the step-down streak).
    public var overBudgetRun: Int { Int(state.over_budget_run) }
    /// Consecutive clean (not over-budget) ticks (the step-up run).
    public var cleanRun: Int { Int(state.clean_run) }
    /// No step-down is permitted until `ticks` reaches this (set on every step-down).
    public var downHoldUntilTick: Int { Int(state.down_hold_until_tick) }
    /// EWMA of non-anchor encoded frame bytes (0 = unseeded — the governor never acts unseeded).
    public var bytesPerFrameEWMA: Double { state.bytes_per_frame_avg }

    public init(baseFps: Int) {
        state = slopdesk_fps_governor_new(Int64(baseFps), Self.config)
        ladder = Self.ladder(baseFps: baseFps)
    }

    /// Clean-divisor ladder: divisors {1,2,3,4} of `baseFps`, floored at ``minFps``, dedup,
    /// descending. baseFps 60 → [60, 30, 20, 15]. Integer division; entries below `minFps` are
    /// dropped — but the ladder always contains `baseFps` itself, so it is never empty. Clean
    /// divisors matter: at a 16.7 ms delivery grid the governed intervals are exact multiples
    /// (2/3/4 slots), which is what makes the ``EncodeCadenceGate`` cadence metronome-regular.
    public static func ladder(baseFps: Int) -> [Int] {
        ladder(baseFps: baseFps, minFps: minFps)
    }

    /// Clean-divisor ladder with an explicit floor. Four rungs is the whole answer, so the buffer is
    /// sized once and the count the door returns is what is read back out of it.
    static func ladder(baseFps: Int, minFps: Int) -> [Int] {
        var rungs = [Int64](repeating: 0, count: 4)
        let count = rungs.withUnsafeMutableBufferPointer {
            slopdesk_fps_ladder(Int64(baseFps), Int64(minFps), $0.baseAddress, $0.count)
        }
        return rungs.prefix(Swift.min(count, rungs.count)).map(Int.init)
    }

    /// Fold one ENCODED frame's byte size (the motion/entropy proxy). `isAnchor` (keyframe ||
    /// crisp) frames are EXCLUDED: anchors are episodic 5-10× outliers — folding them would fake
    /// over-budget right after every recovery IDR and step fps down exactly when recovering.
    /// LTR-refresh frames (≈1.49× a delta) ARE folded — they are steady-state stream cost, so the
    /// budget test self-accounts for the self-heal cadence.
    public mutating func noteEncodedFrame(bytes: Int, isAnchor: Bool) {
        state = slopdesk_fps_governor_note_frame(state, Int64(bytes), isAnchor)
    }

    /// One tick per folded NetworkStats report (~50 ms). `targetBps` is the host's
    /// `lastActuatedBitrate` (== the resolution-aware ceiling when the ABR is idle/off);
    /// `congested` is POSITIVE congestion evidence for THIS tick (see ``congestionEvidence``).
    /// Returns the (possibly unchanged) selected fps.
    @discardableResult
    public mutating func onTick(targetBps: Int, congested: Bool) -> Int {
        let tick = slopdesk_fps_governor_tick(state, Int64(targetBps), congested)
        state = tick.governor
        return Int(tick.fps)
    }

    /// PURE congestion-evidence predicate — the step-down gate's second AND-arm. Deliberately
    /// reads the ABR's OWN tunables (the same ``LiveCongestionController`` config the rate law
    /// runs on) so the two controllers agree on what "congested" means — do NOT fork these
    /// constants. ABR-below-ceiling is included because that controller only cuts on positive
    /// evidence, making it a clean, already-debounced congestion proxy — and it automatically
    /// composes with any new ABR cut mechanism (anything that lowers `current` feeds this arm).
    public static func congestionEvidence(
        lastLossSample: Double,
        smoothedRTTMillis: Double,
        minRTTMillis: Double,
        abrCurrent: Int?,
        abrCeiling: Int?,
    ) -> Bool {
        slopdesk_fps_congestion_evidence(
            LiveCongestionController.config, lastLossSample, smoothedRTTMillis, minRTTMillis,
            abrCurrent != nil, Int64(abrCurrent ?? 0), abrCeiling != nil, Int64(abrCeiling ?? 0),
        )
    }

    /// Equality is over the whole record plus the rungs derived from it — a C struct synthesises
    /// nothing, so the comparison is spelled out.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.base_fps == rhs.state.base_fps
            && lhs.state.current_fps == rhs.state.current_fps
            && lhs.state.bytes_per_frame_avg == rhs.state.bytes_per_frame_avg
            && lhs.state.ticks == rhs.state.ticks
            && lhs.state.over_budget_run == rhs.state.over_budget_run
            && lhs.state.clean_run == rhs.state.clean_run
            && lhs.state.down_hold_until_tick == rhs.state.down_hold_until_tick
            && lhs.ladder == rhs.ladder
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
/// hand-off (not an alternating skip). The SCStream delivery rate stays untouched (the 2× capture
/// ceiling exists because ceiling==content-rate produces ~30 ms slot-beat gaps); this gate admits
/// deliveries on a drift-free schedule at the governed interval:
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
        let verdict = slopdesk_fps_gate_admit(
            nextDueSeconds, now, targetIntervalSeconds, toleranceSeconds, forced,
        )
        nextDueSeconds = verdict.next_due_seconds
        return verdict.admitted
    }
}

/// PURE time-equivalent self-heal cadence at a governed fps. The self-heal K (`SLOPDESK_SELF_HEAL`,
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
        Int(slopdesk_fps_self_heal_every(Int64(baseEvery), Int64(baseFps), Int64(governedFps)))
    }
}

/// PURE self-tuning ENCODER-LOAD pacer — the COMPUTE-axis twin of ``FPSGovernor`` (which is the
/// LINK-axis).
///
/// WHY a second controller: ``FPSGovernor`` only steps fps down on NETWORK congestion (`overBudget
/// AND congested`). On a clean, fast link — the exact case the user benchmarks against Parsec — the
/// bottleneck is not the link but the HW ENCODER: a fat scroll delta whose `VTCompressionSessionEncodeFrame`
/// over-runs the base-fps inter-arrival budget (16.7 ms at 60 fps) backs up the decoupled encode
/// queue, and ``WindowCapturer``'s capture hand-off then drops deltas RAGGEDLY (whenever the backlog
/// is momentarily full). Ragged drops are an irregular 16.7/33/50 ms present cadence — a primary
/// scroll-stutter source (the 100–140 ms client present hitch), even though the average encode is
/// well under budget. The governor never sees this (the link is clean) so nothing regularises it.
///
/// This pacer measures encode WALL-TIME and, when the encoder cannot sustain the current rung's
/// budget, steps the effective fps DOWN one clean divisor so the SAME schedule-anchored
/// ``EncodeCadenceGate`` does a metronome-regular decimation (30 fps clean) instead of the ragged
/// backlog drop — Parsec's discipline, keyed on the COMPUTE budget rather than the link budget. It
/// steps back UP when even the (larger) current-rung frames fit the next-higher rung's tighter
/// budget — the governor's projection-conservatism, mirrored for encode time. INERT (returns
/// baseFps) until it has sustained evidence of over-run, so a stream the encoder keeps up with is
/// never touched. Composed at the hand-off via `min(governedFps, pacedFps)`, so the two axes never
/// fight.
///
/// PURE + DETERMINISTIC: "time" is the count of encoded frames folded (`ticks`); no wall-clock, no
/// I/O.
public struct EncodeLoadPacer: Sendable, Equatable {
    /// The defaults, spelled once on the far side. These are not env-overridable — the compute
    /// budget is a property of the machine, not a knob.
    private static let defaults = slopdesk_fps_pacer_config_default()

    /// EWMA weight for the encode-ms fold (~4-frame memory — encode spikes are bursty).
    public static let alpha = defaults.alpha
    /// Step DOWN a rung when the encode-ms EWMA reaches this fraction of the CURRENT rung's budget
    /// (`1000/currentFps` ms). < 1 so the backlog is caught building, not only once it saturates.
    public static let downFraction = defaults.down_fraction
    /// Step UP a rung when the encode-ms EWMA (measured at the current, coarser rung ⇒ LARGER frames)
    /// still fits this fraction of the NEXT-higher rung's budget. Since the higher rung's frames are
    /// SMALLER (less motion each), fitting the bigger frames under its budget is a conservative,
    /// biased-safe projection (mirrors ``FPSGovernor``'s step-up fit).
    public static let upFraction = defaults.up_fraction
    /// Consecutive over-budget encoded frames before a step-down (~50 ms at 60 fps) — fast, so a
    /// scroll burst is caught within a few frames.
    public static let downTicks = Int(defaults.down_ticks)
    /// Consecutive headroom frames before a step-up — slow (a step is a visible cadence change);
    /// ~1.5 s at 30 fps.
    public static let upTicks = Int(defaults.up_ticks)
    /// Frames to fold before ANY action (cold-start guard).
    public static let warmupTicks = Int(defaults.warmup_ticks)

    private var state: SlopDeskFpsPacer

    /// Clean-divisor rungs (reuses ``FPSGovernor/ladder(baseFps:)`` so the two controllers share the
    /// exact same metronome-regular divisor set).
    public let ladder: [Int]

    public var baseFps: Int { Int(state.base_fps) }
    public var currentFps: Int { Int(state.current_fps) }
    public var encodeMsEWMA: Double { state.encode_millis_avg }
    public var ticks: Int { Int(state.ticks) }
    public var overRun: Int { Int(state.over_run) }
    public var cleanRun: Int { Int(state.clean_run) }

    public init(baseFps: Int) {
        state = slopdesk_fps_pacer_new(Int64(baseFps), Self.defaults, Int64(FPSGovernor.minFps))
        ladder = FPSGovernor.ladder(baseFps: baseFps)
    }

    /// The per-frame wall-clock budget (ms) at a given fps.
    static func budgetMs(_ fps: Int) -> Double { slopdesk_fps_budget_millis(Int64(fps)) }

    /// Fold one encoded frame's measured wall-time (ms) and return the (possibly unchanged) paced
    /// fps. ANCHOR frames (keyframe/crisp) are episodic 5–10× encode-time outliers — excluded, like
    /// the governor excludes them from its bytes EWMA — so a recovery IDR never fakes a step-down.
    @discardableResult
    public mutating func note(encodeMs: Double, isAnchor: Bool) -> Int {
        let note = slopdesk_fps_pacer_note(state, encodeMs, isAnchor)
        state = note.pacer
        return Int(note.fps)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.base_fps == rhs.state.base_fps
            && lhs.state.current_fps == rhs.state.current_fps
            && lhs.state.encode_millis_avg == rhs.state.encode_millis_avg
            && lhs.state.ticks == rhs.state.ticks
            && lhs.state.over_run == rhs.state.over_run
            && lhs.state.clean_run == rhs.state.clean_run
            && lhs.ladder == rhs.ladder
    }
}
