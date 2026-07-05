import Foundation

/// PURE decision for static-frame suppression: should the host SKIP encoding/sending a captured
/// `.complete` frame because its pixels are byte-identical to the last submitted frame?
///
/// HEVC + ScreenCaptureKit idle-skip already drop most static content; this catches the residual
/// case where SCK re-delivers a `.complete` frame whose pixels are pixel-identical to the previous
/// one (`hashEqualToLast == true`). The host hashes the locked NV12 planes (NEON kernel) and feeds
/// the equality + the forced-frame obligations here; this type owns ONLY the boolean rule — no
/// hashing, no pixel buffers, no clocks — so it is exhaustively unit-testable headlessly, exactly
/// like ``StaticIDRDecider`` / ``IdleReapDecider`` ("decider beside the capture path").
///
/// ## THE invariant — never suppress a forced obligation
/// A frame must be ENCODED (return `false` = do not suppress) whenever ANY of these holds, no
/// matter that the pixels are unchanged, because each is a contract the client is waiting on:
/// - `isFirstFrame` — the stream's first frame is always a keyframe the client needs to start.
/// - `forcedKeyframePending` — a client loss-recovery / heartbeat IDR latch is pending.
/// - `recoveryPending` — an LTR-refresh recovery latch is pending.
/// - `heartbeatDue` — the periodic insurance IDR cadence is due.
/// - `ltrRefreshDue` — a long-term-reference refresh is scheduled.
/// - `selfHealDue` — the self-heal cadence frame is due.
///
/// Suppression is therefore allowed ONLY when the pixels are unchanged AND none of those
/// obligations is outstanding — a duplicate frame with nothing else to deliver. Because the rule
/// is conjunctive on `!`-of-every-flag, adding a future obligation is a matter of threading one
/// more `false`-when-set flag through, and the default (any flag set) is always "encode".
public struct StaticFrameSuppressionDecider: Sendable, Equatable {
    public init() {}

    /// Whether the captured frame should be SUPPRESSED (skipped, not handed to the encoder).
    ///
    /// Returns `true` ONLY when `hashEqualToLast && !isFirstFrame` and EVERY forced-frame obligation
    /// is clear; any single obligation (or a changed/unknown hash, or the first frame) forces
    /// `false` (encode). Pure: no side effects, deterministic in its inputs.
    public func shouldSuppress(
        hashEqualToLast: Bool,
        isFirstFrame: Bool,
        forcedKeyframePending: Bool,
        recoveryPending: Bool,
        heartbeatDue: Bool,
        ltrRefreshDue: Bool,
        selfHealDue: Bool,
    ) -> Bool {
        // The first frame, or any pending/ due forced obligation, must ALWAYS be encoded — these
        // win over a pixel-identical hash. Only a true duplicate with no obligation is suppressed.
        guard hashEqualToLast,
              !isFirstFrame,
              !forcedKeyframePending,
              !recoveryPending,
              !heartbeatDue,
              !ltrRefreshDue,
              !selfHealDue
        else {
            return false
        }
        return true
    }
}
