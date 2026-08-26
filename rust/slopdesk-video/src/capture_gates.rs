//! The capture path's operating point: every `SLOPDESK_*` gate `WindowCapturer` reads, resolved
//! ONCE, plus the five decisions those gates feed.
//!
//! ## Why they are one table
//!
//! [`host_gates`](crate::host_gates) made this argument for the SESSION's thirty-three knobs; this
//! is the same argument for the CAPTURER's twenty-eight, and it has one extra edge. Twenty-five of
//! the Swift statics this replaces read `ProcessInfo.processInfo.environment` DIRECTLY rather than
//! through `EnvConfig`, so the settings overlay `docs/58` describes — the process-wide table hostd
//! folds `video-prefs.json` into at launch — never reached them. There is no settings GUI, so a
//! knob outside the overlay is a knob only an exported shell variable can move. Routing the whole
//! family through one door fixes that for all twenty-eight at once, and it cannot drift back: the
//! caller resolves [`KEYS`] and nothing else.
//!
//! ## The lookup stays in Swift, for the reason it does next door
//!
//! [`KEYS`] is the list of names in the order [`CaptureGates::from_env`] expects their values.
//! Swift reads each through `EnvConfig.string` — env, then overlay — and hands the texts back
//! positionally. Not `std::env::var`, because the overlay is Swift's table and a gate resolved out
//! from under it would quietly stop honouring a setting.
//!
//! ## Faithfulness
//!
//! Every rule is the Swift it replaces, carried verbatim rather than tidied — including the four
//! idioms that are not the project's usual two. `SLOPDESK_VIDEO_DEBUG` tests PRESENCE, so `=0`
//! enables it. `SLOPDESK_SCROLL_MOTION_MILLI` takes any parseable `u32` with no clamp. Three gates
//! are CONJUNCTIONS — the pacer and freshest-wins both require the decoupled encode queue, and
//! idle-skip needs the adaptive-QP measurement it reuses — and each conjunction was a comment
//! inside the static that implemented it. `SLOPDESK_MIN_IDR_MS` is the one gate whose default is
//! another gate's value.

use crate::encoder_config::qp_knob;

/// The inputs a gate needs that are not its own environment key.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CaptureGateContext {
    /// `VideoEncoder.maxAllowedFrameQP` — the static drop-avoidance ceiling, which is the default
    /// the adaptive-QP motion cap falls back to when `SLOPDESK_AQP_MAX` says nothing usable.
    pub max_allowed_frame_qp: i32,
    /// `EncodeLoadPacer.alpha` — the EWMA weight [`fold_encode_ewma`] folds a sample at. Passed in
    /// rather than read here so the pacer's own configuration stays its own.
    pub encode_ewma_alpha: f64,
}

/// The environment keys, in the order [`CaptureGates::from_env`] reads their values.
pub const KEYS: [&str; 28] = [
    "SLOPDESK_MOTION_HEARTBEAT",
    "SLOPDESK_AUDIO",
    "SLOPDESK_CRISP",
    "SLOPDESK_STATIC_SUPPRESS",
    "SLOPDESK_STILL_CRISP",
    "SLOPDESK_STILL_CRISP_FRAMES",
    "SLOPDESK_SCROLL_REPROJECT",
    "SLOPDESK_SCROLL_QUANTIZE",
    "SLOPDESK_ADAPTIVE_QP",
    "SLOPDESK_AQP_SHARP",
    "SLOPDESK_AQP_MAX",
    "SLOPDESK_AQP_UP_RAMP",
    "SLOPDESK_AQP_DOWN_STEP",
    "SLOPDESK_AQP_BLO_MILLI",
    "SLOPDESK_AQP_BHI_MILLI",
    "SLOPDESK_IDLE_SKIP",
    "SLOPDESK_SCROLL_FPS",
    "SLOPDESK_SCROLL_MOTION_MILLI",
    "SLOPDESK_ENCODE_OFFQUEUE",
    "SLOPDESK_ENCODE_PACER",
    "SLOPDESK_ENCODE_FRESHEST",
    "SLOPDESK_ENCODE_QUEUE_MAX",
    "SLOPDESK_FORCE_COMPACT_EVERY",
    "SLOPDESK_SELF_HEAL",
    "SLOPDESK_SELF_HEAL_LOSS_GATE",
    "SLOPDESK_MIN_IDR_MS",
    "SLOPDESK_RECOVERY_IDR_V2",
    "SLOPDESK_VIDEO_DEBUG",
];

