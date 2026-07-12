// Adaptive pacer depth: late-EVENT driven 1↔2 jitter-depth boost + always-on presentation-health
// telemetry.
//
// Sizing the depth from RFC3550 inter-arrival jitter is avoided: it conflates benign sender-cadence
// variance (host idle-skip, VideoSendLane chunked pacing, frame-size-dependent encode time) with
// actual presentation risk — on a jittery-but-fine WAN that approach pins the depth at 2-4
// (+17-50ms standing latency) with zero late presents ever observed. And under the display-native
// 120Hz tick the pacer's `underflowRun` oscillates 0↔1 BY DESIGN on a healthy 60fps stream, so
// growing depth on a transient dip in that counter ratchets to maxDepth on a clean link. The model
// here inverts that: pay latency only AFTER observed late presents (events), refund after a clean
// dwell — and never reuse `underflowRun` as a signal.
//
// A content-present-gap classifier is also NOT the promotion source, because it is structurally
// wrong for that job: comparing present gaps against the cadence hint makes natural sub-cadence
// content (e.g. VS Code idle repaint ~40fps under a 60fps hint) clear the late boundary on every
// re-show — field testing showed late=1 in every 50ms report at ALL flow densities, pinning the
// depth at 2 for 99.6% of a session with demote unreachable. Arrival GAPS conflate "the network
// delivered late" with "the host didn't produce a frame". The two jobs are split instead:
//  - PROMOTION/DEMOTION run on NETWORK-late events (`noteNetworkLate`): per-frame one-way-delay
//    spikes past the path baseline (`OwdLateDetector`, fed by the session off the wire send
//    stamps). That is the signal a slack frame actually absorbs, it is measured at ARRIVAL
//    (depth-independent ⇒ no self-sustaining promotion at depth 2), and content cadence can't
//    fake it.
//  - The present-gap machinery below stays as pure telemetry: `notePresent` still classifies
//    (GapClass diagnostics), `noteReshow` still counts stall episodes (`presentGaps`, the
//    HW-validated 28ms-threshold probe) — but no gap classification feeds the depth action.
//
// PURE + headlessly testable: no Apple imports, all time injected as client-monotonic seconds
// (pattern: LiveCongestionController / AdaptiveFECPolicy). The FramePacer owns one instance under
// its lock.

/// One windowed drain of the pacer's presentation-health counters, carried client→host on the
/// NetworkStats recovery message (Phase-0 telemetry: log-only host-side).
public struct PacerTelemetrySnapshot: Sendable, Equatable {
    /// Windowed: NETWORK-late events (owd spikes past baseline, ``PacerDepthPolicy/noteNetworkLate(_:)``;
    /// the depth-promotion input) — not present-gap lates; see the file header for why those are
    /// telemetry-only.
    public var lateFrames: UInt32
    /// Windowed: late-gap EPISODES OPENED (counted at the first re-show past the late threshold).
    /// Deliberately a SUPERSET of ``lateFrames``: a gap that no frame ever resolves (motion stop)
    /// still counts here, so the difference ≈ motion-stop boundaries. Log readers beware.
    public var presentGaps: UInt32
    /// Gauge: the live presentation depth (0 = no pacer attached).
    public var depth: UInt32
    public init(lateFrames: UInt32, presentGaps: UInt32, depth: UInt32) {
        self.lateFrames = lateFrames
        self.presentGaps = presentGaps
        self.depth = depth
    }
}

