//! The input injector's operating point: every `SLOPDESK_*` gate it reads, resolved ONCE.
//!
//! ## Why they are one table
//!
//! These were seven `private static let`s in `InputInjector.swift`, each hand-writing its own
//! lookup, parse and default beside the measurement that chose it. The prose stays with the
//! injector; the DECISIONS move here, for the reason [`crate::host_gates`] and
//! [`crate::capture_gates`] give at length — a default is a rule, a clamp is a rule, and a rule
//! that reads identically in two languages can only be TESTED in one of them.
//!
//! ## The lookup stays with the caller
//!
//! [`KEYS`] is the list of names, in the order [`InjectorGates::from_env`] expects their values.
//! The caller resolves each through the environment and then the settings overlay (`docs/58`) and
//! hands the texts back positionally. Deliberately not `std::env::var` here: the overlay is a table
//! the host folds `video-prefs.json` into at launch, and a gate that read past it would quietly
//! stop honouring a setting the moment its key became user-facing.
//!
//! ## Faithfulness, and the four idioms in seven keys
//!
//! Carried verbatim rather than tidied, which means this small family spans four different parse
//! rules and each is marked at its field:
//!
//! * PRESENCE — `SLOPDESK_VIDEO_INJECT_TO_PID`, so `=0` ENABLES it.
//! * DEFAULT-ON — `SLOPDESK_TABLET_MOUSE`, off on exactly `0`; and `SLOPDESK_SCROLL_PHASE`, which
//!   also accepts a case-insensitive `false` and is the only key in the repo that does.
//! * REJECT-TO-DEFAULT — `SLOPDESK_SCROLL_GAIN`, the bitrate controller's rule.
//! * NEITHER — `SLOPDESK_SCROLL_SPREAD` takes any parseable float with NO bound at all, and
//!   `SLOPDESK_SCROLL_RESAMPLE_HZ` is three-way: unset is not the same answer as unparseable.

use crate::congestion::validated_double_from_env;

/// The one input this table needs that is not its own environment key.
///
/// `SLOPDESK_INPUT_TRACE` belongs to [`crate::host_gates`] — it gates the session's tracing too,
/// and resolving it twice is the drift this whole module exists to delete. It arrives already
/// resolved so the swipe-nav trace can be OR-ed against it without a second lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InjectorGateContext {
    /// Whether the session-wide input trace is on: the swipe-nav trace inherits it.
    pub input_trace: bool,
}

/// The environment keys, in the order [`InjectorGates::from_env`] reads their values.
pub const KEYS: [&str; 6] = [
    "SLOPDESK_SCROLL_SPREAD",
    "SLOPDESK_VIDEO_INJECT_TO_PID",
    "SLOPDESK_TABLET_MOUSE",
    "SLOPDESK_SCROLL_GAIN",
    "SLOPDESK_SCROLL_PHASE",
    "SLOPDESK_SCROLL_RESAMPLE_HZ",
];

/// The swipe-nav trace key — a name that belongs to no table's `KEYS`, and is read by two.
///
/// Not in [`KEYS`], because [`InjectorGates::from_env`] does not read its value ALONE: the field is
/// this key's presence OR the session-wide trace from [`InjectorGateContext`]. Not in
/// [`crate::swipe_nav_config::KEYS`] either, because that table's operating point does not read it
/// at all — a trace switch changes nothing about which app is navigable. So it is spelled once,
/// here, and the caller resolves it alongside both families rather than inventing the string.
pub const SWIPE_NAV_TRACE_KEY: &str = "SLOPDESK_SWIPE_NAV_TRACE";

/// The resolved injector operating point.
// The same opt-out the other gate tables take, for the same reason: a gate family is mostly
// switches, that is its shape in the docs and in the operator's head, and folding pairs into
// two-variant enums would name types nobody would mention twice.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a table of switches IS mostly switches"
)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InjectorGates {
    /// How many resampler sub-events one forwarded scroll is spread across.
    ///
    /// NO BOUND, carried verbatim: any parseable float wins, including a non-finite one. Default 3,
    /// which is NOT [`crate::scroll_resample::ScrollResampler::DEFAULT_SPREAD`] — the resampler's
    /// own constant serves the restore path, this one serves a live injector, and the two were
    /// tuned apart.
    pub scroll_spread: f64,
    /// Address events at a pid rather than at the session. PRESENCE, not value: `=0` enables it.
    pub inject_to_pid: bool,
    /// Parsec-style pointer motion. Default ON; `0` restores the warp path and its three
    /// synchronous window-server round trips per hover move.
    pub tablet_mouse: bool,
    /// The scroll distance multiplier. Default 1.0 — byte-identical pass-through — and REJECTS
    /// anything outside 0.1…10 back to it rather than clamping, because a scroll gain outside the
    /// A/B band is a typo and the nearest legal value would invent a feel nobody chose.
    pub scroll_gain: f64,
    /// Replay the forwarded gesture phase and inertia on the injected event. Default ON, off on
    /// `0` or on a case-insensitive `false`.
    pub scroll_phase: bool,
    /// The resampler's output rate in hertz, or ZERO for the direct-post path.
    ///
    /// Three-way, and the third way is the load-bearing one: UNSET is 250, an explicit value that
    /// does not parse to a positive integer is OFF, and anything else is clamped into 60…1000. So
    /// `SLOPDESK_SCROLL_RESAMPLE_HZ=0` is a request to disable resampling, not a request for the
    /// default — which is why this key cannot use either of the project's usual two idioms.
    pub scroll_resample_hz: i64,
    /// Trace swipe-nav decisions. PRESENCE, OR the session-wide input trace.
    pub swipe_nav_trace: bool,
}