/// Consecutive fast-scroll frames required before the scroll-fps cap engages.
///
/// A debounce, so a single flick frame is never decimated. Not a gate: it was a bare `static let`
/// in Swift with no key, and it stays one number here.
pub const SCROLL_MOTION_SUSTAIN_FRAMES: u32 = 2;

/// The loss EWMA at or above which self-heal stays armed under the clean-link loss gate.
///
/// 0.5%, mirroring the session's `kf_dup_loss_threshold` — the adaptive-FEC ladder's lowest
/// escalation boundary, and deliberately the same number so the two periodic-overhead mechanisms
/// judge a link the same way.
pub const SELF_HEAL_LOSS_GATE_THRESHOLD: f64 = 0.005;

/// The resolved capture operating point.
///
/// Every field is what the corresponding `static let` in `WindowCapturer` used to compute. Units
/// are named in the field where the key's unit is not the field's: the recovery-IDR spacing is
/// SECONDS from a key in milliseconds.
// The same opt-out `HostGates` takes, for the same reason: a gate family is mostly switches, that
// is its shape in the docs and in the operator's head, and folding pairs into two-variant enums
// would name types nobody would mention twice.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a table of switches IS mostly switches"
)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CaptureGates {
    /// Emit the periodic motion IDR during sustained motion. Default OFF: the synchronous
    /// complete-frames call blocks the capture queue, and an in-sync client recovers by other
    /// means. `=1` restores it for a genuinely lossy WAN.
    pub motion_heartbeat: bool,
    /// Configure the capture audio tap at all. Default ON; `=0` masters the feature off.
    pub audio_capture: bool,
    /// Upgrade the static-IDR timer's re-encode to a CRISP near-lossless frame. Default ON.
    pub crisp_when_static: bool,
    /// Hash each complete frame and drop a pixel-identical re-delivery. Default OFF.
    pub static_suppress: bool,
    /// Trigger the crisp re-anchor off consecutive byte-identical frames rather than off the
    /// wall-clock quiet window. Default OFF — it adds a per-frame hash to the capture queue.
    pub still_crisp: bool,
    /// Consecutive identical frames the event-driven re-anchor needs. Default 2, clamp 1…30.
    pub still_crisp_threshold: u32,
    /// Measure content scroll per frame and send the offset for the client to warp by. Default OFF.
    pub scroll_reproject: bool,
    /// Bits each luma byte is right-shifted by before the per-row scroll hash, so capture noise
    /// cannot break the exact row match. Default 3, clamp 0…7; `0` demands a byte-exact row.
    pub scroll_quantize_shift: u8,
    /// Drive the live frame's QP ceiling from the measured change magnitude. Default OFF.
    pub adaptive_qp: bool,
    /// The sharp (low) ceiling a small change is pinned to. Default 22, clamp 1…51.
    pub adaptive_qp_sharp: i32,
    /// The coarse ceiling a burst ramps up to. Defaults to the encoder's own static ceiling; the
    /// key goes through the SAME `[1, 51]` knob rule its four siblings do.
    pub adaptive_qp_max: i32,
    /// Frames the smoothed QP takes to ease UP to a coarser target — the step is
    /// `(raw - smoothed) / N`. Default 1 (instant), clamp ≥ 1.
    pub adaptive_qp_up_ramp: i32,
    /// Most QP per frame the smoothed value may ease DOWN when motion stops. Default 4, clamp ≥ 1;
    /// a huge value makes the snap-down instant again.
    pub adaptive_qp_down_step: i32,
    /// Low end of the changed-row band, in milli. Default 20, clamped to ≤ 1000.
    pub adaptive_qp_band_lo_milli: u32,
    /// High end of the changed-row band, in milli. Default 300, clamped to ≤ 1000.
    pub adaptive_qp_band_hi_milli: u32,
    /// Drop a truly-idle frame before the encode hand-off. Default OFF, and it REQUIRES
    /// `SLOPDESK_ADAPTIVE_QP`: the idle verdict IS that measurement, so without it there is nothing
    /// to be idle by. The conjunction was a sentence in the Swift static's prose.
    pub idle_skip: bool,
    /// Encode only ~N of the captured fps during sustained fast scroll. `0` disables.
    pub scroll_fps: i32,
    /// Changed-row fraction, in milli, at or above which a frame counts as FAST scroll. Default
    /// 120. No clamp — any parseable `u32`, which is the Swift it replaces.
    pub scroll_motion_threshold_milli: u32,
    /// Hand the encode to a dedicated serial queue instead of running it in the sample handler.
    /// Default ON.
    pub encode_off_queue: bool,
    /// Step the effective fps down a clean divisor when the encoder cannot sustain the budget.
    /// Default ON, and it REQUIRES the decoupled queue — it paces THAT queue's over-run.
    pub encode_pacer: bool,
    /// On a full backlog, evict the OLDEST pending delta rather than drop the incoming one.
    /// Default OFF, and it REQUIRES the decoupled queue.
    pub freshest_wins: bool,
    /// Pending encodes the decoupled queue admits. Default 3, clamp 1…12.
    pub max_encode_pending: i32,
    /// DIAGNOSTIC: force a compact recovery IDR every Nth live frame. `0` disables.
    pub force_compact_every: i32,
    /// Live deltas between self-heal LTR refreshes. Default 30; `0` disables; otherwise clamp
    /// 2…120.
    pub self_heal_every: i32,
    /// Suppress the self-heal refresh while the loss EWMA is below
    /// [`SELF_HEAL_LOSS_GATE_THRESHOLD`]. Default OFF ⇒ always heal at K, exactly as before.
    pub self_heal_loss_gate: bool,
    /// Minimum spacing between SENT recovery IDRs, in SECONDS from a key in milliseconds. `0`
    /// disables the gate. Honoured in `0…5000` ms; otherwise it defaults to whatever
    /// `SLOPDESK_RECOVERY_IDR_V2` implies — `0` while v2 owns admission, 0.5 s on the fallback.
    pub min_recovery_idr_interval: f64,
    /// Mirror capture-gap diagnostics to stderr. PRESENCE, not value: `=0` enables it.
    pub debug_gaps: bool,
}

