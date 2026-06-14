import AislopdeskVideoProtocol

/// DELIVERY-KEYED recovery-IDR admission policy (component 2, 2026-06-11) — replaces the
/// capturer's sent-keyed F1 cooldown (`AISLOPDESK_MIN_IDR_MS`, 500 ms) as the single authority on
/// whether a client recovery request may force a real IDR.
///
/// THE BUG THIS FIXES (the ranked-#1 hitch): the F1 gate keyed the cooldown on keyframe SEND
/// time. When BOTH kfDup copies of a recovery IDR were lost (burst), the client's 2·RTT
/// escalation re-requested every ~2·RTT — and EVERY request landing inside the 500 ms window was
/// suppressed (the host kept shipping P-frames the broken client could not use). Worst case
/// ~600 ms of freeze, C-dominated and RTT-independent. Delivery-keying removes the C term: a
/// request that carries `lastDecodedFrameID < newest sent keyframe` past the in-flight grace
/// PROVES that keyframe is a casualty ⇒ grant immediately (the casualty bypass).
///
/// Decision table (`r` = request's lastDecoded, `K` = newest sent keyframe):
///  - r ≥ K                       ⇒ the request itself proves K delivered + reports a genuinely
///                                  new post-K loss ⇒ grant (token-gated).
///  - r < K, age(K) <  grace      ⇒ request plausibly crossed K in flight ⇒ suppress; if K was
///                                  lost the client re-escalates 2·RTT later into the next row.
///  - r < K, age(K) ≥  grace      ⇒ K presumed a casualty ⇒ THE BYPASS: grant immediately.
///  - r < a keyframe the client decode-ACKED ⇒ stale request from before the client's own
///                                  re-anchor ⇒ suppress at zero cost regardless of age.
///  - token bucket (cap 2, refill 1/500 ms) caps everything that reaches "grant": sustained
///    rate identical to the old F1 (≤2/s), burst of 2 so the casualty-bypass second IDR is
///    never blocked.
///
/// PURE + WALL-CLOCK-ONLY: all time injected as `Double` seconds (the session's `systemUptime`
/// domain), zero frame counting — immune to FPS-governor cadence changes. No Apple imports
/// (`UInt32.distanceWrapped` comes from AislopdeskVideoProtocol). Headlessly unit-testable like
/// ``LiveCongestionController``.
public struct RecoveryIDRPolicy: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// In-flight grace = `graceFraction × smoothedRTT`, clamped to [floor, ceil]. A crossing
        /// request arrives ≤ RTT/2 + jitter after the keyframe send; 0.75×RTT adds ~50% jitter
        /// margin (the measured path jitters RTT 10-59 ms).
        public var graceFraction: Double = 0.75
        /// Covers the rtt-unknown bootstrap (smoothedRTT = 0 before the first netstats fold).
        public var graceFloorSeconds: Double = 0.040
        /// = kfDupMinInterval: beyond it the kfDup second copy has also long been sent, so
        /// further suppression only adds freeze.
        public var graceCeilSeconds: Double = 0.250
        /// Burst allowance: exactly one ordinary grant + one casualty-bypass grant back-to-back
        /// (recovery IDRs are compact + kfDup-doubled ⇒ 2 grants ≈ 4 wire copies in <500 ms —
        /// bounded; 3+ would re-open the F1 storm).
        public var bucketCapacity: Double = 2.0
        /// 1 token / 500 ms sustained — preserves the old F1 spacing ceiling exactly.
        public var refillTokensPerSecond: Double = 2.0
        /// A granted-but-unserviced latch suppresses duplicates until this expires. Sized above
        /// the worst legitimate latch-service path: a freshly-quiet window waits the
        /// StaticIDRDecider quietWindow (1.0 s) + timer tick (0.25 s) + margin. Prevents both
        /// premature double-grants and a permanent wedge if capture dies.
        public var grantPendingTimeout: Double = 1.5
        /// Keyframes are rare (recovery + static-crisp + first-frame; motion heartbeat default
        /// OFF) — 4 covers every keyframe plausibly in flight within one ack round-trip.
        public var keyframeRingCapacity: Int = 4
        public init() {}
    }

    /// One sent keyframe (a tuple won't synthesize Equatable).
    public struct SentKeyframe: Sendable, Equatable {
        public let id: UInt32
        public let at: Double
        public init(id: UInt32, at: Double) {
            self.id = id
            self.at = at
        }
    }

    public enum Verdict: Equatable, Sendable {
        case grant
        /// An IDR grant is already latched and unexpired — the duplicate-request absorber.
        case suppressGrantPending
        /// The request provably predates a keyframe the client DECODED (acked) — zero-cost
        /// suppression regardless of age.
        case suppressStale
        /// The newest sent keyframe plausibly is still in flight to the client.
        case suppressInFlight
        /// Token bucket empty — the storm cap.
        case suppressRateLimited
    }

    public let config: Config
    /// Newest-last ring of recently-sent keyframes, capped at `keyframeRingCapacity`.
    private var recentKeyframes: [SentKeyframe] = []
    /// Newest SENT-keyframe id the client decode-ACKED (ring-matched — an LTR-P ack never
    /// masquerades as keyframe delivery).
    private var deliveredKeyframeID: UInt32?
    private var tokens: Double
    private var lastRefillAt: Double?
    /// Time of the last `.grant` not yet serviced by a `noteKeyframeSent` (nil = none pending).
    private var grantedAt: Double?

    public init(config: Config = Config()) {
        self.config = config
        tokens = config.bucketCapacity
    }

    /// Read-only token level (observability/tests — proves suppress* verdicts spend nothing).
    public var availableTokens: Double { tokens }

    /// Called from `onEncodedFrame` for EVERY keyframe handed to the wire (recovery, first-frame,
    /// static-crisp, heartbeat) with `packetizer.peekNextFrameID` read BEFORE packetize.
    public mutating func noteKeyframeSent(frameID: UInt32, now: Double) {
        recentKeyframes.append(SentKeyframe(id: frameID, at: now))
        if recentKeyframes.count > config.keyframeRingCapacity { recentKeyframes.removeFirst() }
        grantedAt = nil // a keyframe went out: any pending grant is serviced
    }

    /// Called from the `.ack` fold. Idempotent; only ids matching a ring entry count (an LTR-P
    /// ack must not masquerade as keyframe delivery). Wrap-aware keep-newest.
    public mutating func noteKeyframeDelivered(frameID: UInt32) {
        guard recentKeyframes.contains(where: { $0.id == frameID }) else { return }
        if let delivered = deliveredKeyframeID, frameID.distanceWrapped(from: delivered) <= 0 { return }
        deliveredKeyframeID = frameID
    }

    /// THE admission decision for one IDR-issuing recovery request.
    /// `clientLastDecoded == nil` ⇔ wire sentinel "nothing decoded yet" (treated as maximally
    /// behind — the connect-time first-IDR-loss case rides the same bypass).
    public mutating func decide(now: Double, clientLastDecoded: UInt32?, smoothedRTTSeconds: Double) -> Verdict {
        refill(now: now)
        if let granted = grantedAt, now - granted < config.grantPendingTimeout {
            return .suppressGrantPending
        }
        if let delivered = deliveredKeyframeID, let request = clientLastDecoded,
           request.distanceWrapped(from: delivered) < 0
        {
            // Exact, not heuristic: the client's lastDecoded is monotonic, so a request older
            // than a keyframe it ACKED was composed before that keyframe decoded — stale.
            return .suppressStale
        }
        if let newest = recentKeyframes.last {
            // nil lastDecoded (nothing decoded yet) is maximally behind by definition.
            let clientBehind = clientLastDecoded.map { $0.distanceWrapped(from: newest.id) < 0 } ?? true
            if clientBehind, now - newest.at < grace(rtt: smoothedRTTSeconds) {
                return .suppressInFlight
            }
        }
        guard tokens >= 1.0 else { return .suppressRateLimited }
        tokens -= 1.0
        grantedAt = now
        return .grant
    }

    /// In-flight grace window for the given smoothed RTT: clamp(graceFraction × rtt, floor, ceil).
    public func grace(rtt: Double) -> Double {
        min(config.graceCeilSeconds, max(config.graceFloorSeconds, config.graceFraction * rtt))
    }

    private mutating func refill(now: Double) {
        defer { lastRefillAt = now }
        guard let last = lastRefillAt, now > last else { return }
        tokens = min(config.bucketCapacity, tokens + (now - last) * config.refillTokensPerSecond)
    }
}
