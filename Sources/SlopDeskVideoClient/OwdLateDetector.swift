import Foundation
import SlopDeskVideoProtocol

/// Depth v3 (2026-06-12): per-frame one-way-delay SPIKE detector — the promotion signal for the
/// pacer's adaptive 1↔2 depth boost.
///
/// WHY (replaces the present-gap "late" classifier): the v2 classifier compared CONTENT-PRESENT
/// gaps against the cadence hint, but natural sub-cadence content (VS Code idle repaint ~40 fps
/// under a 60 fps hint) makes every gap clear the late boundary — measured live (FPT↔Viettel):
/// late=1 in every 50 ms report at ALL flow densities, pinning the depth at 2 (+17 ms standing
/// latency) for 99.6% of the session. Structural, not a tuning problem: arrival GAPS conflate
/// "the network delivered late" with "the host simply didn't produce a frame".
///
/// The signal depth actually absorbs is NETWORK DELAY VARIATION: a frame whose one-way delay
/// spikes past the path's baseline would miss its present slot at depth 1; a standing slack frame
/// (depth 2) covers it. So "late" is now measured where it happens — on the wire stamp, not the
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
/// skips never produce false lates — the v2 failure mode is structurally impossible here.
///
/// KEY PROPERTY vs v2: measured at ARRIVAL, independent of presentation depth — promotion can't
/// self-sustain at depth 2 (the v2 pinning loop), so demote-on-clean actually happens.
///
/// PURE + deterministic: caller injects every sample; headlessly unit-testable.
public struct OwdLateDetector: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Baseline bucket span (ms). Baseline = min(current bucket, previous bucket) ⇒ effective
        /// history 1–2 buckets. Long enough to straddle multi-frame bursts (a whole burst must not
        /// instantly become the baseline), short enough to track a real path change within ~4 s.
        public var bucketMs: Double = 2000
        /// Absolute spike floor (ms). MEASURED LIVE (2026-06-12, first deploy at 10ms): the send
        /// stamp is minted at PACKETIZE time, BEFORE the VideoSendLane pacer — so big-frame
        /// serialization + queue-behind-a-big-predecessor shows up as 10-20ms of owd wobble
        /// during dense scroll (153 "lates"/90s, depth flapping 1↔2). 25ms sits above that
        /// self-inflicted pacing band; a genuine network burst that threatens presents (the
        /// >28ms KHỰNG class) still clears it. `SLOPDESK_OWD_LATE_FLOOR_MS`.
        public var thresholdFloorMs: Double = 25
        /// Interval-proportional component: a spike beyond this fraction of the content frame
        /// interval risks losing more than the one slot depth 2 buys back (1.25 × interval at a
        /// governed-down fps keeps the threshold meaningfully above the bigger frame spacing).
        /// `SLOPDESK_OWD_LATE_FRAC_PCT` (0...400, percent).
        public var thresholdIntervalFraction: Double = 1.25
        /// Samples required before any late verdict — the baseline needs population first
        /// (connection bring-up transients must not promote; pairs with the policy's warmup).
        public var warmupSamples: Int = 20
        public init() {}

        /// Env-tunable construction (absent/unparseable ⇒ default), clamped to sane bands. Pure.
        public static func fromEnvironment(_ env: [String: String]) -> Self {
            var c = Self()
            if let v = env["SLOPDESK_OWD_LATE_FLOOR_MS"].flatMap(Double.init), v.isFinite {
                c.thresholdFloorMs = min(200, max(1, v))
            }
            if let v = env["SLOPDESK_OWD_LATE_FRAC_PCT"].flatMap(Double.init), v.isFinite {
                c.thresholdIntervalFraction = min(400, max(0, v)) / 100.0
            }
            if let v = env["SLOPDESK_OWD_LATE_WARMUP"].flatMap(Int.init) {
                c.warmupSamples = min(1000, max(1, v))
            }
            return c
        }
    }

    private let config: Config

    /// Host send stamp unwrapped into a monotone double (the UInt32 wire stamp wraps at ~49 days;
    /// accumulating wrap-aware deltas keeps owd continuous across the wrap).
    private var unwrappedSendMs = 0.0
    private var prevSendTs: UInt32?
    /// Two-bucket rolling min over owd (see Config.bucketMs).
    private var currentBucketMin = Double.infinity
    private var previousBucketMin = Double.infinity
    private var bucketStartArrivalMs: Double?
    private var samples = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Folds one per-frame sample (the caller admits one per strictly-newer frameID via
    /// `TrendSampler`, so reorder/kfDup/ts==0 never reach here). Returns the deviation above
    /// threshold (ms) when the sample is a network-late spike, else `nil`.
    public mutating func note(arrivalMs: Double, sendTs: UInt32, intervalMs: Double) -> Double? {
        if let prev = prevSendTs {
            // Wrap-aware monotone unwrap; the sampler guarantees strictly-newer frames, but a
            // negative delta is tolerated as 0 forward progress (defense in depth). `max(0, …)` is
            // an ORDERED Int max (no NaN concern — UInt32 wrap-delta), matching Rust `.max(0)`.
            unwrappedSendMs += Double(max(0, sendTs.distanceWrapped(from: prev)))
        }
        prevSendTs = sendTs
        let owd = arrivalMs - unwrappedSendMs

        // Bucket rotation on ARRIVAL time (content gaps just stretch a bucket — harmless to min).
        if let start = bucketStartArrivalMs {
            if arrivalMs - start >= config.bucketMs {
                previousBucketMin = currentBucketMin
                currentBucketMin = .infinity
                bucketStartArrivalMs = arrivalMs
            }
        } else {
            bucketStartArrivalMs = arrivalMs
        }

        // NaN-faithful ORDERED min nesting — `min(prev, min(cur, owd))`, mirroring the Rust core's
        // `previous.min(current.min(owd))`. owd is finite here; `.infinity` seeds are ordered.
        let baseline = min(previousBucketMin, min(currentBucketMin, owd))
        currentBucketMin = min(currentBucketMin, owd)
        samples += 1
        guard samples >= config.warmupSamples, baseline.isFinite else { return nil }

        // ORDERED max for the threshold (floor vs fraction × interval); `max(0, intervalMs)` guards
        // a stray negative interval. Mirrors Rust `floor.max(fraction * interval.max(0.0))`.
        let threshold = max(
            config.thresholdFloorMs,
            config.thresholdIntervalFraction * max(0, intervalMs),
        )
        let deviation = owd - baseline
        return deviation > threshold ? deviation - threshold : nil
    }
}
