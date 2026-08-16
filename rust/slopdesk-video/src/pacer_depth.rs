//! The presentation queue's adaptive depth, and the one-way-delay spike detector that drives it.
//!
//! Sizing the depth from inter-arrival jitter was tried and is wrong: it conflates benign
//! sender-cadence variance — host idle-skip, chunked pacing, frame-size-dependent encode time —
//! with actual presentation risk, and on a jittery-but-fine wide-area link it pins the depth at two
//! to four frames of standing latency with not one late present ever observed. Under the
//! display-native tick the pacer's underflow run also oscillates BY DESIGN on a healthy stream, so
//! growing depth on a dip in that counter ratchets to the maximum on a clean link. The model here
//! inverts it: pay latency only AFTER observed late events, refund after a clean dwell.
//!
//! A present-GAP classifier is not the promotion source either, and the reason is structural rather
//! than a tuning miss. Comparing present gaps against the cadence hint makes natural sub-cadence
//! content — an editor's idle repaint at forty frames under a sixty-frame hint — clear the late
//! boundary on every re-show; field testing showed a late in every single report at ALL flow
//! densities, pinning the depth for the whole session with demote unreachable. Arrival gaps
//! conflate "the network delivered late" with "the host did not produce a frame".
//!
//! So the two jobs are split. Promotion and demotion run on NETWORK-late events: per-frame
//! one-way-delay spikes past the path baseline, which [`OwdLateDetector`] finds off the wire send
//! stamps. That is the signal a slack frame actually absorbs, it is measured at ARRIVAL and is
//! therefore depth-independent — promotion cannot self-sustain through its own pinning loop — and
//! content cadence cannot fake it. The present-gap machinery stays as pure telemetry: gaps are
//! still classified and stall episodes still counted, but no gap classification moves the depth.

/// The one-way-delay SPIKE detector: the promotion signal for the depth boost.
///
/// The delay is the client-clock arrival minus the unwrapped host send stamp, which is
/// offset-skewed and does not matter, because the constant cross-machine offset cancels against the
/// baseline — the same discipline the jitter and trendline estimators use. The baseline is a
/// two-bucket rolling MINIMUM, so spikes can never raise it while a genuine path change re-bases
/// within one bucket rotation: a standing queue becomes the new normal, which is the bitrate
/// controller's problem, and only VARIATION above it counts, which is the depth's. Content gaps
/// mean nothing to a minimum, so idle skips cannot produce false lates at all.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OwdLateConfig {
    /// The baseline bucket span in milliseconds. The effective history is one to two buckets: long
    /// enough that a whole burst cannot instantly become the baseline, short enough to track a real
    /// path change within a few seconds.
    pub bucket_ms: f64,
    /// The absolute spike floor in milliseconds.
    ///
    /// The send stamp is minted at packetize time, BEFORE the paced send lane, so big-frame
    /// serialisation and queueing behind a fat predecessor show up as tens of milliseconds of
    /// wobble during dense scroll. A ten-millisecond floor let that self-inflicted wobble alone
    /// trigger a hundred and fifty lates in ninety seconds with the depth flapping. This sits above
    /// the pacing band, while a genuine network burst — the class that actually threatens a present
    /// — still clears it.
    pub threshold_floor_ms: f64,
    /// The interval-proportional component. A spike beyond this fraction of the content frame
    /// interval risks losing more than the one slot the boost buys back.
    pub threshold_interval_fraction: f64,
    /// How many samples the baseline needs before any late verdict. Connection bring-up transients
    /// must not promote.
    pub warmup_samples: usize,
}

impl Default for OwdLateConfig {
    fn default() -> Self {
        Self {
            bucket_ms: 2000.0,
            threshold_floor_ms: 25.0,
            threshold_interval_fraction: 1.25,
            warmup_samples: 20,
        }
    }
}

/// The spike floor's environment name.
pub const OWD_LATE_FLOOR_MS_KEY: &str = "SLOPDESK_OWD_LATE_FLOOR_MS";
/// The interval fraction's environment name, in percent.
pub const OWD_LATE_FRACTION_PCT_KEY: &str = "SLOPDESK_OWD_LATE_FRAC_PCT";
/// The warm-up count's environment name.
pub const OWD_LATE_WARMUP_KEY: &str = "SLOPDESK_OWD_LATE_WARMUP";

impl OwdLateConfig {
    /// Parses the operating point from the raw environment values, each clamped to a sane band. An
    /// absent, unparseable or non-finite value keeps the default.
    #[must_use]
    pub fn from_env(floor_ms: Option<&str>, fraction_pct: Option<&str>, warmup: Option<&str>) -> Self {
        let mut config = Self::default();
        for (key, value) in [
            (OWD_LATE_FLOOR_MS_KEY, floor_ms),
            (OWD_LATE_FRACTION_PCT_KEY, fraction_pct),
            (OWD_LATE_WARMUP_KEY, warmup),
        ] {
            if let Some(text) = value {
                config.apply_env_pair(key, text);
            }
        }
        config
    }

    /// Applies ONE environment pair, which is how a caller holding a whole environment map reaches
    /// the same bands without knowing which knob answers to which name.
    ///
    /// An unknown key, an unparseable value and a non-finite one all leave the config untouched.
    pub fn apply_env_pair(&mut self, key: &str, value: &str) {
        match key {
            OWD_LATE_FLOOR_MS_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.threshold_floor_ms = parsed.clamp(1.0, 200.0);
                }
            },
            OWD_LATE_FRACTION_PCT_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.threshold_interval_fraction = parsed.clamp(0.0, 400.0) / 100.0;
                }
            },
            OWD_LATE_WARMUP_KEY => {
                if let Some(parsed) = integer_text(value) {
                    self.warmup_samples = usize::try_from(parsed.clamp(1, 1000)).unwrap_or(1);
                }
            },
            _ => {},
        }
    }
}

/// A parsed finite double, which is what every band clamp below assumes.
fn finite_text(raw: &str) -> Option<f64> {
    raw.parse::<f64>().ok().filter(|value| value.is_finite())
}

