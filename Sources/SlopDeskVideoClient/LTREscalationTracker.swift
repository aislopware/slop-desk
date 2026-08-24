import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// The Swift face of `rust/slopdesk-video`'s `recovery::LtrEscalationTracker`, reached through the
/// doors of the same name.
///
/// Tracks the **first** outstanding LTR-refresh request so the IDR escalation can actually fire —
/// pure (host time is passed in), so escalation timing is testable without a socket or a
/// `VTDecompressionSession`.
///
/// WHY the clock is anchored to the first request: loss is detected once per dropped frame, so
/// re-anchoring on EVERY detection never reaches the deadline under sustained loss — the
/// guaranteed-recovery forced IDR never fires and the stream can starve forever. The clock is armed
/// only on ENTERING recovery, never re-armed by a later loss, and cleared by a decoded keyframe or
/// by a frame proving the chain re-anchored on its own.
///
/// A VALUE, not a handle: the whole state is two optionals, so it crosses the boundary as a
/// `SlopDeskLtrEscalation` and every door answers the value that follows from it. There is nothing
/// to allocate, free or alias.
public struct LTREscalationTracker: Sendable, Equatable {
    /// The state the doors read and write.
    private var state = slopdesk_ltr_escalation_clear()

    public init() {}

    /// Host time (seconds) of the first request in the current recovery episode, or `nil` when no
    /// recovery is outstanding.
    public var firstRequestTime: TimeInterval? {
        state.has_first_request ? state.first_request_time : nil
    }

    /// The NEWEST (wrap-aware) frameID declared unrecoverably lost in the current episode, or `nil`
    /// when no loss was attributed — a `requestIDR` from a hard decode failure arms the episode with
    /// no frameID, and then ONLY a keyframe can clear it.
    public var maxLostFrameID: UInt32? {
        state.has_max_lost ? state.max_lost_frame_id : nil
    }

    /// Whether a recovery episode is currently outstanding.
    public var hasOutstandingRequest: Bool { state.has_first_request }

    /// Records one unrecoverably-lost frame of the current episode (wrap-aware keep-newest). Called
    /// by the loss-detection path BEFORE the recovery request is sent.
    public mutating func noteLoss(frameID: UInt32) {
        state = slopdesk_ltr_escalation_note_loss(state, frameID)
    }

    /// A NON-keyframe decoded successfully. Ends the episode iff it is strictly newer than every
    /// recorded loss AND a loss was actually attributed. Returns whether the episode was cleared.
    @discardableResult
    public mutating func frameDecoded(frameID: UInt32) -> Bool {
        let outcome = slopdesk_ltr_escalation_frame_decoded(state, frameID)
        state = outcome.state
        return outcome.cleared
    }

    /// Records that a recovery request is being sent at host time `now`, arming the clock ONLY when
    /// entering recovery. A request sent while one is already outstanding must NOT move the clock.
    public mutating func noteRequestSent(now: TimeInterval) {
        state = slopdesk_ltr_escalation_note_request_sent(state, now)
    }

    /// Whether to escalate to a forced IDR right now. Pure — does not mutate; the caller decides
    /// whether to act. `observingLoss` is defaulted so a caller with no loss signal gets the plain
    /// clock.
    public func shouldEscalate(
        now: TimeInterval,
        rtt: TimeInterval,
        policy: RecoveryPolicy,
        observingLoss: Bool = false,
    ) -> Bool {
        slopdesk_ltr_escalation_should_escalate(
            state,
            policy.idrTimeoutRTTMultiple,
            policy.lossyIdrTimeoutRTTMultiple,
            policy.lossyEscalationFloor,
            policy.lossyEscalationFloorRTTMultiple,
            now,
            rtt,
            observingLoss,
        )
    }

    /// A keyframe decoded — the episode is over unconditionally, because a keyframe references
    /// nothing. The next loss starts a fresh episode and re-arms the clock.
    public mutating func keyframeDecoded() {
        state = slopdesk_ltr_escalation_clear()
    }

    /// Re-anchors the clock to `now` AFTER a forced-IDR escalation actually fired, so the NEXT
    /// escalation waits a full deadline instead of re-firing on every subsequent dropped frame.
    ///
    /// DISTINCT from ``noteRequestSent(now:)``: an ordinary recovery request must NOT move the
    /// first-request clock — that is what lets the window elapse at all. Only a fired escalation
    /// re-arms it.
    public mutating func noteEscalated(now: TimeInterval) {
        state = slopdesk_ltr_escalation_note_escalated(state, now)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.firstRequestTime == rhs.firstRequestTime && lhs.maxLostFrameID == rhs.maxLostFrameID
    }
}
