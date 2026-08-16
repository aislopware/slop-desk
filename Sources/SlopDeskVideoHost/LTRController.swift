import CSlopDeskFFI

/// The Swift face of `rust/slopdesk-video`'s `ltr`, reached through the door of the same name.
///
/// PURE Long-Term-Reference (LTR) recovery bookkeeping for the live HEVC stream.
///
/// WHY: on this host, a low-latency HEVC `VTCompressionSession` accepts
/// `kVTCompressionPropertyKey_EnableLTR` and emits LTR frames carrying
/// `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`. That lets us recover a client that
/// lost frames with a CHEAP P-frame referencing an *acknowledged* long-term reference
/// (`ForceLTRRefresh`) instead of a full IDR — no decoder flush, a fraction of the bytes.
///
/// THE ACKED-ONLY INVARIANT (paramount): a `ForceLTRRefresh` may ONLY reference a long-term
/// reference the client *definitely holds*. Referencing a lost / un-acked LTR makes the recovery
/// frame depend on a frame the client lacks → persistent corruption until an IDR. So a token enters
/// the acknowledged set EXCLUSIVELY via ``ackFrame(frameID:)``, which the host calls only when the
/// client sends `RecoveryMessage.ack(frameID)` — and the client sends that ONLY after it has
/// *successfully decoded* the LTR-flagged frame. Two safety nets then stack: this controller's gate
/// (``recoveryDecision(request:hasEnableLTR:)`` returns `.idr` when no token is acked) AND VT's own
/// contract (`ForceLTRRefresh` emits an IDR if no LTR has been acknowledged).
///
/// THAT is why the gate is not written twice. A second copy of "has anything been acked" that
/// drifts open by one line issues a refresh against a reference the client never held — corruption
/// that persists until the next IDR, with no error anywhere to trace it to.
///
/// A HANDLE, and therefore a CLASS: the `frameID → token` map is the big part and PRODUCTION never
/// reads it — it reads `hasAckedToken` and the ≤8 tokens to stage. The map is reported back only
/// for introspection, which is exactly §4b's test coming out on the handle side.
///
/// BOUNDED ON EVERY DIMENSION (the codebase is paranoid about attacker/stream-driven growth): the
/// map and the acknowledged-token set are both capped with evict-oldest on the far side, so a long
/// frame stream, a flood of acks, or unknown/duplicate ack frameIDs can never grow memory.
public final class LTRController: @unchecked Sendable {
    /// The caps, from the door, so neither language writes them down twice.
    private static let caps = slopdesk_ltr_caps()
    /// Max recorded `frameID → token` mappings retained for ack look-up. Once a recorded LTR frame is
    /// older than this many recordings it is evicted (a client ack for it then returns nil — a safe
    /// no-op). ~1 LTR frame per heartbeat/crisp/recovery, so it covers a generous recent window.
    public static var frameTokenCap: Int { caps.frame_token_cap }
    /// Max acknowledged tokens retained (keep the most-recently-acked, drop oldest). VT references the
    /// newest acked LTR on a refresh, so a small most-recent set suffices.
    public static var acknowledgedTokenCap: Int { caps.acknowledged_token_cap }

    /// The recorded mappings and the acknowledged set.
    private let handle: OpaquePointer?

    public init() {
        handle = slopdesk_ltr_new()
    }

    deinit {
        slopdesk_ltr_free(handle)
    }

    /// The recovery a client request should trigger.
    public enum RecoveryAction: Equatable, Sendable {
        /// Issue a `ForceLTRRefresh` — a cheap P-frame against an ACKNOWLEDGED long-term reference the
        /// client definitely holds (NO decoder flush). Only ever returned when the ACKED-ONLY
        /// invariant holds.
        case ltrRefresh
        /// Force a full IDR keyframe — the guaranteed, heavier re-anchor. The safe fallback whenever
        /// LTR is off OR no token has been acknowledged yet, and ALWAYS for an explicit `requestIDR`.
        case idr
    }

    /// The kind of client recovery request driving the decision.
    public enum Request: Equatable, Sendable {
        /// `RecoveryMessage.requestLTRRefresh` — eligible for an LTR refresh under the ACKED-ONLY gate.
        case ltrRefresh
        /// `RecoveryMessage.requestIDR` — the guaranteed-recovery escalation; ALWAYS a real IDR.
        case idr
    }

    /// Recorded `frameID → token` for LTR frames the encoder emitted, awaiting a client ack.
    /// Introspection only — the production path reads ``hasAckedToken`` and the staged tokens.
    public var frameTokens: [UInt32: Int64] {
        let (ids, tokens) = recordedFrames()
        return Dictionary(uniqueKeysWithValues: zip(ids, tokens))
    }

    /// Insertion order of ``frameTokens`` keys (oldest first) — the far side's evict-oldest, observed.
    public var frameOrder: [UInt32] { recordedFrames().ids }

