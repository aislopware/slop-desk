//! Every knob the HEVC encoder session is built from, resolved once and checked here.
//!
//! These are the readings that used to sit as `static let`s beside the `VTSessionSetProperty` calls
//! they fed, in a file whose own header conceded it was "COMPILED + code-reviewed but NEVER
//! instantiated in a test" — because `VTCompressionSessionCreate` hangs without a window server.
//! Sitting next to a call that cannot run headless made them unrunnable too, and they are not
//! calls: they are a dozen environment parses, three clamps and a rate-limit calculation, every one
//! of which is a function of a string.
//!
//! ## The clamp discipline, and why it is not a rejection
//! A quantiser knob outside `[1, 51]` is CLAMPED, never rejected to a default. The reading that
//! produces the surprise is the other one: `SLOPDESK_MAX_QP=0` asks for the sharpest ceiling the
//! encoder has, and rejecting it silently yields 51, the COARSEST — the request inverted with
//! nothing said. Clamping answers 1, which is the nearest thing the caller asked for and the only
//! reading they could act on.
//!
//! `None` is reserved for a knob that is ABSENT or whose text is not a number at all, because that
//! is the one answer that cannot have come from a real value — and two knobs
//! ([`Config::const_qp`], and the ceiling adaptation [`Config::qp_ceiling_adaptive`] keys off)
//! decide off PRESENCE rather than value.

use crate::encoder_ceiling::{CeilingBand, qp_ceiling};
use crate::live_bitrate::MINIMUM_BITRATE;
use crate::qp_control::clamped_int_from_env;

/// The spike's 12 Mbps default target. Suits video; sharp TEXT wants more, which is why the host
/// may raise it and why the ceiling is a constructor argument rather than this constant.
pub const DEFAULT_BITRATE: i64 = 12_000_000;

/// The `[1, 51]` HEVC quantiser range every QP knob here is clamped into.
pub const QP_MIN: i32 = 1;
/// The coarsest quantiser HEVC has.
pub const QP_MAX: i32 = 51;

/// Worst-case quantiser ceiling when nothing overrides it.
///
/// 51 is UNCAPPED, and paired with pure VBR that is the point: the encoder must ALWAYS be able to
/// coarsen its way under the budget rather than drop, because a dropped frame IS visible stutter
/// while a coarse one is a frame the crisp static refresh re-sharpens the moment motion stops.
pub const DEFAULT_MAX_QP: i32 = QP_MAX;

/// Quantiser ceiling for the near-lossless crisp static refresh. ~18 is visually transparent for
/// text and far smaller than QP 14.
pub const DEFAULT_CRISP_QP: i32 = 18;

/// Quantiser ceiling for a COMPACT recovery/heartbeat IDR — coarser than live, so the encoder can
/// shrink the forced IDR by coarsening rather than dropping it.
pub const DEFAULT_COMPACT_QP: i32 = 46;

/// Rate-control target applied for exactly the compact IDR, far below the live rate so the
/// controller budgets the forced IDR small.
pub const DEFAULT_COMPACT_BITRATE: i64 = 8_000_000;

/// Widened `DataRateLimits` byte budget around a crisp IDR (64 Mbit) so the hard cap does not DROP
/// the much larger near-lossless intra frame.
pub const CRISP_DATA_RATE_MAX_BYTES: i64 = 8_000_000;

/// The sliding window `DataRateLimits` is expressed over, in seconds, when nothing overrides it.
///
/// A TIGHTER window caps per-frame size spikes while preserving the average rate, but paired with a
/// capped quantiser ceiling it re-introduces the `HiDPI` scroll drops the high [`DEFAULT_MAX_QP`]
/// exists to avoid — hence 1.0.
pub const DEFAULT_VBV_WINDOW: f64 = 1.0;

/// The narrowest window a knob may ask for. Below this the budget rounds toward zero.
pub const VBV_WINDOW_MIN: f64 = 0.01;
/// The widest. Beyond this the cap stops resembling a cap.
pub const VBV_WINDOW_MAX: f64 = 4.0;

/// The byte budget that stands in for "no hard cap" under pure VBR — 1 GB/s, which no encoder
/// approaches.
///
/// Unbinding rather than removing the property is what keeps ONE code path: every set site —
/// create, crisp, compact, the rate actuator, the probe — routes through [`data_rate_limits`], so a
/// half-threaded gate is impossible.
pub const PURE_VBR_UNBOUND_BYTES: i64 = 1_000_000_000;

