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

/// Ceiling the consecutive-fast-scroll run counts to.
///
/// The run is only ever compared against [`SCROLL_MOTION_SUSTAIN_FRAMES`], so anything past a
/// million is the same answer as a million; the cap is there so a scroll that never stops cannot
/// walk the counter into an overflow. A bare `min` in Swift, and one number here.
pub const SCROLL_MOTION_RUN_CEILING: u32 = 1_000_000;

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
        self.should_self_heal_every(self.self_heal_every, frames_since_anchor, eligible, loss_rate)
    }

    /// [`Self::should_self_heal`] against a cadence the caller supplies rather than the table's
    /// own.
    ///
    /// The below-gate path rebases K time-equivalently at a governed fps
    /// (`slopdesk_fps_self_heal_every` — 60→6, 30→3, 20→2, 15→2) so the wall-clock heal latency
    /// stays ≈100–133 ms, and it is THAT K the counter must be compared against. Splitting it
    /// out keeps [`Self::should_self_heal`] — the ungoverned question — spelled once.
    #[must_use]
    pub fn should_self_heal_every(
        &self,
        heal_every: i32,
        frames_since_anchor: i32,
        eligible: bool,
        loss_rate: f64,
    ) -> bool {
        if heal_every <= 0 || frames_since_anchor < heal_every || !eligible {
            return false;
        }
        // A clean link — skip the refresh doublet.
        !(self.self_heal_loss_gate && loss_rate < SELF_HEAL_LOSS_GATE_THRESHOLD)
    }

    /// Whether a periodic motion-heartbeat IDR is DUE.
    ///
    /// The heartbeat is default-OFF, so the gate is half the question and the clock is the other
    /// half. Spelled once because it is asked twice per frame: the static-suppression decider must
    /// not suppress a frame that owes the periodic insurance IDR, and the below-gate resolution
    /// promotes that frame to a keyframe.
    #[must_use]
    pub const fn heartbeat_due(&self, now: f64, last_heartbeat: f64, interval: f64) -> bool {
        self.motion_heartbeat && now - last_heartbeat >= interval
    }

    /// The asymmetric smoothing law for the per-frame adaptive-QP ceiling.
    ///
    /// `previous` is the last smoothed value, or `None` on the first measured frame — which seeds
    /// the smoother WHOLE, exactly as the encode EWMA does.
    ///
    /// The two directions are deliberately unequal. Coarsening on motion ONSET eases up by
    /// `(raw - smoothed) / up_ramp`, floored at ONE QP so a ramp wider than the gap still MOVES —
    /// a step that rounded to zero would pin the smoother at the sharp end for the whole burst,
    /// which is the ~80 KB-per-frame scroll start this law exists to avoid. Re-sharpening on STOP
    /// steps down by at most `down_step` per frame, because a snap straight to the floor re-encodes
    /// the whole settled viewport in ONE frame (the scroll-stop stutter).
    ///
    /// Both clamps are `at_least(…, 1, …)` in [`Self::from_env`], so the division is by a positive
    /// number; the `max(1)` on the divisor is for a table that did not come from there — a door
    /// takes its record from C — and lands on the same value for every table that did.
    #[must_use]
    #[expect(
        clippy::integer_division,
        reason = "QP is a whole number on the wire — the truncated step is the law, and its remainder is \
                  carried by the next frame's gap rather than lost"
    )]
    pub fn smooth_adaptive_qp(&self, previous: Option<i32>, raw_qp: i32) -> i32 {
        let Some(smoothed) = previous else { return raw_qp };
        if raw_qp > smoothed {
            let gap = raw_qp.saturating_sub(smoothed);
            smoothed.saturating_add((gap / self.adaptive_qp_up_ramp.max(1)).max(1))
        } else {
            raw_qp.max(smoothed.saturating_sub(self.adaptive_qp_down_step))
        }
    }

    /// The scroll-fps cap: a sustain-run debounce, then an even Bresenham decimation.
    ///
    /// `motion_run` and `phase` are the caller's carried state; the answer carries both back
    /// advanced. `base_fps` is the CAPTURE rate the cap is a fraction of, `measured` and
    /// `change_milli` are this frame's change measurement, and `obligated` says the frame owes
    /// something — a pending forced keyframe, a pending LTR refresh, or a due heartbeat.
    ///
    /// Two guards, each load-bearing. The run must reach [`SCROLL_MOTION_SUSTAIN_FRAMES`] before
    /// the cap engages at all, so a single flick frame is never decimated; and an obligated frame
    /// always passes, so a recovery anchor cannot be dropped by a rate cap. Either guard also
    /// RESETS the accumulator, so a burst always starts its decimation pattern from the same phase
    /// rather than from wherever the last burst left off.
    #[must_use]
    pub fn scroll_decimation(
        &self,
        motion_run: u32,
        phase: i32,
        base_fps: i32,
        measured: bool,
        change_milli: u32,
        obligated: bool,
    ) -> ScrollDecimation {
        // Slow scroll and caret motion never trigger: the changed-row fraction is the whole test
        // for what counts as FAST, and an unmeasured frame is not fast by default.
        let fast = self.scroll_fps > 0
            && self.scroll_fps < base_fps
            && measured
            && change_milli >= self.scroll_motion_threshold_milli;
        let run = if fast {
            motion_run.saturating_add(1).min(SCROLL_MOTION_RUN_CEILING)
        } else {
            0
        };
        if run < SCROLL_MOTION_SUSTAIN_FRAMES || obligated {
            return ScrollDecimation {
                motion_run: run,
                phase: 0,
                encode: true,
            };
        }
        let advanced = phase.saturating_add(self.scroll_fps);
        if advanced >= base_fps {
            ScrollDecimation {
                motion_run: run,
                phase: advanced.saturating_sub(base_fps),
                encode: true,
            }
        } else {
            ScrollDecimation {
                motion_run: run,
                phase: advanced,
                encode: false,
            }
        }
    }

    /// The below-gate keyframe / compact / LTR-refresh resolution for one frame.
    ///
    /// The largest decision on the capture path and the highest-consequence one: a wrong verdict
    /// here is a visible stream artefact, not a crash. It is a pure state transition — the answer
    /// carries the advanced [`EncodeAnchors`] back, and the caller assigns them.
    ///
    /// The ladder, in the order the reasons compose:
    ///
    /// 1. The drained recovery latch proposes a keyframe.
    /// 2. The FIRST delivered frame always forces one, and marks itself so.
    /// 3. Otherwise a DUE motion heartbeat forces one (default OFF — the synchronous
    ///    complete-frames call blocks the capture queue).
    /// 4. RECOVERY-IDR STORM COLLAPSE: if the latch is the ONLY reason and a keyframe went out less
    ///    than [`Self::min_recovery_idr_interval`] ago, ship a P-frame instead — the recent
    ///    keyframe already re-anchored the client, and the client's 2·RTT escalation re-requests
    ///    later, OUTSIDE the window, if that one was lost too. The dropped force is NOT re-latched,
    ///    so it cannot deferred-storm. It never gates the first-frame or heartbeat IDR.
    /// 5. Any ACTUALLY-emitted keyframe re-anchors BOTH clocks.
    /// 6. A forced IDR on the live path is compact — `compact = force_keyframe && !first_frame`.
    ///    The first frame stays full quality (one-time, no loop).
    /// 7. An LTR refresh ships only when no keyframe does: a keyframe is a superset recovery and
    ///    wins, so a refresh latched alongside one is simply consumed.
    /// 8. SELF-HEAL cadence, at the caller's fps-rebased `heal_every`. The counter advances only on
    ///    a frame that is neither a keyframe nor an already-latched refresh, and RESETS on either.
    /// 9. The diagnostic force-compact storm, which fires only when no real obligation already did.
    #[must_use]
    pub fn resolve_encode(&self, anchors: EncodeAnchors, frame: EncodeFrame) -> EncodeResolution {
        let mut next = anchors;
        let mut force_keyframe = frame.keyframe_latched;
        let mut is_first_frame = false;
        let mut is_heartbeat = false;
        if anchors.has_emitted_first_frame {
            if self.heartbeat_due(frame.now, anchors.last_heartbeat, frame.heartbeat_interval) {
                force_keyframe = true;
                is_heartbeat = true;
            }
        } else {
            force_keyframe = true;
            is_first_frame = true;
            next.has_emitted_first_frame = true;
        }
        if force_keyframe
            && frame.keyframe_latched
            && !is_first_frame
            && !is_heartbeat
            && self.min_recovery_idr_interval > 0.0
            && frame.now - anchors.last_keyframe_emit < self.min_recovery_idr_interval
        {
            force_keyframe = false;
        }
        if force_keyframe {
            next.last_heartbeat = frame.now;
            next.last_keyframe_emit = frame.now;
        }
        let compact = force_keyframe && !is_first_frame;
        let mut ltr_refresh = frame.ltr_latched && !force_keyframe;
        // The counter keeps climbing while the clean-link loss gate suppresses (skipped, not
        // reset), which is what makes re-arming on the first lossy frame immediate.
        if frame.heal_every > 0 && !force_keyframe && !ltr_refresh {
            next.frames_since_anchor = next.frames_since_anchor.saturating_add(1);
            if self.should_self_heal_every(
                frame.heal_every,
                next.frames_since_anchor,
                frame.self_heal_eligible,
                frame.self_heal_loss_rate,
            ) {
                ltr_refresh = true;
            }
        }
        if force_keyframe || ltr_refresh {
            next.frames_since_anchor = 0;
        }
        let mut force_compact = compact;
        if self.force_compact_every > 0 && !force_keyframe && !ltr_refresh && !compact {
            next.force_compact_counter = next.force_compact_counter.saturating_add(1);
            if next.force_compact_counter % self.force_compact_every == 0 {
                force_compact = true;
            }
        }
        EncodeResolution {
            anchors: next,
            force_keyframe,
            compact: force_compact,
            ltr_refresh,
        }
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

/// The synthetic-PTS counter: one 90 kHz tick past the last emitted PTS.
///
/// A COUNTER, not a clock (Sunshine's discipline): the static-IDR timer's re-encode of a cached
/// frame has no capture timestamp of its own, and one tick past the high-water mark is strictly
/// monotonic and collision-free with every real frame — which the live session requires, since it
/// encodes with frame reordering off.
///
/// Saturating rather than wrapping, which is `CMTimeAdd`'s own behaviour at the top of the range
/// and unreachable either way: at 90 kHz, `i64::MAX` ticks is about three million years.
#[must_use]
pub const fn synthetic_pts(last_ticks: i64) -> i64 {
    last_ticks.saturating_add(1)
}

/// The high-water clamp a REAL frame's PTS passes through before the encode hand-off.
///
/// Clamping the value ACTUALLY handed to the encoder — not just the tracker — is what stops a real
/// frame from reversing a prior synthetic IDR's PTS. Both sides are 90 kHz ticks, so the comparison
/// is exact rather than a rational one.
#[must_use]
pub fn monotonic_pts(last_ticks: i64, incoming_ticks: i64) -> i64 {
    last_ticks.max(incoming_ticks)
}

/// The scroll-fps cap's verdict, and the decimator state it leaves behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrollDecimation {
    /// Consecutive fast-scroll frames, after this one.
    pub motion_run: u32,
    /// The Bresenham accumulator, after this one.
    pub phase: i32,
    /// Whether this frame goes on to the encode hand-off. `false` drops it entirely — no encode,
    /// no packetize, no send.
    pub encode: bool,
}

