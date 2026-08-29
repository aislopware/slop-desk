import XCTest
@testable import SlopDeskWorkspaceCore

/// `docs/65` §2 — the ONE place in the store's port where a measurement, not a rule, picks the design.
///
/// ``WorkspaceStore/tree`` is read dozens of times per layout pass by every tracked arm in both
/// shells, so the rule the rest of the port follows — *the decision goes to Rust* — would, taken
/// literally, put an FFI crossing on the hottest read in the client. It does not, and the reason is
/// this file: a read of ``WorkspaceMirrorBox/topology`` decodes the WHOLE document across the
/// boundary and re-runs `WorkspaceTopology(entries:)` over every cell in it, while a memo hit is a
/// counter compare. So the projection stays a Swift memo — keyed on a revision the HANDLE owns
/// (``WorkspaceCoreHandle/revision``), rebuilt from one whole-topology delivery when that counter
/// moves. Cross once per change, never per read, exactly as `docs/64`'s table does.
///
/// The margin asserted below is deliberately far looser than the measured gap. These are wall-clock
/// ratios, which read machine load, and the failure this test exists to catch is a STRUCTURAL one —
/// somebody removing the memo, or keying it on something that moves per read — which shows up as a
/// ratio near 1, not as a few percent of drift.
@MainActor
final class TreeProjectionMemoTests: XCTestCase {
    /// A store on the loopback document with `panes` leaves, which is what makes the projection cost
    /// anything at all: the walk is per cell.
    private func makeStore(panes: Int) -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        while store.tree.allPaneIDs().count < panes {
            store.splitActivePane(axis: .horizontal, kind: .terminal)
        }
        return store
    }

    /// The memoized read is DRAMATICALLY cheaper than the crossing it stands in for.
    ///
    /// Both loops read the same document the same number of times; only the memo differs. If the
    /// projection ever starts crossing per read, the two converge and this fails.
    func testTheMemoIsWorthKeepingAgainstACrossingPerRead() {
        let store = makeStore(panes: 12)
        let reads = 2000

        // Warm both paths, so neither loop pays a first-touch cost the other does not.
        _ = store.tree
        _ = store.workspaceMirror.topology

        let memoStart = ContinuousClock.now
        for _ in 0..<reads { XCTAssertFalse(store.tree.allPaneIDs().isEmpty) }
        let memoized = ContinuousClock.now - memoStart

        let crossStart = ContinuousClock.now
        for _ in 0..<reads { XCTAssertNotNil(store.workspaceMirror.topology) }
        let crossing = ContinuousClock.now - crossStart

        XCTAssertLessThan(
            memoized * 10,
            crossing,
            """
            \(reads) memoized `tree` reads took \(memoized), \(reads) uncached crossings took \
            \(crossing). A ratio this close means the memo is gone or its key moves per read — \
            docs/65 §2 keeps the projection in Swift precisely because this gap is large.
            """,
        )
    }

    /// The memo's key is the CORE's counter, and every mutation moves it.
    ///
    /// The structural half of the same claim: a projection is only as correct as the revision it is
    /// keyed on, and that revision now has exactly one owner. A mutation that failed to move it
    /// would freeze the layout — which is why the counter is deliberately the coarser of the two
    /// errors it can make.
    func testEveryMutationMovesTheCounterTheProjectionIsKeyedOn() {
        let store = makeStore(panes: 3)
        XCTAssertEqual(
            store.workspaceMirrorRevision,
            store.core.revision,
            "the published shadow is the core's counter, never a second one",
        )

        let before = store.workspaceMirrorRevision
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        XCTAssertGreaterThan(store.workspaceMirrorRevision, before, "a document frame moved the key")
        XCTAssertEqual(store.workspaceMirrorRevision, store.core.revision, "and it stayed the core's")

        // The two LOCAL overlays touch no document at all, so nothing else would move the key for
        // them — and a drag frame that skipped it would neither repaint nor invalidate.
        let beforeDrag = store.workspaceMirrorRevision
        store.setLiveDividerWeight(nil)
        XCTAssertGreaterThan(store.workspaceMirrorRevision, beforeDrag, "the divider preview moved it too")
        XCTAssertEqual(store.workspaceMirrorRevision, store.core.revision)
    }
}