/// A switch that is ON unless the value is exactly `"0"` — the project's default-ON idiom.
fn default_on(raw: Option<&str>) -> bool {
    raw != Some("0")
}

/// A switch that is OFF unless the value is exactly `"1"` — the project's default-OFF idiom.
fn default_off(raw: Option<&str>) -> bool {
    raw == Some("1")
}

/// A parsed integer, or `None` when the text is absent or is not one.
fn integer(raw: Option<&str>) -> Option<i64> {
    raw.and_then(|text| text.parse::<i64>().ok())
}

/// A parsed real, or `None` when the text is absent or is not one.
fn real(raw: Option<&str>) -> Option<f64> {
    raw.and_then(|text| text.parse::<f64>().ok())
}

/// A clamped `i32` from a parsed integer, or `fallback` when there is not one.
///
/// The clamp happens in `i64` and the narrowing is `try_from`, so a value far outside `i32` lands
/// at the bound the operator asked to be near rather than wrapping past it.
fn clamped(raw: Option<&str>, low: i32, high: i32, fallback: i32) -> i32 {
    integer(raw).map_or(fallback, |value| {
        i32::try_from(value.clamp(i64::from(low), i64::from(high))).unwrap_or(fallback)
    })
}

/// A parsed integer held at or above `floor`, saturating at the top, or `fallback`.
///
/// The one shape four knobs share: a count where anything below the floor is not a slower setting
/// but a nonsensical one — a zero ramp is a division by zero, a zero cadence is "never" spelled as
/// "always" — so a value under it falls back rather than clamping up into a rate nobody asked for.
fn at_least(raw: Option<&str>, floor: i64, fallback: i32) -> i32 {
    integer(raw)
        .filter(|value| *value >= floor)
        .map_or(fallback, |value| i32::try_from(value).unwrap_or(i32::MAX))
}