/// The `MaxFrameDelayCount` probe, smallest-latency FIRST.
///
/// The order is load-bearing: the caller keeps the FIRST value the encoder accepts, so a descending
/// sequence would pin the LARGEST delay the encoder tolerates — the opposite of the intent. The
/// framework's own default is unlimited, which lets the hardware encoder hold frames for
/// rate-control lookahead and adds glass-to-glass latency nobody chose.
pub const FRAME_DELAY_PROBE: [i64; 7] = [0, 1, 2, 3, 4, 5, 6];

/// The largest delay the probe will ask for; a knob pinning one is clamped to this.
pub const FRAME_DELAY_MAX: i64 = 6;

/// Compact-IDR bitrate knob bounds, in kbit/s.
const COMPACT_KBPS_MIN: i64 = 500;
/// As above.
const COMPACT_KBPS_MAX: i64 = 100_000;

/// The `MaxFrameDelayCount` values to probe, resolved from the knob's text.
///
/// * absent, or text that is neither `off`/`-1` nor a number in range ⇒ the full probe
/// * `off` or `-1` ⇒ empty, meaning leave the key unset and take the framework's own default
/// * a number in `[0, 6]` ⇒ exactly that one, pinned
///
/// The unparseable case falls back to the PROBE rather than to "unset", because the probe is the
/// behaviour the default has and a typo should not silently restore the legacy latency.
#[must_use]
pub fn frame_delay_candidates(raw: Option<&str>) -> Vec<i64> {
    let Some(raw) = raw else {
        return FRAME_DELAY_PROBE.to_vec();
    };
    let lowered = raw.to_ascii_lowercase();
    if lowered == "off" || lowered == "-1" {
        return Vec::new();
    }
    match raw.trim().parse::<i64>() {
        Ok(pinned) if (0..=FRAME_DELAY_MAX).contains(&pinned) => vec![pinned],
        _ => FRAME_DELAY_PROBE.to_vec(),
    }
}

/// The `DataRateLimits` window in seconds, clamped so a bad knob can never zero the budget.
#[must_use]
pub fn resolve_vbv_window(raw: Option<&str>) -> f64 {
    raw.and_then(|text| text.trim().parse::<f64>().ok())
        .filter(|seconds| (VBV_WINDOW_MIN..=VBV_WINDOW_MAX).contains(seconds))
        .unwrap_or(DEFAULT_VBV_WINDOW)
}

/// Scales a per-second byte budget over `seconds`, PRESERVING the average rate.
///
/// The budget scales WITH the window: `(budget × T, T)`, never the wrong `(budget, T)` which would
/// slash the average to `budget / T`. At `T == 1.0` this is the identity for any budget an encoder
/// could name, so the default path is byte-identical to not having a window knob at all.
#[must_use]
pub fn vbv_components(bytes_per_second: i64, seconds: f64) -> (i64, f64) {
    // The product is taken in `f64` because the window is one; `as` truncates toward zero, which is
    // the conservative direction for a cap.
    #[expect(clippy::cast_precision_loss, reason = "a byte budget is far below 2^53")]
    #[expect(
        clippy::cast_possible_truncation,
        reason = "truncating a cap downward is the safe direction"
    )]
    let scaled = (bytes_per_second as f64 * seconds) as i64;
    (scaled, seconds)
}

/// The `[maxBytes, seconds]` pair for a per-second byte budget, under the pure-VBR gate.
///
/// Under pure VBR the hard cap is UNBOUND rather than absent, because the framework's cap DROPS a
/// frame that overruns the window budget — silently, with the output handler simply receiving no
/// sample. That was HW-measured as a clean sixty-frame capture with send gaps of 28–400 ms whenever
/// the budget was tight. Unbound, the encoder coarsens through the quantiser instead: a soft frame
/// beats a missing one.
#[must_use]
pub fn data_rate_limits(bytes_per_second: i64, pure_vbr: bool, window_seconds: f64) -> (i64, f64) {
    let effective = if pure_vbr {
        PURE_VBR_UNBOUND_BYTES
    } else {
        bytes_per_second
    };
    vbv_components(effective, window_seconds)
}

/// The compact-IDR rate-control target in bits/sec, from a knob expressed in kbit/s.
#[must_use]
pub fn compact_bitrate(raw: Option<&str>) -> i64 {
    raw.and_then(|text| text.trim().parse::<i64>().ok())
        .filter(|kbps| (COMPACT_KBPS_MIN..=COMPACT_KBPS_MAX).contains(kbps))
        .map_or(DEFAULT_COMPACT_BITRATE, |kbps| kbps * 1_000)
}

