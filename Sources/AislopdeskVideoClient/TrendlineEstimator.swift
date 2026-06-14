import AislopdeskVideoProtocol
import Foundation

/// PURE libwebrtc-trendline-style one-way-delay-GRADIENT detector (component 3, 2026-06-11).
///
/// WHY: the ABR's smoothed-RTT path needs ~250-300ms from congestion onset to its first cut (EWMA
/// crossing + `rttStreakTicks` + not-improving guard). The queue's *slope* is visible much earlier
/// than its *level*: this estimator regresses the per-FRAME delay variation against arrival time
/// (16.7ms sample cadence at 60fps — independent of the 50ms report cadence) and flags OVERUSE the
/// way GCC/libwebrtc does, so the host can authorize one early multiplicative cut per spacing
/// window (`AISLOPDESK_ABR_GRAD`, see `LiveCongestionController`).
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
/// PURE + DETERMINISTIC + Equatable: no wall-clock, no I/O — the caller injects every arrival, so
/// the math is replayable and headlessly unit-testable (`TrendlineEstimatorTests`).
public struct TrendlineEstimator: Sendable, Equatable {
    /// Detector output, encoded into bits 0-1 of the wire flags field.
    public enum State: UInt8, Sendable {
        case normal = 0
        case overusing = 1
        case underusing = 2
    }

    // MARK: Tunables (libwebrtc defaults; env-overridable AISLOPDESK_TREND_* for HW A/B)

    /// Regression window in per-frame samples (kDefaultTrendlineWindowSize; 333ms @60fps).
    /// `AISLOPDESK_TREND_WINDOW`.
    public static let windowSize: Int = envInt("AISLOPDESK_TREND_WINDOW", 20, min: 5, max: 200)
    /// Exponential smoothing on the accumulated delay (kDefaultTrendlineSmoothingCoeff).
    public static let smoothingCoef = 0.9
    /// Gain applied to the slope before the threshold compare (kDefaultTrendlineThresholdGain).
    /// `AISLOPDESK_TREND_GAIN`.
    public static let thresholdGain: Double = envDouble("AISLOPDESK_TREND_GAIN", 4.0, min: 0.1, max: 100)
    /// Adaptive-threshold start value (libwebrtc OveruseDetector), clamped to [min, max] forever.
    public static let initialThreshold = 12.5
    public static let thresholdMin = 6.0
    public static let thresholdMax = 600.0
    /// Adaptive-threshold gains: rise slowly toward a loud |trend| (kUp), fall quickly back toward
    /// a quiet one (kDown) — the asymmetry keeps one spike from desensitizing the detector for long.
    public static let kUp = 0.0087
    public static let kDown = 0.039
    /// Skip threshold adaptation when |modifiedTrend| overshoots it by more than this — a gross
    /// outlier must not yank the threshold up to its own level.
    public static let outlierSkipMargin = 15.0
    /// Clamp on the per-sample dt used in threshold adaptation (ms).
    public static let maxAdaptDtMs = 100.0
    /// Time over threshold required before overuse SIGNALS (kOverUsingTimeThreshold, ms).
    public static let overusingTimeMs = 10.0
    /// OURS: an arrival gap larger than this resets the window (≥15 missed frame slots at 60fps —
    /// stale queue context + the two-cluster regression artifact; FPS-governor-proof).
    public static let resetGapMs = 250.0
    /// `numDeltas` saturation in the modified-trend scale factor (libwebrtc caps at 60).
    static let maxScaledDeltas = 60

    // MARK: State (all value-type ⇒ auto Equatable / Sendable)

    /// Latest detector verdict. Stays `.normal` until the window fills (the warm-up gate).
    public private(set) var state: State = .normal
    /// `min(numDeltas, 60) × slope × thresholdGain` — the value compared against `threshold`,
    /// shipped on the wire (×1000, Int32 bit-pattern) for host-side logging/corroboration.
    public private(set) var modifiedTrend: Double = 0
    /// Total samples folded (saturates at 1000), shipped (capped 255) for host log context.
    public private(set) var numDeltas = 0
    /// The adaptive detection threshold (see kUp/kDown).
    public private(set) var threshold = Self.initialThreshold