/// Late/idle/dense gap classifier (telemetry) + promote/demote depth policy (driven by
/// NETWORK-late events, see the file header).
///
/// Promote: ≥ `promoteLateCount` network-late EVENTS (``noteNetworkLate(_:)``) within
/// `promoteWindowSeconds` ⇒ depth 1 → `boostDepth` (2 — NEVER higher; an unbounded ratchet here
/// is the latency failure mode this policy exists to avoid).
/// Demote: `demoteCleanSeconds` with ≤ `demoteToleranceLates` network-late events (and ≥
/// `minHoldSeconds` since promotion) ⇒ back to 1. Counters always run (telemetry); only the
/// depth action is gated by `adaptEnabled`.
public struct PacerDepthPolicy: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// late iff gap > max(`absoluteLateFloorSeconds`, `lateGapFactor` × expectedInterval).
        /// 1.6 sits above 1-interval + 120Hz-tick quantization + present-on-arrival wobble
        /// (~1.3-1.5×) and below a fully missed content slot (2.0×).
        public var lateGapFactor: Double = 1.6
        /// The HW-validated stall threshold (FramePacer.dbgNoteHold) — also immunizes the depth-2
        /// tick-alternation case (8.3/25ms present gaps) against self-sustaining promotion.
        public var absoluteLateFloorSeconds: Double = 0.028
        /// A gap above this is IDLE (host idle-skip / motion stop), never late. Recovery stalls on
        /// the target path land ~20-150ms; misclassification fails safe (under-count ⇒ no promote).
        public var idleGapSeconds: Double = 0.25
        /// Late additionally requires gap ≥ this × the previous in-flow present gap (suppresses
        /// gradual cadence drift; one skipped 60fps slot is a 2.0× step and passes).
        public var gapGradientFactor: Double = 1.45
        /// Dense flow = ≥ this many arrivals within `denseWindowSeconds` before the gap opened
        /// (≈ sustained ≥23fps motion). Excludes typing/sparse content from ever counting late.
        public var denseMinArrivals: Int = 8
        public var denseWindowSeconds: Double = 0.35
        /// LATE SLACK: extra margin ON TOP of the late boundary, as a fraction of the expected
        /// interval. Without it, a steady trickle of routine vsync/arrival jitter landing a hair
        /// past the bare boundary keeps the depth pinned at 2 almost permanently (observed at ALL
        /// flow densities in field testing). 0.25 × interval (≈4.2ms @60fps) absorbs that jitter
        /// while a genuinely skipped slot (2.0× interval) still clears the boundary by a wide
        /// margin. `SLOPDESK_DEPTH_LATE_SLACK_PCT` (0...100).
        public var lateSlackFraction: Double = 0.25
        /// Promote on this many late events within `promoteWindowSeconds`.
        public var promoteLateCount: Int = 2
        public var promoteWindowSeconds: Double = 1.0
        /// Demote after this long with at most `demoteToleranceLates` late events in the window…
        public var demoteCleanSeconds: Double = 2.5
        /// …but never sooner than this after a promotion (anti-flap).
        public var minHoldSeconds: Double = 1.0
        /// DEMOTE TOLERANCE: the dwell does not demand a PERFECTLY clean window — up to this many
        /// late events inside the trailing `demoteCleanSeconds` still demote (a lone genuine late
        /// must not re-arm the whole dwell; the slack above kills most of the trickle, this is the
        /// backstop). 0 = a strict dwell. `SLOPDESK_DEPTH_DEMOTE_TOLERANCE` (0...3 — the late ring
        /// holds 4).
        public var demoteToleranceLates: Int = 1
        /// PROMOTE WARMUP: promote decisions are IGNORED for this long after stream start (first
        /// arrival) — the LiveCongestionController `warmupTicks` cold-start pattern. Connection
        /// bring-up produces transient gap shapes that look like a genuine promotion trigger and,
        /// left unguarded, never demote afterward. Counters still run (telemetry unconditional);
        /// only the promote ACTION is gated. `SLOPDESK_DEPTH_WARMUP_MS` (0...30000).
        public var promoteWarmupSeconds: Double = 2.0
        /// The boosted depth. 1↔2 only; NEVER higher (one frame of slack covers the dominant
        /// one-slot-late hitch; deeper is pure standing latency).
        public var boostDepth: Int = 2
        /// expected-interval = median of the last N in-flow inter-ARRIVAL gaps (median, not
        /// min/mean: at depth 2 presents/arrivals can alternate 8.3/25ms around tick quantization —
        /// the median stays ≈ the true content interval; min would collapse and over-detect).
        public var intervalRingSize: Int = 15
        public var minSamplesForEstimate: Int = 5
        public var defaultIntervalSeconds: Double = 1.0 / 60
        public var minIntervalSeconds: Double = 1.0 / 240
        public var maxIntervalSeconds: Double = 1.0 / 10
        public init() {}

        /// Env-tunable construction (`SLOPDESK_DEPTH_*`), each clamped to a sane band; absent /
        /// unparseable values keep the default. Pure — unit-testable headlessly.
        public static func fromEnvironment(_ env: [String: String]) -> Self {
            var c = Self()
            if let v = env["SLOPDESK_DEPTH_PROMOTE_LATES"].flatMap(Int.init) {
                // lateTimes ring holds 4 — a count above that could never be satisfied.
                c.promoteLateCount = min(4, max(1, v))
            }
            if let v = env["SLOPDESK_DEPTH_PROMOTE_WINDOW_MS"].flatMap(Double.init), v.isFinite {
                c.promoteWindowSeconds = min(10.0, max(0.1, v / 1000.0))
            }
            if let v = env["SLOPDESK_DEPTH_DEMOTE_MS"].flatMap(Double.init), v.isFinite {
                c.demoteCleanSeconds = min(30.0, max(0.5, v / 1000.0))
            }
            if let v = env["SLOPDESK_DEPTH_MINHOLD_MS"].flatMap(Double.init), v.isFinite {
                c.minHoldSeconds = min(10.0, max(0.0, v / 1000.0))
            }
            if let v = env["SLOPDESK_DEPTH_LATE_FACTOR"].flatMap(Double.init), v.isFinite {
                c.lateGapFactor = min(4.0, max(1.1, v))
            }
            if let v = env["SLOPDESK_DEPTH_IDLE_MS"].flatMap(Double.init), v.isFinite {
                // Raise if a host-side recovery cooldown pushes worst-case recovery past ~200ms.
                c.idleGapSeconds = min(2.0, max(0.1, v / 1000.0))
            }
            if let v = env["SLOPDESK_DEPTH_LATE_SLACK_PCT"].flatMap(Double.init), v.isFinite {
                c.lateSlackFraction = min(100.0, max(0.0, v)) / 100.0
            }
            if let v = env["SLOPDESK_DEPTH_DEMOTE_TOLERANCE"].flatMap(Int.init) {
                c.demoteToleranceLates = min(3, max(0, v)) // lateTimes ring holds 4
            }
            if let v = env["SLOPDESK_DEPTH_WARMUP_MS"].flatMap(Double.init), v.isFinite {
                c.promoteWarmupSeconds = min(30.0, max(0.0, v / 1000.0))
            }
            return c
        }
    }

    /// Classification of one content-present gap (returned by ``notePresent(_:)`` for tests/diagnostics).
    public enum GapClass: Sendable, Equatable {
        case first
        case normal
        case late
        case idle
    }

    /// The recommended presentation depth: 1 or `boostDepth`. Always 1 while `adaptEnabled` is
    /// false (counters still run — telemetry is unconditional).
    public private(set) var depth: Int

    private let config: Config
    private let adaptEnabled: Bool

    // Arrival-side state.
    private var lastArrival: Double?
    /// Recent arrival times (cap 16) for the dense-flow gate.
    private var arrivalRing: [Double] = []
    /// In-flow inter-arrival gaps (gap ∈ (0, idleGapSeconds]), cap `intervalRingSize`.
    private var intervalRing: [Double] = []
    /// FPS-governor seam: overrides the estimator while non-nil (`FramePacer.setContentFps`).
    private var intervalHint: Double?

    // Present-side state.
    private var lastPresentAt: Double?
    private var prevPresentGap: Double?
    /// Recent late-event times (cap 4) for the promote pairing window AND the demote-tolerance
    /// window count (the cap is safe: any count above the 0...3 tolerance clamp blocks demote
    /// identically whether the ring holds 4 or 40).
    private var lateTimes: [Double] = []
    private var promotedAt: Double = -1e30
    /// Stream start = the FIRST arrival: promote decisions are ignored until
    /// `promoteWarmupSeconds` past this, mirroring `LiveCongestionController.warmupTicks`.
    private var streamStartAt: Double?
    /// Latched once a re-show tick opens a gap episode; cleared by the next present or idle
    /// classification, so an episode is counted exactly ONCE however many re-shows span it.
    private var gapEpisodeOpen = false

    // Windowed, saturating counters (drained per NetworkStats report, ~50ms).
    private var lateCount: UInt32 = 0
    private var gapCount: UInt32 = 0

    public init(config: Config = Config(), adaptEnabled: Bool) {
        self.config = config
        self.adaptEnabled = adaptEnabled
        depth = 1
    }

    /// The expected content interval: the hint (if set), else the median of the in-flow
    /// inter-arrival ring (once warmed), else the default — clamped to a sane band.
    public var expectedIntervalSeconds: Double {
        let raw: Double =
            if let intervalHint {
                intervalHint
            } else if intervalRing.count >= config.minSamplesForEstimate {
                Self.median(intervalRing)
            } else {
                config.defaultIntervalSeconds
            }
        return min(config.maxIntervalSeconds, max(config.minIntervalSeconds, raw))
    }

    /// The late boundary: `max(absFloor, factor × expectedInterval) + slackFraction × expectedInterval`.
    /// The slack term sits ON TOP of the base boundary so ±routine-jitter arrivals — gaps
    /// a few ms past the bare boundary at dense flow — stop classifying late (see
    /// ``Config/lateSlackFraction``).
    public var lateThresholdSeconds: Double {
        // BIT-EXACT (Rust parity): keep the `mul` and the `add` SEPARATE — never fma. The base
        // boundary is `max(absFloor, lateGapFactor * expected)`; the slack term `slack * expected`
        // is a SEPARATE product added on top (two distinct multiplies, one add).
        max(config.absoluteLateFloorSeconds, config.lateGapFactor * expectedIntervalSeconds)
            + config.lateSlackFraction * expectedIntervalSeconds
    }

    /// Fold one decoded-frame SUBMIT (client-monotonic seconds). Also evaluates demote so a
    /// post-idle resume demotes BEFORE the pacer re-primes (avoids one extra held frame at resume).
    public mutating func noteArrival(_ now: Double) {
        if streamStartAt == nil { streamStartAt = now }
        if let last = lastArrival {
            let gap = now - last
            if gap > 0, gap <= config.idleGapSeconds {
                intervalRing.append(gap)
                if intervalRing.count > config.intervalRingSize {
                    intervalRing.removeFirst(intervalRing.count - config.intervalRingSize)
                }
            }
        }
        arrivalRing.append(now)
        if arrivalRing.count > 16 { arrivalRing.removeFirst(arrivalRing.count - 16) }
        lastArrival = now
        evaluateDemote(now)
    }

    /// Fold one CONTENT present and classify its gap. Late requires ALL of: gap past the late
    /// boundary, dense flow when the gap opened, and a sharp (≥ gradient-factor) step up from the
    /// previous in-flow gap.
    @discardableResult
    public mutating func notePresent(_ now: Double) -> GapClass {
        guard let last = lastPresentAt else {
            lastPresentAt = now
            return .first
        }
        let gap = now - last
        if gap > config.idleGapSeconds {
            // Host idle-skip / motion stop: never late, and the next in-flow gap must not be
            // gradient-compared against this idle span.
            gapEpisodeOpen = false
            prevPresentGap = nil
            lastPresentAt = now
            evaluateDemote(now)
            return .idle
        }
        // BIT-EXACT (Rust parity): `gapGradientFactor * prevGap` is a SEPARATE multiply, no fma.
        let gradientOK = prevPresentGap.map { gap >= config.gapGradientFactor * $0 } ?? true
        // Classification only (GapClass diagnostics) — a present-gap late does not count or
        // promote (it would reintroduce the cadence-hint pinning problem in the file header); the
        // depth action runs on ``noteNetworkLate(_:)``.
        let isLate = gap > lateThresholdSeconds && gradientOK && wasDense(asOf: last)
        gapEpisodeOpen = false // any present closes an open re-show episode
        prevPresentGap = gap
        lastPresentAt = now
        evaluateDemote(now)
        return isLate ? .late : .normal
    }

    /// Fold one NETWORK-late event (the session's `OwdLateDetector` flagged a one-way-delay spike
    /// past the path baseline): THE promotion input, and the demote dwell's content. Counted into
    /// the windowed `lateFrames` telemetry too, so the wire's late= field reports the
    /// promotion-relevant signal.
    public mutating func noteNetworkLate(_ now: Double) {
        if lateCount < .max { lateCount += 1 }
        lateTimes.append(now)
        if lateTimes.count > 4 { lateTimes.removeFirst(lateTimes.count - 4) }
        evaluatePromote(now)
    }

    /// Fold one empty-queue re-show tick. Counts a late-gap EPISODE (once) the moment the open gap
    /// crosses the late boundary — so the hitch is counted AS IT HAPPENS even if no frame ever
    /// resolves it (motion stop). Promotion never uses this counter, so stop boundaries can't promote.
    public mutating func noteReshow(_ now: Double) {
        guard let last = lastPresentAt, !gapEpisodeOpen else { return }
        let openGap = now - last
        if openGap > lateThresholdSeconds, openGap <= config.idleGapSeconds, wasDense(asOf: last) {
            if gapCount < .max { gapCount += 1 }
            gapEpisodeOpen = true
        }
    }

    /// Read + reset the windowed counters (one drain per NetworkStats report).
    public mutating func drainCounters() -> (lateFrames: UInt32, presentGaps: UInt32) {
        defer { lateCount = 0
            gapCount = 0
        }
        return (lateCount, gapCount)
    }

    /// FPS-governor seam: a host `streamCadence` message pins the expected interval (instant
    /// late-boundary rebase, no ~8-arrival estimator transient). `nil` / non-finite / non-positive
    /// returns to the estimator.
    public mutating func setIntervalHint(_ seconds: Double?) {
        if let s = seconds, s.isFinite, s > 0 {
            intervalHint = s
        } else {
            intervalHint = nil
        }
    }

    /// Dense-flow gate: ≥ `denseMinArrivals` arrivals in the `denseWindowSeconds` before `t`
    /// (the moment the gap OPENED — arrivals after it must not count).
    private func wasDense(asOf t: Double) -> Bool {
        let windowStart = t - config.denseWindowSeconds
        var n = 0
        for a in arrivalRing where a > windowStart && a <= t { n += 1 }
        return n >= config.denseMinArrivals
    }

    private mutating func evaluatePromote(_ now: Double) {
        guard adaptEnabled, depth == 1 else { return }
        // Cold-start guard: connection bring-up produces transient gap shapes that look late;
        // ignore promote DECISIONS (never the counters) until the warmup elapses.
        guard let start = streamStartAt, now - start >= config.promoteWarmupSeconds else { return }
        let windowStart = now - config.promoteWindowSeconds
        var recent = 0
        for t in lateTimes where t >= windowStart && t <= now { recent += 1 }
        if recent >= config.promoteLateCount {
            depth = max(2, config.boostDepth)
            promotedAt = now
        }
    }

    private mutating func evaluateDemote(_ now: Double) {
        guard depth > 1 else { return }
        guard now - promotedAt >= config.minHoldSeconds else { return }
        // Demote tolerance: demote when the trailing dwell window holds ≤ tolerance late events
        // (tolerance 0 ≡ a strict "now − lastLate ≥ dwell": the newest late is always in the
        // capped ring). A lone genuine late does not re-arm the full dwell.
        let windowStart = now - config.demoteCleanSeconds
        var recent = 0
        for t in lateTimes where t > windowStart && t <= now { recent += 1 }
        guard recent <= config.demoteToleranceLates else { return }
        depth = 1
    }

    /// Median of a small array (ring ≤ 15 entries; sort cost is negligible at this size).
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
