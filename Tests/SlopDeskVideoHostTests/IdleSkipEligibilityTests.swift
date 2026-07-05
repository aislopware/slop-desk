import XCTest
@testable import SlopDeskVideoHost

/// Tests for the PURE true-idle-skip eligibility rule (`WindowCapturer.idleSkipEligible`). No pixel
/// buffers, no SCStream — only the boolean guard, so this runs headlessly under `swift test`.
///
/// The load-bearing property is the FALSE-IDLE GUARD: a frame is idle-eligible ONLY when the adaptive-QP
/// NEON measurement actually ran (`measured == true`) AND reported zero changed rows. The FFI's
/// degenerate-frame fallback also reports `changeMilli == 0` but with `measured == false`, so dropping
/// the `measured` guard would make an UNMEASURABLE frame masquerade as idle and get wrongly skipped —
/// the regression this test pins (revert-to-confirm-fail: delete `measured &&` → the second case fails).
final class IdleSkipEligibilityTests: XCTestCase {
    func testEligibleOnlyWhenMeasuredAndZeroChange() {
        // The one and only eligible case: a real measurement with zero changed rows.
        XCTAssertTrue(WindowCapturer.idleSkipEligible(measured: true, changeMilli: 0))
    }

    func testUnmeasuredZeroChangeIsNotIdle() {
        // FALSE-IDLE GUARD: change 0 but no real measurement (degenerate/unmeasurable frame) ⇒ NOT idle.
        XCTAssertFalse(WindowCapturer.idleSkipEligible(measured: false, changeMilli: 0))
    }

    func testAnyChangeIsNotIdle() {
        // Any non-zero change — even one row (1‰) — is motion and must never be skipped.
        XCTAssertFalse(WindowCapturer.idleSkipEligible(measured: true, changeMilli: 1))
        XCTAssertFalse(WindowCapturer.idleSkipEligible(measured: true, changeMilli: 5))
        XCTAssertFalse(WindowCapturer.idleSkipEligible(measured: true, changeMilli: 1000))
        // And not idle when unmeasured regardless of the (stale) change value.
        XCTAssertFalse(WindowCapturer.idleSkipEligible(measured: false, changeMilli: 300))
    }
}
