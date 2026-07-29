import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The ⌃⇥ tab switcher's PURE model: how the candidate order is frozen at open, and how the
/// provisional highlight walks it.
///
/// The switcher is a MOST-RECENTLY-USED ring, not the positional ⌘⇧]/⌘⇧[ cycle — one ⌃⇥ press must
/// land on the tab you were last in, no matter where it sits in the tab bar. The candidate order is
/// SNAPSHOT at open precisely so committing does not reshuffle the list under a still-held ⌃.
final class TabSwitcherTests: XCTestCase {
    private func tabs(_ count: Int) -> [TabID] { (0..<count).map { _ in TabID() } }

    /// Opens a switcher or fails the test — the `init?` returns nil only for fewer than two candidates,
    /// which every caller below has already established is not the case.
    private func open(_ candidates: [TabID], forward: Bool, armed: Bool = true) throws -> TabSwitcher {
        try XCTUnwrap(
            TabSwitcher(candidates: candidates, forward: forward, armedByModifier: armed),
            "a multi-candidate ring must open",
        )
    }

    // MARK: - Candidate ordering

    /// The active tab leads, then the MRU ring (most-recent first), then anything never visited in
    /// creation order. This is what makes ONE ⌃⇥ land on "the tab I was just in".
    func testCandidatesPutActiveFirstThenMRUThenUnvisited() {
        let t = tabs(4)
        // Visited c then b (ring is most-recent-first and includes the active tab at its head).
        let order = TabSwitcher.candidates(
            active: t[0], mru: [t[0], t[2], t[1]], ordered: [t[0], t[1], t[2], t[3]],
        )
        XCTAssertEqual(
            order, [t[0], t[2], t[1], t[3]],
            "active leads, then MRU by recency, then the never-visited tab in creation order",
        )
    }

    /// A cold session (nothing visited yet) has an EMPTY host ring — the switcher must still offer
    /// every tab, falling through to creation order rather than collapsing to a single candidate.
    func testCandidatesFallBackToCreationOrderWhenMRUIsEmpty() {
        let t = tabs(3)
        let order = TabSwitcher.candidates(active: t[1], mru: [], ordered: t)
        XCTAssertEqual(order, [t[1], t[0], t[2]], "active first, remaining tabs in creation order")
    }

    /// The host ring is pruned to live tabs by the applier, but the client mirror can lag a close.
    /// A candidate that no longer exists would commit a focus intent naming a dead tab.
    func testCandidatesDropMRUEntriesThatAreNoLongerLive() {
        let t = tabs(3)
        let dead = TabID()
        let order = TabSwitcher.candidates(active: t[0], mru: [t[0], dead, t[1]], ordered: t)
        XCTAssertEqual(order, [t[0], t[1], t[2]], "the stale ring entry is dropped, live tabs keep their order")
    }

    /// With device focus UNFOLLOWED (`followSessionFocus == false`) this device's active tab is NOT
    /// the host ring's head. The local active tab still has to lead, or the first ⌃⇥ jumps relative
    /// to another device's focus.
    func testCandidatesLeadWithLocalActiveEvenWhenItIsNotTheRingHead() {
        let t = tabs(3)
        let order = TabSwitcher.candidates(active: t[2], mru: [t[0], t[1], t[2]], ordered: t)
        XCTAssertEqual(order, [t[2], t[0], t[1]], "the LOCAL active tab leads, not the ring head")
    }

    /// A tab appearing twice in the ring (a mirror that folded two frames) must not be offered twice —
    /// stepping would visit the same tab at two indices.
    func testCandidatesDedupeRepeatedRingEntries() {
        let t = tabs(3)
        let order = TabSwitcher.candidates(active: t[0], mru: [t[0], t[1], t[1], t[0]], ordered: t)
        XCTAssertEqual(order, [t[0], t[1], t[2]], "duplicates collapse to first appearance")
    }

    // MARK: - Opening

    /// One tab is not switchable. Opening must FAIL so the dispatcher passes ⌃⇥ through instead of
    /// swallowing it into an empty overlay.
    func testOpeningRefusesFewerThanTwoCandidates() {
        XCTAssertNil(TabSwitcher(candidates: [], forward: true, armedByModifier: true))
        XCTAssertNil(TabSwitcher(candidates: [TabID()], forward: true, armedByModifier: true))
    }

    /// The FIRST ⌃⇥ already highlights the previous tab — press-and-release with no repeat is the
    /// "flip to last tab" gesture, so the highlight opens at index 1, not 0.
    func testOpeningForwardHighlightsThePreviousTabImmediately() throws {
        let t = tabs(3)
        let switcher = try open(t, forward: true)
        XCTAssertEqual(switcher.highlightIndex, 1)
        XCTAssertEqual(switcher.highlighted, t[1], "one ⌃⇥ lands on the most-recently-used OTHER tab")
    }

    /// ⌃⇧⇥ opens at the far end of the ring (the least-recently-used tab), mirroring the macOS
    /// app switcher's reverse gesture.
    func testOpeningBackwardHighlightsTheLeastRecentTab() throws {
        let t = tabs(3)
        let switcher = try open(t, forward: false)
        XCTAssertEqual(switcher.highlightIndex, 2)
        XCTAssertEqual(switcher.highlighted, t[2])
    }

    // MARK: - Stepping

    /// Repeated ⌃⇥ walks forward and WRAPS — a ring, so holding ⌃ and tapping ⇥ never dead-ends.
    func testSteppingForwardWrapsAroundTheRing() throws {
        let t = tabs(3)
        var switcher = try open(t, forward: true)
        XCTAssertEqual(switcher.highlighted, t[1])
        switcher.step(forward: true)
        XCTAssertEqual(switcher.highlighted, t[2])
        switcher.step(forward: true)
        XCTAssertEqual(switcher.highlighted, t[0], "wraps back to the tab we started on")
        switcher.step(forward: true)
        XCTAssertEqual(switcher.highlighted, t[1])
    }

    /// ⇧ reverses direction mid-gesture (overshoot correction without releasing ⌃).
    func testSteppingBackwardWrapsTheOtherWay() throws {
        let t = tabs(3)
        var switcher = try open(t, forward: true)
        switcher.step(forward: false)
        XCTAssertEqual(switcher.highlighted, t[0], "back from index 1 reaches the starting tab")
        switcher.step(forward: false)
        XCTAssertEqual(switcher.highlighted, t[2], "and wraps to the ring's tail")
    }

    // MARK: - Arming

    /// Opened by the HELD ⌃⇥ gesture, releasing ⌃ commits. Opened from the palette (no modifier
    /// held), a stray modifier release must NOT commit — only Return does.
    func testOnlyAModifierArmedSwitcherCommitsOnRelease() throws {
        let t = tabs(2)
        XCTAssertTrue(try open(t, forward: true, armed: true).armedByModifier)
        XCTAssertFalse(try open(t, forward: true, armed: false).armedByModifier)
    }
}
