// The delivery-keyed recovery-IDR admission law, as the Swift face of `rust/slopdesk-video`'s
// `recovery_idr`, reached through `rust/slopdesk-ffi`'s `rate_control` door.
//
// ## What is not here any more
//
// The token bucket and its refill, the ring of recently sent keyframes, the ack match that stops an
// LTR-P ack masquerading as keyframe delivery, the wrap-aware comparisons, and the load-bearing
// branch order the whole policy IS. All Rust's, in a crate that forbids `unsafe`.
//
// The `SLOPDESK_IDR_*` tuning went with it. It used to be a Swift struct whose seven fields were
// seeded from the door and whose three environment overrides — the parse, the clamps and the
// millis→rate inversion — were hand-written at the session's one `ProcessInfo` read. Those are
// rules, so they are `recovery_idr`'s too now, reached through `slopdesk_idr_config_from_env`.
//
// ## What stays, and why it has to
//
// ``Verdict``, because a Swift `switch` needs cases rather than a `UInt32`, and the LOOKUP behind
// ``tunedConfig()`` — the env → settings-overlay precedence of `docs/58` is a property of this
// process, not of the law, so this side resolves the texts and the door decides what they mean.
// The mapping between the two verdict spellings is the only thing this file decides, and the
// door's constants name every arm of it.
//
// ## Why this crosses as a handle and the quantiser does not
//
// It is a `final class` on purpose: a struct would be value-copied by mistake at every owner, and
// the bucket is stateful and must stay one shared instance. That is exactly the shape a handle
// models — one allocation, one owner, mutated in place.

import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

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

    /// The bucket, the keyframe ring and the latch, all of it Rust's.
    private let policy: OpaquePointer

    /// A policy at the tuned defaults unless the caller hands over an operating point — which the
    /// host does, from ``tunedConfig()``. The default argument is the DOOR's answer rather than a
    /// struct assembled here, so the seven numbers are never re-typed on this side.
    public init(config: SlopDeskIdrConfig = slopdesk_idr_config_default()) {
        policy = slopdesk_idr_policy_new(config)
    }

    /// The host's operating point: the tuned defaults with `SLOPDESK_IDR_*` applied.
    ///
    /// This side resolves the three TEXTS and nothing else. What each one means — the parse, the
    /// clamp, the millis→rate inversion, and the fact that the grace key pins floor and ceiling
    /// together — is `slopdesk_video::recovery_idr`'s, beside the law those numbers tune. The names
    /// come back from the same door that reads them, so a key cannot be mistyped here: a mistyped
    /// key is the invisible failure, because the knob simply stops working and every test still
    /// passes.
    ///
    /// The lookup stays Swift's because ``EnvConfig/string(_:)`` is the env → settings-overlay
    /// precedence of `docs/58` — a property of this process, which the host folds `video-prefs.json`
    /// into at launch. It is also a strict gain on what it replaces: the session read
    /// `ProcessInfo.processInfo.environment` directly, so a GUI setting could never have reached
    /// these three at all.
    public static func tunedConfig() -> SlopDeskIdrConfig {
        precondition(gateKeys.count == 3, "the recovery-IDR door takes one value per key")
        let resolved = gateKeys.map { key in EnvConfig.string(key).map { Array($0.utf8) } ?? [] }
        // An unset key lends a NULL base (an empty `Array`'s base address is nil), which is how the
        // door spells absent — and an empty value folds to the same answer there on purpose.
        return resolved[0].withUnsafeBufferPointer { tokens in
            resolved[1].withUnsafeBufferPointer { refill in
                resolved[2].withUnsafeBufferPointer { grace in
                    slopdesk_idr_config_from_env(
                        tokens.baseAddress, tokens.count, refill.baseAddress, refill.count,
                        grace.baseAddress, grace.count,
                    )
                }
            }
        }
    }

    /// The environment key names, in the order the door takes their values. Read once, from the
    /// list the law itself keeps.
    private static let gateKeys: [String] = {
        let needed = Int(slopdesk_idr_gate_keys(nil, 0))
        guard needed > 0 else { return [] }
        var blob = [UInt8](repeating: 0, count: needed)
        let written = blob.withUnsafeMutableBufferPointer {
            Int(slopdesk_idr_gate_keys($0.baseAddress, $0.count))
        }
        guard written == needed, let text = String(bytes: blob, encoding: .utf8) else { return [] }
        return text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }()

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
