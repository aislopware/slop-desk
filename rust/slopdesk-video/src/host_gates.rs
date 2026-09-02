//! The video host's operating point: every `SLOPDESK_*` gate it reads, resolved ONCE.
//!
//! ## Why they are one table
//!
//! These thirty-three knobs were thirty-three `private static let`s in
//! `SlopDeskVideoHostSession.swift`, each hand-writing its own lookup, its own parse, its own clamp
//! and its own default beside four hundred lines of prose explaining the measurement that chose it.
//! The prose is the valuable part and it stays there. The DECISIONS are what moved: a default is a
//! rule, a clamp is a rule, and "unset means twelve megabits but an explicit zero means off" is a
//! rule that reads identically in both languages and can only be tested in one of them.
//!
//! It also makes the family answerable as a family. The pacing gates alone have a precedence order
//! between them — an explicit `SLOPDESK_PACE_US` pins the static gap and therefore turns adaptive
//! pacing OFF, no matter what `SLOPDESK_PACE_ADAPTIVE` says — and that order was previously a
//! comment inside one of the two statics that implements it.
//!
//! ## The lookup stays in Swift
//!
//! [`KEYS`] is the list of names, in the order [`HostGates::from_env`] expects their values. Swift
//! reads each one through `EnvConfig.string`, which is the env → settings-overlay precedence
//! (`docs/58`), and hands the resolved texts back. That is deliberately NOT `std::env::var` here:
//! the overlay is a process-wide table the host folds `video-prefs.json` into at launch, so a gate
//! resolved out from under it would quietly stop honouring a setting the moment one of these keys
//! became user-facing.
//!
//! ## Faithfulness
//!
//! Every rule below is the Swift it replaces, carried verbatim rather than tidied — including the
//! three places the idioms are NOT the project's usual two. `SLOPDESK_VIDEO_DEBUG` and
//! `SLOPDESK_INPUT_TRACE` test PRESENCE (`!= nil`), so `=0` enables them;
//! `SLOPDESK_SMALL_DUP_MAX_BYTES` and the two NACK ring bounds take any parseable integer with NO
//! clamp at all. Each is marked at its field. The one difference from Swift's parser is that a
//! hexadecimal FLOAT literal (`0x1p3`), which `Double.init(String)` accepts and Rust's does not,
//! now falls to the default — a spelling no operating point has ever been written in.

/// The two inputs a gate needs that are not its own environment key.
///
/// Both are other components' resolved constants, and both are read by a gate that has to agree
/// with them: the scroll coalescer's default FOLLOWS the injector's resampler (stacking the two
/// double-quantizes the stream), and the client-silence pause is clamped INTO the keepalive
/// window's open interval. Passing them in keeps this module free of the two crates that own them
/// while leaving the rule itself here, where the rest of the table is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GateContext {
    /// Whether the input injector's scroll resampler is active — the default the scroll coalescer
    /// follows when its own key is unset.
    pub scroll_resampler_active: bool,
    /// The keepalive interval, in seconds: the FLOOR a client-silence pause threshold is lifted to.
    pub keepalive_interval: f64,
    /// The idle-reap timeout, in seconds: the (open) CEILING that threshold is held under.
    pub idle_timeout: f64,
}

/// The environment keys, in the order [`HostGates::from_env`] reads their values.
///
/// The caller resolves these names and passes the texts back positionally. One list, so a key
/// cannot be resolved under one spelling and read under another.
pub const KEYS: [&str; 33] = [
    "SLOPDESK_VIDEO_DEBUG",
    "SLOPDESK_INTERLEAVE",
    "SLOPDESK_PACE",
    "SLOPDESK_PACE_US",
    "SLOPDESK_PACE_ADAPTIVE",
    "SLOPDESK_PACE_RATE_X",
    "SLOPDESK_SEND_LANE",
    "SLOPDESK_KF_PACE_FLOOR_BPS",
    "SLOPDESK_DELTA_PACE_FLOOR_BPS",
    "SLOPDESK_BACKPRESSURE",
    "SLOPDESK_BACKPRESSURE_DEPTH",
    "SLOPDESK_SCROLL_COALESCE",
    "SLOPDESK_SCROLL_INJECT_MS",
    "SLOPDESK_FPS_GOVERNOR",
    "SLOPDESK_INPLACE_RESIZE",
    "SLOPDESK_KF_DUP",
    "SLOPDESK_KF_DUP_LOSS",
    "SLOPDESK_SMALL_DUP",
    "SLOPDESK_SMALL_DUP_MAX_BYTES",
    "SLOPDESK_NACK",
    "SLOPDESK_NACK_RING_FRAMES",
    "SLOPDESK_NACK_RING_BYTES",
    "SLOPDESK_RECOVERY_IDR_V2",
    "SLOPDESK_RECOVERY_DEDUP_MS",
    "SLOPDESK_NETSTATS",
    "SLOPDESK_ABR",
    "SLOPDESK_ADAPTIVE_FEC",
    "SLOPDESK_FULL_RANGE",
    "SLOPDESK_LTR",
    "SLOPDESK_INPUT_TRACE",
    "SLOPDESK_DIALOG_EXPAND",
    "SLOPDESK_FEC",
    "SLOPDESK_VIDEO_PAUSE_SILENT_SEC",
];

