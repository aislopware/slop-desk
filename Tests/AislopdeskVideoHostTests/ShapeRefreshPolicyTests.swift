import XCTest
@testable import AislopdeskVideoHost

/// PURE cursor shape-refresh decision (SHAPE-LAG FIX, 2026-06-10). Decides whether a 120 Hz
/// cursor-queue tick should dispatch the main-thread `NSCursor.currentSystem` refresh, given the
/// window-server cursor seed (nil = private symbol unavailable). No AppKit, no dlsym — safe under
/// `swift test --filter ShapeRefreshPolicyTests`.
final class ShapeRefreshPolicyTests: XCTestCase {
    // 1. First call with a seed always refreshes (the prime that unblocks `shapePrimed`).
    func testFirstSeedAlwaysRefreshes() {
        var p = ShapeRefreshPolicy()
        XCTAssertTrue(p.shouldRefresh(seed: 7, tickCount: 1), "lastSeed starts nil ⇒ prime refresh")
    }

    // 2. Seed change ⇒ refresh on the SAME tick, regardless of tick phase.
    func testSeedChangeRefreshesImmediately() {
        var p = ShapeRefreshPolicy()
        _ = p.shouldRefresh(seed: 7, tickCount: 1)
        XCTAssertFalse(p.shouldRefresh(seed: 7, tickCount: 2), "stable seed, off-cadence ⇒ no refresh")
        XCTAssertTrue(p.shouldRefresh(seed: 8, tickCount: 3), "seed changed ⇒ refresh NOW (≤ one tick)")
        XCTAssertFalse(p.shouldRefresh(seed: 8, tickCount: 4), "new seed latched ⇒ quiet again")
    }

    // 3. Stable seed: only the slow safety cadence (default every 120th tick ≈ 1 Hz) refreshes.
    func testStableSeedSafetyCadence() {
        var p = ShapeRefreshPolicy()
        _ = p.shouldRefresh(seed: 7, tickCount: 1)
        for tick in 2...119 {
            XCTAssertFalse(p.shouldRefresh(seed: 7, tickCount: tick), "tick \(tick): stable ⇒ quiet")
        }
        XCTAssertTrue(p.shouldRefresh(seed: 7, tickCount: 120), "safety refresh at the 1 Hz cadence")
        XCTAssertFalse(p.shouldRefresh(seed: 7, tickCount: 121))
    }

    // 4. Seed unavailable (symbol missing) ⇒ legacy 30 Hz fallback (every 4th tick), stateless.
    func testNilSeedLegacyFallback() {
        var p = ShapeRefreshPolicy()
        XCTAssertFalse(p.shouldRefresh(seed: nil, tickCount: 1))
        XCTAssertFalse(p.shouldRefresh(seed: nil, tickCount: 2))
        XCTAssertFalse(p.shouldRefresh(seed: nil, tickCount: 3))
        XCTAssertTrue(p.shouldRefresh(seed: nil, tickCount: 4), "legacy every-4th-tick cadence")
        XCTAssertTrue(p.shouldRefresh(seed: nil, tickCount: 8))
    }

    // 5. A nil seed does not corrupt the latched seed: seed returning after a nil gap still
    //    compares against the last REAL seed (no spurious refresh for the same value).
    func testNilGapKeepsLatchedSeed() {
        var p = ShapeRefreshPolicy()
        _ = p.shouldRefresh(seed: 7, tickCount: 1)
        _ = p.shouldRefresh(seed: nil, tickCount: 2)
        XCTAssertFalse(p.shouldRefresh(seed: 7, tickCount: 3), "same seed after a nil gap ⇒ no refresh")
        XCTAssertTrue(p.shouldRefresh(seed: 9, tickCount: 5), "a genuinely new seed still fires")
    }
}