    /// One regression point: x = arrival ms since the window's first arrival, y = smoothed delay.
    private struct Sample: Equatable {
        var x: Double
        var y: Double
    }

    private var prevArrivalMs: Double?
    private var prevSendTs: UInt32?
    private var accumulatedDelayMs = 0.0
    private var smoothedDelayMs = 0.0
    private var window: [Sample] = []
    private var firstArrivalMs = 0.0
    /// Arrival ms of the FIRST over-threshold sample of the current excursion (`nil` = not over).
    private var overuseStartMs: Double?
    private var prevTrend = 0.0

    public init() {}

    /// Folds one per-FRAME sample (the caller gates to one sample per strictly-newer frameID via
    /// ``TrendSampler``): the client-monotonic arrival ms of the frame's first-seen fragment plus
    /// that frame's `hostSendTsMillis` stamp.
    public mutating func note(arrivalMs: Double, sendTs: UInt32) {
        guard let prevArrival = prevArrivalMs, let prevSend = prevSendTs else {
            // First sample: seed only.
            prevArrivalMs = arrivalMs
            prevSendTs = sendTs
            firstArrivalMs = arrivalMs
            return
        }
        if arrivalMs - prevArrival > Self.resetGapMs {
            // IDLE RESET (see type doc): clear the regression context, re-seed, re-warm.
            resetWindow()
            prevArrivalMs = arrivalMs
            prevSendTs = sendTs
            firstArrivalMs = arrivalMs
            return
        }
        // Wrap-aware host-stamp delta. A negative delta (an older frame slipping through) is
        // ignored entirely — defense in depth; ``TrendSampler`` already rejects reordered frames.
        let dSend = Double(sendTs.distanceWrapped(from: prevSend))
        guard dSend >= 0 else { return }
        let dArrival = arrivalMs - prevArrival
        prevArrivalMs = arrivalMs
        prevSendTs = sendTs

        // Delay variation: positive d ⇒ this frame spent longer in flight than the last (queue
        // growing). The cross-machine clock offset cancels in the two deltas.
        let d = dArrival - dSend
        accumulatedDelayMs += d
        smoothedDelayMs = Self.smoothingCoef * smoothedDelayMs + (1 - Self.smoothingCoef) * accumulatedDelayMs
        numDeltas = min(numDeltas + 1, 1000)

        window.append(Sample(x: arrivalMs - firstArrivalMs, y: smoothedDelayMs))
        if window.count > Self.windowSize {
            window.removeFirst(window.count - Self.windowSize)
        }
        // Warm-up gate: no verdict until the window is full.
        guard window.count >= Self.windowSize else { return }

        // OLS slope over the window (ms of delay per ms of arrival time).
        let n = Double(window.count)
        var meanX = 0.0, meanY = 0.0
        for s in window { meanX += s.x
            meanY += s.y
        }
        meanX /= n
        meanY /= n
        var numer = 0.0, denom = 0.0
        for s in window {
            numer += (s.x - meanX) * (s.y - meanY)
            denom += (s.x - meanX) * (s.x - meanX)
        }
        let trend = denom > 0 ? numer / denom : prevTrend
        modifiedTrend = Double(min(numDeltas, Self.maxScaledDeltas)) * trend * Self.thresholdGain

        // Detect (libwebrtc OveruseDetector): overuse must be SUSTAINED (>overusingTimeMs anchored
        // at the first over-threshold arrival) with a NON-DECREASING trend before it signals; a
        // sub-threshold sample resolves to normal/underusing immediately and clears the clock.
        if modifiedTrend > threshold {
            if overuseStartMs == nil { overuseStartMs = arrivalMs }
            if let start = overuseStartMs, arrivalMs - start > Self.overusingTimeMs, trend >= prevTrend {
                state = .overusing
            }
        } else if modifiedTrend < -threshold {
            state = .underusing
            overuseStartMs = nil
        } else {
            state = .normal
            overuseStartMs = nil
        }

        // Adapt the threshold toward |modifiedTrend| (skip gross outliers) — noisy paths raise it,
        // quiet ones let it fall back; clamped to [thresholdMin, thresholdMax].
        if abs(modifiedTrend) <= threshold + Self.outlierSkipMargin {
            let k = abs(modifiedTrend) < threshold ? Self.kDown : Self.kUp
            threshold += k * (abs(modifiedTrend) - threshold) * min(dArrival, Self.maxAdaptDtMs)
            threshold = min(Self.thresholdMax, max(Self.thresholdMin, threshold))
        }
        prevTrend = trend
    }

