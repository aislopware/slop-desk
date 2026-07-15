import XCTest
@testable import SlopDeskVideoHost

/// `SlopDeskVideoHostSession.shouldDupKeyframe` gates the keyframe double-send. Two arms:
///  - loss present (smoothed EWMA ≥ threshold) — steady loss, dup for protection;
///  - fast-attack window open — a recovery IDR was just requested, so dup the FIRST re-anchor IDR of a
///    burst even before the burst's `unrecovered` count has folded into the lagging loss EWMA.
/// The second arm exists because the loss EWMA only moves on a 50ms NetworkStats fold, so a clean→burst
/// edge would otherwise ship that first recovery IDR un-dupped — the load-bearing freeze case kfDup
/// exists for (a review-confirmed regression in the first cut of the loss-EWMA gate).
final class KfDupPolicyTests: XCTestCase {
    private let threshold = 0.005

    func testCleanLinkNoRecoveryDoesNotDup() {
        // loss ≈ 0 and no fast-attack window ⇒ heartbeat crisp IDR is NOT dupped (the bandwidth win).
        XCTAssertFalse(SlopDeskVideoHostSession.shouldDupKeyframe(
            lossRate: 0, nowUptime: 100, fastAttackUntil: 0, threshold: threshold,
        ))
        XCTAssertFalse(SlopDeskVideoHostSession.shouldDupKeyframe(
            lossRate: 0.004, nowUptime: 100, fastAttackUntil: 0, threshold: threshold,
        ))
    }

    func testSteadyLossDups() {
        XCTAssertTrue(SlopDeskVideoHostSession.shouldDupKeyframe(
            lossRate: 0.005, nowUptime: 100, fastAttackUntil: 0, threshold: threshold,
        ))
        XCTAssertTrue(SlopDeskVideoHostSession.shouldDupKeyframe(
            lossRate: 0.05, nowUptime: 100, fastAttackUntil: 0, threshold: threshold,
        ))
    }

    func testFastAttackWindowDupsAtZeroLoss() {
        // THE REGRESSION FIX: recovery IDR requested at t=100 arms the window to t=100.5; the IDR is
        // encoded+sent at ~t=100.02 with lossRate STILL ~0 (the burst report hasn't folded) — must dup.
        XCTAssertTrue(SlopDeskVideoHostSession.shouldDupKeyframe(
            lossRate: 0, nowUptime: 100.02, fastAttackUntil: 100.5, threshold: threshold,
        ))
    }

    func testFastAttackExpiredAtZeroLossDoesNotDup() {
        // Window closed and loss decayed ⇒ back to no-dup (clean steady state).
        XCTAssertFalse(SlopDeskVideoHostSession.shouldDupKeyframe(
            lossRate: 0, nowUptime: 101.0, fastAttackUntil: 100.5, threshold: threshold,
        ))
    }
}