impl InjectorGates {
    /// The rate the resampler runs at when nobody said otherwise.
    pub const DEFAULT_RESAMPLE_HZ: i64 = 250;
    /// The resampler's legal output band, once an explicit positive rate has parsed.
    const RESAMPLE_HZ_FLOOR: i64 = 60;
    /// The ceiling of that band.
    const RESAMPLE_HZ_CEIL: i64 = 1000;

    /// The operating point resolved from the texts of [`KEYS`], in that order, plus the one
    /// resolved value from [`InjectorGateContext`].
    ///
    /// `swipe_nav_trace` is not in [`KEYS`] because it is not this table's only input: it is
    /// [`SWIPE_NAV_TRACE_KEY`]'s presence OR the context's trace, which is why that name stands on
    /// its own rather than in either family's list.
    #[must_use]
    pub fn from_env(
        values: &[Option<&str>; KEYS.len()],
        swipe_nav_trace: Option<&str>,
        context: InjectorGateContext,
    ) -> Self {
        // BY NAME, not by position — the shape `crate::host_gates` settled: a positional read
        // agrees with a table that has drifted, and four of these six switches are one character
        // apart in meaning.
        let at = |key: &str| -> Option<&str> {
            KEYS.iter()
                .position(|name| *name == key)
                .and_then(|index| values.get(index).copied().flatten())
        };
        Self {
            scroll_spread: at("SLOPDESK_SCROLL_SPREAD")
                .and_then(|text| text.parse::<f64>().ok())
                .unwrap_or(3.0),
            inject_to_pid: at("SLOPDESK_VIDEO_INJECT_TO_PID").is_some(),
            tablet_mouse: at("SLOPDESK_TABLET_MOUSE") != Some("0"),
            scroll_gain: validated_double_from_env(at("SLOPDESK_SCROLL_GAIN"), 1.0, 0.1, 10.0),
            scroll_phase: scroll_phase_from_env(at("SLOPDESK_SCROLL_PHASE")),
            scroll_resample_hz: resample_hz_from_env(at("SLOPDESK_SCROLL_RESAMPLE_HZ")),
            swipe_nav_trace: swipe_nav_trace.is_some() || context.input_trace,
        }
    }
}

/// The gesture-phase switch: ON unless the value is `0` or spells `false` in any case.
///
/// The `false` spelling is this key's alone in the whole `SLOPDESK_*` surface. It is kept because
/// it SHIPPED — an operator with `SLOPDESK_SCROLL_PHASE=False` in a launch record is relying on it,
/// and narrowing the rule would silently turn phase replay back on for them.
fn scroll_phase_from_env(raw: Option<&str>) -> bool {
    !matches!(raw, Some("0")) && !raw.is_some_and(|text| text.eq_ignore_ascii_case("false"))
}