/// The single quantiser to pin BOTH `Min` and `Max` to for one live delta frame under const-QP.
///
/// `floor` on a static frame, the content-driven ceiling on motion, and a per-frame ceiling BELOW
/// the floor is clamped UP — the floor is a sharpness guarantee, not a suggestion.
#[must_use]
pub const fn const_qp_for_frame(floor: i32, per_frame_max_qp: Option<i32>) -> i32 {
    match per_frame_max_qp {
        Some(motion) if motion > floor => motion,
        _ => floor,
    }
}

/// One `[1, 51]` quantiser knob, clamped, or `None` when it is absent or is not a number.
///
/// Routed through [`clamped_int_from_env`] so the rule has one home: the same door the link-AIMD's
/// own knobs use. The sentinel is the door's UNCLAMPED default — pass a value outside the range and
/// an absent knob is the only thing that can answer it back.
#[must_use]
pub fn qp_knob(raw: Option<&str>, fallback: i32) -> Option<i32> {
    let answer = clamped_int_from_env(raw, fallback, QP_MIN, QP_MAX);
    (answer >= QP_MIN).then_some(answer)
}

/// What a hardware capability probe concluded about long-term references.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LtrProbeVerdict {
    /// `EnableLTR` took, a forced refresh in the documented form took, and the encoder actually
    /// emitted a frame carrying an acknowledgement token. The full wire/ack path is worth building.
    Supported,
    /// `EnableLTR` or every forced-refresh form was rejected. Keep the compact-IDR fallback.
    Unsupported,
    /// Accepted but unconfirmed: no acknowledgement token was seen, or only the undocumented
    /// `CFNumber` form of the refresh took. Needs manual inspection before anything is built on it.
    Ambiguous,
    /// The probe never reached the question — the session or the pixel buffer failed first. Re-run.
    Unknown,
}

/// What one probe run observed, as values.
///
/// `enable_status` is `None` when `EnableLTR` was never reached at all, which is a different answer
/// from it being rejected. `force_ltr_number_status` is `None` when the `CFNumber` retry was not
/// attempted, because the documented Boolean form already succeeded.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LtrProbe {
    /// The status `EnableLTR` answered, or `None` if the probe never got there.
    pub enable_status: Option<i32>,
    /// The status the seeding keyframe encode answered.
    pub keyframe_encode_status: i32,
    /// The status a forced refresh answered in the documented `kCFBooleanTrue` form.
    pub force_ltr_boolean_status: i32,
    /// The status the `CFNumber` retry answered, when one was attempted.
    pub force_ltr_number_status: Option<i32>,
    /// Whether ANY emitted sample carried the acknowledgement-token attachment.
    pub saw_ack_token: bool,
}

/// Reads a probe's statuses into a single verdict.
///
/// API ACCEPTANCE ALONE IS NOT ENOUGH. A property that returns success may still be a no-op, so
/// [`LtrProbeVerdict::Supported`] requires both the documented form AND an actually-emitted frame
/// carrying the acknowledgement token. Everything accepted-but-unconfirmed is
/// [`LtrProbeVerdict::Ambiguous`], which is a verdict a person acts on rather than a build does.
#[must_use]
pub fn interpret_ltr_probe(probe: LtrProbe) -> LtrProbeVerdict {
    const NO_ERR: i32 = 0;
    let Some(enable_status) = probe.enable_status else {
        return LtrProbeVerdict::Unknown;
    };
    if enable_status != NO_ERR || probe.keyframe_encode_status != NO_ERR {
        return LtrProbeVerdict::Unsupported;
    }
    let boolean_took = probe.force_ltr_boolean_status == NO_ERR;
    let number_took = probe.force_ltr_number_status == Some(NO_ERR);
    if !boolean_took && !number_took {
        return LtrProbeVerdict::Unsupported;
    }
    if boolean_took && probe.saw_ack_token {
        LtrProbeVerdict::Supported
    } else {
        LtrProbeVerdict::Ambiguous
    }
}

impl LtrProbeVerdict {
    /// The single word a log line carries.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Unsupported => "unsupported",
            Self::Ambiguous => "ambiguous",
            Self::Unknown => "unknown",
        }
    }
}