/// The resolved operating point.
///
/// Every field is what the corresponding `static let` in the video host used to compute. Units are
/// named in the field, because half of them are not the unit their key is written in: the pace gap
/// is nanoseconds from a key in microseconds, and both interval fields are SECONDS from keys in
/// milliseconds.
// A gate family is mostly switches, and that is the shape it has on the wire, in the docs and in
// the operator's head. The lint's advice — fold pairs of them into two-variant enums — would name
// twenty types nobody would ever mention twice, and each one would still be read as a boolean at
// the site that acts on it. The opt-out stops at this struct.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a table of switches IS mostly switches"
)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HostGates {
    /// Mirror lifecycle beats to stderr. PRESENCE, not value: `SLOPDESK_VIDEO_DEBUG=0` enables it.
    pub debug_stderr: bool,
    /// Burst-resilient transmit interleaving. Default ON.
    pub interleave_transmit: bool,
    /// Chunked send pacing at all. Default ON.
    pub pace_send: bool,
    /// The static inter-chunk gap, in NANOSECONDS. `SLOPDESK_PACE_US` is in microseconds and is
    /// honoured only in `1…10000`; anything else falls to 0.5 ms.
    pub pace_gap_nanos: u64,
    /// Compute the gap from the live ABR target instead of using the static one. Default ON —
    /// EXCEPT that an explicit `SLOPDESK_PACE_US`, parseable or not, pins the static gap and wins.
    pub pacing_adaptive: bool,
    /// Pace at this multiple of the live target. Clamped to `1…10`, default 2.5.
    pub pace_rate_multiplier: f64,
    /// Route paced sends through the dedicated lane rather than the encoder pump. Default ON.
    pub send_lane_enabled: bool,
    /// Keyframe pace-rate floor, bits per second. Clamped to `1M…100M`, default 12M.
    pub kf_pace_floor_bps: i64,
    /// Delta pace-rate floor, bits per second. Default 12M; an explicit non-positive value means
    /// OFF (0, i.e. raw ABR pacing) rather than being clamped up to the 1M floor.
    pub delta_pace_floor_bps: i64,
    /// Drop a capture frame before encode when the send lane is deep. Default ON.
    pub backpressure_enabled: bool,
    /// The lane depth that starts dropping. Clamped to `1…30`, default 3.
    pub backpressure_depth: i64,
    /// Sum consecutive same-phase scroll deltas into one post. Default FOLLOWS the injector's
    /// resampler — off while it is active — and an explicit value overrides either way.
    pub scroll_coalesce_enabled: bool,
    /// Minimum interval between injected summed scrolls, in SECONDS. `SLOPDESK_SCROLL_INJECT_MS` is
    /// in milliseconds and is honoured only in `4…50`; anything else falls to 8 ms.
    pub scroll_inject_interval: f64,
    /// The schedule-anchored encode cadence governor. Default OFF.
    pub fps_governor_enabled: bool,
    /// Reconfigure a live capture stream on resize instead of restarting it. Default OFF.
    ///
    /// OFF because the branch it selects has never run on a real host: the reconfigure and the
    /// encoder swap under it are exercised by unit tests over doubles, and a unit test cannot show
    /// that a `ScreenCaptureKit` stream actually applied a new configuration or that the first
    /// buffer after it arrived at the new size. `synthetic-tests-prove-nothing-fires` — so the
    /// default stayed OFF until `just gui-video` drove a real pane resize through it on
    /// 2026-09-02 and read the swap, the absence of a restart and the client's adoption of the
    /// new size off the logs (`docs/70` §2.7). Default ON since; `0` takes the restart path,
    /// which is what every way the fast path declines still falls back to.
    pub in_place_resize_enabled: bool,
    /// Duplicate-send keyframes. Default ON.
    pub kf_dup: bool,
    /// The smoothed loss rate at which duplication arms. Any non-negative value, default 0.005.
    pub kf_dup_loss_threshold: f64,
    /// Duplicate-send small changed deltas too. Default OFF.
    pub small_dup: bool,
    /// The encoded byte length below which a delta counts as small. NO clamp — any parseable
    /// integer, default 1400.
    pub small_dup_max_bytes: i64,
    /// Answer client NACKs from a send history. Default OFF.
    pub nack_enabled: bool,
    /// Retransmit ring depth, in frames. NO clamp, default 96.
    pub retransmit_ring_frames: i64,
    /// Retransmit ring ceiling, in bytes. NO clamp, default 8 MiB.
    pub retransmit_ring_max_bytes: i64,
    /// Delivery-keyed recovery-IDR cooldown rather than the sent-keyed capturer gate. Default ON.
    pub recovery_idr_v2: bool,
    /// The recovery-request dedup window, in SECONDS. `SLOPDESK_RECOVERY_DEDUP_MS` is in
    /// milliseconds and is honoured in `0…200` — 0 admits every datagram — default 25 ms.
    pub recovery_dedup_window: f64,
    /// Stamp send times and fold the client's reports. Default ON.
    pub telemetry_enabled: bool,
    /// Actuate the congestion controller's target. Default ON.
    pub abr_enabled: bool,
    /// Pick the per-frame FEC tier from measured loss. Default ON.
    pub adaptive_fec_enabled: bool,
    /// Full-range colour on all four coupled points. Default OFF.
    pub full_range: bool,
    /// Long-term-reference recovery. Default ON.
    pub ltr_enabled: bool,
    /// Log every injected input event with a sequence number. PRESENCE, not value.
    pub input_trace: bool,
    /// Expand the capture region over a system dialog. Default ON.
    pub dialog_expand_enabled: bool,
    /// The A/B that builds the packetizer with NO FEC scheme at all. Only `SLOPDESK_FEC=0`.
    pub fec_disabled: bool,
    /// Pause capture after this many SECONDS of client silence; 0 disables. Set values are clamped
    /// into `[keepalive_interval, idle_timeout)`, and unset or non-positive means off.
    pub client_silence_pause_seconds: f64,
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

impl HostGates {
    /// Resolves the operating point from the texts of [`KEYS`], in that order.
    ///
    /// A value shorter than the list, or a `None` entry, is an unset key — so a caller that has not
    /// caught up with a new gate gets that gate's default rather than a panic.
    #[must_use]
    pub fn from_env(values: &[Option<&str>], context: GateContext) -> Self {
        let at = |key: &str| -> Option<&str> {
            KEYS.iter()
                .position(|name| *name == key)
                .and_then(|index| values.get(index).copied().flatten())
        };

        // An explicit microsecond pin wins over the adaptive gap, parseable or not: the operator
        // asked for a STATIC gap, and answering with a computed one would be an A/B that silently
        // did not run.
        let pace_micros = at("SLOPDESK_PACE_US");

        Self {
            debug_stderr: at("SLOPDESK_VIDEO_DEBUG").is_some(),
            interleave_transmit: default_on(at("SLOPDESK_INTERLEAVE")),
            pace_send: default_on(at("SLOPDESK_PACE")),
            pace_gap_nanos: match pace_micros.and_then(|text| text.parse::<u64>().ok()) {
                Some(micros @ 1..=10_000) => micros * 1_000,
                _ => 500_000,
            },
            pacing_adaptive: pace_micros.is_none() && default_on(at("SLOPDESK_PACE_ADAPTIVE")),
            pace_rate_multiplier: match real(at("SLOPDESK_PACE_RATE_X")) {
                Some(value) if value.is_finite() => value.clamp(1.0, 10.0),
                _ => 2.5,
            },
            send_lane_enabled: default_on(at("SLOPDESK_SEND_LANE")),
            kf_pace_floor_bps: integer(at("SLOPDESK_KF_PACE_FLOOR_BPS"))
                .map_or(12_000_000, |value| value.clamp(1_000_000, 100_000_000)),
            // The one gate whose "off" is spelled by a value the clamp would otherwise raise: an
            // explicit 0 or negative means raw-ABR pacing, not the 1 Mbps floor.
            delta_pace_floor_bps: match integer(at("SLOPDESK_DELTA_PACE_FLOOR_BPS")) {
                None => 12_000_000,
                Some(value) if value <= 0 => 0,
                Some(value) => value.clamp(1_000_000, 100_000_000),
            },
            backpressure_enabled: default_on(at("SLOPDESK_BACKPRESSURE")),
            backpressure_depth: integer(at("SLOPDESK_BACKPRESSURE_DEPTH"))
                .map_or(3, |value| value.clamp(1, 30)),
            scroll_coalesce_enabled: at("SLOPDESK_SCROLL_COALESCE")
                .map_or(!context.scroll_resampler_active, |text| text != "0"),
            scroll_inject_interval: match real(at("SLOPDESK_SCROLL_INJECT_MS")) {
                Some(millis) if (4.0..=50.0).contains(&millis) => millis / 1000.0,
                _ => 0.008,
            },
            fps_governor_enabled: default_off(at("SLOPDESK_FPS_GOVERNOR")),
            in_place_resize_enabled: default_on(at("SLOPDESK_INPLACE_RESIZE")),
            kf_dup: default_on(at("SLOPDESK_KF_DUP")),
            kf_dup_loss_threshold: match real(at("SLOPDESK_KF_DUP_LOSS")) {
                Some(value) if value >= 0.0 => value,
                _ => 0.005,
            },
            small_dup: default_off(at("SLOPDESK_SMALL_DUP")),
            small_dup_max_bytes: integer(at("SLOPDESK_SMALL_DUP_MAX_BYTES")).unwrap_or(1400),
            nack_enabled: default_off(at("SLOPDESK_NACK")),
            retransmit_ring_frames: integer(at("SLOPDESK_NACK_RING_FRAMES")).unwrap_or(96),
            retransmit_ring_max_bytes: integer(at("SLOPDESK_NACK_RING_BYTES")).unwrap_or(8 << 20),
            recovery_idr_v2: default_on(at("SLOPDESK_RECOVERY_IDR_V2")),
            recovery_dedup_window: match real(at("SLOPDESK_RECOVERY_DEDUP_MS")) {
                Some(millis) if (0.0..=200.0).contains(&millis) => millis / 1000.0,
                _ => 0.025,
            },
            telemetry_enabled: default_on(at("SLOPDESK_NETSTATS")),
            abr_enabled: default_on(at("SLOPDESK_ABR")),
            adaptive_fec_enabled: default_on(at("SLOPDESK_ADAPTIVE_FEC")),
            full_range: default_off(at("SLOPDESK_FULL_RANGE")),
            ltr_enabled: default_on(at("SLOPDESK_LTR")),
            input_trace: at("SLOPDESK_INPUT_TRACE").is_some(),
            dialog_expand_enabled: default_on(at("SLOPDESK_DIALOG_EXPAND")),
            fec_disabled: at("SLOPDESK_FEC") == Some("0"),
            client_silence_pause_seconds: match real(at("SLOPDESK_VIDEO_PAUSE_SILENT_SEC")) {
                Some(seconds) if seconds > 0.0 => {
                    seconds
                        .max(context.keepalive_interval)
                        .min(context.idle_timeout - 0.001)
                },
                _ => 0.0,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{GateContext, HostGates, KEYS};

    /// The keepalive window the host actually runs in — the pause clamp is only meaningful against
    /// real bounds, and these are `KeepaliveTiming`'s.
    const CONTEXT: GateContext = GateContext {
        scroll_resampler_active: true,
        keepalive_interval: 5.0,
        idle_timeout: 30.0,
    };

    fn resolve(pairs: &[(&str, &str)]) -> HostGates {
        let values: Vec<Option<&str>> = KEYS
            .iter()
            .map(|key| {
                pairs
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, value)| *value)
            })
            .collect();
        HostGates::from_env(&values, CONTEXT)
    }

    /// Every default, as the thirty-three statics computed them. This is the shipped operating
    /// point: if one number here moves, the host's behaviour moved with it.
    #[test]
    fn the_unset_environment_is_the_shipped_operating_point() {
        let gates = resolve(&[]);
        assert!(!gates.debug_stderr);
        assert!(gates.interleave_transmit);
        assert!(gates.pace_send);
        assert_eq!(gates.pace_gap_nanos, 500_000);
        assert!(gates.pacing_adaptive);
        assert!((gates.pace_rate_multiplier - 2.5).abs() < f64::EPSILON);
        assert!(gates.send_lane_enabled);
        assert_eq!(gates.kf_pace_floor_bps, 12_000_000);
        assert_eq!(gates.delta_pace_floor_bps, 12_000_000);
        assert!(gates.backpressure_enabled);
        assert_eq!(gates.backpressure_depth, 3);
        assert!(
            !gates.scroll_coalesce_enabled,
            "the resampler is active in this context"
        );
        assert!((gates.scroll_inject_interval - 0.008).abs() < f64::EPSILON);
        assert!(!gates.fps_governor_enabled);
        assert!(gates.in_place_resize_enabled);
        assert!(gates.kf_dup);
        assert!((gates.kf_dup_loss_threshold - 0.005).abs() < f64::EPSILON);
        assert!(!gates.small_dup);
        assert_eq!(gates.small_dup_max_bytes, 1400);
        assert!(!gates.nack_enabled);
        assert_eq!(gates.retransmit_ring_frames, 96);
        assert_eq!(gates.retransmit_ring_max_bytes, 8 << 20);
        assert!(gates.recovery_idr_v2);
        assert!((gates.recovery_dedup_window - 0.025).abs() < f64::EPSILON);
        assert!(gates.telemetry_enabled);
        assert!(gates.abr_enabled);
        assert!(gates.adaptive_fec_enabled);
        assert!(!gates.full_range);
        assert!(gates.ltr_enabled);
        assert!(!gates.input_trace);
        assert!(gates.dialog_expand_enabled);
        assert!(!gates.fec_disabled);
        assert!(gates.client_silence_pause_seconds.abs() < f64::EPSILON);
    }

    /// EVERY key is wired to a field: each one, set alone to a value that must move the answer,
    /// moves it. A key resolved under a name no arm reads would silently answer its default here,
    /// which is exactly the failure a positional table invites.
    #[test]
    fn every_key_reaches_a_field() {
        let flipping: [(&str, &str); 33] = [
            ("SLOPDESK_VIDEO_DEBUG", "1"),
            ("SLOPDESK_INTERLEAVE", "0"),
            ("SLOPDESK_PACE", "0"),
            ("SLOPDESK_PACE_US", "7"),
            ("SLOPDESK_PACE_ADAPTIVE", "0"),
            ("SLOPDESK_PACE_RATE_X", "4"),
            ("SLOPDESK_SEND_LANE", "0"),
            ("SLOPDESK_KF_PACE_FLOOR_BPS", "20000000"),
            ("SLOPDESK_DELTA_PACE_FLOOR_BPS", "0"),
            ("SLOPDESK_BACKPRESSURE", "0"),
            ("SLOPDESK_BACKPRESSURE_DEPTH", "9"),
            ("SLOPDESK_SCROLL_COALESCE", "1"),
            ("SLOPDESK_SCROLL_INJECT_MS", "16"),
            ("SLOPDESK_FPS_GOVERNOR", "1"),
            ("SLOPDESK_INPLACE_RESIZE", "0"),
            ("SLOPDESK_KF_DUP", "0"),
            ("SLOPDESK_KF_DUP_LOSS", "0.02"),
            ("SLOPDESK_SMALL_DUP", "1"),
            ("SLOPDESK_SMALL_DUP_MAX_BYTES", "900"),
            ("SLOPDESK_NACK", "1"),
            ("SLOPDESK_NACK_RING_FRAMES", "12"),
            ("SLOPDESK_NACK_RING_BYTES", "4096"),
            ("SLOPDESK_RECOVERY_IDR_V2", "0"),
            ("SLOPDESK_RECOVERY_DEDUP_MS", "60"),
            ("SLOPDESK_NETSTATS", "0"),
            ("SLOPDESK_ABR", "0"),
            ("SLOPDESK_ADAPTIVE_FEC", "0"),
            ("SLOPDESK_FULL_RANGE", "1"),
            ("SLOPDESK_LTR", "0"),
            ("SLOPDESK_INPUT_TRACE", "1"),
            ("SLOPDESK_DIALOG_EXPAND", "0"),
            ("SLOPDESK_FEC", "0"),
            ("SLOPDESK_VIDEO_PAUSE_SILENT_SEC", "10"),
        ];
        let defaults = resolve(&[]);
        for (key, value) in flipping {
            assert!(KEYS.contains(&key), "{key} is not in the key list");
            assert_ne!(
                resolve(&[(key, value)]),
                defaults,
                "{key}={value} changed nothing — no arm reads that name",
            );
        }
        assert_eq!(
            flipping.len(),
            KEYS.len(),
            "one flipping value per key, and no more"
        );
    }

    /// The three keys whose idiom is PRESENCE rather than value: `=0` turns them ON.
    #[test]
    fn a_presence_gate_is_on_even_when_it_says_zero() {
        assert!(resolve(&[("SLOPDESK_VIDEO_DEBUG", "0")]).debug_stderr);
        assert!(resolve(&[("SLOPDESK_INPUT_TRACE", "0")]).input_trace);
        assert!(resolve(&[("SLOPDESK_VIDEO_DEBUG", "")]).debug_stderr);
    }

    /// A static microsecond pin turns adaptive pacing off — even when it is unparseable, and even
    /// when the adaptive key explicitly asks for it.
    #[test]
    fn an_explicit_pace_pin_wins_over_the_adaptive_gap() {
        let pinned = resolve(&[("SLOPDESK_PACE_US", "250")]);
        assert_eq!(pinned.pace_gap_nanos, 250_000);
        assert!(!pinned.pacing_adaptive);

        let nonsense = resolve(&[("SLOPDESK_PACE_US", "banana"), ("SLOPDESK_PACE_ADAPTIVE", "1")]);
        assert_eq!(
            nonsense.pace_gap_nanos, 500_000,
            "an unparseable pin still falls to the default gap"
        );
        assert!(
            !nonsense.pacing_adaptive,
            "but it is still a pin, so adaptive stays off"
        );

        assert!(resolve(&[("SLOPDESK_PACE_ADAPTIVE", "1")]).pacing_adaptive);
    }

    /// Out-of-range values fall to the default rather than to the nearest bound, for the two gates
    /// written that way — a `SLOPDESK_PACE_US` of 0 is a typo, not a request for no gap.
    #[test]
    fn an_out_of_range_window_falls_to_its_default() {
        assert_eq!(resolve(&[("SLOPDESK_PACE_US", "0")]).pace_gap_nanos, 500_000);
        assert_eq!(resolve(&[("SLOPDESK_PACE_US", "10001")]).pace_gap_nanos, 500_000);
        assert_eq!(
            resolve(&[("SLOPDESK_PACE_US", "10000")]).pace_gap_nanos,
            10_000_000
        );

        let too_fast = resolve(&[("SLOPDESK_SCROLL_INJECT_MS", "1")]);
        assert!((too_fast.scroll_inject_interval - 0.008).abs() < f64::EPSILON);
        let honoured = resolve(&[("SLOPDESK_SCROLL_INJECT_MS", "16")]);
        assert!((honoured.scroll_inject_interval - 0.016).abs() < f64::EPSILON);
    }

    /// The numeric gates that CLAMP rather than fall through, at both of their bounds.
    #[test]
    fn a_clamped_gate_is_held_at_its_bounds() {
        assert_eq!(
            resolve(&[("SLOPDESK_KF_PACE_FLOOR_BPS", "1")]).kf_pace_floor_bps,
            1_000_000
        );
        assert_eq!(
            resolve(&[("SLOPDESK_KF_PACE_FLOOR_BPS", "999999999")]).kf_pace_floor_bps,
            100_000_000,
        );
        assert_eq!(
            resolve(&[("SLOPDESK_BACKPRESSURE_DEPTH", "0")]).backpressure_depth,
            1
        );
        assert_eq!(
            resolve(&[("SLOPDESK_BACKPRESSURE_DEPTH", "99")]).backpressure_depth,
            30
        );
        let multiplier = resolve(&[("SLOPDESK_PACE_RATE_X", "0.1")]).pace_rate_multiplier;
        assert!((multiplier - 1.0).abs() < f64::EPSILON);
        let capped = resolve(&[("SLOPDESK_PACE_RATE_X", "1000")]).pace_rate_multiplier;
        assert!((capped - 10.0).abs() < f64::EPSILON);
        let infinite = resolve(&[("SLOPDESK_PACE_RATE_X", "inf")]).pace_rate_multiplier;
        assert!(
            (infinite - 2.5).abs() < f64::EPSILON,
            "a non-finite multiplier is not a request"
        );
    }

    /// The delta floor's explicit OFF, which is the one place a non-positive value is NOT clamped
    /// up: `max(abr, 0) == abr`, i.e. raw-ABR pacing, which is what the operator asked for.
    #[test]
    fn an_explicit_zero_delta_floor_means_off_rather_than_the_floor() {
        assert_eq!(
            resolve(&[("SLOPDESK_DELTA_PACE_FLOOR_BPS", "0")]).delta_pace_floor_bps,
            0
        );
        assert_eq!(
            resolve(&[("SLOPDESK_DELTA_PACE_FLOOR_BPS", "-5")]).delta_pace_floor_bps,
            0
        );
        assert_eq!(
            resolve(&[("SLOPDESK_DELTA_PACE_FLOOR_BPS", "500")]).delta_pace_floor_bps,
            1_000_000,
            "a positive value below the floor IS clamped up",
        );
        assert_eq!(
            resolve(&[("SLOPDESK_DELTA_PACE_FLOOR_BPS", "nope")]).delta_pace_floor_bps,
            12_000_000,
            "unparseable is unset",
        );
    }

    /// The scroll coalescer follows the resampler while its own key is unset, and stops following
    /// the moment it is set — in either direction.
    #[test]
    fn the_scroll_coalescer_follows_the_resampler_until_it_is_told_not_to() {
        let idle = GateContext {
            scroll_resampler_active: false,
            ..CONTEXT
        };
        let values: Vec<Option<&str>> = KEYS.iter().map(|_| None).collect();
        assert!(HostGates::from_env(&values, idle).scroll_coalesce_enabled);
        assert!(!resolve(&[]).scroll_coalesce_enabled);
        assert!(resolve(&[("SLOPDESK_SCROLL_COALESCE", "1")]).scroll_coalesce_enabled);
        assert!(!resolve(&[("SLOPDESK_SCROLL_COALESCE", "0")]).scroll_coalesce_enabled);
    }

    /// The client-silence pause is clamped INTO the keepalive window: a threshold below one
    /// keepalive interval would trip on a normal quiet gap, and one at or past the reaper is
    /// pointless because the session is already gone.
    #[test]
    fn a_silence_pause_is_clamped_into_the_keepalive_window() {
        let short = resolve(&[("SLOPDESK_VIDEO_PAUSE_SILENT_SEC", "1")]);
        assert!((short.client_silence_pause_seconds - 5.0).abs() < f64::EPSILON);
        let long = resolve(&[("SLOPDESK_VIDEO_PAUSE_SILENT_SEC", "999")]);
        assert!((long.client_silence_pause_seconds - 29.999).abs() < 1e-9);
        let inside = resolve(&[("SLOPDESK_VIDEO_PAUSE_SILENT_SEC", "12")]);
        assert!((inside.client_silence_pause_seconds - 12.0).abs() < f64::EPSILON);
        let off = resolve(&[("SLOPDESK_VIDEO_PAUSE_SILENT_SEC", "0")]);
        assert!(off.client_silence_pause_seconds.abs() < f64::EPSILON);
    }

    /// A caller that has not caught up with a new key gets that key's default, not a panic.
    #[test]
    fn a_short_value_list_resolves_to_defaults() {
        let gates = HostGates::from_env(&[Some("1")], CONTEXT);
        assert!(gates.debug_stderr, "the value it DID pass is still read");
        assert!(gates.ltr_enabled, "and everything past its end is unset");
    }
}