impl CaptureGates {
    /// Resolves the capture operating point from the texts of [`KEYS`], in that order.
    ///
    /// A value shorter than the list, or a `None` entry, is an unset key — so a caller that has not
    /// caught up with a new gate gets that gate's default rather than a panic.
    #[must_use]
    pub fn from_env(values: &[Option<&str>], context: CaptureGateContext) -> Self {
        let at = |key: &str| -> Option<&str> {
            KEYS.iter()
                .position(|name| *name == key)
                .and_then(|index| values.get(index).copied().flatten())
        };

        // Three conjunctions, each of which was a sentence in the prose of the static that
        // implemented it. Naming them here is what makes them checkable.
        let off_queue = default_on(at("SLOPDESK_ENCODE_OFFQUEUE"));
        let adaptive_qp = default_off(at("SLOPDESK_ADAPTIVE_QP"));
        // v2 owns recovery-IDR admission by default, and while it does, this sent-keyed gate is
        // INERT — it suppresses BEFORE latching, so a granted latch must never be dropped here.
        let recovery_v2 = default_on(at("SLOPDESK_RECOVERY_IDR_V2"));

        Self {
            motion_heartbeat: default_off(at("SLOPDESK_MOTION_HEARTBEAT")),
            audio_capture: default_on(at("SLOPDESK_AUDIO")),
            crisp_when_static: default_on(at("SLOPDESK_CRISP")),
            static_suppress: default_off(at("SLOPDESK_STATIC_SUPPRESS")),
            still_crisp: default_off(at("SLOPDESK_STILL_CRISP")),
            still_crisp_threshold: clamped(at("SLOPDESK_STILL_CRISP_FRAMES"), 1, 30, 2).unsigned_abs(),
            scroll_reproject: default_off(at("SLOPDESK_SCROLL_REPROJECT")),
            // The one knob whose Swift clamped what it had ALREADY defaulted: an unparseable value
            // reads 3 and is then clamped, which is the same 3. Carried as written.
            scroll_quantize_shift: u8::try_from(clamped(at("SLOPDESK_SCROLL_QUANTIZE"), 0, 7, 3))
                .unwrap_or(3),
            adaptive_qp,
            adaptive_qp_sharp: clamped(at("SLOPDESK_AQP_SHARP"), 1, 51, 22),
            // Through the encoder's own knob rule rather than a fifth hand-rolled clamp: an
            // explicit `0` asked for the sharpest motion cap there is and used to get the coarsest.
            adaptive_qp_max: qp_knob(at("SLOPDESK_AQP_MAX"), context.max_allowed_frame_qp)
                .unwrap_or(context.max_allowed_frame_qp),
            adaptive_qp_up_ramp: at_least(at("SLOPDESK_AQP_UP_RAMP"), 1, 1),
            adaptive_qp_down_step: at_least(at("SLOPDESK_AQP_DOWN_STEP"), 1, 4),
            adaptive_qp_band_lo_milli: unsigned(at("SLOPDESK_AQP_BLO_MILLI"), 20),
            adaptive_qp_band_hi_milli: unsigned(at("SLOPDESK_AQP_BHI_MILLI"), 300),
            idle_skip: adaptive_qp && default_off(at("SLOPDESK_IDLE_SKIP")),
            scroll_fps: at_least(at("SLOPDESK_SCROLL_FPS"), 1, 0),
            scroll_motion_threshold_milli: at("SLOPDESK_SCROLL_MOTION_MILLI")
                .and_then(|text| text.parse::<u32>().ok())
                .unwrap_or(120),
            encode_off_queue: off_queue,
            encode_pacer: off_queue && default_on(at("SLOPDESK_ENCODE_PACER")),
            freshest_wins: off_queue && default_off(at("SLOPDESK_ENCODE_FRESHEST")),
            max_encode_pending: clamped(at("SLOPDESK_ENCODE_QUEUE_MAX"), 1, 12, 3),
            force_compact_every: at_least(at("SLOPDESK_FORCE_COMPACT_EVERY"), 1, 0),
            // The one knob where an explicit zero is not "unset" but "off", and every other value
            // is held inside the band the measurement supports.
            self_heal_every: match integer(at("SLOPDESK_SELF_HEAL")) {
                None => 30,
                Some(0) => 0,
                Some(_) => clamped(at("SLOPDESK_SELF_HEAL"), 2, 120, 30),
            },
            self_heal_loss_gate: default_off(at("SLOPDESK_SELF_HEAL_LOSS_GATE")),
            min_recovery_idr_interval: match real(at("SLOPDESK_MIN_IDR_MS")) {
                Some(millis) if (0.0..=5000.0).contains(&millis) => millis / 1000.0,
                _ if recovery_v2 => 0.0,
                _ => 0.5,
            },
            debug_gaps: at("SLOPDESK_VIDEO_DEBUG").is_some(),
        }
    }