    /// Tokens the client has ACKNOWLEDGED (decoded), oldest → newest. Non-empty ⇒ a `ForceLTRRefresh`
    /// may reference an acked LTR. Bounded keep-most-recent.
    public var acknowledgedTokens: [Int64] {
        let count = slopdesk_ltr_acked_tokens(handle, nil, 0)
        guard count > 0 else { return [] }
        var tokens = [Int64](repeating: 0, count: count)
        let copied = tokens.withUnsafeMutableBufferPointer { out in
            slopdesk_ltr_acked_tokens(handle, out.baseAddress, out.count)
        }
        return copied == count ? tokens : []
    }

    /// Records that the encoder emitted an LTR frame `frameID` carrying acknowledgement `token`.
    /// Insertion-ordered; evicts the oldest mapping past the cap. Idempotent on a repeated `frameID`
    /// (updates the token, keeps its place — frameIDs are monotonic so this is essentially never hit).
    public func recordLTRFrame(frameID: UInt32, token: Int64) {
        slopdesk_ltr_record(handle, frameID, token)
    }

    /// Folds a client acknowledgement of `frameID` (the `RecoveryMessage.ack` UInt32 field carries a
    /// frameID, NOT a streamSeq): if that frameID maps to a recorded token, add the token to
    /// the acknowledged set (keep-most-recent, dedup) and RETURN it so the actor can stage it onto the
    /// encoder. An unknown / already-evicted frameID returns nil — a safe no-op, never a crash or
    /// unbounded growth.
    @discardableResult
    public func ackFrame(frameID: UInt32) -> Int64? {
        var token: Int64 = 0
        guard slopdesk_ltr_ack(handle, frameID, &token) else { return nil }
        return token
    }

    /// The acknowledged tokens (oldest → newest) to feed the encoder as `AcknowledgedLTRTokens`.
    public func currentAcknowledgedTokens() -> [Int64] { acknowledgedTokens }

    /// Whether ANY token has been acknowledged — the ACKED-ONLY gate's positive signal.
    public var hasAckedToken: Bool { slopdesk_ltr_acked_tokens(handle, nil, 0) > 0 }

    /// Invalidate ALL acked-token + frame-map state. The host MUST call this whenever it rebuilds the
    /// encoder / `VTCompressionSession` (initial bring-up, an in-session resize, or a resize-failure
    /// recovery rebuild). A fresh VT session holds ZERO acknowledged long-term references and the new
    /// encoder's `pendingAckedTokens` starts empty, so the acknowledged set MUST be cleared in lockstep:
    /// a token acked against the now-destroyed session would otherwise keep ``hasAckedToken`` true and
    /// let ``recoveryDecision(request:hasEnableLTR:)`` return `.ltrRefresh` — issuing a `ForceLTRRefresh`
    /// against an LTR the new session never had. That collapses the documented two-net stack to ONE
    /// (only VT's own contract), so the host-side half of the ACKED-ONLY invariant is bypassed until the
    /// client decodes+acks a NEW LTR frame on the rebuilt session. Resetting here re-arms the host gate
    /// (`.idr` fallback) until that fresh ack arrives. The `frameID → token` map is cleared too: those
    /// tokens belong to the dead session, so a late ack for one must NOT re-arm `hasAckedToken`.
    public func reset() {
        slopdesk_ltr_reset(handle)
    }

    /// THE recovery decision. A `requestIDR` ALWAYS forces a real IDR (the guaranteed-recovery
    /// escalation must never degrade to an LTR refresh). A `requestLTRRefresh` becomes an `.ltrRefresh`
    /// ONLY when EnableLTR is on AND at least one token has been acknowledged (the ACKED-ONLY
    /// invariant); otherwise it falls back to `.idr` — the same behavior as when LTR is off.
    public func recoveryDecision(request: Request, hasEnableLTR: Bool) -> RecoveryAction {
        let kind = request == .ltrRefresh ? SLOPDESK_LTR_REQUEST_REFRESH : SLOPDESK_LTR_REQUEST_IDR
        return slopdesk_ltr_decision(handle, kind, hasEnableLTR) == SLOPDESK_LTR_ACTION_REFRESH
            ? .ltrRefresh : .idr
    }

    /// The recorded ids in insertion order, with their tokens alongside.
    private func recordedFrames() -> (ids: [UInt32], tokens: [Int64]) {
        let count = slopdesk_ltr_frames(handle, nil, nil, 0)
        guard count > 0 else { return ([], []) }
        var ids = [UInt32](repeating: 0, count: count)
        var tokens = [Int64](repeating: 0, count: count)
        let copied = ids.withUnsafeMutableBufferPointer { outIDs in
            tokens.withUnsafeMutableBufferPointer { outTokens in
                slopdesk_ltr_frames(handle, outIDs.baseAddress, outTokens.baseAddress, outIDs.count)
            }
        }
        return copied == count ? (ids, tokens) : ([], [])
    }
}