/// The frameQueue-owned anchors the below-gate resolution carries between frames.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncodeAnchors {
    /// Uptime seconds of the last heartbeat-cadence anchor — any emitted keyframe.
    pub last_heartbeat: f64,
    /// Uptime seconds of the last EMITTED keyframe, which drives the recovery-IDR cooldown.
    pub last_keyframe_emit: f64,
    /// Live frames since the last re-anchor (keyframe or LTR refresh).
    pub frames_since_anchor: i32,
    /// The diagnostic force-compact counter.
    pub force_compact_counter: i32,
    /// Whether a frame has ever been handed to the encoder on this capturer.
    pub has_emitted_first_frame: bool,
}

/// One below-gate frame's inputs that are neither the table nor the anchors.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncodeFrame {
    /// Uptime seconds, the same clock the anchors are stamped in.
    pub now: f64,
    /// The periodic motion-IDR cadence, in seconds.
    pub heartbeat_interval: f64,
    /// The freshly-folded loss EWMA the session pushes, consulted only under the loss gate. High
    /// (infinite) before any report, so an unmeasured link never suppresses healing.
    pub self_heal_loss_rate: f64,
    /// The self-heal cadence for THIS frame — the table's K rebased time-equivalently at the
    /// governed fps. Equal to the table's own K while the fps governor is inert.
    pub heal_every: i32,
    /// The DRAINED forced-keyframe latch (a client loss-recovery request).
    pub keyframe_latched: bool,
    /// The DRAINED LTR-refresh latch — the cheap recovery alternative to a forced IDR.
    pub ltr_latched: bool,
    /// Whether client LTR acks are flowing, which is what arms the self-heal cadence.
    pub self_heal_eligible: bool,
}

