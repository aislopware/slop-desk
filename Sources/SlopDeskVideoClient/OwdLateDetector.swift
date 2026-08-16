import CSlopDeskFFI

/// Per-frame one-way-delay SPIKE detector — the promotion signal for the pacer's adaptive 1↔2
/// depth boost.
///
/// A present-gap "late" classifier (comparing CONTENT-PRESENT gaps against the cadence hint) is
/// avoided: natural sub-cadence content (VS Code idle repaint ~40 fps under a 60 fps hint) makes
/// every gap clear the late boundary — late=1 in every 50 ms report at ALL flow densities, pinning
/// the depth at 2 (+17 ms standing latency) for the vast majority of a session. That's structural,
/// not a tuning problem: arrival GAPS conflate "the network delivered late" with "the host simply
/// didn't produce a frame".
///
/// The signal depth actually absorbs is NETWORK DELAY VARIATION: a frame whose one-way delay
/// spikes past the path's baseline would miss its present slot at depth 1; a standing slack frame
/// (depth 2) covers it. So "late" is measured where it happens — on the wire stamp, not the
/// present clock:
///
///     owd_i  = arrival_i (client clock, ms) − send_i (host stamp, ms)   // offset-skewed, fine
///     late_i = owd_i − baseline > max(floorMs, fraction × frameInterval)
///
/// The cross-machine clock offset is CONSTANT over the window, so it cancels against the
/// baseline (the same discipline as `OWDJitterEstimator` / `TrendlineEstimator`). The baseline is
/// a two-bucket rolling MIN (~`2×bucketMs` of history): spikes can never raise it (min is
/// outlier-proof upward), while a genuine path change re-bases within one bucket rotation — a
/// standing queue becomes the new normal (the ABR's job), and only VARIATION above it counts
/// (the depth's job). Content gaps don't matter to a min-baseline, so the FPS governor / idle
/// skips never produce false lates — the present-gap failure mode is structurally impossible here.
///
/// Measured at ARRIVAL, independent of presentation depth — promotion can't self-sustain at
/// depth 2 via its own pinning loop, so demote-on-clean actually happens.
///
/// The law itself is `rust/slopdesk-video`'s `pacer_depth`; this is its face. The detector is a
/// value its owner copies out, folds into and writes back, so it crosses BY VALUE — the whole
/// state travels on every sample, because a baseline is a rolling minimum over samples this side
/// no longer holds (`docs/55-ffi-boundary.md` §4b).
public struct OwdLateDetector: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        private var state: SlopDeskOwdLateConfig

        /// The record as the detector reads it.
        var crossing: SlopDeskOwdLateConfig { state }

        public init() { state = slopdesk_owd_late_config_default() }

        /// Baseline bucket span (ms). Baseline = min(current bucket, previous bucket) ⇒ effective
        /// history 1–2 buckets. Long enough to straddle multi-frame bursts (a whole burst must not
        /// instantly become the baseline), short enough to track a real path change within ~4 s.
        public var bucketMs: Double {
            get { state.bucket_ms }
            set { state.bucket_ms = newValue }
        }

        /// Absolute spike floor (ms). The send stamp is minted at PACKETIZE time, BEFORE the
        /// VideoSendLane pacer — so big-frame serialization + queue-behind-a-big-predecessor shows
        /// up as 10-20ms of owd wobble during dense scroll; a 10ms floor lets that self-inflicted
        /// wobble alone trigger 153 "lates"/90s with depth flapping 1↔2. 25ms sits above that
        /// pacing band, while a genuine network burst that threatens presents (the >28ms stutter
        /// class) still clears it. `SLOPDESK_OWD_LATE_FLOOR_MS`.
        public var thresholdFloorMs: Double {
            get { state.threshold_floor_ms }
            set { state.threshold_floor_ms = newValue }
        }

        /// Interval-proportional component: a spike beyond this fraction of the content frame
        /// interval risks losing more than the one slot depth 2 buys back (1.25 × interval at a
        /// governed-down fps keeps the threshold meaningfully above the bigger frame spacing).
        /// `SLOPDESK_OWD_LATE_FRAC_PCT` (0...400, percent).
        public var thresholdIntervalFraction: Double {
            get { state.threshold_interval_fraction }
            set { state.threshold_interval_fraction = newValue }
        }

        /// Samples required before any late verdict — the baseline needs population first
        /// (connection bring-up transients must not promote; pairs with the policy's warmup).
        public var warmupSamples: Int {
            get { state.warmup_samples }
            set { state.warmup_samples = newValue }
        }

        /// Env-tunable construction (absent/unparseable ⇒ default), clamped to sane bands. Every
        /// band and every `SLOPDESK_OWD_LATE_*` name lives behind the door, so this hands the whole
        /// environment over one pair at a time and lets the law recognise its own knobs. The knobs
        /// are independent, so the dictionary's arbitrary order cannot change the answer.
        public static func fromEnvironment(_ env: [String: String]) -> Self {
            var config = Self()
            for (key, value) in env {
                config.state = apply(config.state, key, value)
            }
            return config
        }

        /// One environment pair through the door.
        private static func apply(
            _ config: SlopDeskOwdLateConfig,
            _ key: String,
            _ value: String,
        ) -> SlopDeskOwdLateConfig {
            var key = key
            var value = value
            return key.withUTF8 { keyBytes in
                value.withUTF8 { valueBytes in
                    slopdesk_owd_late_config_apply(
                        config, keyBytes.baseAddress, keyBytes.count,
                        valueBytes.baseAddress, valueBytes.count,
                    )
                }
            }
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.state.bucket_ms == rhs.state.bucket_ms
                && lhs.state.threshold_floor_ms == rhs.state.threshold_floor_ms
                && lhs.state.threshold_interval_fraction == rhs.state.threshold_interval_fraction
                && lhs.state.warmup_samples == rhs.state.warmup_samples
        }
    }

    private var state: SlopDeskOwdLate

    public init(config: Config = Config()) {
        state = slopdesk_owd_late_new(config.crossing)
    }

    /// Folds one per-frame sample (the caller admits one per strictly-newer frameID via
    /// `TrendSampler`, so reorder/kfDup/ts==0 never reach here). Returns the deviation above
    /// threshold (ms) when the sample is a network-late spike, else `nil`.
    public mutating func note(arrivalMs: Double, sendTs: UInt32, intervalMs: Double) -> Double? {
        let note = slopdesk_owd_late_note(state, arrivalMs, sendTs, intervalMs)
        state = note.detector
        return note.has_deviation ? note.deviation_ms : nil
    }

    /// Two detectors are equal when every field the next fold reads agrees — the baseline's two
    /// bucket minima included, since a detector that agreed on its verdicts but not on those would
    /// diverge on the next sample.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.unwrapped_send_ms == rhs.state.unwrapped_send_ms
            && lhs.state.has_prev_send_ts == rhs.state.has_prev_send_ts
            && lhs.state.prev_send_ts == rhs.state.prev_send_ts
            && lhs.state.current_bucket_min == rhs.state.current_bucket_min
            && lhs.state.previous_bucket_min == rhs.state.previous_bucket_min
            && lhs.state.has_bucket_start == rhs.state.has_bucket_start
            && lhs.state.bucket_start_arrival_ms == rhs.state.bucket_start_arrival_ms
            && lhs.state.samples == rhs.state.samples
            && lhs.state.config.bucket_ms == rhs.state.config.bucket_ms
            && lhs.state.config.threshold_floor_ms == rhs.state.config.threshold_floor_ms
            && lhs.state.config.threshold_interval_fraction
            == rhs.state.config.threshold_interval_fraction
            && lhs.state.config.warmup_samples == rhs.state.config.warmup_samples
    }
}
