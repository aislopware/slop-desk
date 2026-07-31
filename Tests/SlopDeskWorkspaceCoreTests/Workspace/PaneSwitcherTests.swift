import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The ⌃⇥ pane switcher's PURE model: how the candidate order is frozen at open, and how the
/// provisional highlight walks it.
///
/// The switcher is a MOST-RECENTLY-USED ring, not the positional ⌘]/⌘[ cycle — one ⌃⇥ press must
/// land on the pane you were last in, no matter which tab it sits in. The candidate order is
/// SNAPSHOT at open precisely so committing does not reshuffle the list under a still-held ⌃.
final class PaneSwitcherTests: XCTestCase {
    private func panes(_ count: Int) -> [PaneID] { (0..<count).map { _ in PaneID() } }

    /// Opens a switcher or fails the test — the `init?` returns nil only for fewer than two candidates,
    /// which every caller below has already established is not the case.
    private func open(_ candidates: [PaneID], forward: Bool, armed: Bool = true) throws -> PaneSwitcher {
        try XCTUnwrap(
            PaneSwitcher(candidates: candidates, forward: forward, armedByModifier: armed),
            "a multi-candidate ring must open",
        )
    }

    // MARK: - Candidate ordering

    /// The active pane leads, then the MRU ring (most-recent first), then anything never visited in
    /// creation order. This is what makes ONE ⌃⇥ land on "the pane I was just in".
    func testCandidatesPutActiveFirstThenMRUThenUnvisited() {
        let t = panes(4)
        // Visited c then b (ring is most-recent-first and includes the active pane at its head).
        let order = PaneSwitcher.candidates(
            active: t[0], mru: [t[0], t[2], t[1]], ordered: [t[0], t[1], t[2], t[3]],
        )
        XCTAssertEqual(
            order, [t[0], t[2], t[1], t[3]],
            "active leads, then MRU by recency, then the never-visited pane in flat order",
        )
    }

    /// A fresh client (nothing visited yet) has an EMPTY ring — the switcher must still offer every
    /// pane, falling through to the session's flat order rather than collapsing to a single candidate.
    func testCandidatesFallBackToCreationOrderWhenMRUIsEmpty() {
        let t = panes(3)
        let order = PaneSwitcher.candidates(active: t[1], mru: [], ordered: t)
        XCTAssertEqual(order, [t[1], t[0], t[2]], "active first, remaining panes in flat order")
    }

    /// The ring is never pruned on write, and the client mirror can lag a close either way. A
    /// candidate that no longer exists would commit a focus intent naming a dead pane.
    func testCandidatesDropMRUEntriesThatAreNoLongerLive() {
        let t = panes(3)
        let dead = PaneID()
        let order = PaneSwitcher.candidates(active: t[0], mru: [t[0], dead, t[1]], ordered: t)
        XCTAssertEqual(order, [t[0], t[1], t[2]], "the stale ring entry is dropped, live panes keep their order")
    }

    /// A device moved by ANOTHER client's focus intent has an active pane its own visit ring never
    /// saw. The local active pane still has to lead, or the first ⌃⇥ jumps relative to somewhere the
    /// user is not.
    func testCandidatesLeadWithLocalActiveEvenWhenItIsNotTheRingHead() {
        let t = panes(3)
        let order = PaneSwitcher.candidates(active: t[2], mru: [t[0], t[1], t[2]], ordered: t)
        XCTAssertEqual(order, [t[2], t[0], t[1]], "the LOCAL active pane leads, not the ring head")
    }

    /// A pane appearing twice in the ring (the local ring and the tab ring both naming it) must not be
    /// offered twice — stepping would visit the same pane at two indices.
    func testCandidatesDedupeRepeatedRingEntries() {
        let t = panes(3)
        let order = PaneSwitcher.candidates(active: t[0], mru: [t[0], t[1], t[1], t[0]], ordered: t)
        XCTAssertEqual(order, [t[0], t[1], t[2]], "duplicates collapse to first appearance")
    }

    // MARK: - Opening

    /// One pane is not switchable. Opening must FAIL so the dispatcher passes ⌃⇥ through instead of
    /// swallowing it into an empty overlay.
    func testOpeningRefusesFewerThanTwoCandidates() {
        XCTAssertNil(PaneSwitcher(candidates: [], forward: true, armedByModifier: true))
        XCTAssertNil(PaneSwitcher(candidates: [PaneID()], forward: true, armedByModifier: true))
    }

    /// The FIRST ⌃⇥ already highlights the previous pane — press-and-release with no repeat is the
    /// "flip to last pane" gesture, so the highlight opens at index 1, not 0.
    func testOpeningForwardHighlightsThePreviousPaneImmediately() throws {
        let t = panes(3)
        let switcher = try open(t, forward: true)
        XCTAssertEqual(switcher.highlightIndex, 1)
        XCTAssertEqual(switcher.highlighted, t[1], "one ⌃⇥ lands on the most-recently-used OTHER pane")
    }

    /// ⌃⇧⇥ opens at the far end of the ring (the least-recently-used pane), mirroring the macOS
    /// app switcher's reverse gesture.
    func testOpeningBackwardHighlightsTheLeastRecentTab() throws {
        let t = panes(3)
        let switcher = try open(t, forward: false)
        XCTAssertEqual(switcher.highlightIndex, 2)
        XCTAssertEqual(switcher.highlighted, t[2])
    }

    // MARK: - Stepping

    /// Repeated ⌃⇥ walks forward and WRAPS — a ring, so holding ⌃ and tapping ⇥ never dead-ends.
    func testSteppingForwardWrapsAroundTheRing() throws {
        let t = panes(3)
        var switcher = try open(t, forward: true)
        XCTAssertEqual(switcher.highlighted, t[1])
        switcher.step(forward: true)
        XCTAssertEqual(switcher.highlighted, t[2])
        switcher.step(forward: true)
        XCTAssertEqual(switcher.highlighted, t[0], "wraps back to the pane we started on")
        switcher.step(forward: true)
        XCTAssertEqual(switcher.highlighted, t[1])
    }

    /// ⇧ reverses direction mid-gesture (overshoot correction without releasing ⌃).
    func testSteppingBackwardWrapsTheOtherWay() throws {
        let t = panes(3)
        var switcher = try open(t, forward: true)
        switcher.step(forward: false)
        XCTAssertEqual(switcher.highlighted, t[0], "back from index 1 reaches the starting pane")
        switcher.step(forward: false)
        XCTAssertEqual(switcher.highlighted, t[2], "and wraps to the ring's tail")
    }

    // MARK: - Arming

    /// Opened by the HELD ⌃⇥ gesture, releasing ⌃ commits. Opened from the palette (no modifier
    /// held), a stray modifier release must NOT commit — only Return does.
    func testOnlyAModifierArmedSwitcherCommitsOnRelease() throws {
        let t = panes(2)
        XCTAssertTrue(try open(t, forward: true, armed: true).armedByModifier)
        XCTAssertFalse(try open(t, forward: true, armed: false).armedByModifier)
    }
}
