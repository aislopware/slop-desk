import Foundation

/// CONTENT-ADAPTIVE FPS (2026-06-09) — the capability aislopdesk lacked vs Parsec.
///
/// Measured root cause of the scroll khựng/nặng/flicker/nhoè: the link sustains only ~12Mbps, but a
/// 60fps FULL-SCREEN scroll produces ~58–200KB motion frames = far more than `link/60` bytes/frame, so
/// even with rate-proportional send pacing the data rate exceeds the link → loss → blur/freeze/flicker.
///
/// Parsec's fix (and now aislopdesk's): under heavy motion DROP the frame rate. Fewer frames means each gets a
/// bigger byte budget (sharper) AND the aggregate data rate halves (fits the link, no loss). When motion is
/// light (frames already under budget) the full frame rate is kept (smooth).
///
/// Mechanism: SKIP a capture (never hand it to the encoder) when the PREVIOUS encoded frame exceeded the
/// per-frame link budget. Skipping a capture is reference-safe — the encoder simply emits its next frame as
/// a delta off the last ENCODED frame (a larger delta covering two capture intervals), so there is no
/// keyframe churn and no decode break. Skips are capped at one-in-a-row, flooring the rate at fps/2
/// (≈30fps from 60) — the validated floor; below that the encoder coarsens (QP) instead.
///
/// Thread-safe (`@unchecked Sendable` + a lock): `shouldSkip` is called on the capture queue, `noteEncoded`
/// from the encoder-output path — they only share the lock-guarded fields. The decision is otherwise pure
/// and unit-tested via ``decide``.
public final class AdaptiveFPSController: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEncodedBytes = 0
    private var skippedPrevious = false
    /// Per-frame byte budget at full fps (≈ linkCeilingBps / 8 / fps). A frame above this needed more than
    /// the link can carry at full fps → drop the next capture to give the stream 2× the budget.
    private let budgetBytes: Int
    /// When false (`AISLOPDESK_ADAPTIVE_FPS=0`), `shouldSkip` always returns false ⇒ byte-identical to full fps.
    private let enabled: Bool

    public init(budgetBytes: Int, enabled: Bool) {
        self.budgetBytes = max(1, budgetBytes)
        self.enabled = enabled
    }

    /// Record the size of the most recently ENCODED frame (the skip signal). Called off the encode path.
    public func noteEncoded(bytes: Int) {
        lock.lock(); lastEncodedBytes = bytes; lock.unlock()
    }

    /// Should this captured frame be SKIPPED (not encoded) to adapt the rate down? Forced frames
    /// (keyframe / crisp / compact / LTR-refresh) NEVER skip — they are recovery/heartbeat and must ship.
    public func shouldSkip(isForcedFrame: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let skip = Self.decide(enabled: enabled, isForcedFrame: isForcedFrame,
                               lastEncodedBytes: lastEncodedBytes, budgetBytes: budgetBytes,
                               skippedPrevious: skippedPrevious)
        skippedPrevious = skip
        return skip
    }

    /// PURE decision (unit-tested): skip iff enabled, not a forced frame, the last encoded frame exceeded
    /// the per-frame budget, AND we did NOT skip the previous capture (one-in-a-row cap ⇒ rate floor fps/2).
    public static func decide(enabled: Bool, isForcedFrame: Bool, lastEncodedBytes: Int,
                              budgetBytes: Int, skippedPrevious: Bool) -> Bool {
        guard enabled, !isForcedFrame else { return false }
        return lastEncodedBytes > budgetBytes && !skippedPrevious
    }
}
