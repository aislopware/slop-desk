// ChromeAutoHideTests — the SWIFT half of the auto-hide seam: `WorkspaceChromePolicy.applyAutoHide`.
//
// The DECISION is `slopdesk_settings::chrome::apply_auto_hide` and is tested there — which modes have an
// opinion, the 1↔>1 regime edge, and that a manual ⌘⇧L is never fought within a regime. Re-asserting any
// of that here would be the cross-language mirror the one-implementation rule forbids, and the deleted
// `SidebarAutoHidePolicyTests` was exactly that.
//
// What only this side can state is the MARSHALLING, and it is the half a Rust test structurally cannot
// see:
//   · `Bool?` ⇄ `(last_auto, last_auto_present)` in both directions — C has no optional, so "never driven
//     yet" travels as a second field, and dropping it silently turns `nil` into `false`, which reads as
//     "the policy last drove a REVEAL" and swallows the first regime edge.
//   · the three GUARDED writes back onto the `@Observable` chrome. These are why the shells' `follow()`
//     re-arm is cheap: a decision that changed nothing must wake no tracker. An unguarded assignment
//     passes every behavioural assertion below and still costs a repaint per tab tick, so it is pinned
//     through Observation rather than by reading the values back.
//
// Headless: a bare `WorkspaceChromeState`, no split, no window, no view.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class ChromeAutoHideTests: XCTestCase {
    /// A thread-safe flag box for the `withObservationTracking` onChange — a `@Sendable` closure, so it
    /// may not capture a plain local `var`. The `willSet` fires synchronously on the main actor here, so
    /// the unchecked conformance is honest (the same box `ProjectKeyStoreTests` uses).
    private final class MutationFlag: @unchecked Sendable {
        var fired = false
    }

    private func makeChrome(
        collapsed: Bool = false, manual: Bool = false, lastAuto: Bool? = nil,
    ) -> WorkspaceChromeState {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = collapsed
        chrome.manualSidebarOverride = manual
        chrome.lastAutoHideCollapsed = lastAuto
        return chrome
    }

    // MARK: - The optional, in both directions

    /// The FIRST application: `lastAutoHideCollapsed` is `nil`, which must travel as `present: false` and
    /// come back as a concrete `Bool`. The door treats an absent last value as an edge, so a manual
    /// override standing before anything was ever driven is cleared rather than deferred to.
    ///
    /// FAILS if the outbound `present` flag is dropped: `nil` would arrive as `last_auto: false`, the
    /// door would see `false != true` — still an edge here by luck — but the RETURNED `nil` would be
    /// indistinguishable from a driven `false` on the next pass.
    func testTheFirstApplicationSeedsTheAbsentLastValueAndClearsAManualOverride() {
        let chrome = makeChrome(collapsed: false, manual: true, lastAuto: nil)
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)

        XCTAssertTrue(chrome.sidebarCollapsed, "one tab: nothing to switch between")
        XCTAssertFalse(chrome.manualSidebarOverride, "nothing was ever driven, so there is nothing to defer to")
        XCTAssertEqual(chrome.lastAutoHideCollapsed, true, "the policy has now driven one, and says so")
    }

    /// A mode with NO OPINION hands every flag straight back — including an absent last value, which must
    /// stay absent. This is the inbound half of the optional: reading `last_auto` without consulting
    /// `last_auto_present` would write `false` here, and the next `.auto` application would then read a
    /// regime the policy never actually drove.
    func testAModeWithNoOpinionLeavesTheAbsentLastValueAbsent() {
        for mode in [AutoHideTabsPanelMode.default, .always] {
            let chrome = makeChrome(collapsed: true, manual: true, lastAuto: nil)
            WorkspaceChromePolicy.applyAutoHide(mode: mode, tabCount: 5, chrome: chrome)

            XCTAssertTrue(chrome.sidebarCollapsed, "\(mode) actuates nothing")
            XCTAssertTrue(chrome.manualSidebarOverride, "\(mode) actuates nothing")
            XCTAssertNil(chrome.lastAutoHideCollapsed, "\(mode) drove nothing, so it recorded nothing")
        }
    }

    /// The whole Swift→C→Swift trip on the case the seam exists for: a swipe at three tabs survives the
    /// fourth. The arbitration is Rust's; what is pinned here is that the state carrying it reaches the
    /// door intact and lands back on the chrome unmangled.
    func testAManualCollapseSurvivesAnUnrelatedTabWithinTheRegime() {
        // Two tabs: the policy reveals and remembers it did.
        let chrome = makeChrome()
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed)
        XCTAssertEqual(chrome.lastAutoHideCollapsed, false)

        // The user swipes it away, then opens a third tab — same regime.
        WorkspaceChromePolicy.applySidebarCollapsed(true, chrome: chrome)
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 3, chrome: chrome)

        XCTAssertTrue(chrome.sidebarCollapsed, "an unrelated open must not fight the user")
        XCTAssertTrue(chrome.manualSidebarOverride)

        // Back to one tab CROSSES the regime, so the mode's opinion legitimately re-asserts.
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed)
        XCTAssertFalse(chrome.manualSidebarOverride, "the edge cleared it")
        XCTAssertEqual(chrome.lastAutoHideCollapsed, true)
    }

    // MARK: - The guarded writes

    /// An application whose decision changes NOTHING must wake no observer. This is the property the
    /// shells' `follow()` re-arm economics rest on — the controller already elides a call whose `(mode,
    /// tabCount)` pair is unchanged, so the calls that DO reach the door are the ones where a flag might
    /// move, and most of those still decide nothing new.
    ///
    /// FAILS on the obvious spelling — three unconditional assignments — which is behaviourally identical
    /// and costs a full tracker wake per tab tick.
    func testAnApplicationThatDecidesNothingNewWakesNoObserver() {
        let chrome = makeChrome()
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome)

        let mutated = MutationFlag()
        withObservationTracking {
            _ = chrome.sidebarCollapsed
            _ = chrome.manualSidebarOverride
            _ = chrome.lastAutoHideCollapsed
        } onChange: {
            mutated.fired = true
        }
        // Same regime, same mode, nothing decided: every field already holds what the door answers.
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 3, chrome: chrome)

        XCTAssertFalse(mutated.fired, "an unchanged decision must not invalidate the chrome")
    }

    /// …and the guard is not simply "never write": a decision that DOES move a flag still fires, so the
    /// test above cannot pass by the tracker being armed wrongly.
    func testAnApplicationThatCrossesTheEdgeDoesWakeAnObserver() {
        let chrome = makeChrome()
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome)

        let mutated = MutationFlag()
        withObservationTracking {
            _ = chrome.sidebarCollapsed
            _ = chrome.manualSidebarOverride
            _ = chrome.lastAutoHideCollapsed
        } onChange: {
            mutated.fired = true
        }
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)

        XCTAssertTrue(mutated.fired, "the 1↔>1 edge moved two flags")
    }

    // MARK: - The second manual entry point

    /// The iPad column swipe records the override only on a GENUINE flip. The `!=` guard is what keeps a
    /// value written back unchanged — the shells re-assert the collapsed flag when they actuate the split
    /// — from being mis-recorded as a manual choice, which would freeze the auto-hide policy out of the
    /// next regime edge it legitimately owns.
    func testASwipeRecordsTheOverrideButAnEchoOfTheSameValueDoesNot() {
        let chrome = makeChrome(collapsed: false)

        WorkspaceChromePolicy.applySidebarCollapsed(false, chrome: chrome)
        XCTAssertFalse(chrome.manualSidebarOverride, "the value did not move — that was an echo")

        WorkspaceChromePolicy.applySidebarCollapsed(true, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed)
        XCTAssertTrue(chrome.manualSidebarOverride, "a real swipe is honoured like ⌘⇧L")
    }

    /// A tab count no session can hold is CLAMPED rather than trusted: the door's `tab_count` is a
    /// `size_t`, so a negative would wrap to an enormous count and read as ">1" — a reveal where the
    /// truth is "empty, hide it".
    func testANegativeTabCountClampsToTheEmptyReadingRatherThanWrapping() {
        let chrome = makeChrome()
        WorkspaceChromePolicy.applyAutoHide(mode: .auto, tabCount: -1, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, "an empty session hides like a one-tab one")
    }
}
