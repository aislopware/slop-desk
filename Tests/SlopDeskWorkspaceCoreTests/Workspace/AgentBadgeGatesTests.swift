import XCTest
@testable import SlopDeskWorkspaceCore

/// E13 WI-3 (ES-E13-2): the ``AgentBadgeGates`` value type — the per-pane toggle bundle the tab context-menu
/// flips. The SOURCE-AWARE gating itself (which families each toggle drops) now lives in ``TabBadgeGating`` and
/// is pinned by `TabBadgeGatingTests`; this file pins only the value-type contract (single-bit toggling).
final class AgentBadgeGatesTests: XCTestCase {
    // MARK: toggling flips exactly one bit

    func testTogglingFlipsExactlyOneGate() {
        let base = AgentBadgeGates.allOn
        let flipped = base.toggling(.whenComplete)
        XCTAssertFalse(flipped.badgeWhenComplete, "the targeted bit flips")
        XCTAssertTrue(flipped.badgeWhileProcessing, "the other two are preserved")
        XCTAssertTrue(flipped.badgeWhenAwaitingInput)
        XCTAssertEqual(flipped.toggling(.whenComplete), base, "a second flip restores the original")
    }

    /// `allOn` is the explicit all-true baseline the per-pane override seeds from.
    func testAllOnIsAllTrue() {
        XCTAssertTrue(AgentBadgeGates.allOn.badgeWhileProcessing)
        XCTAssertTrue(AgentBadgeGates.allOn.badgeWhenComplete)
        XCTAssertTrue(AgentBadgeGates.allOn.badgeWhenAwaitingInput)
    }
}
