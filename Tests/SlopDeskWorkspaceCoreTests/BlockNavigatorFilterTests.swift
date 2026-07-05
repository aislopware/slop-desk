import Foundation
import SlopDeskClient
import XCTest
@testable import SlopDeskWorkspaceCore

/// WB3 — the PURE navigator filter + jump-to-failed model logic: `blocks(filter:)` (all / failed /
/// bookmarked, newest-first), `BlockNavigation.adjacentFailed` (no-wrap cursor stepping past failures),
/// the bookmark set (toggle idempotence, cap, persistence closure), and `CommandBlock.isFailed` (running
/// is never failed). All headless / view-free.
@MainActor
final class BlockNavigatorFilterTests: XCTestCase {
    /// Builds a block with the given status shape. A still-RUNNING block (`complete == false`) carries
    /// NO durationMS — matching the wire (the host only stamps a duration once a block finishes, incl.
    /// an interrupted close); the client treats a duration-stamped block as finished.
    private func block(_ index: UInt32, exit: Int32?, complete: Bool = true) -> CommandBlock {
        CommandBlock(
            index: index,
            commandText: "c\(index)",
            exitCode: exit,
            durationMS: complete ? 1 : nil,
            complete: complete,
            outputLen: 0,
        )
    }

    private func seed(_ model: TerminalBlockModel, _ blocks: [CommandBlock]) {
        for b in blocks {
            model.upsert(
                index: b.index, commandText: b.commandText, exitCode: b.exitCode,
                durationMS: b.durationMS, complete: b.complete, outputLen: b.outputLen,
            )
        }
    }

    // MARK: isFailed

    func testIsFailedOnlyForCompletedNonZero() {
        XCTAssertTrue(block(1, exit: 137).isFailed)
        XCTAssertFalse(block(1, exit: 0).isFailed, "exit 0 is success")
        XCTAssertFalse(block(1, exit: nil).isFailed, "no reported code is success")
        XCTAssertFalse(block(1, exit: 137, complete: false).isFailed, "a RUNNING block is never failed")
    }

    // MARK: blocks(filter:)

    func testFilterAllFailedBookmarked() {
        let model = TerminalBlockModel()
        // idx: 0 ok, 1 failed, 2 running, 3 failed (newest)
        seed(model, [
            block(0, exit: 0),
            block(1, exit: 2),
            block(2, exit: nil, complete: false),
            block(3, exit: 1),
        ])
        model.toggleBookmark(index: 0)
        model.toggleBookmark(index: 3)

        XCTAssertEqual(model.blocks(filter: .all).map(\.index), [3, 2, 1, 0], "all = newest-first")
        XCTAssertEqual(model.blocks(filter: .failed).map(\.index), [3, 1], "failed excludes ok + running")
        XCTAssertEqual(model.blocks(filter: .bookmarked).map(\.index), [3, 0], "bookmarked = starred, newest-first")
    }

    // MARK: adjacentFailed (newest-first, no wrap, advance past)

    private func nav(_ blocks: [CommandBlock], from: UInt32?, forward: Bool) -> UInt32? {
        BlockNavigation.adjacentFailed(in: blocks, fromIndex: from, forward: forward)?.index
    }

    func testAdjacentFailedNilWhenNoneFailed() {
        // newest-first list, all succeeded
        let list = [block(3, exit: 0), block(2, exit: 0), block(1, exit: 0)]
        XCTAssertNil(nav(list, from: nil, forward: true))
        XCTAssertNil(nav(list, from: nil, forward: false))
        XCTAssertNil(nav(list, from: 2, forward: true))
    }

    func testAdjacentFailedSingleFailedFromEnds() {
        // newest-first: [4 ok, 3 FAIL, 2 ok, 1 ok]
        let list = [block(4, exit: 0), block(3, exit: 1), block(2, exit: 0), block(1, exit: 0)]
        XCTAssertEqual(nav(list, from: nil, forward: true), 3, "forward from newest end finds the only failure")
        XCTAssertEqual(nav(list, from: nil, forward: false), 3, "backward from oldest end finds it too")
    }