    /// Whether the latest verdict is STALE at `nowMs`: no accepted sample within ``resetGapMs``.
    /// State only mutates in ``note(arrivalMs:sendTs:)``, so across a content-idle gap a latched
    /// `.overusing` would otherwise ride EVERY ~50 ms report until the NEXT arrival performs the
    /// idle reset (≥250 ms later) — the report path consults this and ships neutral/zero trend
    /// fields instead (the host must never act on queue context that no longer exists). No samples
    /// yet ⇒ stale. The `>` mirrors ``note(arrivalMs:sendTs:)``'s own reset condition exactly.
    public func isStale(nowMs: Double) -> Bool {
        guard let prev = prevArrivalMs else { return true }
        return nowMs - prev > Self.resetGapMs
    }

    /// Clears the regression context (window/accumulators/verdict) but KEEPS the adapted threshold
    /// — path-noise knowledge survives an idle gap; queue context does not.
    private mutating func resetWindow() {
        window.removeAll(keepingCapacity: true)
        accumulatedDelayMs = 0
        smoothedDelayMs = 0
        numDeltas = 0
        overuseStartMs = nil
        prevTrend = 0
        modifiedTrend = 0
        state = .normal
    }
}

// MARK: - Wire packing (NetworkStatsReport.owdTrendMilli / .owdTrendFlags)

public extension TrendlineEstimator {
    /// `modifiedTrend × 1000` rounded, clamped to ±1_000_000_000, as an Int32 bit-pattern. Static
    /// so the clamp is testable at magnitudes the estimator cannot reach organically.
    static func packTrendMilli(_ modifiedTrend: Double) -> UInt32 {
        let milli = (modifiedTrend * 1000).rounded()
        let clamped = min(1_000_000_000.0, max(-1_000_000_000.0, milli))
        return UInt32(bitPattern: Int32(clamped))
    }

    /// Bits 0-1: detector state raw value; bits 8-15: `min(numDeltas, 255)` (host log context).
    static func packTrendFlags(state: State, numDeltas: Int) -> UInt32 {
        UInt32(state.rawValue & 0x3) | (UInt32(min(max(numDeltas, 0), 255)) << 8)
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
    private var lastFrameID: UInt32?

    public init() {}

    /// `true` exactly once per strictly-newer frameID (and never for `sendTs == 0`).
    public mutating func shouldSample(frameID: UInt32, sendTs: UInt32) -> Bool {
        guard sendTs != 0 else { return false }
        guard let last = lastFrameID else {
            lastFrameID = frameID
            return true
        }
        guard frameID.distanceWrapped(from: last) > 0 else { return false }
        lastFrameID = frameID
        return true
    }
}

// MARK: - Env parsing helpers (same pattern as LiveCongestionController)

private func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
    guard let s = ProcessInfo.processInfo.environment[key], let v = Int(s), v >= lo, v <= hi else { return fallback }
    return v
}

private func envDouble(_ key: String, _ fallback: Double, min lo: Double, max hi: Double) -> Double {
    guard let s = ProcessInfo.processInfo.environment[key], let v = Double(s), v >= lo, v <= hi else { return fallback }
    return v
}
