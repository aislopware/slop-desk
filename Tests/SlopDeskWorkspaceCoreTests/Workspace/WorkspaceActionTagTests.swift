import CSlopDeskFFI
import XCTest
@testable import SlopDeskWorkspaceCore

/// The tag is a POSITION, and this is the Swift half of that claim (docs/64 §2).
///
/// `lint-invariants` pins the two tag SETS equal by reading the numbers out of both files, which
/// catches a case added on one side only. What it cannot see is whether the two DIRECTIONS of the
/// Swift mapping agree with each other — `tag` and `init?(tag:arg:)` are two switches over the same
/// vocabulary, and a transposed pair would pass every regex and rebind two commands onto each
/// other's rows. So the round trip is asserted here, over the whole range the crate declares.
final class WorkspaceActionTagTests: XCTestCase {
    /// `.applyLayout` is the one action with no row: the five named presets are menu/palette only,
    /// and a preset has no index in this vocabulary to reconstruct one from.
    private let applyLayoutTag: UInt16 = 19

    func testEveryTagTheCrateDeclaresRoundTripsExceptApplyLayout() {
        // The count is the crate's, not a number typed here: a vocabulary that grew must fail this
        // test rather than be silently half-covered by a stale upper bound.
        var highest: UInt16 = 0
        while WorkspaceAction(tag: highest + 1, arg: 0) != nil || highest + 1 == applyLayoutTag {
            highest += 1
        }
        XCTAssertGreaterThan(highest, 70, "the vocabulary is far larger than this — the walk stopped early")

        for tag in 0...highest where tag != applyLayoutTag {
            guard let action = WorkspaceAction(tag: tag, arg: 0) else {
                XCTFail("tag \(tag) names no action, but it is inside the declared range")
                return
            }
            XCTAssertEqual(action.tag, tag, "\(action) does not round-trip")
        }
    }

    func testApplyLayoutHasATagButNoTableCanProduceIt() {
        XCTAssertEqual(WorkspaceAction.applyLayout(.tiled).tag, applyLayoutTag)
        XCTAssertNil(
            WorkspaceAction(tag: applyLayoutTag, arg: 0),
            "a preset cannot be rebuilt from an index, so nothing crossing a table may claim to be one",
        )
    }

    func testTheSelectPaneDigitSurvivesTheCrossing() {
        for digit in 1...9 {
            let action = WorkspaceAction.selectPane(digit)
            XCTAssertEqual(WorkspaceAction(tag: action.tag, arg: Int32(digit)), action)
        }
    }

    func testATagThisBuildDoesNotKnowIsNilRatherThanGuessedAt() {
        XCTAssertNil(WorkspaceAction(tag: .max, arg: 0))
    }

    /// The pane requirement is the crate's answer, not a Swift switch — and the two families it
    /// splits are the ones the table documents.
    func testTheActivePaneRequirementComesFromTheCrate() {
        XCTAssertTrue(WorkspaceAction.splitRight.requiresActivePane)
        XCTAssertTrue(WorkspaceAction.applyLayout(.tiled).requiresActivePane)
        XCTAssertTrue(WorkspaceAction.find.requiresActivePane)
        XCTAssertFalse(WorkspaceAction.commandPalette.requiresActivePane)
        XCTAssertFalse(WorkspaceAction.selectPane(1).requiresActivePane)
        XCTAssertFalse(WorkspaceAction.reattachAllPanes.requiresActivePane)
    }
}