    func testAdjacentFailedAdvancesPastCursorOnAFailure() {
        // newest-first: [5 FAIL, 4 ok, 3 FAIL, 2 ok, 1 FAIL]
        let list = [block(5, exit: 1), block(4, exit: 0), block(3, exit: 1), block(2, exit: 0), block(1, exit: 1)]
        // Cursor ON failed 3, forward (toward older) → the NEXT failure past it is 1.
        XCTAssertEqual(nav(list, from: 3, forward: true), 1, "forward advances past the cursor's own failure")
        // Cursor ON failed 3, backward (toward newer) → 5.
        XCTAssertEqual(nav(list, from: 3, forward: false), 5, "backward advances past the cursor's own failure")
    }

    func testAdjacentFailedStopsAtEndsNoWrap() {
        // newest-first: [5 FAIL, 4 ok, 3 ok, 2 ok, 1 FAIL]
        let list = [block(5, exit: 1), block(4, exit: 0), block(3, exit: 0), block(2, exit: 0), block(1, exit: 1)]
        // From the oldest failure (1), forward (older) → no more → nil (no wrap to 5).
        XCTAssertNil(nav(list, from: 1, forward: true), "forward off the oldest end does not wrap")
        // From the newest failure (5), backward (newer) → no more → nil.
        XCTAssertNil(nav(list, from: 5, forward: false), "backward off the newest end does not wrap")
    }

    func testAdjacentFailedSkipsSucceededAndRunning() {
        // newest-first: [4 running, 3 ok, 2 FAIL, 1 ok]
        let list = [block(4, exit: nil, complete: false), block(3, exit: 0), block(2, exit: 1), block(1, exit: 0)]
        XCTAssertEqual(nav(list, from: nil, forward: true), 2, "skips running + succeeded to the failure")
    }

    // MARK: Bookmarks (toggle idempotence, persistence closure, cap)

    func testToggleBookmarkIdempotenceAndIsBookmarked() {
        let model = TerminalBlockModel()
        XCTAssertFalse(model.isBookmarked(7))
        model.toggleBookmark(index: 7)
        XCTAssertTrue(model.isBookmarked(7))
        XCTAssertEqual(model.bookmarkedIndices, [7])
        model.toggleBookmark(index: 7) // toggle back
        XCTAssertFalse(model.isBookmarked(7))
        XCTAssertEqual(model.bookmarkedIndices, [], "two toggles return to the original set")
    }

    func testBookmarkChangeClosureFiresWithCurrentSet() {
        let model = TerminalBlockModel()
        var observed: [Set<UInt32>] = []
        model.onBookmarksChanged = { observed.append($0) }
        model.toggleBookmark(index: 1)
        model.toggleBookmark(index: 2)
        model.toggleBookmark(index: 1) // un-star 1
        XCTAssertEqual(observed, [[1], [1, 2], [2]], "the closure fires each toggle with the resulting set")
    }

    func testBookmarkCapEvictsOldest() {
        let model = TerminalBlockModel()
        let cap = TerminalBlockModel.maxBookmarks
        for i in 0..<UInt32(cap + 5) { model.toggleBookmark(index: i) }
        XCTAssertEqual(model.bookmarkedIndices.count, cap, "the set is capped at maxBookmarks")
        // The first 5 (oldest-inserted) were evicted FIFO; the newest are retained.
        XCTAssertFalse(model.isBookmarked(0), "the oldest-inserted bookmark was evicted")
        XCTAssertFalse(model.isBookmarked(4))
        XCTAssertTrue(model.isBookmarked(5), "the first surviving bookmark")
        XCTAssertTrue(model.isBookmarked(UInt32(cap + 4)), "the newest bookmark is retained")
    }

    func testSetBookmarksSeedsWithoutFiringAndTrimsToCap() {
        let model = TerminalBlockModel()
        var fired = false
        model.onBookmarksChanged = { _ in fired = true }
        model.setBookmarks([3, 9, 3, 12]) // duplicate 3 deduped
        XCTAssertEqual(model.bookmarkedIndices, [3, 9, 12])
        XCTAssertFalse(fired, "seeding from persistence does NOT fire the change closure")
    }

    func testResetClearsBookmarksWithoutFiring() {
        let model = TerminalBlockModel()
        var fired = false
        model.toggleBookmark(index: 1)
        model.onBookmarksChanged = { _ in fired = true }
        model.reset()
        XCTAssertEqual(model.bookmarkedIndices, [], "reset clears bookmarks")
        XCTAssertFalse(fired, "reset must not overwrite persistence (no closure fire)")
    }
}