/// Every resolved knob the encoder session is built and driven from.
#[derive(Clone, Copy, Debug, PartialEq)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each is one independent operator gate, not a state enum"
)]
pub struct Config {
    /// The worst-case quantiser ceiling; the bound everything else composes up to.
    pub max_allowed_frame_qp: i32,
    /// Quantiser ceiling for the crisp static refresh.
    pub crisp_qp: i32,
    /// Quantiser ceiling for a compact recovery IDR.
    pub compact_qp: i32,
    /// Rate-control target for exactly the compact IDR.
    pub compact_bitrate: i64,
    /// Const-QP mode's seed, and its PRESENCE is what engages the mode at all.
    pub const_qp: Option<i32>,
    /// Whether the budget-adaptive ceiling drives `MaxAllowedFrameQP`.
    pub qp_ceiling_adaptive: bool,
    /// Whether a motion frame keeps `Min` at the sharp floor while only `Max` rises.
    pub qp_decouple: bool,
    /// Whether the hard rate cap is unbound.
    pub pure_vbr: bool,
    /// The window `DataRateLimits` is expressed over.
    pub vbv_window_seconds: f64,
    /// Whether to hint the encoder to prefer speed over quality.
    pub speed_over_quality: bool,
    /// Whether a compact IDR defers its restore to the next live encode rather than draining twice.
    pub compact_lazy_restore: bool,
    /// The budget-derived ceiling's sharp/coarse band.
    pub band: CeilingBand,
}

impl Config {
    /// Resolves every knob through `read`, which answers an environment variable's text.
    ///
    /// A reader rather than a direct environment read so the whole resolution is a function of a
    /// lookup table, and so a test can drive the combinations the host actually ships — which is
    /// what the Swift `static let`s made impossible: each was resolved once per process, at first
    /// touch, from the real environment.
    ///
    /// `qp_decouple_override` exists for the ONE knob whose value a graphical setting may supply
    /// rather than the environment. The overlay lives on the far side of the boundary, so the
    /// already-resolved bool crosses; every other knob resolves here.
    #[must_use]
    pub fn resolve(read: &dyn Fn(&str) -> Option<String>, qp_decouple_override: Option<bool>) -> Self {
        let text = |key: &str| read(key);
        let max_qp_raw = text("SLOPDESK_MAX_QP");
        let const_qp = qp_knob(text("SLOPDESK_CONST_QP").as_deref(), 0);
        // Adaptation is off when a static ceiling is PINNED, when it is explicitly disabled, or
        // when const-QP owns the quantiser dials outright. Presence, not value, decides the first.
        let qp_ceiling_adaptive = max_qp_raw.is_none()
            && text("SLOPDESK_QP_CEILING_ADAPT").as_deref() != Some("0")
            && const_qp.is_none();
        Self {
            max_allowed_frame_qp: qp_knob(max_qp_raw.as_deref(), DEFAULT_MAX_QP).unwrap_or(DEFAULT_MAX_QP),
            crisp_qp: qp_knob(text("SLOPDESK_CRISP_QP").as_deref(), DEFAULT_CRISP_QP)
                .unwrap_or(DEFAULT_CRISP_QP),
            compact_qp: qp_knob(text("SLOPDESK_COMPACT_QP").as_deref(), DEFAULT_COMPACT_QP)
                .unwrap_or(DEFAULT_COMPACT_QP),
            compact_bitrate: compact_bitrate(text("SLOPDESK_COMPACT_KBPS").as_deref()),
            const_qp,
            qp_ceiling_adaptive,
            // Default ON; only an explicit `0` disables. The override wins when supplied.
            qp_decouple: qp_decouple_override
                .unwrap_or_else(|| text("SLOPDESK_QP_DECOUPLE").as_deref() != Some("0")),
            pure_vbr: text("SLOPDESK_PURE_VBR").as_deref() != Some("0"),
            vbv_window_seconds: resolve_vbv_window(text("SLOPDESK_VBV_WINDOW").as_deref()),
            speed_over_quality: text("SLOPDESK_SPEED_OVER_QUALITY").as_deref() == Some("1"),
            compact_lazy_restore: text("SLOPDESK_COMPACT_LAZY_RESTORE").as_deref() != Some("0"),
            band: CeilingBand::default(),
        }
    }

    /// The `[maxBytes, seconds]` pair for a per-second byte budget under this configuration.
    #[must_use]
    pub fn data_rate_limits(&self, bytes_per_second: i64) -> (i64, f64) {
        data_rate_limits(bytes_per_second, self.pure_vbr, self.vbv_window_seconds)
    }

