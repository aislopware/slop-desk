// SidebarAutoHideWiringTests — pins the E19 / WI-7 view-side ACTUATION of the `auto-hide-tabs-panel` policy
// WITHOUT a live view or an NSWindow.
//
// The pure decision (`SidebarAutoHidePolicy.desiredCollapsed`) is pinned headlessly in
// `SidebarAutoHidePolicyTests` (WI-2). What this suite pins is the thin view-side glue WI-7 adds in
// `WorkspaceRootView`: the static `applyAutoHide(mode:tabCount:chrome:)` that the `.onChange(of:)` observers
// call, and the iOS `sidebarVisibility(sidebarCollapsed:)` column mapping that makes the shared
// `chrome.sidebarCollapsed` flag honored on iPad (not a dead toggle). Both are pure + cross-platform so the
// contract is unit-tested in the macOS `swift test` Gate, never instantiating a view / split / NSWindow.

import SwiftUI
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class SidebarAutoHideWiringTests: XCTestCase {
    // MARK: - applyAutoHide: the `.auto` mode actuates `chrome.sidebarCollapsed` on the policy's opinion

    /// `.auto` COLLAPSES the sidebar when the active session drops to ≤1 tab. Start REVEALED, apply the policy
    /// at one tab, and the live chrome flag flips to collapsed — the actuation the `.onChange(of:)` observer
    /// performs on a tab-close transition. REVERT-TO-CONFIRM-FAIL: `applyAutoHide` does not exist on the
    /// un-fixed `WorkspaceRootView`, so this fails to compile-then-pass only once WI-7 adds it.
    func testAutoModeCollapsesWhenDownToOneTab() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false // resting: sidebar revealed

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".auto at 1 tab collapses the TABS panel")
    }

    /// `.auto` REVEALS the sidebar when the active session grows past one tab. Start COLLAPSED, apply at two
    /// tabs, and the flag flips back to revealed — the actuation on a tab-open transition. Asserts against the
    /// independent truth (`>1 tab ⇒ revealed`), not the function's own derivation.
    func testAutoModeRevealsWhenMoreThanOneTab() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // resting: sidebar collapsed

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, ".auto at 2 tabs reveals the TABS panel")
    }

    /// An empty active session (0 tabs) collapses under `.auto` — there is nothing to switch between (parity
    /// with `SidebarAutoHidePolicy`'s `tabCount <= 1`).
    func testAutoModeCollapsesAtZeroTabs() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false
        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 0, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".auto at 0 tabs collapses (nothing to switch between)")
    }

    /// THE launch-path pin (M2): a fresh window rests with `sidebarCollapsed == false` (revealed), so a launch
    /// with a persisted `.auto` mode + a single-tab session must collapse the TABS panel AT LAUNCH — not wait
    /// for a tab add/remove. This pins what the `.onChange(of: activeTabCount, initial: true)` observer drives on
    /// first render: starting from the DEFAULT chrome state, applying the policy at one tab collapses it.
    /// REVERT-TO-CONFIRM-FAIL: without `initial: true` the observer never fires on first appearance, so the
    /// launch state stays revealed — this test models the desired-collapsed the initial path must compute.
    func testAutoModeAtLaunchCollapsesSingleTabFromDefaultState() {
        let chrome = WorkspaceChromeState() // a fresh window: sidebarCollapsed defaults to false (revealed)
        XCTAssertFalse(chrome.sidebarCollapsed, "precondition: a fresh window rests revealed")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".auto + a single-tab session collapses the TABS panel at launch")
    }

    // MARK: - applyAutoHide: `.default` / `.always` NEVER fight a manual collapse (no opinion)

    /// THE "never fight a manual ⌘⇧L" pin: in `.default` the policy has NO opinion, so a manual collapse the
    /// user set with ⌘⇧L SURVIVES regardless of the tab count. Start MANUALLY collapsed with several tabs (a
    /// count `.auto` would WANT to reveal) and assert `applyAutoHide` leaves it collapsed. REVERT-TO-CONFIRM-
    /// FAIL: an implementation that ignored the `nil` opinion and forced `tabCount <= 1` would REVEAL here
    /// (set `false`), failing the assertion — exactly the manual-toggle-fighting regression this guards.
    func testDefaultModeLeavesManualCollapseAlone() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // the user manually collapsed it (⌘⇧L)

        WorkspaceRootView.applyAutoHide(mode: .default, tabCount: 5, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".default has no opinion — a manual collapse is never fought")
    }

    /// The mirror of the above: in `.default` a manually REVEALED sidebar at one tab also stands (a count
    /// `.auto` would WANT to collapse). The no-opinion mode never touches the flag in either direction.
    func testDefaultModeLeavesManualRevealAlone() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false // manually revealed

        WorkspaceRootView.applyAutoHide(mode: .default, tabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, ".default never collapses a manually-revealed sidebar")
    }

    /// `.always` is also a no-opinion mode in the vertical-tabs-only clone (both non-`auto` modes mean "never
    /// auto-hide"). A revealed sidebar at one tab stays revealed; a fighting implementation would collapse it.
    func testAlwaysModeHasNoOpinion() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false
        WorkspaceRootView.applyAutoHide(mode: .always, tabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, ".always never auto-hides (no opinion)")
    }

    // MARK: - applyAutoHide: already-satisfied states are left as-is (the guard)

    /// When the live flag ALREADY matches the policy's opinion, `applyAutoHide` is a no-op — the guard against
    /// re-applying the same value (so the wiring reacts to a transition, never re-asserts a steady state). Both
    /// directions: `.auto` at 2 tabs already-revealed stays revealed; `.auto` at 1 tab already-collapsed stays
    /// collapsed.
    func testAlreadySatisfiedStateIsLeftAsIs() {
        let revealed = WorkspaceChromeState()
        revealed.sidebarCollapsed = false
        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: revealed)
        XCTAssertFalse(revealed.sidebarCollapsed, "already-revealed at >1 tab stays revealed")

        let collapsed = WorkspaceChromeState()
        collapsed.sidebarCollapsed = true
        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: collapsed)
        XCTAssertTrue(collapsed.sidebarCollapsed, "already-collapsed at ≤1 tab stays collapsed")
    }

    // MARK: - applyAutoHide: a manual ⌘⇧L is NOT fought by an unrelated tab open/close (E19 WI-7)

    /// THE manual-override pin (revert-to-confirm-fail): in `.auto`, a manual ⌘⇧L collapse at >1 tabs SURVIVES
    /// an unrelated tab OPEN that stays within the same >1 regime. Reveal at 2 tabs, manually collapse (the real
    /// `chrome.toggleSidebar()` entry point that records the override), then open a 3rd tab — the sidebar must
    /// STAY collapsed. REVERT-TO-CONFIRM-FAIL: the pre-fix `applyAutoHide` (only a `!= desired` de-dup, no
    /// override / regime-edge gate) recomputed `desired == false` at 3 tabs, saw it differ from the manual
    /// `true`, and REVERTED the collapse to revealed — failing this assertion. (E19-carryovers WI-7: "do NOT
    /// fight a manual ⌘⇧L".)
    func testManualOverrideSurvivesUnrelatedTabOpenWithinRegime() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false // resting revealed

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, "precondition: .auto at 2 tabs reveals")

        chrome.toggleSidebar() // the user manually COLLAPSES (⌘⇧L / titlebar / palette all route here)
        XCTAssertTrue(chrome.sidebarCollapsed, "precondition: ⌘⇧L collapsed it")
        XCTAssertTrue(chrome.manualSidebarOverride, "precondition: the manual override is recorded")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 3, chrome: chrome)
        XCTAssertTrue(
            chrome.sidebarCollapsed,
            "a manual ⌘⇧L collapse survives an unrelated tab open (2→3, same >1 regime) — never fought",
        )
    }

    /// The mirror within the ≤1 regime: a manual REVEAL at one tab is not re-collapsed by a within-regime
    /// re-evaluation (an `.onChange(initial:)` re-fire / a no-op tab churn at the same count). REVERT-TO-
    /// CONFIRM-FAIL: the pre-fix code would force `desired == true` (collapse) over the manual reveal.
    func testManualRevealSurvivesWithinRegimeReevaluation() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // resting collapsed

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome) // settle the regime at ≤1
        XCTAssertTrue(chrome.sidebarCollapsed, "precondition: .auto at 1 tab collapses")

        chrome.toggleSidebar() // the user manually REVEALS at one tab
        XCTAssertFalse(chrome.sidebarCollapsed, "precondition: ⌘⇧L revealed it")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome) // same ≤1 regime
        XCTAssertFalse(chrome.sidebarCollapsed, "a manual reveal at one tab survives a same-regime re-evaluation")
    }

    /// The 1↔>1 transition EDGE re-asserts the auto opinion AND clears the manual override (so the auto
    /// default-state is honored on a genuine regime change, "auto is a default state, not a lock"). Manually
    /// collapse at 2 tabs, close to 1 (edge → override cleared), then re-open to 2 — with the override gone the
    /// `.auto` opinion legitimately REVEALS again. Pins that the override is edge-scoped, not permanent.
    func testRegimeEdgeClearsManualOverrideAndReasserts() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome) // revealed (>1 regime)
        chrome.toggleSidebar() // manual collapse → override set
        XCTAssertTrue(chrome.sidebarCollapsed && chrome.manualSidebarOverride, "precondition: manual collapse recorded")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome) // EDGE >1→1
        XCTAssertFalse(chrome.manualSidebarOverride, "the 1↔>1 regime edge clears the manual override")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome) // EDGE 1→>1, override gone
        XCTAssertFalse(
            chrome.sidebarCollapsed,
            "after the edge cleared the override, .auto reveals again at >1 tabs (default state, not a lock)",
        )
    }

    // MARK: - sidebarVisibility: the iOS column mapping makes the shared flag honored on iPad

    /// The pure map the iOS `sidebarColumnVisibility` binding uses: a collapsed sidebar hides the leading TABS
    /// column (`.doubleColumn` = content + detail), a revealed sidebar shows `.all`. Pins that the WI-7 policy
    /// (which sets `chrome.sidebarCollapsed`) actually hides/reveals the panel on iPad — the shared flag is not
    /// a dead toggle there. Cross-platform (`NavigationSplitViewVisibility` exists on macOS) so it runs in the
    /// macOS Gate.
    func testSidebarVisibilityMapping() {
        XCTAssertEqual(
            WorkspaceRootView.sidebarVisibility(sidebarCollapsed: true), .doubleColumn,
            "a collapsed sidebar hides the leading TABS column on iPad (content + detail remain)",
        )
        XCTAssertEqual(
            WorkspaceRootView.sidebarVisibility(sidebarCollapsed: false), .all,
            "a revealed sidebar shows all columns on iPad",
        )
    }

    // MARK: - applySidebarVisibility: the iPad swipe is the SECOND manual entry point (Batch 3 finding 2)

    /// A user SWIPE that collapses the leading column (revealed → `.doubleColumn`) is a genuine manual choice:
    /// it writes the shared flag AND records the override, so the policy honors it like ⌘⇧L. REVERT-TO-CONFIRM-
    /// FAIL: the pre-fix setter wrote `chrome.sidebarCollapsed` directly and never touched
    /// `manualSidebarOverride`, so this fails (the override stays false).
    func testSwipeCollapseRecordsManualOverride() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false // resting revealed (the swipe genuinely flips it)
        XCTAssertFalse(chrome.manualSidebarOverride, "precondition: no override yet")

        WorkspaceRootView.applySidebarVisibility(.doubleColumn, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, "the swipe collapses the TABS panel")
        XCTAssertTrue(chrome.manualSidebarOverride, "an iPad swipe is a manual entry point — the override is recorded")
    }

    /// The mirror: a swipe that REVEALS the column (collapsed → `.all`) also records the override.
    func testSwipeRevealRecordsManualOverride() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // resting collapsed
        WorkspaceRootView.applySidebarVisibility(.all, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, "the swipe reveals the TABS panel")
        XCTAssertTrue(chrome.manualSidebarOverride, "a manual reveal swipe is recorded too")
    }

    /// A binding ECHO — SwiftUI writing back the SAME value the getter derived from a policy-driven flag — must
    /// NOT be mis-recorded as a manual override (else every auto-hide actuation would also lock the panel). The
    /// value matches the live flag, so the guard short-circuits: no write, no override.
    func testEchoOfPolicyValueDoesNotRecordOverride() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // the policy just collapsed it; the getter yields `.doubleColumn`
        WorkspaceRootView.applySidebarVisibility(.doubleColumn, chrome: chrome) // SwiftUI echoes it back unchanged
        XCTAssertTrue(chrome.sidebarCollapsed, "the flag is unchanged")
        XCTAssertFalse(chrome.manualSidebarOverride, "an echo of the policy's own value is NOT a manual override")
    }

    /// THE end-to-end pin (the WI-7 regression finding 2 closes): an iPad user who SWIPES the panel away at >1
    /// tabs keeps it hidden across an unrelated within-regime tab open — exactly as a ⌘⇧L collapse does. REVERT-
    /// TO-CONFIRM-FAIL: with the pre-fix setter (no override recorded) `applyAutoHide` at 3 tabs sees no override,
    /// recomputes `desired=false`, and FORCIBLY reveals the panel — failing this assertion.
    func testSwipeCollapseSurvivesUnrelatedTabOpenWithinRegime() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome) // settle >1 regime, revealed
        XCTAssertFalse(chrome.sidebarCollapsed, "precondition: .auto at 2 tabs reveals")

        WorkspaceRootView.applySidebarVisibility(.doubleColumn, chrome: chrome) // the iPad swipe-away
        XCTAssertTrue(chrome.sidebarCollapsed && chrome.manualSidebarOverride, "precondition: swipe recorded")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 3, chrome: chrome) // unrelated tab open, same regime
        XCTAssertTrue(
            chrome.sidebarCollapsed,
            "an iPad swipe-collapse survives an unrelated tab open (2→3, same >1 regime) — never forcibly revealed",
        )
    }
}
