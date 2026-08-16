import CSlopDeskFFI

/// The Swift face of `rust/slopdesk-video`'s `frame_gate` stillness decider, reached through the door.
///
/// PURE decider for the EVENT-DRIVEN crisp re-anchor (latency-first; gated).
///
/// `StaticIDRDecider` re-sharpens on a wall-clock quiet window (~300ms after the last real frame).
/// When ScreenCaptureKit re-delivers the now-static frame a few times after motion stops, the host
/// can detect "screen at rest" SOONER straight from the NEON frame hash: `restThreshold` consecutive
/// byte-identical `.complete` frames ⇒ the picture has settled ⇒ fire the crisp re-anchor immediately
/// instead of waiting out the full quiet window. This type owns ONLY the count rule — no hashing, no
/// clocks, no pixel buffers — so it is exhaustively unit-testable ("decider beside the capture path",
/// like ``StaticFrameSuppressionDecider`` / ``StaticIDRDecider``).
///
/// It fires AT MOST once per rest period: a changed frame re-arms it (motion resumed). The
/// `StaticIDRDecider` quiet-window timer remains the fallback for content that never goes
/// byte-identical (a blinking cursor) or that SCK idle-skips without ever re-delivering.
///
/// A FOLD, and therefore still a `struct`: the whole state is a count and a latch, so each step
/// hands the door the two numbers it was last given and stores the two it answers with. A handle
/// would buy an allocation per capture session in return for nothing.
public struct StillnessCrispDecider: Sendable, Equatable {
    /// The count and the latch, exactly as the door reports them.
    private var state = slopdesk_stillness_crisp_new()

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.consecutiveEqual == rhs.consecutiveEqual && lhs.firedThisRest == rhs.firedThisRest
    }

    /// Consecutive byte-identical `.complete` frames observed (reset to 0 on any change).
    public var consecutiveEqual: Int { state.consecutive_equal }
    /// Whether the crisp re-anchor has already fired for the CURRENT rest period.
    public var firedThisRest: Bool { state.fired_this_rest }

    /// Feed one `.complete` frame's hash-equality (vs the immediately previous frame). A changed frame
    /// re-arms the decider for the next rest period; an equal frame advances the at-rest count.
    public mutating func onFrame(hashEqualToPrevious: Bool) {
        state = slopdesk_stillness_crisp_on_frame(state, hashEqualToPrevious)
    }

    /// Whether to fire the crisp re-anchor NOW: at least `restThreshold` consecutive identical frames
    /// have been seen AND we have not already fired for this rest period. PURE (no mutation).
    public func shouldFireCrisp(restThreshold: Int) -> Bool {
        slopdesk_stillness_crisp_should_fire(state, max(0, restThreshold))
    }

    /// Record that the crisp re-anchor fired for this rest period (so it fires once until motion resumes).
    public mutating func noteCrispFired() {
        state = slopdesk_stillness_crisp_note_fired(state)
    }
}
