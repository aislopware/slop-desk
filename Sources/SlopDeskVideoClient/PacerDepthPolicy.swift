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
//  - The present-gap machinery stays as pure telemetry: `notePresent` still classifies
//    (GapClass diagnostics), `noteReshow` still counts stall episodes (`presentGaps`, the
//    HW-validated 28ms-threshold probe) — but no gap classification feeds the depth action.
//
// The law itself is `rust/slopdesk-video`'s `pacer_depth`; everything below is its face. The policy
// is a value the FramePacer copies out, folds into and writes back under its lock, so it crosses BY
// VALUE — and the three RINGS travel with it, because a promote window, a demote dwell and the
// dense-flow gate all read TIMES rather than counts (`docs/55-ffi-boundary.md` §4b).

import CSlopDeskFFI

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
        private var state: SlopDeskPacerDepthConfig

        /// The record as the policy reads it.
        var crossing: SlopDeskPacerDepthConfig { state }

        public init() { state = slopdesk_pacer_depth_config_default() }

        /// late iff gap > max(`absoluteLateFloorSeconds`, `lateGapFactor` × expectedInterval).
        /// 1.6 sits above 1-interval + 120Hz-tick quantization + present-on-arrival wobble
        /// (~1.3-1.5×) and below a fully missed content slot (2.0×).
        public var lateGapFactor: Double {
            get { state.late_gap_factor }
            set { state.late_gap_factor = newValue }
        }

        /// The HW-validated stall threshold (FramePacer.dbgNoteHold) — also immunizes the depth-2
        /// tick-alternation case (8.3/25ms present gaps) against self-sustaining promotion.
        public var absoluteLateFloorSeconds: Double {
            get { state.absolute_late_floor_seconds }
            set { state.absolute_late_floor_seconds = newValue }
        }

        /// A gap above this is IDLE (host idle-skip / motion stop), never late. Recovery stalls on
        /// the target path land ~20-150ms; misclassification fails safe (under-count ⇒ no promote).
        public var idleGapSeconds: Double {
            get { state.idle_gap_seconds }
            set { state.idle_gap_seconds = newValue }
        }

        /// Late additionally requires gap ≥ this × the previous in-flow present gap (suppresses
        /// gradual cadence drift; one skipped 60fps slot is a 2.0× step and passes).
        public var gapGradientFactor: Double {
            get { state.gap_gradient_factor }
            set { state.gap_gradient_factor = newValue }
        }

        /// Dense flow = ≥ this many arrivals within `denseWindowSeconds` before the gap opened
        /// (≈ sustained ≥23fps motion). Excludes typing/sparse content from ever counting late.
        public var denseMinArrivals: Int {
            get { state.dense_min_arrivals }
            set { state.dense_min_arrivals = newValue }
        }

        public var denseWindowSeconds: Double {
            get { state.dense_window_seconds }
            set { state.dense_window_seconds = newValue }
        }

        /// LATE SLACK: extra margin ON TOP of the late boundary, as a fraction of the expected
        /// interval. Without it, a steady trickle of routine vsync/arrival jitter landing a hair
        /// past the bare boundary keeps the depth pinned at 2 almost permanently (observed at ALL
        /// flow densities in field testing). 0.25 × interval (≈4.2ms @60fps) absorbs that jitter
        /// while a genuinely skipped slot (2.0× interval) still clears the boundary by a wide
        /// margin. `SLOPDESK_DEPTH_LATE_SLACK_PCT` (0...100).
        public var lateSlackFraction: Double {
            get { state.late_slack_fraction }
            set { state.late_slack_fraction = newValue }
        }

        /// Promote on this many late events within `promoteWindowSeconds`.
        public var promoteLateCount: Int {
            get { state.promote_late_count }
            set { state.promote_late_count = newValue }
        }

        public var promoteWindowSeconds: Double {
            get { state.promote_window_seconds }
            set { state.promote_window_seconds = newValue }
        }

        /// Demote after this long with at most `demoteToleranceLates` late events in the window…
        public var demoteCleanSeconds: Double {
            get { state.demote_clean_seconds }
            set { state.demote_clean_seconds = newValue }
        }

        /// …but never sooner than this after a promotion (anti-flap).
        public var minHoldSeconds: Double {
            get { state.min_hold_seconds }
            set { state.min_hold_seconds = newValue }
        }

        /// DEMOTE TOLERANCE: the dwell does not demand a PERFECTLY clean window — up to this many
        /// late events inside the trailing `demoteCleanSeconds` still demote (a lone genuine late
        /// must not re-arm the whole dwell; the slack above kills most of the trickle, this is the
        /// backstop). 0 = a strict dwell. `SLOPDESK_DEPTH_DEMOTE_TOLERANCE` (0...3 — the late ring
        /// holds 4).
        public var demoteToleranceLates: Int {
            get { state.demote_tolerance_lates }
            set { state.demote_tolerance_lates = newValue }
        }

        /// PROMOTE WARMUP: promote decisions are IGNORED for this long after stream start (first
        /// arrival) — the LiveCongestionController `warmupTicks` cold-start pattern. Connection
        /// bring-up produces transient gap shapes that look like a genuine promotion trigger and,
        /// left unguarded, never demote afterward. Counters still run (telemetry unconditional);
        /// only the promote ACTION is gated. `SLOPDESK_DEPTH_WARMUP_MS` (0...30000).
        public var promoteWarmupSeconds: Double {
            get { state.promote_warmup_seconds }
            set { state.promote_warmup_seconds = newValue }
        }

        /// The boosted depth. 1↔2 only; NEVER higher (one frame of slack covers the dominant
        /// one-slot-late hitch; deeper is pure standing latency).
        public var boostDepth: Int {
            get { Int(state.boost_depth) }
            set { state.boost_depth = UInt32(Swift.max(0, newValue)) }
        }

        /// expected-interval = median of the last N in-flow inter-ARRIVAL gaps (median, not
        /// min/mean: at depth 2 presents/arrivals can alternate 8.3/25ms around tick quantization —
        /// the median stays ≈ the true content interval; min would collapse and over-detect).
        /// Capped at the 15 the by-value crossing carries: a ring that kept more would lose its
        /// oldest entry on every fold.
        public var intervalRingSize: Int {
            get { state.interval_ring_size }
            set { state.interval_ring_size = newValue }
        }

        public var minSamplesForEstimate: Int {
            get { state.min_samples_for_estimate }
            set { state.min_samples_for_estimate = newValue }
        }

        public var defaultIntervalSeconds: Double {
            get { state.default_interval_seconds }
            set { state.default_interval_seconds = newValue }
        }

        public var minIntervalSeconds: Double {
            get { state.min_interval_seconds }
            set { state.min_interval_seconds = newValue }
        }

        public var maxIntervalSeconds: Double {
            get { state.max_interval_seconds }
            set { state.max_interval_seconds = newValue }
        }

        /// Env-tunable construction (`SLOPDESK_DEPTH_*`), each clamped to a sane band; absent /
        /// unparseable values keep the default. Every band and every knob NAME lives behind the
        /// door, so this hands the whole environment over one pair at a time and lets the law
        /// recognise its own. The knobs are independent, so the dictionary's arbitrary order
        /// cannot change the answer.
        public static func fromEnvironment(_ env: [String: String]) -> Self {
            var config = Self()
            for (key, value) in env {
                config.state = apply(config.state, key, value)
            }
            return config
        }

        /// One environment pair through the door.
        private static func apply(
            _ config: SlopDeskPacerDepthConfig,
            _ key: String,
            _ value: String,
        ) -> SlopDeskPacerDepthConfig {
            var key = key
            var value = value
            return key.withUTF8 { keyBytes in
                value.withUTF8 { valueBytes in
                    slopdesk_pacer_depth_config_apply(
                        config, keyBytes.baseAddress, keyBytes.count,
                        valueBytes.baseAddress, valueBytes.count,
                    )
                }
            }
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.state.late_gap_factor == rhs.state.late_gap_factor
                && lhs.state.absolute_late_floor_seconds == rhs.state.absolute_late_floor_seconds
                && lhs.state.idle_gap_seconds == rhs.state.idle_gap_seconds
                && lhs.state.gap_gradient_factor == rhs.state.gap_gradient_factor
                && lhs.state.dense_min_arrivals == rhs.state.dense_min_arrivals
                && lhs.state.dense_window_seconds == rhs.state.dense_window_seconds
                && lhs.state.late_slack_fraction == rhs.state.late_slack_fraction
                && lhs.state.promote_late_count == rhs.state.promote_late_count
                && lhs.state.promote_window_seconds == rhs.state.promote_window_seconds
                && lhs.state.demote_clean_seconds == rhs.state.demote_clean_seconds
                && lhs.state.min_hold_seconds == rhs.state.min_hold_seconds
                && lhs.state.demote_tolerance_lates == rhs.state.demote_tolerance_lates
                && lhs.state.promote_warmup_seconds == rhs.state.promote_warmup_seconds
                && lhs.state.boost_depth == rhs.state.boost_depth
                && lhs.state.interval_ring_size == rhs.state.interval_ring_size
                && lhs.state.min_samples_for_estimate == rhs.state.min_samples_for_estimate
                && lhs.state.default_interval_seconds == rhs.state.default_interval_seconds
                && lhs.state.min_interval_seconds == rhs.state.min_interval_seconds
                && lhs.state.max_interval_seconds == rhs.state.max_interval_seconds
        }
    }

    /// Classification of one content-present gap (returned by ``notePresent(_:)`` for tests/diagnostics).
    public enum GapClass: Sendable, Equatable {
        case first
        case normal
        case late
        case idle

        /// The door's code as a classification. An unknown code cannot arise — the door emits
        /// exactly these four — and reads as the benign one.
        static func of(_ code: UInt32) -> Self {
            switch code {
            case UInt32(SLOPDESK_GAP_CLASS_FIRST): .first
            case UInt32(SLOPDESK_GAP_CLASS_LATE): .late
            case UInt32(SLOPDESK_GAP_CLASS_IDLE): .idle
            default: .normal
            }
        }
    }

    private var state: SlopDeskPacerDepth

    public init(config: Config = Config(), adaptEnabled: Bool) {
        state = slopdesk_pacer_depth_new(config.crossing, adaptEnabled)
    }

    /// The recommended presentation depth: 1 or `boostDepth`. Always 1 while `adaptEnabled` is
    /// false (counters still run — telemetry is unconditional).
    public var depth: Int { Int(state.depth) }

    /// The expected content interval: the hint (if set), else the median of the in-flow
    /// inter-arrival ring (once warmed), else the default — clamped to a sane band.
    public var expectedIntervalSeconds: Double {
        slopdesk_pacer_depth_expected_interval(state)
    }

    /// The late boundary: `max(absFloor, factor × expectedInterval) + slackFraction × expectedInterval`.
    /// The slack term sits ON TOP of the base boundary so ±routine-jitter arrivals — gaps
    /// a few ms past the bare boundary at dense flow — stop classifying late (see
    /// ``Config/lateSlackFraction``).
    public var lateThresholdSeconds: Double {
        slopdesk_pacer_depth_late_threshold(state)
    }

    /// Fold one decoded-frame SUBMIT (client-monotonic seconds). Also evaluates demote so a
    /// post-idle resume demotes BEFORE the pacer re-primes (avoids one extra held frame at resume).
    public mutating func noteArrival(_ now: Double) {
        state = slopdesk_pacer_depth_note_arrival(state, now)
    }

    /// Fold one CONTENT present and classify its gap. Late requires ALL of: gap past the late
    /// boundary, dense flow when the gap opened, and a sharp (≥ gradient-factor) step up from the
    /// previous in-flow gap.
    @discardableResult
    public mutating func notePresent(_ now: Double) -> GapClass {
        let present = slopdesk_pacer_depth_note_present(state, now)
        state = present.policy
        return GapClass.of(present.gap_class)
    }

    /// Fold one NETWORK-late event (the session's `OwdLateDetector` flagged a one-way-delay spike
    /// past the path baseline): THE promotion input, and the demote dwell's content. Counted into
    /// the windowed `lateFrames` telemetry too, so the wire's late= field reports the
    /// promotion-relevant signal.
    public mutating func noteNetworkLate(_ now: Double) {
        state = slopdesk_pacer_depth_note_network_late(state, now)
    }

    /// Fold one empty-queue re-show tick. Counts a late-gap EPISODE (once) the moment the open gap
    /// crosses the late boundary — so the hitch is counted AS IT HAPPENS even if no frame ever
    /// resolves it (motion stop). Promotion never uses this counter, so stop boundaries can't promote.
    public mutating func noteReshow(_ now: Double) {
        state = slopdesk_pacer_depth_note_reshow(state, now)
    }

    /// Read + reset the windowed counters (one drain per NetworkStats report).
    public mutating func drainCounters() -> (lateFrames: UInt32, presentGaps: UInt32) {
        let drained = slopdesk_pacer_depth_drain(state)
        state = drained.policy
        return (drained.late_frames, drained.present_gaps)
    }

    /// FPS-governor seam: a host `streamCadence` message pins the expected interval (instant
    /// late-boundary rebase, no ~8-arrival estimator transient). `nil` / non-finite / non-positive
    /// returns to the estimator.
    public mutating func setIntervalHint(_ seconds: Double?) {
        state = slopdesk_pacer_depth_set_interval_hint(state, seconds != nil, seconds ?? 0)
    }

    /// Two policies are equal when every field the next fold reads agrees — the three rings
    /// included, which is the one comparison this side cannot spell for itself: a C array is a
    /// tuple here, and a tuple that long has no equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        slopdesk_pacer_depth_eq(lhs.state, rhs.state)
    }
}
