import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// WHERE THE KEYBOARD LANDS WHEN A PANE CLOSES. The tree op's own refocus is the closing pane's
/// geometric NEIGHBOUR, so in an `A | B | C` row closing `B` always hands the keyboard to `A` — however
/// long the user had been working between `C` and `B` (user-reported 2026-08-10: "it focuses some
/// arbitrary pane"). The store names the landing from its visit ring instead, and says it as a focus
/// INTENT so every client agrees on it.
///
/// Pins the pure pick (``WorkspaceStore/mostRecentSurvivor(mru:survivors:)``); the store wiring that
/// feeds it is exercised by the close paths in `WorkspaceStoreTreeTests`.
@MainActor
final class PaneCloseLandingTests: XCTestCase {
    func testTheMostRecentSURVIVORWins() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        // The ring's front is the pane being closed; `c` is where the user was before it.
        XCTAssertEqual(
            WorkspaceStore.mostRecentSurvivor(mru: [b, c, a], survivors: [a, c]),
            c,
            "the pane the user was just in, not the first survivor in tree order",
        )
    }

    func testDeadRingEntriesAreSkipped() {
        let a = PaneID(), ghost = PaneID()
        // The ring is never pruned on close (the switcher intersects with the live set instead), so
        // the pick has to walk past ids nothing can focus any more.
        XCTAssertEqual(WorkspaceStore.mostRecentSurvivor(mru: [ghost, a], survivors: [a]), a)
    }

    func testARingWithNoLiveSurvivorDecidesNothing() {
        // Nothing recorded, or nothing recorded that is still open — the tree op's neighbour rule
        // stands rather than being overridden with a guess.
        XCTAssertNil(WorkspaceStore.mostRecentSurvivor(mru: [], survivors: [PaneID()]))
        XCTAssertNil(WorkspaceStore.mostRecentSurvivor(mru: [PaneID()], survivors: [PaneID()]))
    }
}