/// The resampler rate: unset is the default, an explicit non-positive or unparseable value is OFF,
/// and a positive one is clamped into the legal band.
///
/// The middle case is why this cannot be [`crate::congestion::validated_int_from_env`]. That helper
/// answers the DEFAULT for anything it rejects, and here an unparseable explicit value must answer
/// ZERO: the operator asked for something, and the honest reading of a request the parser cannot
/// serve is "not the default" — falling back to 250 Hz would resume resampling under a knob that
/// was set to turn it off.
fn resample_hz_from_env(raw: Option<&str>) -> i64 {
    let Some(text) = raw else {
        return InjectorGates::DEFAULT_RESAMPLE_HZ;
    };
    match text.parse::<i64>() {
        Ok(rate) if rate > 0 => rate.clamp(InjectorGates::RESAMPLE_HZ_FLOOR, InjectorGates::RESAMPLE_HZ_CEIL),
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::{InjectorGateContext, InjectorGates, KEYS};

    /// The values array, keyed by NAME rather than by index — a positional fixture would agree with
    /// a table that had drifted, which is the exact failure [`KEYS`] exists to prevent.
    fn env(pairs: &[(&str, &'static str)]) -> [Option<&'static str>; KEYS.len()] {
        for (key, _) in pairs {
            assert!(KEYS.contains(key), "{key} is not an injector gate");
        }
        KEYS.map(|name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| *value)
        })
    }

    /// The context with tracing off, which is what every test but the trace pair wants.
    const QUIET: InjectorGateContext = InjectorGateContext { input_trace: false };

    #[test]
    fn the_unset_operating_point_is_the_tuned_one() {
        let gates = InjectorGates::from_env(&env(&[]), None, QUIET);
        assert!((gates.scroll_spread - 3.0).abs() < f64::EPSILON);
        assert!(!gates.inject_to_pid);
        assert!(gates.tablet_mouse);
        assert!((gates.scroll_gain - 1.0).abs() < f64::EPSILON);
        assert!(gates.scroll_phase);
        assert_eq!(gates.scroll_resample_hz, InjectorGates::DEFAULT_RESAMPLE_HZ);
        assert!(!gates.swipe_nav_trace);
    }

    #[test]
    fn an_explicit_zero_disables_the_resampler_rather_than_restoring_the_default() {
        let off = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "0")]), None, QUIET);
        assert_eq!(off.scroll_resample_hz, 0);
        let garbage = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "fast")]), None, QUIET);
        assert_eq!(garbage.scroll_resample_hz, 0, "unparseable is OFF, not 250");
        let negative = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "-1")]), None, QUIET);
        assert_eq!(negative.scroll_resample_hz, 0);
    }

    #[test]
    fn a_positive_resample_rate_is_clamped_into_the_legal_band() {
        let low = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "1")]), None, QUIET);
        assert_eq!(low.scroll_resample_hz, 60);
        let high = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "9000")]), None, QUIET);
        assert_eq!(high.scroll_resample_hz, 1000);
        let inside = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_RESAMPLE_HZ", "120")]), None, QUIET);
        assert_eq!(inside.scroll_resample_hz, 120);
    }

    #[test]
    fn the_phase_switch_accepts_the_word_false_in_any_case() {
        for spelling in ["false", "False", "FALSE"] {
            let gates = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_PHASE", spelling)]), None, QUIET);
            assert!(!gates.scroll_phase, "{spelling} should disable phase replay");
        }
        let zero = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_PHASE", "0")]), None, QUIET);
        assert!(!zero.scroll_phase);
        let noise = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_PHASE", "no")]), None, QUIET);
        assert!(noise.scroll_phase, "only `0` and `false` turn it off");
    }

    #[test]
    fn the_pid_gate_reads_presence_so_a_zero_still_enables_it() {
        let gates = InjectorGates::from_env(&env(&[("SLOPDESK_VIDEO_INJECT_TO_PID", "0")]), None, QUIET);
        assert!(gates.inject_to_pid, "PRESENCE, not value");
    }

    #[test]
    fn the_scroll_gain_rejects_out_of_band_rather_than_clamping() {
        let high = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_GAIN", "50")]), None, QUIET);
        assert!(
            (high.scroll_gain - 1.0).abs() < f64::EPSILON,
            "out of band falls to the default, it does not clamp to 10"
        );
        let inside = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_GAIN", "2.5")]), None, QUIET);
        assert!((inside.scroll_gain - 2.5).abs() < f64::EPSILON);
    }

    #[test]
    fn the_scroll_spread_takes_any_parseable_float_unbounded() {
        let huge = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_SPREAD", "400")]), None, QUIET);
        assert!(
            (huge.scroll_spread - 400.0).abs() < f64::EPSILON,
            "carried verbatim: this key never had a bound"
        );
        let noise = InjectorGates::from_env(&env(&[("SLOPDESK_SCROLL_SPREAD", "wide")]), None, QUIET);
        assert!((noise.scroll_spread - 3.0).abs() < f64::EPSILON);
    }

    #[test]
    fn the_tablet_mouse_is_on_unless_it_is_exactly_zero() {
        let off = InjectorGates::from_env(&env(&[("SLOPDESK_TABLET_MOUSE", "0")]), None, QUIET);
        assert!(!off.tablet_mouse);
        let noise = InjectorGates::from_env(&env(&[("SLOPDESK_TABLET_MOUSE", "0.0")]), None, QUIET);
        assert!(noise.tablet_mouse, "exactly `0`, not any falsey spelling");
    }

    #[test]
    fn the_swipe_nav_trace_inherits_the_session_wide_input_trace() {
        let inherited = InjectorGates::from_env(&env(&[]), None, InjectorGateContext { input_trace: true });
        assert!(inherited.swipe_nav_trace);
        let own = InjectorGates::from_env(&env(&[]), Some(""), QUIET);
        assert!(own.swipe_nav_trace, "PRESENCE, so an empty value arms it");
    }

    #[test]
    fn every_key_is_named_once() {
        let unique: std::collections::BTreeSet<&str> = KEYS.iter().copied().collect();
        assert_eq!(unique.len(), KEYS.len(), "a key is spelled twice");
    }
}