/// A parsed integer knob.
///
/// It parses SIGNED and clamps afterwards rather than parsing into the unsigned type the field
/// holds: a negative knob is an out-of-band value, which every other knob here answers by clamping
/// to the nearest end of its band, not by silently keeping the default.
fn integer_text(raw: &str) -> Option<i64> {
    raw.parse::<i64>().ok()
}

/// The spike detector.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OwdLateDetector {
    config: OwdLateConfig,
    /// The host send stamp unwrapped into a monotone double. The wire stamp wraps at about
    /// forty-nine days, and accumulating wrap-aware deltas keeps the delay continuous across it.
    unwrapped_send_ms: f64,
    prev_send_ts: Option<u32>,
    current_bucket_min: f64,
    previous_bucket_min: f64,
    bucket_start_arrival_ms: Option<f64>,
    samples: usize,
}

impl Default for OwdLateDetector {
    fn default() -> Self {
        Self::new(OwdLateConfig::default())
    }
}

impl OwdLateDetector {
    /// A detector at the given operating point.
    #[must_use]
    pub const fn new(config: OwdLateConfig) -> Self {
        Self {
            config,
            unwrapped_send_ms: 0.0,
            prev_send_ts: None,
            current_bucket_min: f64::INFINITY,
            previous_bucket_min: f64::INFINITY,
            bucket_start_arrival_ms: None,
            samples: 0,
        }
    }

    /// Folds one per-frame sample and returns how far past the threshold it sat, when it is a
    /// network-late spike.
    ///
    /// The caller admits one sample per strictly-newer frame id through the trend sampler, so
    /// reordered frames, keyframe duplicates and a zero stamp never reach here.
    pub fn note(&mut self, arrival_ms: f64, send_ts: u32, interval_ms: f64) -> Option<f64> {
        if let Some(prev) = self.prev_send_ts {
            // A negative delta is tolerated as no forward progress — depth behind the sampler.
            self.unwrapped_send_ms += f64::from(crate::reassembler::distance_wrapped(send_ts, prev).max(0));
        }
        self.prev_send_ts = Some(send_ts);
        let owd = arrival_ms - self.unwrapped_send_ms;

        // The rotation runs on ARRIVAL time, so a content gap merely stretches a bucket, which is
        // harmless to a minimum.
        match self.bucket_start_arrival_ms {
            Some(start) if arrival_ms - start >= self.config.bucket_ms => {
                self.previous_bucket_min = self.current_bucket_min;
                self.current_bucket_min = f64::INFINITY;
                self.bucket_start_arrival_ms = Some(arrival_ms);
            },
            Some(_) => {},
            None => self.bucket_start_arrival_ms = Some(arrival_ms),
        }

        let baseline = self.previous_bucket_min.min(self.current_bucket_min.min(owd));
        self.current_bucket_min = self.current_bucket_min.min(owd);
        self.samples += 1;
        if self.samples < self.config.warmup_samples || !baseline.is_finite() {
            return None;
        }

        // BIT-EXACT: the fraction and the interval multiply separately from the outer maximum, and
        // the guard on a stray negative interval is an ordered maximum of its own.
        let threshold = self
            .config
            .threshold_floor_ms
            .max(self.config.threshold_interval_fraction * interval_ms.max(0.0));
        let deviation = owd - baseline;
        (deviation > threshold).then_some(deviation - threshold)
    }

    /// Every field the next fold reads, for a caller that carries the detector BY VALUE across a
    /// boundary rather than holding it.
    #[must_use]
    pub const fn snapshot(&self) -> OwdLateSnapshot {
        OwdLateSnapshot {
            config: self.config,
            unwrapped_send_ms: self.unwrapped_send_ms,
            prev_send_ts: self.prev_send_ts,
            current_bucket_min: self.current_bucket_min,
            previous_bucket_min: self.previous_bucket_min,
            bucket_start_arrival_ms: self.bucket_start_arrival_ms,
            samples: self.samples,
        }
    }

    /// The detector that snapshot describes. It is the exact inverse of [`Self::snapshot`], so a
    /// fold across the boundary is the fold this side would have run.
    #[must_use]
    pub const fn restored(snapshot: OwdLateSnapshot) -> Self {
        Self {
            config: snapshot.config,
            unwrapped_send_ms: snapshot.unwrapped_send_ms,
            prev_send_ts: snapshot.prev_send_ts,
            current_bucket_min: snapshot.current_bucket_min,
            previous_bucket_min: snapshot.previous_bucket_min,
            bucket_start_arrival_ms: snapshot.bucket_start_arrival_ms,
            samples: snapshot.samples,
        }
    }
}

/// The detector's whole state, for a by-value crossing.
///
/// Nothing here is derived: a baseline is a rolling minimum over samples this side no longer holds,
/// so a caller that dropped a field would fold against a baseline that never existed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OwdLateSnapshot {
    /// The operating point, which travels with the state so the far side needs no second copy.
    pub config: OwdLateConfig,
    /// The monotone unwrapped send stamp.
    pub unwrapped_send_ms: f64,
    /// The previous wire stamp, which the next unwrap steps from.
    pub prev_send_ts: Option<u32>,
    /// The minimum inside the live bucket.
    pub current_bucket_min: f64,
    /// The minimum inside the bucket before it.
    pub previous_bucket_min: f64,
    /// When the live bucket opened, on the ARRIVAL clock.
    pub bucket_start_arrival_ms: Option<f64>,
    /// How many samples have landed, which the warm-up gate reads.
    pub samples: usize,
}

/// One windowed drain of the presentation-health counters, carried to the host on the network stats
/// message. It is log-only host-side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PacerTelemetrySnapshot {
    /// Windowed: NETWORK-late events, which is the depth-promotion input rather than present-gap
    /// lates.
    pub late_frames: u32,
    /// Windowed: late-gap EPISODES OPENED, counted at the first re-show past the late threshold.
    ///
    /// Deliberately a SUPERSET of the late frames: a gap that no frame ever resolves, because
    /// motion stopped, still counts here. The difference between the two is therefore roughly the
    /// motion-stop boundaries, which log readers should know before reading anything into it.
    pub present_gaps: u32,
    /// A gauge rather than a window: the live presentation depth, zero when no pacer is attached.
    pub depth: u32,
}

