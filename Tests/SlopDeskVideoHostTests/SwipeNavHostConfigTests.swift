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

    /// The history bits ride only an ELIGIBLE push (doc 20 §9.6): an ineligible one zeroes
    /// them (canonical wire — the client ignores them behind a dark chip anyway), and a nil
    /// read ships historyKnown=false so the client fails OPEN, never dark.
    func testStatusCarriesHistoryFlagsOnlyWhenEligible() {
        let history = NavHistoryFlags(canGoBack: true, canGoForward: false)
        let lit = SwipeNavHostConfig.status(bundleID: "com.google.Chrome", history: history)
        XCTAssertTrue(lit.eligible)
        XCTAssertTrue(lit.historyKnown)
        XCTAssertTrue(lit.canGoBack)
        XCTAssertFalse(lit.canGoForward)
        let dark = SwipeNavHostConfig.status(bundleID: "com.apple.dt.Xcode", history: history)
        XCTAssertFalse(dark.eligible)
        XCTAssertFalse(dark.historyKnown)
        XCTAssertFalse(dark.canGoBack)
        let unknown = SwipeNavHostConfig.status(bundleID: "com.google.Chrome", history: nil)
        XCTAssertTrue(unknown.eligible)
        XCTAssertFalse(unknown.historyKnown)
    }

    func testWindowStatusAppliesTheSameHistoryZeroRule() {
        let history = NavHistoryFlags(canGoBack: false, canGoForward: true)
        let lit = SwipeNavHostConfig.windowStatus(
            paneBundleID: "com.google.Chrome", frontmostBundleID: "com.google.Chrome",
            history: history,
        )
        XCTAssertTrue(lit.historyKnown)
        XCTAssertFalse(lit.canGoBack)
        XCTAssertTrue(lit.canGoForward)
        // Navigable pane app but focus elsewhere: dark chip, zeroed bits.
        let dark = SwipeNavHostConfig.windowStatus(
            paneBundleID: "com.google.Chrome", frontmostBundleID: "com.apple.dt.Xcode",
            history: history,
        )
        XCTAssertFalse(dark.eligible)
        XCTAssertFalse(dark.historyKnown)
        XCTAssertFalse(dark.canGoForward)
    }
}
