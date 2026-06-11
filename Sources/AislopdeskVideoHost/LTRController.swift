import Foundation

/// PURE Long-Term-Reference (LTR) recovery bookkeeping for the live HEVC stream (WF-8, 2026-06-09).
///
/// WHY: WF-7's HW probe confirmed that, on this host, a low-latency HEVC `VTCompressionSession`
/// accepts `kVTCompressionPropertyKey_EnableLTR` and emits LTR frames carrying
/// `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`. WF-8 uses that to recover a client that
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
/// PURE + DETERMINISTIC: no wall-clock, no I/O, no reference capture — exactly like
/// ``LiveCongestionController`` / ``NetworkEstimate`` / ``StaticIDRDecider``, so it is headlessly
/// unit-testable while the HW-gated ``VideoEncoder`` it drives is never instantiated in a test.
///
/// BOUNDED ON EVERY DIMENSION (the codebase is paranoid about attacker/stream-driven growth): the
/// `frameID → token` map and the acknowledged-token set are both capped with evict-oldest, so a long
/// frame stream, a flood of acks, or unknown/duplicate ack frameIDs can never grow memory.
public struct LTRController: Sendable, Equatable {
    /// Max recorded `frameID → token` mappings retained for ack look-up. Once a recorded LTR frame is
    /// older than this many recordings it is evicted (a client ack for it then returns nil — a safe
    /// no-op). ~1 LTR frame per heartbeat/crisp/recovery, so 64 covers a generous recent window.
    public static let frameTokenCap = 64
    /// Max acknowledged tokens retained (keep the most-recently-acked, drop oldest). VT references the
    /// newest acked LTR on a refresh, so a small most-recent set suffices; 8 is ample headroom.
    public static let acknowledgedTokenCap = 8

    /// Recorded `frameID → token` for LTR frames the encoder emitted, awaiting a client ack. Insertion
    /// order is tracked separately in ``frameOrder`` for deterministic evict-oldest.
    public private(set) var frameTokens: [UInt32: Int64] = [:]
    /// Insertion order of ``frameTokens`` keys (oldest first) — drives the bounded evict-oldest.
    public private(set) var frameOrder: [UInt32] = []
    /// Tokens the client has ACKNOWLEDGED (decoded), oldest → newest. Non-empty ⇒ a `ForceLTRRefresh`
    /// may reference an acked LTR. Bounded keep-most-recent.
    public private(set) var acknowledgedTokens: [Int64] = []

    public init() {}

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

    /// Records that the encoder emitted an LTR frame `frameID` carrying acknowledgement `token`.
    /// Insertion-ordered; evicts the oldest mapping past the cap. Idempotent on a repeated `frameID`
    /// (updates the token, keeps its place — frameIDs are monotonic so this is essentially never hit).
    public mutating func recordLTRFrame(frameID: UInt32, token: Int64) {
        if frameTokens[frameID] == nil {
            frameOrder.append(frameID)
        }
        frameTokens[frameID] = token
        while frameOrder.count > Self.frameTokenCap {
            let evicted = frameOrder.removeFirst()
            frameTokens[evicted] = nil
        }
    }

    /// Folds a client acknowledgement of `frameID` (the `RecoveryMessage.ack` UInt32 field carries a
    /// frameID for WF-8, NOT a streamSeq): if that frameID maps to a recorded token, add the token to
    /// the acknowledged set (keep-most-recent, dedup) and RETURN it so the actor can stage it onto the
    /// encoder. An unknown / already-evicted / duplicate frameID returns nil — a safe no-op, never a
    /// crash or unbounded growth.
    @discardableResult
    public mutating func ackFrame(frameID: UInt32) -> Int64? {
        guard let token = frameTokens[frameID] else { return nil }
        // Keep-most-recent: if already acked, move it to the newest slot so eviction drops the
        // genuinely-stalest token.
        if let idx = acknowledgedTokens.firstIndex(of: token) {
            acknowledgedTokens.remove(at: idx)
        }
        acknowledgedTokens.append(token)
        while acknowledgedTokens.count > Self.acknowledgedTokenCap {
            acknowledgedTokens.removeFirst()
        }
        return token
    }

    /// The acknowledged tokens (oldest → newest) to feed the encoder as `AcknowledgedLTRTokens`.
    public func currentAcknowledgedTokens() -> [Int64] { acknowledgedTokens }

    /// Whether ANY token has been acknowledged — the ACKED-ONLY gate's positive signal.
    public var hasAckedToken: Bool { !acknowledgedTokens.isEmpty }

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
    public mutating func reset() {
        frameTokens.removeAll()
        frameOrder.removeAll()
        acknowledgedTokens.removeAll()
    }

    /// THE recovery decision. A `requestIDR` ALWAYS forces a real IDR (the guaranteed-recovery
    /// escalation must never degrade to an LTR refresh). A `requestLTRRefresh` becomes an `.ltrRefresh`
    /// ONLY when EnableLTR is on AND at least one token has been acknowledged (the ACKED-ONLY
    /// invariant); otherwise it falls back to `.idr` — exactly today's behaviour when LTR is off.
    public func recoveryDecision(request: Request, hasEnableLTR: Bool) -> RecoveryAction {
        guard request == .ltrRefresh else { return .idr }
        guard hasEnableLTR, hasAckedToken else { return .idr }
        return .ltrRefresh
    }
}
