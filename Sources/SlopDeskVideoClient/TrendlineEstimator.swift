import CSlopDeskFFI
import Foundation

/// PURE libwebrtc-trendline-style one-way-delay-GRADIENT detector.
///
/// WHY: the ABR's smoothed-RTT path needs ~250-300ms from congestion onset to its first cut (EWMA
/// crossing + `rttStreakTicks` + not-improving guard). The queue's *slope* is visible much earlier
/// than its *level*: this estimator regresses the per-FRAME delay variation against arrival time
/// (16.7ms sample cadence at 60fps — independent of the 50ms report cadence) and flags OVERUSE the
/// way GCC/libwebrtc does, so the host can authorize one early multiplicative cut per spacing
/// window (`SLOPDESK_ABR_GRAD`, see `LiveCongestionController`).
///
/// SHAPE (verbatim libwebrtc TrendlineEstimator + OveruseDetector, field-proven at exactly this
/// job): per-sample delay variation `d = dArrival − dSend` accumulates, is exponentially smoothed,
/// and a windowed OLS slope over `(arrival, smoothedDelay)` is scaled into a `modifiedTrend` that
/// is compared against an ADAPTIVE threshold (kUp/kDown — rises on noisy paths automatically; this
/// repo's history falsified two FIXED-threshold delay designs on rate-independent 4G wobble).
/// Overuse must be SUSTAINED (>10ms over threshold with a non-decreasing trend) before it signals.
///
/// CLOCK-SKEW DISCIPLINE: `dSend` is a host-stamp delta, `dArrival` a client-clock delta — the
/// cross-machine offset cancels in the differences (same argument as ``OWDJitterEstimator``);
/// ppm-level rate skew is negligible over the ~333ms window.
///
/// OURS (not in libwebrtc): an IDLE RESET — WebRTC streams continuously, this content-adaptive
/// stream does not (and the FPS governor makes idle gaps MORE common). A ≥`resetGapMs` arrival gap
/// means the queue context is stale; a regression straddling two activity clusters would read a
/// bogus slope, so the window is cleared and re-warmed instead.
///
/// The law itself is `rust/slopdesk-video`'s `trendline`; this is its face. The estimator is a value
/// its owner copies out, folds into and writes back, so it crosses BY VALUE — the regression WINDOW
/// travels with it, because the verdict is a least-squares fit over the samples themselves and
/// running sums would round differently (`docs/55-ffi-boundary.md` §4b).
public struct TrendlineEstimator: Sendable, Equatable {
    /// Detector output, encoded into bits 0-1 of the wire flags field.
    public enum State: UInt8, Sendable {
        case normal = 0
        case overusing = 1
        case underusing = 2

        /// The door's code as a verdict. An unknown code cannot arise — the door emits exactly
        /// these three — and reads as the one a fresh detector holds.
        static func of(_ code: UInt32) -> Self {
            switch code {
            case UInt32(SLOPDESK_TREND_STATE_OVERUSING): .overusing
            case UInt32(SLOPDESK_TREND_STATE_UNDERUSING): .underusing
            default: .normal
            }
        }

        /// The verdict as the door's code.
        var code: UInt32 { UInt32(rawValue) }
    }

    // MARK: Tunables (libwebrtc defaults; env-overridable SLOPDESK_TREND_* for HW A/B)

    /// The law's fixed numbers, resolved once. Nothing here is state — no fold moves one — so they
    /// are asked for rather than carried, and this side spells none of them.
    private static let constants = slopdesk_trendline_constants()

    /// The env-tunable half of the operating point, resolved once. Every knob NAME and every band
    /// lives behind the door, so the whole environment is handed over one pair at a time; the two
    /// knobs are independent, so its arbitrary order cannot change the answer. Out-of-band is
    /// REJECTED rather than clamped: these reshape the detector's geometry.
    static let config: SlopDeskTrendlineConfig = {
        var config = slopdesk_trendline_config_default()
        for (key, value) in ProcessInfo.processInfo.environment {
            config = apply(config, key, value)
        }
        return config
    }()

    /// One environment pair through the door.
    private static func apply(
        _ config: SlopDeskTrendlineConfig,
        _ key: String,
        _ value: String,
    ) -> SlopDeskTrendlineConfig {
        var key = key
        var value = value
        return key.withUTF8 { keyBytes in
            value.withUTF8 { valueBytes in
                slopdesk_trendline_config_apply(
                    config, keyBytes.baseAddress, keyBytes.count,
                    valueBytes.baseAddress, valueBytes.count,
                )
            }
        }
    }

    /// Regression window in per-frame samples (kDefaultTrendlineWindowSize; 333ms @60fps).
    /// `SLOPDESK_TREND_WINDOW`.
    public static var windowSize: Int { config.window_size }
    /// The adaptive threshold's floor — the clamp the libwebrtc OveruseDetector never rises from.
    public static var thresholdMin: Double { constants.threshold_min }
    /// Adaptive-threshold gains: rise slowly toward a loud |trend| (kUp), fall quickly back toward
    /// a quiet one (kDown) — the asymmetry keeps one spike from desensitizing the detector for long.
    public static var kUp: Double { constants.k_up }
    public static var kDown: Double { constants.k_down }
    /// OURS: an arrival gap larger than this resets the window (≥15 missed frame slots at 60fps —
    /// stale queue context + the two-cluster regression artifact; FPS-governor-proof).
    public static var resetGapMs: Double { constants.reset_gap_ms }