/// How one content-present gap classified.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GapClass {
    /// The first present of the stream, which has no gap to classify.
    First,
    /// Inside the expected cadence.
    Normal,
    /// Past the late boundary, dense enough to matter, and a sharp step up from the last gap.
    Late,
    /// Long enough to be a host idle-skip or a motion stop, which is never late.
    Idle,
}

/// The depth policy's operating point.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PacerDepthConfig {
    /// A gap is late past the greater of the absolute floor and this factor times the expected
    /// interval. It sits above one interval plus tick quantisation plus present-on-arrival wobble,
    /// and below a fully missed content slot.
    pub late_gap_factor: f64,
    /// The hardware-validated stall threshold, in seconds. It also immunises the tick-alternation
    /// case at the boosted depth against self-sustaining promotion.
    pub absolute_late_floor_seconds: f64,
    /// A gap above this is idle — a host idle-skip or a motion stop — and never late. A
    /// misclassification fails safe, because an under-count merely fails to promote.
    pub idle_gap_seconds: f64,
    /// Late additionally requires the gap to be at least this multiple of the previous in-flow gap,
    /// which suppresses gradual cadence drift. One skipped slot is a doubling and passes.
    pub gap_gradient_factor: f64,
    /// Dense flow is at least this many arrivals inside the dense window before the gap opened.
    /// It excludes typing and sparse content from ever counting late.
    pub dense_min_arrivals: usize,
    /// The window the dense-flow count runs over, in seconds.
    pub dense_window_seconds: f64,
    /// Extra margin on top of the late boundary, as a fraction of the expected interval.
    ///
    /// Without it a steady trickle of routine arrival jitter landing a hair past the bare boundary
    /// keeps the depth pinned almost permanently, which field testing saw at every flow density. A
    /// quarter of an interval absorbs that jitter while a genuinely skipped slot still clears the
    /// boundary by a wide margin.
    pub late_slack_fraction: f64,
    /// Promote on this many late events inside the promote window.
    pub promote_late_count: usize,
    /// The window the promote count runs over, in seconds.
    pub promote_window_seconds: f64,
    /// Demote after this long with at most the tolerated number of late events in the window.
    pub demote_clean_seconds: f64,
    /// But never sooner than this after a promotion, which is the anti-flap.
    pub min_hold_seconds: f64,
    /// How many late events the trailing dwell tolerates and still demotes.
    ///
    /// The dwell does not demand a perfectly clean window: one lone genuine late must not re-arm
    /// the whole thing. The slack above kills most of the trickle and this is the backstop. Zero is
    /// a strict dwell.
    pub demote_tolerance_lates: usize,
    /// How long after the first arrival promote DECISIONS are ignored.
    ///
    /// Connection bring-up produces transient gap shapes that look like a genuine trigger and, left
    /// unguarded, never demote afterward. The counters still run, because telemetry is
    /// unconditional; only the action is gated.
    pub promote_warmup_seconds: f64,
    /// The boosted depth. One slack frame covers the dominant one-slot-late hitch and anything
    /// deeper is pure standing latency, which is the failure mode this policy exists to avoid.
    pub boost_depth: u32,
    /// How many in-flow inter-arrival gaps the interval estimator keeps.
    pub interval_ring_size: usize,
    /// How many it needs before it is trusted over the default.
    pub min_samples_for_estimate: usize,
    /// The interval assumed before the estimator warms, in seconds.
    pub default_interval_seconds: f64,
    /// The floor the expected interval is clamped to.
    pub min_interval_seconds: f64,
    /// The ceiling the expected interval is clamped to.
    pub max_interval_seconds: f64,
}

impl Default for PacerDepthConfig {
    fn default() -> Self {
        Self {
            late_gap_factor: 1.6,
            absolute_late_floor_seconds: 0.028,
            idle_gap_seconds: 0.25,
            gap_gradient_factor: 1.45,
            dense_min_arrivals: 8,
            dense_window_seconds: 0.35,
            late_slack_fraction: 0.25,
            promote_late_count: 2,
            promote_window_seconds: 1.0,
            demote_clean_seconds: 2.5,
            min_hold_seconds: 1.0,
            demote_tolerance_lates: 1,
            promote_warmup_seconds: 2.0,
            boost_depth: 2,
            interval_ring_size: 15,
            min_samples_for_estimate: 5,
            default_interval_seconds: 1.0 / 60.0,
            min_interval_seconds: 1.0 / 240.0,
            max_interval_seconds: 1.0 / 10.0,
        }
    }
}

/// How many late events the ring holds. Every count above the tolerance band blocks a demote
/// identically, so a small ring loses nothing.
pub const LATE_RING_CAPACITY: usize = 4;
/// How many arrivals the dense-flow ring holds.
pub const ARRIVAL_RING_CAPACITY: usize = 16;
/// How many in-flow gaps the interval estimator's ring can hold.
///
/// [`PacerDepthConfig::interval_ring_size`] is how many it KEEPS, which a caller may lower; this is
/// the ceiling a by-value crossing can carry, so a size above it is capped when the state travels.
pub const INTERVAL_RING_CAPACITY: usize = 15;

/// The raw environment values the depth policy reads.
#[derive(Debug, Clone, Copy, Default)]
pub struct PacerDepthEnv<'a> {
    /// How many late events promote.
    pub promote_lates: Option<&'a str>,
    /// The promote window in milliseconds.
    pub promote_window_ms: Option<&'a str>,
    /// The demote dwell in milliseconds.
    pub demote_ms: Option<&'a str>,
    /// The anti-flap hold in milliseconds.
    pub min_hold_ms: Option<&'a str>,
    /// The late boundary's interval factor.
    pub late_factor: Option<&'a str>,
    /// The idle boundary in milliseconds.
    pub idle_ms: Option<&'a str>,
    /// The late slack as a percentage of the interval.
    pub late_slack_pct: Option<&'a str>,
    /// How many lates the dwell tolerates.
    pub demote_tolerance: Option<&'a str>,
    /// The promote warmup in milliseconds.
    pub warmup_ms: Option<&'a str>,
}

