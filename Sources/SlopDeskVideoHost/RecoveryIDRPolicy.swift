// The delivery-keyed recovery-IDR admission law, as the Swift face of `rust/slopdesk-video`'s
// `recovery_idr`, reached through `rust/slopdesk-ffi`'s `rate_control` door.
//
// ## What is not here any more
//
// The token bucket and its refill, the ring of recently sent keyframes, the ack match that stops an
// LTR-P ack masquerading as keyframe delivery, the wrap-aware comparisons, and the load-bearing
// branch order the whole policy IS. All Rust's, in a crate that forbids `unsafe`.
//
// ## What stays, and why it has to
//
// ``Config``, because its numbers are resolved from `SLOPDESK_IDR_*` by the session, and ``Verdict``,
// because a Swift `switch` needs cases rather than a `UInt32`. The mapping between the two verdict
// spellings is the only thing this file decides, and the door's constants name every arm of it.
//
// ## Why this crosses as a handle and the quantiser does not
//
// It is a `final class` on purpose: a struct would be value-copied by mistake at every owner, and
// the bucket is stateful and must stay one shared instance. That is exactly the shape a handle
// models — one allocation, one owner, mutated in place.

import CSlopDeskFFI

/// DELIVERY-KEYED recovery-IDR admission policy — the single authority on whether a client recovery
/// request may force a real IDR, replacing the capturer's sent-keyed F1 cooldown
/// (`SLOPDESK_MIN_IDR_MS`, 500 ms).
///
/// THE BUG THIS FIXES: keying the cooldown on keyframe SEND time can't distinguish send from
/// delivery. If BOTH kfDup copies of a recovery IDR are lost (burst), the client's 2·RTT
/// escalation re-requests every ~2·RTT — and EVERY request landing inside the 500 ms window gets
/// suppressed (the host keeps shipping P-frames the broken client can't use). Worst case
/// ~600 ms of freeze, cooldown-dominated and RTT-independent. Delivery-keying removes that term: a
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
/// domain), zero frame counting — immune to FPS-governor cadence changes.
///
/// `final class`, not a value struct: a struct would be value-copied by mistake at every owner
/// (forcing a `let`→`var` ripple to keep mutations visible), so callers hold and mutate this by
/// reference — the token bucket is stateful and must stay a single shared instance.
/// `@unchecked Sendable` is sound because the single owner (``SlopDeskVideoHostSession``) only
/// touches it on the session actor (and the tests / loopback-validate from one thread), so no two
/// threads race the state behind the handle.
public final class RecoveryIDRPolicy: @unchecked Sendable {
    /// The tuning, resolved Swift-side from `SLOPDESK_IDR_*` and handed to the door once.
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

    /// The admission answer, as a `switch` can read it. Each case is one of the door's
    /// `SLOPDESK_IDR_VERDICT_*` constants and nothing more.
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
    /// The bucket, the keyframe ring and the latch, all of it Rust's.
    private let policy: OpaquePointer

    public init(config: Config = Config()) {
        self.config = config
        policy = slopdesk_idr_policy_new(
            SlopDeskIdrConfig(
                grace_fraction: config.graceFraction,
                grace_floor_seconds: config.graceFloorSeconds,
                grace_ceil_seconds: config.graceCeilSeconds,
                bucket_capacity: config.bucketCapacity,
                refill_tokens_per_second: config.refillTokensPerSecond,
                grant_pending_timeout: config.grantPendingTimeout,
                keyframe_ring_capacity: config.keyframeRingCapacity,
            ),
        )
    }

    deinit { slopdesk_idr_policy_free(policy) }

    /// Read-only token level (observability/tests — proves suppress* verdicts spend nothing).
    public var availableTokens: Double { slopdesk_idr_policy_available_tokens(policy) }

    /// Called from `onEncodedFrame` for EVERY keyframe handed to the wire (recovery, first-frame,
    /// static-crisp, heartbeat) with the frameID the `PacketizeLane` returned for that keyframe.
    public func noteKeyframeSent(frameID: UInt32, now: Double) {
        slopdesk_idr_policy_note_keyframe_sent(policy, frameID, now)
    }

    /// Called from the `.ack` fold. Idempotent; only ids matching a ring entry count (an LTR-P
    /// ack must not masquerade as keyframe delivery). Wrap-aware keep-newest.
    public func noteKeyframeDelivered(frameID: UInt32) {
        slopdesk_idr_policy_note_keyframe_delivered(policy, frameID)
    }

    /// THE admission decision for one IDR-issuing recovery request.
    /// `clientLastDecoded == nil` ⇔ wire sentinel "nothing decoded yet" (treated as maximally
    /// behind — the connect-time first-IDR-loss case rides the same bypass).
    public func decide(now: Double, clientLastDecoded: UInt32?, smoothedRTTSeconds: Double) -> Verdict {
        let answer = slopdesk_idr_policy_decide(
            policy, now, clientLastDecoded != nil, clientLastDecoded ?? 0, smoothedRTTSeconds,
        )
        switch answer {
        case UInt32(SLOPDESK_IDR_VERDICT_GRANT): return .grant
        case UInt32(SLOPDESK_IDR_VERDICT_SUPPRESS_GRANT_PENDING): return .suppressGrantPending
        case UInt32(SLOPDESK_IDR_VERDICT_SUPPRESS_STALE): return .suppressStale
        case UInt32(SLOPDESK_IDR_VERDICT_SUPPRESS_IN_FLIGHT): return .suppressInFlight
        default: return .suppressRateLimited
        }
    }

    /// In-flight grace window for the given smoothed RTT: clamp(graceFraction × rtt, floor, ceil).
    public func grace(rtt: Double) -> Double { slopdesk_idr_policy_grace(policy, rtt) }
}