    private var record: SlopDeskTrendline

    public init() { record = slopdesk_trendline_new(Self.config) }

    /// Latest detector verdict. Stays `.normal` until the window fills (the warm-up gate).
    public var state: State { State.of(record.state) }
    /// `min(numDeltas, 60) × slope × the configured gain` — the value compared against `threshold`,
    /// shipped on the wire (×1000, Int32 bit-pattern) for host-side logging/corroboration.
    public var modifiedTrend: Double { record.modified_trend }
    /// Total samples folded (saturates at 1000), shipped (capped 255) for host log context.
    public var numDeltas: Int { record.num_deltas }
    /// The adaptive detection threshold (see kUp/kDown).
    public var threshold: Double { record.threshold }

    /// Folds one per-FRAME sample (the caller gates to one sample per strictly-newer frameID via
    /// ``TrendSampler``): the client-monotonic arrival ms of the frame's first-seen fragment plus
    /// that frame's `hostSendTsMillis` stamp.
    public mutating func note(arrivalMs: Double, sendTs: UInt32) {
        record = slopdesk_trendline_note(record, arrivalMs, sendTs)
    }

    /// Whether the latest verdict is STALE at `nowMs`: no accepted sample within ``resetGapMs``.
    /// State only mutates in ``note(arrivalMs:sendTs:)``, so across a content-idle gap a latched
    /// `.overusing` would otherwise ride EVERY ~50 ms report until the NEXT arrival performs the
    /// idle reset (≥250 ms later) — the report path consults this and ships neutral/zero trend
    /// fields instead (the host must never act on queue context that no longer exists). No samples
    /// yet ⇒ stale. The `>` mirrors ``note(arrivalMs:sendTs:)``'s own reset condition exactly.
    public func isStale(nowMs: Double) -> Bool {
        slopdesk_trendline_is_stale(record, nowMs)
    }

    /// Two estimators are equal when every field the next fold reads agrees — the whole regression
    /// window included, which is the one comparison this side cannot spell for itself: a C array is
    /// a tuple here, and a tuple that long has no equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        withUnsafePointer(to: lhs.record) { left in
            withUnsafePointer(to: rhs.record) { right in
                slopdesk_trendline_eq(left, right)
            }
        }
    }
}

// MARK: - Wire packing (NetworkStatsReport.owdTrendMilli / .owdTrendFlags)

public extension TrendlineEstimator {
    /// `modifiedTrend × 1000` rounded, clamped to ±1_000_000_000, as an Int32 bit-pattern. Static
    /// so the clamp is testable at magnitudes the estimator cannot reach organically.
    static func packTrendMilli(_ modifiedTrend: Double) -> UInt32 {
        slopdesk_trendline_pack_milli(modifiedTrend)
    }

    /// Bits 0-1: detector state raw value; bits 8-15: `min(numDeltas, 255)` (host log context).
    static func packTrendFlags(state: State, numDeltas: Int) -> UInt32 {
        slopdesk_trendline_pack_flags(state.code, Swift.max(0, numDeltas))
    }

    /// The wire value for ``NetworkStatsReport/owdTrendMilli``.
    var wireTrendMilli: UInt32 { Self.packTrendMilli(modifiedTrend) }
    /// The wire value for ``NetworkStatsReport/owdTrendFlags``.
    var wireTrendFlags: UInt32 { Self.packTrendFlags(state: state, numDeltas: numDeltas) }
}

// MARK: - TrendSampler (the one-sample-per-frame admission gate)

/// Admits exactly ONE trend sample per frame: the FIRST fragment of each wrap-aware strictly-NEWER
/// frameID. In production ALL fragments of one frame share ONE packetize-time `hostSendTsMillis`
/// stamp, so per-fragment samples would carry a built-in positive slope inside every multi-fragment
/// frame (later fragments, same stamp). Gating on the first fragment of a new frame also makes
/// kfDup duplicates (the same frame re-enqueued — same frameID + stamp) and reordered older-frame
/// fragments self-rejecting, and `ts == 0` (telemetry off) never samples.
public struct TrendSampler: Sendable, Equatable {
    private var state: SlopDeskTrendSampler

    public init() { state = slopdesk_trend_sampler_new() }

    /// `true` exactly once per strictly-newer frameID (and never for `sendTs == 0`).
    public mutating func shouldSample(frameID: UInt32, sendTs: UInt32) -> Bool {
        let decision = slopdesk_trend_sampler_should_sample(state, frameID, sendTs)
        state = decision.sampler
        return decision.sampled
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.has_last_frame_id == rhs.state.has_last_frame_id
            && lhs.state.last_frame_id == rhs.state.last_frame_id
    }
}
