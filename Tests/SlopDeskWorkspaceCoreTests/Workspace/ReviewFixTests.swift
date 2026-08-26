import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the fixes from the session self-review: F3 the OSC notification rate limiter, and the one
/// title-redaction rule the tree has.
@MainActor
final class ReviewFixTests: XCTestCase {
    // MARK: - The title-redaction rule

    /// ``PanePresentation/displayTitle(_:spec:)`` masks a secret in the OSC/window title.
    ///
    /// ⚠️ The name this test used to carry — "across every title surface" — was FALSE, and the
    /// assertions below are the only reason the rule still exists at all. The live rail / tab-strip /
    /// switcher titles do NOT go through `displayTitle`: they read
    /// `WorkspaceStore.liveProgramTitle(for:)` (the raw OSC title off the workspace mirror) and
    /// compose it through `slopdesk_ws_tab_display_title`, and nothing on that path redacts. See
    /// `PanePresentation.swift`'s header. This pins the RULE, not its reach; repointing it at the
    /// live path is a change that has to make the live path redact first.
    func testDisplayTitleRedactsSecrets() {
        let spec = PaneSpec(kind: .terminal, title: "PASSWORD=hunter2secretvalue")
        let shown = PanePresentation.displayTitle(nil, spec: spec)
        XCTAssertTrue(shown.contains(SecretRedactor.mask), "the title is redacted")
        XCTAssertFalse(shown.contains("hunter2secretvalue"), "the raw secret never survives the rule")
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