/// The promote count's environment name.
pub const DEPTH_PROMOTE_LATES_KEY: &str = "SLOPDESK_DEPTH_PROMOTE_LATES";
/// The promote window's environment name, in milliseconds.
pub const DEPTH_PROMOTE_WINDOW_MS_KEY: &str = "SLOPDESK_DEPTH_PROMOTE_WINDOW_MS";
/// The demote dwell's environment name, in milliseconds.
pub const DEPTH_DEMOTE_MS_KEY: &str = "SLOPDESK_DEPTH_DEMOTE_MS";
/// The anti-flap hold's environment name, in milliseconds.
pub const DEPTH_MIN_HOLD_MS_KEY: &str = "SLOPDESK_DEPTH_MINHOLD_MS";
/// The late boundary factor's environment name.
pub const DEPTH_LATE_FACTOR_KEY: &str = "SLOPDESK_DEPTH_LATE_FACTOR";
/// The idle boundary's environment name, in milliseconds.
pub const DEPTH_IDLE_MS_KEY: &str = "SLOPDESK_DEPTH_IDLE_MS";
/// The late slack's environment name, in percent of the interval.
pub const DEPTH_LATE_SLACK_PCT_KEY: &str = "SLOPDESK_DEPTH_LATE_SLACK_PCT";
/// The dwell tolerance's environment name.
pub const DEPTH_DEMOTE_TOLERANCE_KEY: &str = "SLOPDESK_DEPTH_DEMOTE_TOLERANCE";
/// The promote warm-up's environment name, in milliseconds.
pub const DEPTH_WARMUP_MS_KEY: &str = "SLOPDESK_DEPTH_WARMUP_MS";

impl PacerDepthConfig {
    /// Parses the operating point from the raw environment values, each clamped to a sane band. An
    /// absent, unparseable or non-finite value keeps the default.
    #[must_use]
    pub fn from_env(env: PacerDepthEnv<'_>) -> Self {
        let mut config = Self::default();
        for (key, value) in [
            (DEPTH_PROMOTE_LATES_KEY, env.promote_lates),
            (DEPTH_PROMOTE_WINDOW_MS_KEY, env.promote_window_ms),
            (DEPTH_DEMOTE_MS_KEY, env.demote_ms),
            (DEPTH_MIN_HOLD_MS_KEY, env.min_hold_ms),
            (DEPTH_LATE_FACTOR_KEY, env.late_factor),
            (DEPTH_IDLE_MS_KEY, env.idle_ms),
            (DEPTH_LATE_SLACK_PCT_KEY, env.late_slack_pct),
            (DEPTH_DEMOTE_TOLERANCE_KEY, env.demote_tolerance),
            (DEPTH_WARMUP_MS_KEY, env.warmup_ms),
        ] {
            if let Some(text) = value {
                config.apply_env_pair(key, text);
            }
        }
        config
    }

    /// Applies ONE environment pair, which is how a caller holding a whole environment map reaches
    /// the same bands without knowing which knob answers to which name.
    ///
    /// An unknown key, an unparseable value and a non-finite one all leave the config untouched.
    pub fn apply_env_pair(&mut self, key: &str, value: &str) {
        // The ring's capacity is the ceiling on both late counts: a promote count above it could
        // never be satisfied, and a tolerance at it would block every demote.
        let capacity = i64::try_from(LATE_RING_CAPACITY).unwrap_or(4);
        match key {
            DEPTH_PROMOTE_LATES_KEY => {
                if let Some(parsed) = integer_text(value) {
                    self.promote_late_count = usize::try_from(parsed.clamp(1, capacity)).unwrap_or(1);
                }
            },
            DEPTH_PROMOTE_WINDOW_MS_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.promote_window_seconds = (parsed / 1000.0).clamp(0.1, 10.0);
                }
            },
            DEPTH_DEMOTE_MS_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.demote_clean_seconds = (parsed / 1000.0).clamp(0.5, 30.0);
                }
            },
            DEPTH_MIN_HOLD_MS_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.min_hold_seconds = (parsed / 1000.0).clamp(0.0, 10.0);
                }
            },
            DEPTH_LATE_FACTOR_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.late_gap_factor = parsed.clamp(1.1, 4.0);
                }
            },
            DEPTH_IDLE_MS_KEY => {
                if let Some(parsed) = finite_text(value) {
                    // Raise this if a host-side recovery cooldown pushes the worst case past it.
                    self.idle_gap_seconds = (parsed / 1000.0).clamp(0.1, 2.0);
                }
            },
            DEPTH_LATE_SLACK_PCT_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.late_slack_fraction = parsed.clamp(0.0, 100.0) / 100.0;
                }
            },
            DEPTH_DEMOTE_TOLERANCE_KEY => {
                if let Some(parsed) = integer_text(value) {
                    self.demote_tolerance_lates = usize::try_from(parsed.clamp(0, capacity - 1)).unwrap_or(0);
                }
            },
            DEPTH_WARMUP_MS_KEY => {
                if let Some(parsed) = finite_text(value) {
                    self.promote_warmup_seconds = (parsed / 1000.0).clamp(0.0, 30.0);
                }
            },
            _ => {},
        }
    }
}

/// The gap classifier and the depth policy, driven by network-late events.
///
/// Promotion takes the configured number of late events inside the promote window and moves the
/// depth from one to the boosted depth, never higher. Demotion takes a clean-enough dwell, and no
/// sooner than the minimum hold since the promotion. The counters always run, because telemetry is
/// unconditional; only the depth ACTION is gated by whether adaptation is enabled at all.
#[derive(Debug, Clone, PartialEq)]
pub struct PacerDepthPolicy {
    config: PacerDepthConfig,
    adapt_enabled: bool,
    depth: u32,
    last_arrival: Option<f64>,
    arrival_ring: Vec<f64>,
    interval_ring: Vec<f64>,
    /// The frame-rate governor's seam: it overrides the estimator while it is set.
    interval_hint: Option<f64>,
    last_present_at: Option<f64>,
    prev_present_gap: Option<f64>,
    late_times: Vec<f64>,
    /// When the last promotion happened. `None` is "never", which no minimum hold can block.
    promoted_at: Option<f64>,
    /// The stream's start, which is the FIRST arrival.
    stream_start_at: Option<f64>,
    /// Latched once a re-show opens a gap episode, so an episode counts exactly once however many
    /// re-shows span it.
    gap_episode_open: bool,
    late_count: u32,
    gap_count: u32,
}

