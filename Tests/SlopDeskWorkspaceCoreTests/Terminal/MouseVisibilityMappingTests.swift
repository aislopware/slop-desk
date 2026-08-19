import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins that the mouse-visibility face reaches the rule, and that the rule's ANSWER is the safe one.
///
/// The rule lives in `slopdesk_terminal::pointer` and is tested there and through the door. What is
/// asserted here is the crossing itself: `mouse-hide-while-typing` is actuated by the embedder, so a face
/// that returned a constant, or inverted the bool on the way back, would hide a pointer forever with
/// every Rust test still green.
final class MouseVisibilityMappingTests: XCTestCase {
    /// The explicit values, in the direction that is easy to invert.
    func testTheExplicitValuesCrossUnflipped() {
        XCTAssertFalse(MouseVisibilityMapping.isVisible(forRawValue: 1)) // hidden
        XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: 0)) // visible
    }

    /// Any unknown, corrupt or future value fails safe to VISIBLE. A `raw != 0` reading — "anything
    /// non-zero is hidden" — passes the two assertions above and fails every one of these.
    func testUnknownValuesFailSafeToVisible() {
        for raw: Int32 in [2, 7, -1, 9999, .min, .max] {
            XCTAssertTrue(MouseVisibilityMapping.isVisible(forRawValue: raw), "raw \(raw)")
        }
    }
}