    /// Whether the capture callback needs the shared full-NV12 hash this frame — the union of the
    /// three hash-consuming gates.
    ///
    /// Its own function rather than a branch at the call site, the way the Swift had it: the
    /// capture callback is already the largest in the file and this keeps the union in one place,
    /// where the fact that idle-skip only wants the hash for a frame it might actually skip is
    /// visible rather than buried in a conjunction.
    #[must_use]
    pub const fn needs_frame_hash(&self, measured: bool, change_milli: u32) -> bool {
        self.still_crisp
            || self.static_suppress
            || (self.idle_skip && idle_skip_eligible(measured, change_milli))
    }

    /// Whether this live delta should become a self-heal LTR refresh.
    ///
    /// Base cadence: the counter has reached K, healing is on, and client acks are flowing. The
    /// clean-link loss gate additionally SUPPRESSES the heal while the folded loss rate is below
    /// [`SELF_HEAL_LOSS_GATE_THRESHOLD`]; with the gate off the loss term is not consulted at all,
    /// so the decision is exactly the pre-gate one. The caller keeps advancing its counter while
    /// suppressed, which is what makes re-arming on the first lossy frame immediate.
    #[must_use]
    pub fn should_self_heal(&self, frames_since_anchor: i32, eligible: bool, loss_rate: f64) -> bool {
        if self.self_heal_every <= 0 || frames_since_anchor < self.self_heal_every || !eligible {
            return false;
        }
        // A clean link — skip the refresh doublet.
        !(self.self_heal_loss_gate && loss_rate < SELF_HEAL_LOSS_GATE_THRESHOLD)
    }

    /// What the decoupled encode backlog does with an arriving frame.
    ///
    /// `pending_forced` is the forced-flag of each frame already queued, oldest first;
    /// `incoming_forced` says whether the arriving frame is a recovery or sharpness anchor, which
    /// is never dropped. Default policy is [`BacklogDecision::DropIncoming`] when full — the
    /// historical drop-newest. Under [`Self::freshest_wins`] the newest delta is admitted and the
    /// stalest pending one is coalesced out instead. A backlog that is somehow ALL forced enqueues:
    /// dropping the fresh delta there would strand the newest pixels behind anchors that are all
    /// staying.
    #[must_use]
    pub fn backlog_decision(&self, pending_forced: &[bool], incoming_forced: bool) -> BacklogDecision {
        // A negative bound is unreachable — the clamp holds it in `1…12` — and reads as a full
        // backlog if it ever were: never enqueue past a cap nobody could have meant.
        let cap = usize::try_from(self.max_encode_pending).unwrap_or(0);
        if incoming_forced || pending_forced.len() < cap {
            return BacklogDecision::Enqueue;
        }
        if !self.freshest_wins {
            return BacklogDecision::DropIncoming;
        }
        pending_forced
            .iter()
            .position(|forced| !*forced)
            .map_or(BacklogDecision::Enqueue, BacklogDecision::EvictOldestUnforced)
    }
}

/// A parsed `u32` clamped to the milli range, or `fallback`.
fn unsigned(raw: Option<&str>, fallback: u32) -> u32 {
    raw.and_then(|text| text.parse::<u32>().ok())
        .map_or(fallback, |value| value.min(1000))
}

/// Eligibility for an idle-skip: a REAL measurement with zero changed rows.
///
/// The `measured` guard rejects the degenerate-frame fallback, which also reports change 0 but on
/// an UNMEASURABLE frame — so a genuinely-unknown frame is never mistaken for an idle one. Free of
/// the table because it is about one frame's measurement and not about any gate;
/// [`CaptureGates::needs_frame_hash`] is what pairs it with the gate that acts on it.
#[must_use]
pub const fn idle_skip_eligible(measured: bool, change_milli: u32) -> bool {
    measured && change_milli == 0
}