impl PacerDepthPolicy {
    /// A policy at the given operating point. Adaptation off leaves the depth at one forever while
    /// every counter keeps running.
    #[must_use]
    pub const fn new(config: PacerDepthConfig, adapt_enabled: bool) -> Self {
        Self {
            config,
            adapt_enabled,
            depth: 1,
            last_arrival: None,
            arrival_ring: Vec::new(),
            interval_ring: Vec::new(),
            interval_hint: None,
            last_present_at: None,
            prev_present_gap: None,
            late_times: Vec::new(),
            promoted_at: None,
            stream_start_at: None,
            gap_episode_open: false,
            late_count: 0,
            gap_count: 0,
        }
    }

    /// The recommended presentation depth.
    #[must_use]
    pub const fn depth(&self) -> u32 {
        self.depth
    }

    /// The expected content interval: the hint when set, else the median of the in-flow ring once
    /// it has warmed, else the default — clamped to a sane band either way.
    ///
    /// The median rather than the minimum or the mean, because at the boosted depth presents and
    /// arrivals can alternate around the tick quantisation: the median stays at the true content
    /// interval where the minimum would collapse and over-detect.
    #[must_use]
    pub fn expected_interval_seconds(&self) -> f64 {
        let raw = self.interval_hint.unwrap_or_else(|| {
            if self.interval_ring.len() >= self.config.min_samples_for_estimate {
                median(&self.interval_ring, self.config.default_interval_seconds)
            } else {
                self.config.default_interval_seconds
            }
        });
        raw.max(self.config.min_interval_seconds)
            .min(self.config.max_interval_seconds)
    }

    /// The late boundary, with the slack term sitting ON TOP of the base boundary so arrivals a few
    /// milliseconds past the bare boundary at dense flow stop classifying late.
    #[must_use]
    pub fn late_threshold_seconds(&self) -> f64 {
        let expected = self.expected_interval_seconds();
        // BIT-EXACT: two distinct multiplies and one add, never a fused one.
        self.config
            .absolute_late_floor_seconds
            .max(self.config.late_gap_factor * expected)
            + self.config.late_slack_fraction * expected
    }

    /// Folds one decoded-frame submit, in client-monotonic seconds.
    ///
    /// It also evaluates the demote, so a post-idle resume demotes BEFORE the pacer re-primes and
    /// avoids one extra held frame at the resume.
    pub fn note_arrival(&mut self, now: f64) {
        if self.stream_start_at.is_none() {
            self.stream_start_at = Some(now);
        }
        if let Some(last) = self.last_arrival {
            let gap = now - last;
            if gap > 0.0 && gap <= self.config.idle_gap_seconds {
                push_capped(&mut self.interval_ring, gap, self.config.interval_ring_size);
            }
        }
        push_capped(&mut self.arrival_ring, now, ARRIVAL_RING_CAPACITY);
        self.last_arrival = Some(now);
        self.evaluate_demote(now);
    }

    /// Folds one content present and classifies its gap.
    ///
    /// Late requires all of: past the late boundary, dense flow when the gap opened, and a sharp
    /// step up from the previous in-flow gap. The verdict is diagnostic only — a present-gap late
    /// neither counts nor promotes, because that would reintroduce the cadence-hint pinning.
    pub fn note_present(&mut self, now: f64) -> GapClass {
        let Some(last) = self.last_present_at else {
            self.last_present_at = Some(now);
            return GapClass::First;
        };
        let gap = now - last;
        if gap > self.config.idle_gap_seconds {
            // A host idle-skip or a motion stop: never late, and the next in-flow gap must not be
            // gradient-compared against this idle span.
            self.gap_episode_open = false;
            self.prev_present_gap = None;
            self.last_present_at = Some(now);
            self.evaluate_demote(now);
            return GapClass::Idle;
        }
        // BIT-EXACT: the gradient factor and the previous gap multiply on their own.
        let gradient_ok = self
            .prev_present_gap
            .is_none_or(|prev| gap >= self.config.gap_gradient_factor * prev);
        let is_late = gap > self.late_threshold_seconds() && gradient_ok && self.was_dense(last);
        // Any present closes an open re-show episode.
        self.gap_episode_open = false;
        self.prev_present_gap = Some(gap);
        self.last_present_at = Some(now);
        self.evaluate_demote(now);
        if is_late { GapClass::Late } else { GapClass::Normal }
    }

    /// Folds one NETWORK-late event, which the spike detector flagged.
    ///
    /// This is THE promotion input and the demote dwell's content. It also lands in the windowed
    /// telemetry, so the wire's late field reports the promotion-relevant signal rather than a
    /// second, unrelated one.
    pub fn note_network_late(&mut self, now: f64) {
        self.late_count = self.late_count.saturating_add(1);
        push_capped(&mut self.late_times, now, LATE_RING_CAPACITY);
        self.evaluate_promote(now);
    }

    /// Folds one empty-queue re-show tick.
    ///
    /// It counts a late-gap EPISODE, once, the moment the open gap crosses the late boundary — so
    /// the hitch is counted AS IT HAPPENS even if no frame ever resolves it. Promotion never reads
    /// this counter, so a motion-stop boundary cannot promote.
    pub fn note_reshow(&mut self, now: f64) {
        let Some(last) = self.last_present_at else { return };
        if self.gap_episode_open {
            return;
        }
        let open_gap = now - last;
        if open_gap > self.late_threshold_seconds()
            && open_gap <= self.config.idle_gap_seconds
            && self.was_dense(last)
        {
            self.gap_count = self.gap_count.saturating_add(1);
            self.gap_episode_open = true;
        }
    }

    /// Reads and resets the windowed counters — one drain per network stats report.
    pub const fn drain_counters(&mut self) -> PacerTelemetrySnapshot {
        let snapshot = PacerTelemetrySnapshot {
            late_frames: self.late_count,
            present_gaps: self.gap_count,
            depth: self.depth,
        };
        self.late_count = 0;
        self.gap_count = 0;
        snapshot
    }

    /// The frame-rate governor's seam: a host cadence message pins the expected interval, which
    /// rebases the late boundary instantly instead of waiting out the estimator's transient. A
    /// missing, non-finite or non-positive value returns to the estimator.
    pub fn set_interval_hint(&mut self, seconds: Option<f64>) {
        self.interval_hint = seconds.filter(|value| value.is_finite() && *value > 0.0);
    }