/// What the below-gate path does with one frame, and the anchors it leaves behind.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncodeResolution {
    /// The advanced anchors — the caller assigns every field back.
    pub anchors: EncodeAnchors,
    /// Encode this frame as an IDR.
    pub force_keyframe: bool,
    /// Encode it SMALL+coarse. `compact ⟹ force_keyframe` for every real obligation; the
    /// DIAGNOSTIC force-compact storm is the one path that sets it alone, on purpose.
    pub compact: bool,
    /// Encode it as a cheap `ForceLTRRefresh` P-frame.
    pub ltr_refresh: bool,
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
    fn the_adaptive_qp_smoother_seeds_whole_then_ramps_up_and_steps_down() {
        let plain = gates(&[]);
        assert_eq!(
            plain.smooth_adaptive_qp(None, 37),
            37,
            "the first frame seeds whole"
        );
        // Default up-ramp 1 ⇒ INSTANT: a scroll's first frames are already coarse.
        assert_eq!(plain.smooth_adaptive_qp(Some(22), 40), 40);
        // Default down-step 4: a stop re-sharpens by at most that per frame, never straight to raw.
        assert_eq!(plain.smooth_adaptive_qp(Some(40), 22), 36);
        // …and the step never OVERSHOOTS past the target.
        assert_eq!(plain.smooth_adaptive_qp(Some(24), 22), 22);
        // Equal is not "up": it takes the down branch and lands on itself.
        assert_eq!(plain.smooth_adaptive_qp(Some(30), 30), 30);

        // The `max(1, …)` boundary: a ramp WIDER than the gap still moves one QP. `(23-22)/4 == 0`
        // in Swift's truncating division and in Rust's, and a smoother pinned at the sharp end for
        // a whole burst is the ~80 KB-per-frame scroll start this law exists to avoid.
        let ramped = gates(&[("SLOPDESK_AQP_UP_RAMP", "4")]);
        assert_eq!(ramped.smooth_adaptive_qp(Some(22), 23), 23);
        assert_eq!(ramped.smooth_adaptive_qp(Some(22), 26), 23, "(26-22)/4 == 1");
        assert_eq!(ramped.smooth_adaptive_qp(Some(22), 42), 27, "(42-22)/4 == 5");

        // A huge down-step makes the snap-down instant again, which is the knob's documented use.
        let snapping = gates(&[("SLOPDESK_AQP_DOWN_STEP", "51")]);
        assert_eq!(snapping.smooth_adaptive_qp(Some(40), 22), 22);
    }

    /// The two ends of the scroll cap: the debounce, and the even Bresenham pattern.
    #[test]
    fn the_scroll_cap_debounces_then_decimates_evenly() {
        let capped = gates(&[("SLOPDESK_SCROLL_FPS", "30")]);
        let fast = capped.scroll_motion_threshold_milli;

        // A single flick frame is never decimated — the run has not reached the sustain.
        let first = capped.scroll_decimation(0, 0, 60, true, fast, false);
        assert_eq!(first, ScrollDecimation {
            motion_run: 1,
            phase: 0,
            encode: true,
        });
        // The second consecutive fast frame reaches the sustain, and 30/60 keeps every other one.
        let second = capped.scroll_decimation(first.motion_run, first.phase, 60, true, fast, false);
        assert_eq!(second, ScrollDecimation {
            motion_run: 2,
            phase: 30,
            encode: false,
        });
        let third = capped.scroll_decimation(second.motion_run, second.phase, 60, true, fast, false);
        assert_eq!(third, ScrollDecimation {
            motion_run: 3,
            phase: 0,
            encode: true,
        });

        // An obligated frame ALWAYS passes and resets the accumulator — a rate cap must never
        // swallow a recovery anchor.
        let owed = capped.scroll_decimation(9, 30, 60, true, fast, true);
        assert!(owed.encode);
        assert_eq!(owed.phase, 0);
        assert_eq!(owed.motion_run, 10, "the run still advances");

        // Slow scroll, an unmeasured frame, and a cap that is not below the capture rate: no run.
        assert_eq!(
            capped
                .scroll_decimation(9, 30, 60, true, fast - 1, false)
                .motion_run,
            0
        );
        assert_eq!(
            capped.scroll_decimation(9, 30, 60, false, fast, false).motion_run,
            0
        );
        assert_eq!(
            capped.scroll_decimation(9, 30, 30, true, fast, false).motion_run,
            0
        );
        // …and the cap OFF is the shipped default, which never counts at all.
        assert_eq!(
            gates(&[])
                .scroll_decimation(9, 30, 60, true, fast, false)
                .motion_run,
            0
        );

        // The run saturates at its ceiling rather than walking into an overflow.
        let pinned = capped.scroll_decimation(SCROLL_MOTION_RUN_CEILING, 0, 60, true, fast, false);
        assert_eq!(pinned.motion_run, SCROLL_MOTION_RUN_CEILING);
    }

    /// Every anchor at rest, as a capturer that has never delivered a frame holds them.
    const FRESH: EncodeAnchors = EncodeAnchors {
        last_heartbeat: 0.0,
        last_keyframe_emit: 0.0,
        frames_since_anchor: 0,
        force_compact_counter: 0,
        has_emitted_first_frame: false,
    };

    /// An ordinary below-gate frame: nothing latched, healing armed at the table's own cadence.
    const LIVE: EncodeFrame = EncodeFrame {
        now: 100.0,
        heartbeat_interval: 2.5,
        self_heal_loss_rate: f64::INFINITY,
        heal_every: 30,
        keyframe_latched: false,
        ltr_latched: false,
        self_heal_eligible: true,
    };

    #[test]
    fn the_first_frame_is_a_full_quality_idr_and_only_the_first() {
        let plain = gates(&[]);
        let first = plain.resolve_encode(FRESH, LIVE);
        assert!(first.force_keyframe);
        assert!(
            !first.compact,
            "the FIRST frame stays full quality — one-time, no loop",
        );
        assert!(!first.ltr_refresh);
        assert!(first.anchors.has_emitted_first_frame);
        assert_eq!(
            first.anchors.last_keyframe_emit, LIVE.now,
            "both clocks re-anchor"
        );
        assert_eq!(first.anchors.last_heartbeat, LIVE.now);

        // A LATCHED recovery on a live frame is compact — that is the whole point of the conjunct.
        let latched = plain.resolve_encode(first.anchors, EncodeFrame {
            keyframe_latched: true,
            ..LIVE
        });
        assert!(latched.force_keyframe);
        assert!(latched.compact);
    }

    #[test]
    fn the_recovery_cooldown_collapses_a_latch_and_nothing_else() {
        // v1 spacing: 500 ms between SENT recovery IDRs.
        let cooled = gates(&[("SLOPDESK_RECOVERY_IDR_V2", "0")]);
        let anchored = EncodeAnchors {
            last_keyframe_emit: 99.9, // 100 ms ago — inside the window
            last_heartbeat: 99.9,
            has_emitted_first_frame: true,
            ..FRESH
        };
        let collapsed = cooled.resolve_encode(anchored, EncodeFrame {
            keyframe_latched: true,
            ..LIVE
        });
        assert!(
            !collapsed.force_keyframe,
            "the recent keyframe already re-anchored"
        );
        assert!(!collapsed.compact);
        assert_eq!(
            collapsed.anchors.last_keyframe_emit, 99.9,
            "a keyframe that did not go out does not re-anchor the cooldown",
        );

        // OUTSIDE the window the same latch is honoured.
        let honoured = cooled.resolve_encode(
            EncodeAnchors {
                last_keyframe_emit: 99.0,
                ..anchored
            },
            EncodeFrame {
                keyframe_latched: true,
                ..LIVE
            },
        );
        assert!(honoured.force_keyframe);

        // It NEVER gates the first frame…
        let first = cooled.resolve_encode(
            EncodeAnchors {
                has_emitted_first_frame: false,
                ..anchored
            },
            EncodeFrame {
                keyframe_latched: true,
                ..LIVE
            },
        );
        assert!(first.force_keyframe);
        // …nor a due heartbeat, whose force does not come from the latch.
        let beating = gates(&[
            ("SLOPDESK_RECOVERY_IDR_V2", "0"),
            ("SLOPDESK_MOTION_HEARTBEAT", "1"),
        ]);
        let heartbeat = beating.resolve_encode(
            EncodeAnchors {
                last_heartbeat: 90.0, // 10 s ago — well past the 2.5 s cadence
                ..anchored
            },
            EncodeFrame {
                keyframe_latched: true,
                ..LIVE
            },
        );
        assert!(heartbeat.force_keyframe);
        // The shipped table leaves this gate INERT: v2 owns admission and suppresses before
        // latching.
        let inert = gates(&[]).resolve_encode(anchored, EncodeFrame {
            keyframe_latched: true,
            ..LIVE
        });
        assert!(inert.force_keyframe, "a granted latch is never dropped under v2");
    }

    #[test]
    fn the_heartbeat_is_off_until_its_gate_says_otherwise() {
        let anchored = EncodeAnchors {
            last_heartbeat: 90.0,
            last_keyframe_emit: 90.0,
            has_emitted_first_frame: true,
            ..FRESH
        };
        assert!(!gates(&[]).resolve_encode(anchored, LIVE).force_keyframe);
        let beating = gates(&[("SLOPDESK_MOTION_HEARTBEAT", "1")]);
        assert!(beating.resolve_encode(anchored, LIVE).force_keyframe);
        assert!(beating.heartbeat_due(100.0, 97.5, 2.5), "exactly due counts");
        assert!(!beating.heartbeat_due(100.0, 97.6, 2.5));
        assert!(
            !gates(&[]).heartbeat_due(100.0, 0.0, 2.5),
            "the gate is half the question"
        );
    }

    #[test]
    fn a_keyframe_wins_over_a_latched_refresh_and_both_reset_the_heal_counter() {
        let plain = gates(&[]);
        let anchored = EncodeAnchors {
            last_heartbeat: 100.0,
            last_keyframe_emit: 100.0,
            frames_since_anchor: 12,
            has_emitted_first_frame: true,
            ..FRESH
        };
        // A keyframe is a superset recovery: the refresh latched alongside it is simply consumed.
        let both = plain.resolve_encode(anchored, EncodeFrame {
            keyframe_latched: true,
            ltr_latched: true,
            ..LIVE
        });
        assert!(both.force_keyframe);
        assert!(!both.ltr_refresh);
        assert_eq!(both.anchors.frames_since_anchor, 0);

        // With no keyframe, the latched refresh ships — and does NOT advance the counter first.
        let refreshed = plain.resolve_encode(anchored, EncodeFrame {
            ltr_latched: true,
            ..LIVE
        });
        assert!(!refreshed.force_keyframe);
        assert!(refreshed.ltr_refresh);
        assert_eq!(refreshed.anchors.frames_since_anchor, 0);
    }

    #[test]
    fn the_self_heal_cadence_counts_encoded_frames_at_the_rebased_k() {
        let plain = gates(&[]);
        let anchored = EncodeAnchors {
            last_heartbeat: 100.0,
            last_keyframe_emit: 100.0,
            frames_since_anchor: 29,
            has_emitted_first_frame: true,
            ..FRESH
        };
        let healed = plain.resolve_encode(anchored, LIVE);
        assert!(healed.ltr_refresh, "the 30th delta is the refresh");
        assert_eq!(healed.anchors.frames_since_anchor, 0);
        assert!(
            !plain
                .resolve_encode(
                    EncodeAnchors {
                        frames_since_anchor: 28,
                        ..anchored
                    },
                    LIVE
                )
                .ltr_refresh
        );

        // The GOVERNED K is the one the counter is compared against — 60→15 fps rebases 30 to 7,
        // so the heal fires four times sooner in frames and at the same wall-clock latency.
        let rebased = plain.resolve_encode(
            EncodeAnchors {
                frames_since_anchor: 6,
                ..anchored
            },
            EncodeFrame {
                heal_every: 7,
                ..LIVE
            },
        );
        assert!(rebased.ltr_refresh);

        // Acks not flowing: the counter still climbs, so healing starts at most one frame after
        // eligibility arms.
        let stalled = plain.resolve_encode(anchored, EncodeFrame {
            self_heal_eligible: false,
            ..LIVE
        });
        assert!(!stalled.ltr_refresh);
        assert_eq!(stalled.anchors.frames_since_anchor, 30);

        // K == 0 disables the cadence, and the counter is not even advanced.
        let off = plain.resolve_encode(anchored, EncodeFrame {
            heal_every: 0,
            ..LIVE
        });
        assert!(!off.ltr_refresh);
        assert_eq!(off.anchors.frames_since_anchor, 29);

        // The clean-link gate suppresses the doublet, counter climbing, and re-arms at threshold.
        let gated = gates(&[("SLOPDESK_SELF_HEAL_LOSS_GATE", "1")]);
        assert!(
            !gated
                .resolve_encode(anchored, EncodeFrame {
                    self_heal_loss_rate: 0.0,
                    ..LIVE
                })
                .ltr_refresh
        );
        assert!(
            gated
                .resolve_encode(anchored, EncodeFrame {
                    self_heal_loss_rate: SELF_HEAL_LOSS_GATE_THRESHOLD,
                    ..LIVE
                })
                .ltr_refresh
        );
    }

    #[test]
    fn the_diagnostic_compact_storm_fires_only_on_an_unobliged_frame() {
        let storming = gates(&[("SLOPDESK_FORCE_COMPACT_EVERY", "3")]);
        let anchored = EncodeAnchors {
            last_heartbeat: 100.0,
            last_keyframe_emit: 100.0,
            has_emitted_first_frame: true,
            ..FRESH
        };
        let mut carried = anchored;
        for expected in [false, false, true, false, false, true] {
            let step = storming.resolve_encode(carried, LIVE);
            assert_eq!(
                step.compact, expected,
                "counter {}",
                step.anchors.force_compact_counter
            );
            assert!(!step.force_keyframe, "the diagnostic never forces an IDR");
            carried = step.anchors;
        }
        // A frame that already owes something does not advance the diagnostic counter at all.
        let owed = storming.resolve_encode(carried, EncodeFrame {
            keyframe_latched: true,
            ..LIVE
        });
        assert_eq!(owed.anchors.force_compact_counter, carried.force_compact_counter);
        assert!(owed.compact, "the real obligation is what made it compact");
        // Unset is off: the shipped table never sets it.
        assert!(!gates(&[]).resolve_encode(anchored, LIVE).compact);
    }

    #[test]
    fn the_synthetic_pts_is_a_counter_and_a_real_frame_never_reverses_it() {
        assert_eq!(synthetic_pts(0), 1);
        assert_eq!(synthetic_pts(90_000), 90_001);
        assert_eq!(synthetic_pts(i64::MAX), i64::MAX, "saturating, like CMTimeAdd");
        assert_eq!(monotonic_pts(90_001, 90_000), 90_001, "the synthetic mark holds");
        assert_eq!(monotonic_pts(90_001, 180_000), 180_000, "a newer real frame wins");
        assert_eq!(monotonic_pts(90_001, 90_001), 90_001);
    }

    #[test]
    fn the_first_encode_sample_seeds_the_average_whole() {
        let alpha = CONTEXT.encode_ewma_alpha;
        assert_eq!(fold_encode_ewma(0.0, 8.0, alpha), 8.0, "no zero-drag warm-up");
        let folded = fold_encode_ewma(8.0, 16.0, alpha);
        assert!(folded > 8.0 && folded < 16.0, "a later sample folds: {folded}");
    }
}
