import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI

/// The trigger that opens a pane's socket, as a value.
///
/// The leaf's connect-on-appear `.task` is keyed on
/// ``TerminalLeafView/dialTaskKey(pane:mayDial:)`` so the launch dial hold
/// (``WorkspaceStore/panesMayDial``) reaches the ONE place a pane actually dials. Both halves of that
/// key matter and they fail differently: a key that is not `nil` while the hold stands dials the very
/// ids the hold exists to keep off the wire, and a key that does not MOVE on the release leaves the
/// pane dark for the rest of the launch — `.task(id:)` re-fires only when its key changes.
@MainActor
final class DialTaskKeyTests: XCTestCase {
    func testTheKeyIsNilWhileTheLaunchHoldStands() {
        XCTAssertNil(
            TerminalLeafView.dialTaskKey(pane: PaneID(), mayDial: false),
            "a pane whose id the host has not confirmed must not open a channel",
        )
        XCTAssertNil(
            TerminalLeafView.dialTaskKey(pane: nil, mayDial: true),
            "a leaf with no live session has nothing to dial",
        )
    }

    func testTheKeyMovesWhenTheHoldReleases() {
        let pane = PaneID()
        let held = TerminalLeafView.dialTaskKey(pane: pane, mayDial: false)
        let released = TerminalLeafView.dialTaskKey(pane: pane, mayDial: true)

        XCTAssertNotEqual(held, released, "the release has to be a NEW key, or the task never re-fires")
        XCTAssertEqual(released, pane, "…and the released key IS the pane")
        XCTAssertEqual(
            released, TerminalLeafView.dialTaskKey(pane: pane, mayDial: true),
            "…and it settles: a released hold must not re-run the connect on every body pass",
        )
    }
}