    /// The dense-flow gate: enough arrivals inside the window before the moment the gap OPENED.
    /// Arrivals after that moment must not count.
    fn was_dense(&self, at: f64) -> bool {
        let window_start = at - self.config.dense_window_seconds;
        let count = self
            .arrival_ring
            .iter()
            .filter(|&&arrival| arrival > window_start && arrival <= at)
            .count();
        count >= self.config.dense_min_arrivals
    }

    fn evaluate_promote(&mut self, now: f64) {
        if !self.adapt_enabled || self.depth != 1 {
            return;
        }
        // The cold-start guard. Bring-up produces transient shapes that look late; the DECISION is
        // ignored until the warmup elapses, never the counters.
        let Some(start) = self.stream_start_at else { return };
        if now - start < self.config.promote_warmup_seconds {
            return;
        }
        let window_start = now - self.config.promote_window_seconds;
        let recent = self.late_count_within(window_start, now, true);
        if recent >= self.config.promote_late_count {
            self.depth = self.config.boost_depth.max(2);
            self.promoted_at = Some(now);
        }
    }

    fn evaluate_demote(&mut self, now: f64) {
        if self.depth <= 1 {
            return;
        }
        if let Some(promoted) = self.promoted_at
            && now - promoted < self.config.min_hold_seconds
        {
            return;
        }
        // The dwell demotes when the trailing window holds at most the tolerated count. A zero
        // tolerance is exactly a strict "nothing since the dwell began", because the newest late is
        // always in the capped ring.
        let window_start = now - self.config.demote_clean_seconds;
        let recent = self.late_count_within(window_start, now, false);
        if recent <= self.config.demote_tolerance_lates {
            self.depth = 1;
        }
    }

    /// How many late events sit in a trailing window. The promote window includes its start, the
    /// demote window excludes it — the two boundaries the Swift original distinguishes.
    fn late_count_within(&self, window_start: f64, now: f64, inclusive_start: bool) -> usize {
        self.late_times
            .iter()
            .filter(|&&at| {
                let after = if inclusive_start {
                    at >= window_start
                } else {
                    at > window_start
                };
                after && at <= now
            })
            .count()
    }

    /// Every field the next fold reads, for a caller that carries the policy BY VALUE across a
    /// boundary rather than holding it.
    ///
    /// The rings travel as fixed-capacity arrays because that is what a by-value crossing can
    /// carry. Each is already capped at that capacity by the folds that fill it, so the
    /// oldest-first truncation here is unreachable in practice and only keeps the function
    /// total.
    #[must_use]
    pub fn snapshot(&self) -> PacerDepthSnapshot {
        let (arrivals, arrival_len) = ring_out(&self.arrival_ring);
        let (intervals, interval_len) = ring_out(&self.interval_ring);
        let (lates, late_len) = ring_out(&self.late_times);
        PacerDepthSnapshot {
            config: self.config,
            adapt_enabled: self.adapt_enabled,
            depth: self.depth,
            last_arrival: self.last_arrival,
            arrivals,
            arrival_len,
            intervals,
            interval_len,
            interval_hint: self.interval_hint,
            last_present_at: self.last_present_at,
            prev_present_gap: self.prev_present_gap,
            lates,
            late_len,
            promoted_at: self.promoted_at,
            stream_start_at: self.stream_start_at,
            gap_episode_open: self.gap_episode_open,
            late_count: self.late_count,
            gap_count: self.gap_count,
        }
    }

    /// The policy that snapshot describes. It is the inverse of [`Self::snapshot`], so a fold
    /// across the boundary is the fold this side would have run.
    #[must_use]
    pub fn restored(snapshot: PacerDepthSnapshot) -> Self {
        let mut config = snapshot.config;
        // A ring that keeps more than the crossing can carry would lose its oldest entry on every
        // trip, so the kept size is capped at the carried capacity rather than silently truncated.
        config.interval_ring_size = config.interval_ring_size.min(INTERVAL_RING_CAPACITY);
        Self {
            config,
            adapt_enabled: snapshot.adapt_enabled,
            depth: snapshot.depth,
            last_arrival: snapshot.last_arrival,
            arrival_ring: ring_in(&snapshot.arrivals, snapshot.arrival_len),
            interval_ring: ring_in(&snapshot.intervals, snapshot.interval_len),
            interval_hint: snapshot.interval_hint,
            last_present_at: snapshot.last_present_at,
            prev_present_gap: snapshot.prev_present_gap,
            late_times: ring_in(&snapshot.lates, snapshot.late_len),
            promoted_at: snapshot.promoted_at,
            stream_start_at: snapshot.stream_start_at,
            gap_episode_open: snapshot.gap_episode_open,
            late_count: snapshot.late_count,
            gap_count: snapshot.gap_count,
        }
    }
}

/// The policy's whole state, for a by-value crossing.
///
/// The rings are the reason this type exists: a promote window and a dense-flow gate both read
/// TIMES rather than counts, so a caller that carried only the counters would fold against windows
/// that never happened.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PacerDepthSnapshot {
    /// The operating point, which travels with the state so the far side needs no second copy.
    pub config: PacerDepthConfig,
    /// Whether the depth ACTION runs at all. The counters run either way.
    pub adapt_enabled: bool,
    /// The live depth.
    pub depth: u32,
    /// The last arrival, which the next in-flow gap steps from.
    pub last_arrival: Option<f64>,
    /// The dense-flow ring, oldest first.
    pub arrivals: [f64; ARRIVAL_RING_CAPACITY],
    /// How many of the arrival ring's slots are live.
    pub arrival_len: usize,
    /// The in-flow inter-arrival gaps the interval estimator holds, oldest first.
    pub intervals: [f64; INTERVAL_RING_CAPACITY],
    /// How many of the interval ring's slots are live.
    pub interval_len: usize,
    /// The governor's cadence pin, when one is set.
    pub interval_hint: Option<f64>,
    /// The last content present.
    pub last_present_at: Option<f64>,
    /// The previous in-flow present gap, which the gradient test compares against.
    pub prev_present_gap: Option<f64>,
    /// The late-event ring, oldest first.
    pub lates: [f64; LATE_RING_CAPACITY],
    /// How many of the late ring's slots are live.
    pub late_len: usize,
    /// When the last promotion happened.
    pub promoted_at: Option<f64>,
    /// The stream's first arrival, which the promote warm-up measures from.
    pub stream_start_at: Option<f64>,
    /// Whether a re-show episode is open and therefore already counted.
    pub gap_episode_open: bool,
    /// The windowed late counter.
    pub late_count: u32,
    /// The windowed gap-episode counter.
    pub gap_count: u32,
}

