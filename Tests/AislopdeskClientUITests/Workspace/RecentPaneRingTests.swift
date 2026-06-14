import XCTest
@testable import AislopdeskClientUI

/// Pins the recent-pane MRU ring + quick-switch ("go to the previously-focused pane"): the ring records
/// focus order (most-recent first, deduped, capped, pruned on close) and the quick-switch WALKS it like
/// browser back/forward without reordering it mid-walk.
@MainActor
final class RecentPaneRingTests: XCTestCase {
    /// A store with `n` terminal panes laid out left-to-right; returns the store + the pane ids.
    private func makeStore(_ n: Int) -> (WorkspaceStore, [PaneID]) {
        let items = (0..<n).map {
            CanvasItem(
                id: PaneID(),
                spec: PaneSpec(kind: .terminal, title: "p\($0)"),
                frame: CGRect(x: CGFloat($0) * 400, y: 0, width: 360, height: 240),
                z: $0,
            )
        }
        let store = WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: items[0].id),
            makeSession: { FakePaneSession($0) },
        )
        return (store, items.map(\.id))
    }

    func testFocusRecordsMRUWithDedupAndSeededOutgoing() {
        let (store, ids) = makeStore(3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.focus(b) // from the restored-focus a → seeds a, fronts b
        store.focus(c)
        XCTAssertEqual(store.focusHistory, [c, b, a], "MRU: most-recent first, outgoing seeded")
        store.focus(b) // re-focus moves to front (dedup, no duplicate)
        XCTAssertEqual(store.focusHistory, [b, c, a])
    }

    func testSwitchWalksTheRingWithoutReorderingThenForwardReturns() {
        let (store, ids) = makeStore(3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.focus(b)
        store.focus(c) // ring [c, b, a], focused c, cursor 0
        store.switchToRecentPane(forward: false) // → older: b
        XCTAssertEqual(store.focusedPane, b, "go-to-previous lands on the prior pane")
        XCTAssertEqual(store.focusHistory, [c, b, a], "the walk does NOT reorder the ring")
        store.switchToRecentPane(forward: false) // → older: a
        XCTAssertEqual(store.focusedPane, a)
        store.switchToRecentPane(forward: true) // → newer: b
        XCTAssertEqual(store.focusedPane, b)
        XCTAssertEqual(store.focusHistory, [c, b, a], "still unreordered after a forward step")
    }

    func testSwitchClampsAtTheEndsAndNoopsBelowTwoPanes() {
        let (store, ids) = makeStore(2)
        let (a, b) = (ids[0], ids[1])
        store.focus(b) // ring [b, a], focused b = NEWEST
        // The pure target helper makes the end-clamp guards directly testable (a behavioral focusedPane
        // assertion would pass even with the guards removed, since focus(self) also early-returns).
        XCTAssertNil(store.recentPaneTarget(forward: true), "at the newest end there is no newer target")
        store.switchToRecentPane(forward: true) // newest → no-op
        XCTAssertEqual(store.focusedPane, b)
        store.switchToRecentPane(forward: false) // → a (oldest)
        XCTAssertEqual(store.focusedPane, a)
        XCTAssertNil(store.recentPaneTarget(forward: false), "at the oldest end there is no older target")
        store.switchToRecentPane(forward: false) // oldest → no-op
        XCTAssertEqual(store.focusedPane, a)

        let (solo, sids) = makeStore(1)
        XCTAssertNil(solo.recentPaneTarget(forward: false), "an empty ring (no focus recorded yet) has no target")
        XCTAssertTrue(solo.focusHistory.isEmpty, "a restored single-pane store has not recorded any visit yet")
        solo.switchToRecentPane(forward: false) // no-op, no crash
        XCTAssertEqual(solo.focusedPane, sids[0], "a single pane has nothing to switch to")
    }

    func testFullCanvasSwapReseedsTheRingSoQuickSwitchStaysLive() throws {
        // A layout-preset switch (and replace-import) re-mints every pane id; without re-seeding, the ring
        // would be all-dead and ⌥⌘; would silently no-op forever. After a swap the ring holds only the new
        // focused pane, and rebuilds (landing on LIVE panes) as the user navigates.
        let (store, ids) = makeStore(3)
        store.focus(ids[1])
        store.focus(ids[2]) // ring [2,1,0] of OLD ids
        store.saveLayoutPreset(name: "L") // snapshot current canvas
        // Add a couple of panes so "L" differs, then switch back to L (re-mints all ids).
        store.addPane(kind: .terminal)
        store.switchToLayoutPreset(name: "L")
        XCTAssertFalse(
            store.focusHistory.contains { !store.workspace.canvas.contains($0) },
            "no re-minted/dead id lingers in the quick-switch ring after a swap",
        )
        // Drive the new layout: focus another live pane, then quick-switch lands on a LIVE pane.
        let live = store.workspace.canvas.allIDs()
        if live.count > 1, let other = live.first(where: { $0 != store.focusedPane }) {
            store.focus(other)
            store.switchToRecentPane(forward: false)
            XCTAssertTrue(
                try store.workspace.canvas.contains(XCTUnwrap(store.focusedPane)),
                "quick-switch lands on a live pane post-swap",
            )
        }
    }

    func testClosingAPaneDropsItFromTheRing() throws {
        let (store, ids) = makeStore(3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.focus(b)
        store.focus(c) // ring [c, b, a]
        store.closePane(c) // close the current → c pruned
        XCTAssertFalse(store.focusHistory.contains(c), "a closed pane is never a quick-switch target")
        // The ring still holds the survivors; a switch never lands on the dead pane.
        store.switchToRecentPane(forward: false)
        XCTAssertNotEqual(store.focusedPane, c)
        XCTAssertTrue(try store.workspace.canvas.contains(XCTUnwrap(store.focusedPane)), "switch lands on a live pane")
    }

    func testUserFocusAfterAWalkRecordsWhereYouWere() {
        let (store, ids) = makeStore(3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.focus(b)
        store.focus(c) // ring [c, b, a]
        store.switchToRecentPane(forward: false) // walk to b (ring unchanged, no record)
        store.focus(a) // a USER focus: fronts the OUTGOING b, then a
        XCTAssertEqual(store.focusHistory.first, a, "the user focus is the new MRU front")
        store.switchToRecentPane(forward: false) // "go to last pane" → b, where the user actually was
        XCTAssertEqual(store.focusedPane, b, "the outgoing pane is recorded as the most-recent-before")
    }

    func testOpeningPanesPopulatesTheRingWithoutAnyClick() {
        // REGRESSION: the creation/raise paths assigned `workspace.focusedPane` DIRECTLY, bypassing the MRU
        // ring, so ⌥⌘; was a silent no-op until the user happened to click/arrow-focus between panes (the
        // only `focus()` caller). Opening a pane must itself record the visit (outgoing-then-incoming).
        let (store, ids) = makeStore(1)
        let first = ids[0]
        XCTAssertTrue(store.focusHistory.isEmpty, "a freshly restored single-pane store records nothing yet")
        store.addPane(kind: .terminal) // open a 2nd pane — NO focus()/click anywhere
        let second = store.focusedPane
        XCTAssertNotEqual(second, first)
        store.switchToRecentPane(forward: false) // "go to last pane" must land back on the first pane
        XCTAssertEqual(store.focusedPane, first, "opening a pane records the ring so quick-switch jumps back")
        store.switchToRecentPane(forward: true) // and forward returns to the pane we just opened
        XCTAssertEqual(store.focusedPane, second)
    }

    func testRaisingAndDuplicatingRecordTheRingToo() {
        // The raise (drag-start / focus affordance) and duplicate creation paths also set focus directly.
        let (store, ids) = makeStore(3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        store.raisePane(b) // raise b (was focused a) → ring [b, a]
        store.raisePane(c) // raise c → ring [c, b, a]
        XCTAssertEqual(store.focusHistory.prefix(3).map(\.self), [c, b, a], "raise records like a user focus")
        let dup = store.duplicatePane(a) // duplicate a NEW pane, focused
        XCTAssertEqual(store.focusedPane, dup)
        store.switchToRecentPane(forward: false) // go back to where we were (c)
        XCTAssertEqual(store.focusedPane, c, "the duplicate's creation recorded the outgoing pane")
    }
}
