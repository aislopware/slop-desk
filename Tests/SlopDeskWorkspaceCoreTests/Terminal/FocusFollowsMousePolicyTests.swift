import XCTest
@testable import SlopDeskWorkspaceCore

/// E8 WI-8 (H6, ES-E8-6): pins the pure ``FocusFollowsMousePolicy`` AND-gate behind mouse-over-to-focus.
/// The GUI view (`GhosttyTerminalView`) is compile-only (outside the headless build), so the decision is
/// extracted here exactly as WI-7 extracted `RightClickAction.effect` — the view is a thin actuator.
///
/// Each case is proven to FAIL on a naive implementation: the `focusFollowsMouse == false` cases catch a
/// missing setting gate, and — load-bearing — the `isAlreadyFocused == true` case catches a DROPPED
/// short-circuit (the bug that re-fires `onRequestFocus` on every `mouseMoved` over the focused pane and
/// flickers the title bar). Not tautological: the assertions encode the spec's 2×2 truth table, not the
/// function's own derivation.
final class FocusFollowsMousePolicyTests: XCTestCase {
    /// Setting ON + pane NOT already focused → hovering claims focus (the whole point of the feature).
    func testHoverFocusesUnfocusedPaneWhenEnabled() {
        XCTAssertTrue(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: true, isAlreadyFocused: false),
            "with focus-follows-mouse ON, hovering an unfocused pane must request focus",
        )
    }

    /// Setting ON + pane ALREADY focused → no request. This is the LOAD-BEARING short-circuit: `mouseMoved`
    /// fires on every motion, so re-requesting focus on the already-focused pane would thrash focus and
    /// flicker the title bar. A naive `focusFollowsMouse`-only gate FAILS this assertion.
    func testHoverDoesNotRefocusAlreadyFocusedPane() {
        XCTAssertFalse(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: true, isAlreadyFocused: true),
            "an already-focused pane must NOT re-request focus on hover (title-bar flicker guard)",
        )
    }

    /// Setting OFF → hover never moves focus, regardless of the pane's current focus state.
    func testHoverNeverFocusesWhenDisabled() {
        XCTAssertFalse(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: false, isAlreadyFocused: false),
            "with focus-follows-mouse OFF, hovering an unfocused pane must NOT request focus",
        )
        XCTAssertFalse(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: false, isAlreadyFocused: true),
            "with focus-follows-mouse OFF, hovering the focused pane must NOT request focus",
        )
    }
}
