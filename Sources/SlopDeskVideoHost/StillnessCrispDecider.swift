import Foundation

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
public struct StillnessCrispDecider: Sendable, Equatable {
    /// Consecutive byte-identical `.complete` frames observed (reset to 0 on any change).
    public private(set) var consecutiveEqual: Int = 0
    /// Whether the crisp re-anchor has already fired for the CURRENT rest period.
    public private(set) var firedThisRest: Bool = false

    public init() {}

    /// Feed one `.complete` frame's hash-equality (vs the immediately previous frame). A changed frame
    /// re-arms the decider for the next rest period; an equal frame advances the at-rest count.
    public mutating func onFrame(hashEqualToPrevious: Bool) {
        if hashEqualToPrevious {
            // Saturate so a long static stretch can't overflow; any value ≥ threshold reads "at rest".
            if consecutiveEqual < Int.max { consecutiveEqual += 1 }
        } else {
            consecutiveEqual = 0
            firedThisRest = false
        }
    }

    /// Whether to fire the crisp re-anchor NOW: at least `restThreshold` consecutive identical frames
    /// have been seen AND we have not already fired for this rest period. PURE (no mutation).
    public func shouldFireCrisp(restThreshold: Int) -> Bool {
        consecutiveEqual >= max(1, restThreshold) && !firedThisRest
    }

    /// Record that the crisp re-anchor fired for this rest period (so it fires once until motion resumes).
    public mutating func noteCrispFired() {
        firedThisRest = true
    }
}