/// The EWMA fold for the encode-wall sample.
///
/// The first sample seeds the average WHOLE — no zero-drag warm-up, which would report a first
/// frame as eight times faster than it was and let the pacer conclude the encoder had headroom it
/// has not measured yet. `alpha` is the pacer's own, passed in.
#[must_use]
pub fn fold_encode_ewma(current: f64, sample_millis: f64, alpha: f64) -> f64 {
    if current > 0.0 {
        current * (1.0 - alpha) + sample_millis * alpha
    } else {
        sample_millis
    }
}

/// What the decoupled encode backlog does with an arriving frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BacklogDecision {
    /// Append the incoming frame and schedule a drain.
    Enqueue,
    /// The backlog is full: drop the incoming (newest) delta — the historical default.
    DropIncoming,
    /// Freshest-wins: remove the pending frame at this index, append the incoming one, and do not
    /// schedule a new drain.
    EvictOldestUnforced(usize),
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "a resolved gate is the exact number the rule computed, which is the property under test"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "a window over a fixed-length key table is indexed by its own length"
    )]

    use super::*;

    /// The two prerequisite gates every conjunction hangs off.
    const BASE: [(&str, &str); 2] = [("SLOPDESK_ADAPTIVE_QP", "1"), ("SLOPDESK_ENCODE_OFFQUEUE", "1")];
    /// Several keys clamp, so `0` and `1` land on one value for them; a key is alive if ANY of
    /// these moves it off what [`BASE`] alone says.
    const PROBES: [&str; 5] = ["0", "1", "2", "9", "5000"];

    const CONTEXT: CaptureGateContext = CaptureGateContext {
        max_allowed_frame_qp: 51,
        encode_ewma_alpha: 0.25,
    };

    /// Resolves the table from a sparse `(key, value)` list; every other key is unset.
    fn gates(pairs: &[(&str, &str)]) -> CaptureGates {
        let values: Vec<Option<&str>> = KEYS
            .iter()
            .map(|key| {
                pairs
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, value)| *value)
            })
            .collect();
        CaptureGates::from_env(&values, CONTEXT)
    }

    #[test]
    fn an_empty_environment_is_the_shipped_operating_point() {
        let shipped = gates(&[]);
        assert!(!shipped.motion_heartbeat, "the periodic motion IDR is off");
        assert!(shipped.audio_capture);
        assert!(shipped.crisp_when_static);
        assert!(!shipped.static_suppress);
        assert!(!shipped.still_crisp);
        assert_eq!(shipped.still_crisp_threshold, 2);
        assert!(!shipped.scroll_reproject);
        assert_eq!(shipped.scroll_quantize_shift, 3);
        assert!(!shipped.adaptive_qp);
        assert_eq!(shipped.adaptive_qp_sharp, 22);
        assert_eq!(shipped.adaptive_qp_max, CONTEXT.max_allowed_frame_qp);
        assert_eq!(shipped.adaptive_qp_up_ramp, 1);
        assert_eq!(shipped.adaptive_qp_down_step, 4);
        assert_eq!(shipped.adaptive_qp_band_lo_milli, 20);
        assert_eq!(shipped.adaptive_qp_band_hi_milli, 300);
        assert!(!shipped.idle_skip);
        assert_eq!(shipped.scroll_fps, 0);
        assert_eq!(shipped.scroll_motion_threshold_milli, 120);
        assert!(shipped.encode_off_queue);
        assert!(shipped.encode_pacer);
        assert!(!shipped.freshest_wins);
        assert_eq!(shipped.max_encode_pending, 3);
        assert_eq!(shipped.force_compact_every, 0);
        assert_eq!(shipped.self_heal_every, 30);
        assert!(!shipped.self_heal_loss_gate);
        assert_eq!(shipped.min_recovery_idr_interval, 0.0, "v2 owns admission");
        assert!(!shipped.debug_gaps);
    }

    #[test]
    fn every_key_is_read_and_no_key_is_read_twice() {
        let mut sorted = KEYS;
        sorted.sort_unstable();
        for pair in sorted.windows(2) {
            assert_ne!(
                pair[0], pair[1],
                "a key spelled twice would read under one index only"
            );
        }
        // Every key MOVES something: a name in the list that no field consults would be a gate the
        // caller resolves and nobody honours, which is the failure this port exists to end.
        //
        // Probed against a base that turns the two PREREQUISITES on, because three gates are
        // conjunctions and idle-skip in particular cannot move at all while the measurement it
        // reuses is off — asked bare, it would read as a dead key rather than as a gated one.
        let base = gates(&BASE);
        for key in KEYS {
            let moved = PROBES.iter().any(|probe| {
                let mut pairs = BASE.to_vec();
                pairs.retain(|(name, _)| *name != key);
                pairs.push((key, probe));
                gates(&pairs) != base
            });
            assert!(moved, "{key} is resolved and then read by nothing");
        }
    }

    #[test]
    fn the_three_conjunctions_hold() {
        // Idle-skip REUSES the adaptive-QP measurement, so it cannot outlive it.
        assert!(!gates(&[("SLOPDESK_IDLE_SKIP", "1")]).idle_skip);
        assert!(gates(&[("SLOPDESK_IDLE_SKIP", "1"), ("SLOPDESK_ADAPTIVE_QP", "1")]).idle_skip);
        // The pacer paces the DECOUPLED queue's over-run; freshest-wins evicts from that backlog.
        let inline = gates(&[
            ("SLOPDESK_ENCODE_OFFQUEUE", "0"),
            ("SLOPDESK_ENCODE_FRESHEST", "1"),
        ]);
        assert!(!inline.encode_pacer);
        assert!(!inline.freshest_wins);
    }

    #[test]
    fn the_recovery_idr_spacing_falls_back_to_whichever_authority_is_live() {
        assert_eq!(
            gates(&[("SLOPDESK_MIN_IDR_MS", "250")]).min_recovery_idr_interval,
            0.25
        );
        // An explicit spacing wins even under v2 — a valid belt-and-suspenders A/B.
        let doubled = gates(&[("SLOPDESK_MIN_IDR_MS", "250"), ("SLOPDESK_RECOVERY_IDR_V2", "1")]);
        assert_eq!(doubled.min_recovery_idr_interval, 0.25);
        // Out of range, and on the v1 fallback: the historical 500 ms sent-keyed spacing.
        assert_eq!(
            gates(&[("SLOPDESK_MIN_IDR_MS", "9000"), ("SLOPDESK_RECOVERY_IDR_V2", "0"),])
                .min_recovery_idr_interval,
            0.5,
        );
        assert_eq!(
            gates(&[("SLOPDESK_RECOVERY_IDR_V2", "0")]).min_recovery_idr_interval,
            0.5
        );
    }

    #[test]
    fn the_clamps_hold_at_both_ends() {
        assert_eq!(
            gates(&[("SLOPDESK_STILL_CRISP_FRAMES", "99")]).still_crisp_threshold,
            30
        );
        assert_eq!(
            gates(&[("SLOPDESK_STILL_CRISP_FRAMES", "0")]).still_crisp_threshold,
            1
        );
        assert_eq!(
            gates(&[("SLOPDESK_SCROLL_QUANTIZE", "99")]).scroll_quantize_shift,
            7
        );
        assert_eq!(
            gates(&[("SLOPDESK_SCROLL_QUANTIZE", "-5")]).scroll_quantize_shift,
            0
        );
        assert_eq!(gates(&[("SLOPDESK_AQP_SHARP", "0")]).adaptive_qp_sharp, 1);
        assert_eq!(gates(&[("SLOPDESK_AQP_SHARP", "99")]).adaptive_qp_sharp, 51);
        assert_eq!(
            gates(&[("SLOPDESK_ENCODE_QUEUE_MAX", "99")]).max_encode_pending,
            12
        );
        assert_eq!(gates(&[("SLOPDESK_ENCODE_QUEUE_MAX", "0")]).max_encode_pending, 1);
        assert_eq!(
            gates(&[("SLOPDESK_AQP_BLO_MILLI", "5000")]).adaptive_qp_band_lo_milli,
            1000
        );
        // A ramp below 1 is not a slower ramp, it is a division by zero: the default stands.
        assert_eq!(gates(&[("SLOPDESK_AQP_UP_RAMP", "0")]).adaptive_qp_up_ramp, 1);
        assert_eq!(gates(&[("SLOPDESK_AQP_DOWN_STEP", "0")]).adaptive_qp_down_step, 4);
    }

    #[test]
    fn self_heal_k_is_zero_off_and_clamped_everywhere_else() {
        assert_eq!(gates(&[("SLOPDESK_SELF_HEAL", "0")]).self_heal_every, 0);
        assert_eq!(gates(&[("SLOPDESK_SELF_HEAL", "1")]).self_heal_every, 2);
        assert_eq!(gates(&[("SLOPDESK_SELF_HEAL", "600")]).self_heal_every, 120);
        assert_eq!(gates(&[("SLOPDESK_SELF_HEAL", "nonsense")]).self_heal_every, 30);
    }

    #[test]
    fn the_debug_gate_reads_presence_so_zero_enables_it() {
        assert!(gates(&[("SLOPDESK_VIDEO_DEBUG", "0")]).debug_gaps);
        assert!(!gates(&[]).debug_gaps);
    }

    #[test]
    fn only_a_measured_zero_change_frame_is_idle() {
        assert!(idle_skip_eligible(true, 0));
        assert!(
            !idle_skip_eligible(false, 0),
            "an unmeasurable frame is not an idle one"
        );
        assert!(!idle_skip_eligible(true, 1));
    }

    #[test]
    fn the_frame_hash_is_taken_for_whichever_gate_wants_it() {
        assert!(
            !gates(&[]).needs_frame_hash(true, 0),
            "no gate wants it by default"
        );
        assert!(gates(&[("SLOPDESK_STILL_CRISP", "1")]).needs_frame_hash(true, 9));
        assert!(gates(&[("SLOPDESK_STATIC_SUPPRESS", "1")]).needs_frame_hash(true, 9));
        // Idle-skip wants it only for a frame it might actually skip.
        let skipping = gates(&[("SLOPDESK_IDLE_SKIP", "1"), ("SLOPDESK_ADAPTIVE_QP", "1")]);
        assert!(skipping.needs_frame_hash(true, 0));
        assert!(!skipping.needs_frame_hash(true, 9));
    }

    #[test]
    fn self_heal_needs_the_cadence_the_acks_and_on_a_gated_link_the_loss() {
        let plain = gates(&[]);
        assert!(!plain.should_self_heal(29, true, 0.0), "before K");
        assert!(plain.should_self_heal(30, true, 0.0), "at K");
        assert!(!plain.should_self_heal(30, false, 0.0), "acks are not flowing");
        assert!(!gates(&[("SLOPDESK_SELF_HEAL", "0")]).should_self_heal(999, true, 0.5));

        let gated = gates(&[("SLOPDESK_SELF_HEAL_LOSS_GATE", "1")]);
        assert!(
            !gated.should_self_heal(30, true, 0.0),
            "a clean link skips the doublet"
        );
        assert!(
            gated.should_self_heal(30, true, SELF_HEAL_LOSS_GATE_THRESHOLD),
            "and re-arms the moment loss reaches the threshold, counter already past K",
        );
    }

    #[test]
    fn a_full_backlog_drops_the_newest_unless_freshest_wins() {
        let historical = gates(&[("SLOPDESK_ENCODE_QUEUE_MAX", "2")]);
        assert_eq!(
            historical.backlog_decision(&[false], false),
            BacklogDecision::Enqueue
        );
        assert_eq!(
            historical.backlog_decision(&[false, false], false),
            BacklogDecision::DropIncoming,
        );
        // A recovery anchor is never dropped, however full the backlog is.
        assert_eq!(
            historical.backlog_decision(&[false, false], true),
            BacklogDecision::Enqueue,
        );

        let freshest = gates(&[
            ("SLOPDESK_ENCODE_QUEUE_MAX", "2"),
            ("SLOPDESK_ENCODE_FRESHEST", "1"),
        ]);
        assert_eq!(
            freshest.backlog_decision(&[true, false], false),
            BacklogDecision::EvictOldestUnforced(1),
            "the stalest UNFORCED pending frame is the one that goes",
        );
        // All-forced: keep the fresh delta rather than drop it behind anchors that are all staying.
        assert_eq!(
            freshest.backlog_decision(&[true, true], false),
            BacklogDecision::Enqueue,
        );
    }

    #[test]
    fn the_first_encode_sample_seeds_the_average_whole() {
        let alpha = CONTEXT.encode_ewma_alpha;
        assert_eq!(fold_encode_ewma(0.0, 8.0, alpha), 8.0, "no zero-drag warm-up");
        let folded = fold_encode_ewma(8.0, 16.0, alpha);
        assert!(folded > 8.0 && folded < 16.0, "a later sample folds: {folded}");
    }
}
