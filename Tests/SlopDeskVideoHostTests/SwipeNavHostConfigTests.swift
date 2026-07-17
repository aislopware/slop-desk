import XCTest
@testable import SlopDeskVideoHost

/// Pins the WINDOW-scoped swipe-nav eligibility (``SwipeNavHostConfig/eligibleWindowTarget``):
/// the chip may only light when the pane's app is navigable AND frontmost — the same condition
/// the fire path gates the chord on (a HID-tap post lands in the OS key-focus holder), so a
/// mismatch here means the affordance promises fires the host swallows. Runs under the default
/// env (no `SLOPDESK_SWIPE_NAV*` set in the test plan).
final class SwipeNavHostConfigTests: XCTestCase {
    func testWindowTargetNeedsNavigableAndFrontmostAgreement() {
        XCTAssertTrue(SwipeNavHostConfig.eligibleWindowTarget(
            paneBundleID: "com.google.Chrome", frontmostBundleID: "com.google.Chrome",
        ))
        // Navigable pane app, but another app holds focus → the chord would land elsewhere.
        XCTAssertFalse(SwipeNavHostConfig.eligibleWindowTarget(
            paneBundleID: "com.google.Chrome", frontmostBundleID: "com.apple.dt.Xcode",
        ))
        // Frontmost, but ⌘[ is an EDIT there → never eligible.
        XCTAssertFalse(SwipeNavHostConfig.eligibleWindowTarget(
            paneBundleID: "com.apple.dt.Xcode", frontmostBundleID: "com.apple.dt.Xcode",
        ))
    }

    func testWindowTargetFailsClosedOnUnknowns() {
        // A nil pane app (process gone) or a nil frontmost read (bare desktop / lock screen —
        // `HostFrontmostApp.bundleID()` deliberately has no fallback) must go dark, not guess.
        XCTAssertFalse(SwipeNavHostConfig.eligibleWindowTarget(
            paneBundleID: nil, frontmostBundleID: "com.google.Chrome",
        ))
        XCTAssertFalse(SwipeNavHostConfig.eligibleWindowTarget(
            paneBundleID: "com.google.Chrome", frontmostBundleID: nil,
        ))
    }
}