    /// The same pair for a budget expressed in BITS, which is how every rate the controller names
    /// arrives.
    ///
    /// The conversion has one home because it is the sort of thing that gets written `/ 4` at one
    /// site and `/ 8` at the next and produces a hard cap at twice the average rate, which looks
    /// like a generous encoder rather than like a bug.
    #[must_use]
    #[expect(
        clippy::integer_division,
        reason = "bits to bytes; the remainder is under one byte a second"
    )]
    pub fn hard_cap(&self, bits_per_second: i64) -> (i64, f64) {
        self.data_rate_limits(bits_per_second / 8)
    }

    /// The budget-derived quantiser ceiling for a target on a given session geometry.
    ///
    /// Pinned to the worst case when adaptation is off, so every caller can compose the same way
    /// whether or not a static ceiling was asked for.
    #[must_use]
    pub fn budget_ceiling(&self, target_bps: i64, width: i64, height: i64, fps: i64) -> i32 {
        if self.qp_ceiling_adaptive {
            qp_ceiling(target_bps, width, height, fps, self.band)
        } else {
            self.max_allowed_frame_qp
        }
    }

    /// The floor a live target is clamped to, which is the stream's own minimum rather than this
    /// module's: an encoder asked for less than [`MINIMUM_BITRATE`] is one nothing can watch.
    #[must_use]
    pub const fn clamp_target(&self, target: i64, ceiling: i64) -> i64 {
        let bounded = if target > ceiling { ceiling } else { target };
        if bounded < MINIMUM_BITRATE {
            MINIMUM_BITRATE
        } else {
            bounded
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{
        CRISP_DATA_RATE_MAX_BYTES, Config, DEFAULT_COMPACT_BITRATE, DEFAULT_COMPACT_QP, DEFAULT_CRISP_QP,
        DEFAULT_MAX_QP, DEFAULT_VBV_WINDOW, FRAME_DELAY_PROBE, LtrProbe, LtrProbeVerdict,
        PURE_VBR_UNBOUND_BYTES, QP_MAX, QP_MIN, compact_bitrate, const_qp_for_frame, data_rate_limits,
        frame_delay_candidates, interpret_ltr_probe, qp_knob, resolve_vbv_window, vbv_components,
    };

    /// Builds a reader over a fixed table, which is what makes the whole resolution testable —
    /// the Swift this replaces read `ProcessInfo` at first touch of a `static let`, so a process
    /// could observe exactly one combination and a test could observe none.
    fn reader(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
        let table: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        move |key: &str| table.get(key).cloned()
    }

    /// An absent knob is the full probe, smallest delay first. The ORDER is the property: the
    /// caller keeps the first accepted value, so a reversed sequence would pin the largest delay
    /// the encoder tolerates and add exactly the pipeline latency the probe exists to remove.
    #[test]
    fn an_absent_frame_delay_knob_probes_smallest_first() {
        assert_eq!(frame_delay_candidates(None), FRAME_DELAY_PROBE.to_vec());
        let mut sorted = FRAME_DELAY_PROBE.to_vec();
        sorted.sort_unstable();
        assert_eq!(FRAME_DELAY_PROBE.to_vec(), sorted);
    }

    /// `off` and `-1` both leave the key unset, which is the framework's own behaviour and the
    /// legacy one. Case does not matter, because a knob is typed by a person.
    #[test]
    fn the_frame_delay_knob_can_ask_for_the_frameworks_own_default() {
        for raw in ["off", "OFF", "Off", "-1"] {
            assert!(frame_delay_candidates(Some(raw)).is_empty(), "{raw}");
        }
    }

    /// A number in range pins exactly it; anything else falls back to the PROBE rather than to
    /// unset, because a typo must not silently restore the latency the default removes.
    #[test]
    fn an_unparseable_frame_delay_knob_falls_back_to_the_probe_not_to_unset() {
        for pinned in 0..=6_i64 {
            assert_eq!(frame_delay_candidates(Some(&pinned.to_string())), vec![pinned]);
        }
        for raw in ["", "seven", "7", "-2", "3.5", "0x2"] {
            assert_eq!(
                frame_delay_candidates(Some(raw)),
                FRAME_DELAY_PROBE.to_vec(),
                "{raw}"
            );
        }
    }

    /// The window clamps rather than rejects into a budget of zero, and every out-of-range or
    /// unparseable knob lands on the default.
    #[test]
    fn a_bad_window_knob_can_never_zero_the_budget() {
        assert!((resolve_vbv_window(None) - DEFAULT_VBV_WINDOW).abs() < f64::EPSILON);
        for raw in ["0", "0.001", "5", "-1", "nan", "", "wide"] {
            let seconds = resolve_vbv_window(Some(raw));
            assert!(
                (seconds - DEFAULT_VBV_WINDOW).abs() < f64::EPSILON,
                "{raw} -> {seconds}"
            );
        }
        for raw in ["0.01", "0.5", "1", "2.5", "4"] {
            let seconds = resolve_vbv_window(Some(raw));
            assert!((0.01..=4.0).contains(&seconds), "{raw} -> {seconds}");
        }
    }

    /// At a one-second window the components are the identity, so the default path is byte-for-byte
    /// what not having the knob would produce. This is the arm every shipped host takes.
    #[test]
    fn a_one_second_window_is_the_identity_on_the_budget() {
        for budget in [1_i64, 1_500_000, 8_000_000, 1_000_000_000] {
            assert_eq!(vbv_components(budget, 1.0), (budget, 1.0));
        }
    }

    /// The budget scales WITH the window, which is what preserves the average rate. Halving the
    /// window and keeping the budget would slash the average to a third — the bug this shape
    /// avoids.
    #[test]
    fn the_budget_scales_with_the_window_so_the_average_rate_holds() {
        let (bytes, seconds) = vbv_components(1_500_000, 0.5);
        assert_eq!((bytes, seconds), (750_000, 0.5));
        let (bytes, seconds) = vbv_components(1_500_000, 2.0);
        assert_eq!((bytes, seconds), (3_000_000, 2.0));
    }

    /// Pure VBR unbinds the cap rather than removing the property, and it does so at EVERY budget —
    /// which is the property that makes a half-threaded gate impossible.
    #[test]
    fn pure_vbr_unbinds_every_budget_it_is_given() {
        for budget in [
            1_i64,
            1_500_000,
            CRISP_DATA_RATE_MAX_BYTES,
            PURE_VBR_UNBOUND_BYTES,
        ] {
            assert_eq!(data_rate_limits(budget, true, 1.0), (PURE_VBR_UNBOUND_BYTES, 1.0));
            assert_eq!(data_rate_limits(budget, false, 1.0), (budget, 1.0));
        }
    }

    /// The compact knob is kbit/s and is bounded; anything outside is the default rather than an
    /// invented operating point.
    #[test]
    fn the_compact_bitrate_knob_is_bounded_in_kilobits() {
        assert_eq!(compact_bitrate(None), DEFAULT_COMPACT_BITRATE);
        assert_eq!(compact_bitrate(Some("500")), 500_000);
        assert_eq!(compact_bitrate(Some("100000")), 100_000_000);
        for raw in ["499", "100001", "0", "-1", "", "eight"] {
            assert_eq!(compact_bitrate(Some(raw)), DEFAULT_COMPACT_BITRATE, "{raw}");
        }
    }

    /// A per-frame ceiling below the const-QP floor is clamped UP: the floor is a sharpness
    /// guarantee. A static frame pins the floor, motion pins the coarser value.
    #[test]
    fn a_motion_ceiling_below_the_floor_is_clamped_up_to_it() {
        assert_eq!(const_qp_for_frame(30, None), 30);
        assert_eq!(const_qp_for_frame(30, Some(20)), 30);
        assert_eq!(const_qp_for_frame(30, Some(30)), 30);
        assert_eq!(const_qp_for_frame(30, Some(44)), 44);
    }

    /// A quantiser knob CLAMPS. `0` asks for the sharpest ceiling and must not silently invert into
    /// the coarsest — the exact surprise the old reject-to-default reading produced.
    #[test]
    fn a_quantiser_knob_clamps_rather_than_inverting_the_request() {
        assert_eq!(qp_knob(Some("0"), DEFAULT_MAX_QP), Some(QP_MIN));
        assert_eq!(qp_knob(Some("-5"), DEFAULT_MAX_QP), Some(QP_MIN));
        assert_eq!(qp_knob(Some("99"), DEFAULT_MAX_QP), Some(QP_MAX));
        assert_eq!(qp_knob(Some("18"), DEFAULT_MAX_QP), Some(18));
    }

    /// Absent, or text that is not a number, is the ONE answer that cannot have come from a real
    /// value — which is what lets const-QP decide off presence.
    #[test]
    fn only_an_absent_or_unparseable_knob_answers_nothing() {
        assert_eq!(qp_knob(None, 0), None);
        for raw in ["", "sharp", "1.5", "  "] {
            assert_eq!(qp_knob(Some(raw), 0), None, "{raw}");
        }
    }

    /// A probe that never reached the question is `Unknown`, which is a re-run rather than a
    /// verdict — distinct from the rejection that means "keep the fallback forever".
    #[test]
    fn a_probe_that_never_asked_reports_unknown_not_unsupported() {
        let probe = LtrProbe {
            enable_status: None,
            keyframe_encode_status: 0,
            force_ltr_boolean_status: 0,
            force_ltr_number_status: None,
            saw_ack_token: true,
        };
        assert_eq!(interpret_ltr_probe(probe), LtrProbeVerdict::Unknown);
    }

    /// Acceptance alone is NOT support. A property that returns success may be a no-op, so a run
    /// with no emitted acknowledgement token is `Ambiguous` — a verdict a person acts on.
    #[test]
    fn acceptance_without_an_emitted_token_is_ambiguous_not_supported() {
        let accepted = LtrProbe {
            enable_status: Some(0),
            keyframe_encode_status: 0,
            force_ltr_boolean_status: 0,
            force_ltr_number_status: None,
            saw_ack_token: false,
        };
        assert_eq!(interpret_ltr_probe(accepted), LtrProbeVerdict::Ambiguous);
        assert_eq!(
            interpret_ltr_probe(LtrProbe {
                saw_ack_token: true,
                ..accepted
            }),
            LtrProbeVerdict::Supported
        );
    }

    /// The undocumented `CFNumber` form taking where the documented Boolean form did not is
    /// `Ambiguous` however convincing the rest looks — the header contradicts itself there, and a
    /// build must not resolve that on its own.
    #[test]
    fn only_the_documented_refresh_form_can_reach_supported() {
        let number_only = LtrProbe {
            enable_status: Some(0),
            keyframe_encode_status: 0,
            force_ltr_boolean_status: -12_900,
            force_ltr_number_status: Some(0),
            saw_ack_token: true,
        };
        assert_eq!(interpret_ltr_probe(number_only), LtrProbeVerdict::Ambiguous);
        assert_eq!(
            interpret_ltr_probe(LtrProbe {
                force_ltr_number_status: Some(-12_900),
                ..number_only
            }),
            LtrProbeVerdict::Unsupported
        );
    }

    /// A rejected `EnableLTR`, or a seeding keyframe that never encoded, is `Unsupported` whatever
    /// followed — there was no long-term reference for a refresh to have referenced.
    #[test]
    fn a_rejected_enable_or_a_failed_seed_is_unsupported() {
        let base = LtrProbe {
            enable_status: Some(-12_900),
            keyframe_encode_status: 0,
            force_ltr_boolean_status: 0,
            force_ltr_number_status: None,
            saw_ack_token: true,
        };
        assert_eq!(interpret_ltr_probe(base), LtrProbeVerdict::Unsupported);
        assert_eq!(
            interpret_ltr_probe(LtrProbe {
                enable_status: Some(0),
                keyframe_encode_status: -1,
                ..base
            }),
            LtrProbeVerdict::Unsupported
        );
    }

    /// An empty environment is the shipped default: adaptive ceiling on, decouple on, pure VBR on,
    /// lazy restore on, quality-first, const-QP off. This is the configuration every host runs
    /// unless somebody typed something, and until now no test could name it.
    #[test]
    fn an_empty_environment_resolves_the_shipped_default() {
        let config = Config::resolve(&reader(&[]), None);
        assert_eq!(config.max_allowed_frame_qp, DEFAULT_MAX_QP);
        assert_eq!(config.crisp_qp, DEFAULT_CRISP_QP);
        assert_eq!(config.compact_qp, DEFAULT_COMPACT_QP);
        assert_eq!(config.compact_bitrate, DEFAULT_COMPACT_BITRATE);
        assert_eq!(config.const_qp, None);
        assert!(config.qp_ceiling_adaptive);
        assert!(config.qp_decouple);
        assert!(config.pure_vbr);
        assert!(config.compact_lazy_restore);
        assert!(!config.speed_over_quality);
        assert!((config.vbv_window_seconds - DEFAULT_VBV_WINDOW).abs() < f64::EPSILON);
    }

    /// PINNING a static ceiling disables adaptation, and it does so by PRESENCE — the value is
    /// irrelevant, which is why the knob's text is read twice for two different questions.
    #[test]
    fn pinning_a_static_ceiling_disables_adaptation_by_presence() {
        for raw in ["38", "51", "0", "not-a-number"] {
            let config = Config::resolve(&reader(&[("SLOPDESK_MAX_QP", raw)]), None);
            assert!(!config.qp_ceiling_adaptive, "{raw}");
        }
        // And an unparseable pin still lands on the default VALUE while disabling adaptation —
        // the two readings genuinely differ.
        let config = Config::resolve(&reader(&[("SLOPDESK_MAX_QP", "not-a-number")]), None);
        assert_eq!(config.max_allowed_frame_qp, DEFAULT_MAX_QP);
    }

    /// Const-QP also disables the budget-adaptive ceiling, because it owns the quantiser dials
    /// outright. Two independent routes to the same off, and both are load-bearing.
    #[test]
    fn const_qp_disables_the_adaptive_ceiling_too() {
        let config = Config::resolve(&reader(&[("SLOPDESK_CONST_QP", "28")]), None);
        assert_eq!(config.const_qp, Some(28));
        assert!(!config.qp_ceiling_adaptive);
        // A const-QP knob that is not a number leaves the mode OFF rather than inventing an
        // operating point, so adaptation stays ON.
        let off = Config::resolve(&reader(&[("SLOPDESK_CONST_QP", "sharp")]), None);
        assert_eq!(off.const_qp, None);
        assert!(off.qp_ceiling_adaptive);
    }

    /// The default-ON knobs take only an explicit `0`. Anything else — including the empty string
    /// and `false` — leaves them on, which is the idiom the whole tree uses.
    #[test]
    fn the_default_on_knobs_take_only_an_explicit_zero() {
        for (key, off) in [
            ("SLOPDESK_QP_DECOUPLE", "0"),
            ("SLOPDESK_PURE_VBR", "0"),
            ("SLOPDESK_COMPACT_LAZY_RESTORE", "0"),
        ] {
            let disabled = Config::resolve(&reader(&[(key, off)]), None);
            let still_on = Config::resolve(&reader(&[(key, "false")]), None);
            match key {
                "SLOPDESK_QP_DECOUPLE" => {
                    assert!(!disabled.qp_decouple);
                    assert!(still_on.qp_decouple);
                },
                "SLOPDESK_PURE_VBR" => {
                    assert!(!disabled.pure_vbr);
                    assert!(still_on.pure_vbr);
                },
                _ => {
                    assert!(!disabled.compact_lazy_restore);
                    assert!(still_on.compact_lazy_restore);
                },
            }
        }
    }

    /// The decouple override WINS over the environment, because the setting it carries lives on the
    /// far side of the boundary and a graphical toggle that lost to an unset variable would be a
    /// toggle that does nothing.
    #[test]
    fn the_decouple_override_wins_over_the_environment() {
        let env_off = reader(&[("SLOPDESK_QP_DECOUPLE", "0")]);
        assert!(Config::resolve(&env_off, Some(true)).qp_decouple);
        assert!(!Config::resolve(&reader(&[]), Some(false)).qp_decouple);
    }

    /// A target is clamped into `[minimum, ceiling]` and never past either end, whatever the
    /// controller asks for — including a negative one, which an arithmetic slip upstream produces.
    #[test]
    fn a_live_target_is_clamped_into_the_band_on_both_sides() {
        let config = Config::resolve(&reader(&[]), None);
        let ceiling = 40_000_000;
        assert_eq!(config.clamp_target(60_000_000, ceiling), ceiling);
        assert_eq!(
            config.clamp_target(-1, ceiling),
            crate::live_bitrate::MINIMUM_BITRATE
        );
        assert_eq!(
            config.clamp_target(0, ceiling),
            crate::live_bitrate::MINIMUM_BITRATE
        );
        assert_eq!(config.clamp_target(20_000_000, ceiling), 20_000_000);
    }

    /// With adaptation off the budget ceiling is the pinned worst case at EVERY target, which is
    /// what lets every caller compose the same expression regardless of the mode.
    #[test]
    fn an_unadaptive_ceiling_is_the_pinned_worst_case_at_every_target() {
        let config = Config::resolve(&reader(&[("SLOPDESK_MAX_QP", "38")]), None);
        for target in [1_000_000_i64, 12_000_000, 60_000_000] {
            assert_eq!(config.budget_ceiling(target, 1920, 1080, 60), 38);
        }
    }
}
