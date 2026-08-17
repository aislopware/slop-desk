import CoreGraphics
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the fixes from the session self-review: F3 the OSC notification rate limiter, and the
/// title redaction that reaches every title surface.
@MainActor
final class ReviewFixTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { seed in FakePaneSession(seed.spec) }, liveVideoCap: 5)
    }

    // MARK: - Titles are redacted everywhere

    /// displayTitle (now used by the carousel tab + top bar, not just the pill/sidebar) masks secrets,
    /// so a secret in the OSC/window title never leaks into ANY title surface.
    func testDisplayTitleRedactsSecretsAcrossEveryTitleSurface() {
        let spec = PaneSpec(kind: .terminal, title: "PASSWORD=hunter2secretvalue")
        let shown = PanePresentation.displayTitle(nil, spec: spec)
        XCTAssertTrue(shown.contains(SecretRedactor.mask), "the title is redacted")
        XCTAssertFalse(shown.contains("hunter2secretvalue"), "the raw secret never reaches a title surface")
    }

    // MARK: - F3: notification rate limiter (pure)

    func testRateLimiterAllowsBurstThenThrottles() {
        var limiter = NotificationRateLimiter(capacity: 3, refillPerSecond: 1, now: 0)
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertFalse(limiter.allow(now: 0), "the 4th in a burst is dropped")
        XCTAssertFalse(limiter.allow(now: 0.5), "half a token refilled — still dropped")
        XCTAssertTrue(limiter.allow(now: 1.0), "one token refilled after 1s")
        XCTAssertFalse(limiter.allow(now: 1.0))
    }

    func testRateLimiterCapsAtCapacity() {
        var limiter = NotificationRateLimiter(capacity: 2, refillPerSecond: 1, now: 0)
        // A long idle refills to capacity, not beyond.
        XCTAssertTrue(limiter.allow(now: 100))
        XCTAssertTrue(limiter.allow(now: 100))
        XCTAssertFalse(limiter.allow(now: 100), "tokens cap at capacity (2), not 100")
    }
}
