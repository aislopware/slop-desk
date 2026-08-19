import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the CROSSING behind mouse-over-to-focus: two booleans out, in their own slots. The gate itself —
/// and why the already-focused term prevents a per-`mouseMoved` title-bar flicker — is
/// `slopdesk_terminal::surface::focus_follows_mouse`'s, and is tested there.
final class FocusFollowsMousePolicyTests: XCTestCase {
    /// The one true corner, and the two ways to lose it. Swapping the arguments at the door would answer
    /// `true` for the already-focused pane instead.
    func testTheSettingAndTheFocusReachTheirOwnSlots() {
        XCTAssertTrue(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: true, isAlreadyFocused: false),
        )
        XCTAssertFalse(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: true, isAlreadyFocused: true),
        )
        XCTAssertFalse(
            FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse: false, isAlreadyFocused: false),
        )
    }
}