/// Copies a ring into its carried array, keeping the NEWEST entries when it somehow overflows —
/// the same end the fold's own capping drops from.
fn ring_out<const N: usize>(values: &[f64]) -> ([f64; N], usize) {
    let mut carried = [0.0; N];
    let start = values.len().saturating_sub(N);
    let mut len = 0;
    for (slot, value) in carried.iter_mut().zip(values.iter().skip(start)) {
        *slot = *value;
        len += 1;
    }
    (carried, len)
}

/// Reads a carried array back into a ring, ignoring the slots the length does not claim.
fn ring_in<const N: usize>(carried: &[f64; N], len: usize) -> Vec<f64> {
    carried.iter().copied().take(len.min(N)).collect()
}

/// The median of a small ring. Sorting is nothing at fifteen entries, and the fallback cannot be
/// reached in practice — the caller gates on the warm-up count first.
fn median(values: &[f64], fallback: f64) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    #[expect(
        clippy::integer_division,
        reason = "the upper-median index, which is what the Swift original's truncating divide picks"
    )]
    let index = sorted.len() / 2;
    sorted.get(index).copied().unwrap_or(fallback)
}

/// Appends to a ring, dropping from the front once it is over capacity.
fn push_capped(ring: &mut Vec<f64>, value: f64, capacity: usize) {
    ring.push(value);
    if ring.len() > capacity {
        let excess = ring.len() - capacity;
        ring.drain(..excess);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the intervals and thresholds are compared against their own pinned constants"
    )]

    use super::{
        GapClass, OwdLateConfig, OwdLateDetector, PacerDepthConfig, PacerDepthEnv, PacerDepthPolicy,
    };

    /// The detector past its warm-up on a flat path, so the baseline is a known zero.
    fn warmed() -> OwdLateDetector {
        let mut detector = OwdLateDetector::default();
        for step in 0..20_u32 {
            let at = f64::from(step) * 16.0;
            assert_eq!(
                detector.note(at, step * 16, 16.0),
                None,
                "a flat path is never late"
            );
        }
        detector
    }

    #[test]
    fn a_spike_past_the_floor_reports_how_far_past_it_sat() {
        let mut detector = warmed();
        // The floor is twenty-five milliseconds and the interval term is twenty; the floor wins.
        assert_eq!(detector.note(320.0 + 40.0, 20 * 16, 16.0), Some(15.0));
    }

    #[test]
    fn a_spike_inside_the_floor_is_the_pacers_own_wobble_and_never_late() {
        let mut detector = warmed();
        assert_eq!(detector.note(320.0 + 20.0, 20 * 16, 16.0), None);
    }

    #[test]
    fn the_interval_term_takes_over_at_a_governed_down_frame_rate() {
        let mut detector = warmed();
        // A hundred-millisecond interval puts the threshold at a hundred and twenty-five.
        assert_eq!(detector.note(320.0 + 100.0, 20 * 16, 100.0), None);
        assert_eq!(detector.note(320.0 + 200.0, 21 * 16, 100.0), Some(59.0));
    }

    #[test]
    fn the_warmup_swallows_every_bring_up_transient() {
        let mut detector = OwdLateDetector::default();
        for step in 0..19_u32 {
            assert_eq!(detector.note(f64::from(step) * 200.0, step * 16, 16.0), None);
        }
    }

    #[test]
    fn a_standing_queue_re_bases_within_a_bucket_rotation() {
        let mut detector = warmed();
        let mut at = 320.0;
        // The path steps up by eighty milliseconds and stays there. Two bucket rotations — four
        // seconds — is what it takes for the old level to age out of both buckets.
        for step in 20..300_u32 {
            at += 16.0;
            detector.note(at + 80.0, step * 16, 16.0);
        }
        assert!(at > 4000.0, "the sweep spans two rotations");
        at += 16.0;
        assert_eq!(
            detector.note(at + 80.0, 300 * 16, 16.0),
            None,
            "the new level became the baseline rather than a permanent late",
        );
    }

    #[test]
    fn the_stamp_unwrap_survives_the_wire_wrap() {
        let mut detector = OwdLateDetector::new(OwdLateConfig {
            warmup_samples: 1,
            ..OwdLateConfig::default()
        });
        assert_eq!(detector.note(0.0, u32::MAX - 15, 16.0), None);
        assert_eq!(
            detector.note(16.0, 0, 16.0),
            None,
            "sixteen forward across the wrap"
        );
        assert_eq!(detector.note(32.0 + 60.0, 16, 16.0), Some(35.0));
    }

    /// A policy warmed past the promote guard with a dense arrival flow behind it.
    fn primed(adapt: bool) -> (PacerDepthPolicy, f64) {
        let mut policy = PacerDepthPolicy::new(PacerDepthConfig::default(), adapt);
        let mut now = 0.0;
        for _ in 0..200 {
            now += 1.0 / 60.0;
            policy.note_arrival(now);
            policy.note_present(now);
        }
        (policy, now)
    }

    #[test]
    fn two_network_lates_inside_the_window_pay_one_frame_of_slack() {
        let (mut policy, now) = primed(true);
        assert_eq!(policy.depth(), 1);
        policy.note_network_late(now);
        assert_eq!(policy.depth(), 1, "one late is not a pattern");
        policy.note_network_late(now + 0.1);
        assert_eq!(policy.depth(), 2);
    }

    #[test]
    fn the_boost_is_refunded_after_a_clean_dwell_but_never_before_the_hold() {
        let (mut policy, now) = primed(true);
        policy.note_network_late(now);
        policy.note_network_late(now + 0.1);
        assert_eq!(policy.depth(), 2);
        policy.note_arrival(now + 0.5);
        assert_eq!(policy.depth(), 2, "inside the anti-flap hold");
        policy.note_arrival(now + 2.7);
        assert_eq!(policy.depth(), 1);
    }

    #[test]
    fn a_lone_late_inside_the_dwell_is_tolerated_rather_than_re_arming_it() {
        let (mut policy, now) = primed(true);
        policy.note_network_late(now);
        policy.note_network_late(now + 0.1);
        policy.note_network_late(now + 2.0);
        policy.note_arrival(now + 2.7);
        assert_eq!(policy.depth(), 1, "one late in the trailing window still demotes");
    }

    #[test]
    fn the_warmup_gates_the_action_and_never_the_counters() {
        let mut policy = PacerDepthPolicy::new(PacerDepthConfig::default(), true);
        policy.note_arrival(0.0);
        policy.note_network_late(0.1);
        policy.note_network_late(0.2);
        assert_eq!(policy.depth(), 1, "bring-up transients must not promote");
        let drained = policy.drain_counters();
        assert_eq!(drained.late_frames, 2, "but they are still reported");
        assert_eq!(drained.depth, 1);
    }

    #[test]
    fn adaptation_off_still_counts_everything_it_would_have_acted_on() {
        let (mut policy, now) = primed(false);
        policy.note_network_late(now);
        policy.note_network_late(now + 0.1);
        assert_eq!(policy.depth(), 1);
        assert_eq!(policy.drain_counters().late_frames, 2);
        assert_eq!(
            policy.drain_counters().late_frames,
            0,
            "the drain resets the window"
        );
    }

    #[test]
    fn an_idle_gap_classifies_as_idle_and_clears_the_gradient_reference() {
        let (mut policy, now) = primed(true);
        assert_eq!(policy.note_present(now + 1.0), GapClass::Idle);
        assert_eq!(
            policy.note_present(now + 1.0 + 0.05),
            GapClass::Normal,
            "no reference to step from"
        );
    }

    #[test]
    fn a_skipped_slot_at_dense_flow_classifies_late() {
        let (mut policy, now) = primed(true);
        assert_eq!(policy.note_present(now + 0.1), GapClass::Late);
    }

    #[test]
    fn a_late_gap_episode_counts_once_however_many_re_shows_span_it() {
        let (mut policy, now) = primed(true);
        policy.note_reshow(now + 0.05);
        policy.note_reshow(now + 0.06);
        policy.note_reshow(now + 0.07);
        assert_eq!(policy.drain_counters().present_gaps, 1);
    }

    #[test]
    fn the_first_present_has_no_gap_to_classify() {
        let mut policy = PacerDepthPolicy::new(PacerDepthConfig::default(), true);
        assert_eq!(policy.note_present(0.0), GapClass::First);
    }

    /// The accumulated arrivals land a few units in the last place off a clean sixtieth.
    fn about(value: f64, expected: f64) -> bool {
        (value - expected).abs() < 1e-9
    }

    #[test]
    fn the_cadence_hint_rebases_the_boundary_without_waiting_for_the_estimator() {
        let (mut policy, _) = primed(true);
        assert!(about(policy.expected_interval_seconds(), 1.0 / 60.0));
        policy.set_interval_hint(Some(1.0 / 30.0));
        assert_eq!(policy.expected_interval_seconds(), 1.0 / 30.0);
        assert!(policy.late_threshold_seconds() > 0.028);
        policy.set_interval_hint(Some(f64::NAN));
        assert!(
            about(policy.expected_interval_seconds(), 1.0 / 60.0),
            "back to the estimator",
        );
        policy.set_interval_hint(Some(-1.0));
        assert!(about(policy.expected_interval_seconds(), 1.0 / 60.0));
    }

    #[test]
    fn the_expected_interval_is_clamped_to_its_band() {
        let mut policy = PacerDepthPolicy::new(PacerDepthConfig::default(), true);
        policy.set_interval_hint(Some(10.0));
        assert_eq!(policy.expected_interval_seconds(), 1.0 / 10.0);
        policy.set_interval_hint(Some(0.0001));
        assert_eq!(policy.expected_interval_seconds(), 1.0 / 240.0);
    }

    #[test]
    fn sparse_flow_never_classifies_late_however_long_the_gap() {
        let mut policy = PacerDepthPolicy::new(PacerDepthConfig::default(), true);
        let mut now = 0.0;
        // Sixteen-per-second content: only five arrivals fall inside the dense window, well under
        // the eight the gate wants.
        for _ in 0..10 {
            now += 0.06;
            policy.note_arrival(now);
            policy.note_present(now);
        }
        assert_eq!(
            policy.note_present(now + 0.15),
            GapClass::Normal,
            "typing is not a hitch"
        );
    }

    #[test]
    fn the_environment_clamps_every_band_and_keeps_the_default_otherwise() {
        let tuned = PacerDepthConfig::from_env(PacerDepthEnv {
            promote_lates: Some("9"),
            promote_window_ms: Some("500"),
            demote_ms: Some("100"),
            late_slack_pct: Some("400"),
            demote_tolerance: Some("7"),
            warmup_ms: Some("nonsense"),
            ..PacerDepthEnv::default()
        });
        assert_eq!(tuned.promote_late_count, 4, "the ring's capacity is the ceiling");
        assert_eq!(tuned.promote_window_seconds, 0.5);
        assert_eq!(tuned.demote_clean_seconds, 0.5, "the floor holds");
        assert_eq!(tuned.late_slack_fraction, 1.0);
        assert_eq!(tuned.demote_tolerance_lates, 3);
        assert_eq!(tuned.promote_warmup_seconds, 2.0);
        assert_eq!(
            PacerDepthConfig::from_env(PacerDepthEnv::default()),
            PacerDepthConfig::default()
        );
    }

    #[test]
    fn the_late_environment_clamps_its_own_bands() {
        let tuned = OwdLateConfig::from_env(Some("1000"), Some("50"), Some("0"));
        assert_eq!(tuned.threshold_floor_ms, 200.0);
        assert_eq!(tuned.threshold_interval_fraction, 0.5);
        assert_eq!(tuned.warmup_samples, 1);
        assert_eq!(
            OwdLateConfig::from_env(None, None, None),
            OwdLateConfig::default()
        );
    }
}
