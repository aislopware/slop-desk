// L3BlockHistoryTests — pure command-block logic (REBUILD-V2 L3), today surfaced by the ⌃⌘O Command
// Navigator overlay (the old inspector Commands panel is removed).
//
// Logic-level only: the "Failed only" filter (`TerminalBlockModel.blocks(filter:)`),
// the `CommandBlock` status → symbol/label/tint mapping, and the bookmark
// toggle. NO view rendering (no libghostty / Metal / surface). The block model
// is pure + `@MainActor`, so these run headless under the guarded runner.

import AislopdeskWorkspaceCore
import XCTest

@MainActor
final class L3BlockHistoryTests: XCTestCase {
    /// Builds a model with three blocks: a success, a running one, and a failure.
    private func makeModel() -> TerminalBlockModel {
        let model = TerminalBlockModel()
        model.upsert(index: 0, commandText: "ls", exitCode: 0, durationMS: 12, complete: true, outputLen: 40)
        model.upsert(index: 1, commandText: "sleep 5", exitCode: nil, durationMS: nil, complete: false, outputLen: 0)
        model.upsert(index: 2, commandText: "false", exitCode: 1, durationMS: 3, complete: true, outputLen: 0)
        return model
    }

    // MARK: Failed-only filter (the inspector's toggle)

    func testAllFilterIsNewestFirst() {
        let model = makeModel()
        let all = model.blocks(filter: .all)
        XCTAssertEqual(all.map(\.index), [2, 1, 0], "navigator shows newest-first")
    }

    func testFailedFilterKeepsOnlyCompletedNonZeroExits() {
        let model = makeModel()
        let failed = model.blocks(filter: .failed)
        XCTAssertEqual(failed.map(\.index), [2], "only the completed non-zero exit is failed")
    }

    func testRunningBlockIsNeverFailed() {
        let model = makeModel()
        let running = model.block(at: 1)
        XCTAssertEqual(running?.status, .running)
        XCTAssertFalse(running?.isFailed ?? true, "a running block has no exit code → never failed")
    }

    // MARK: Row status → presentation mapping (BlockRowView reads these)

    func testSucceededRowMapping() {
        let block = CommandBlock(index: 0, commandText: "ls", exitCode: 0, durationMS: 12, complete: true)
        XCTAssertEqual(block.status, .succeeded)
        XCTAssertEqual(block.statusSymbol, "checkmark.circle.fill")
        XCTAssertEqual(block.statusLabel, "exit 0")
        XCTAssertEqual(block.durationLabel, "12ms")
        XCTAssertFalse(block.isFailed)
    }

    func testFailedRowMapping() {
        let block = CommandBlock(index: 2, commandText: "false", exitCode: 137, durationMS: 1500, complete: true)
        XCTAssertEqual(block.status, .failed(code: 137))
        XCTAssertEqual(block.statusSymbol, "xmark.octagon.fill")
        XCTAssertEqual(block.statusLabel, "exit 137")
        XCTAssertEqual(block.durationLabel, "1.5s", "≥1000ms formats as seconds with one decimal")
        XCTAssertTrue(block.isFailed)
    }

    func testRunningRowMapping() {
        let block = CommandBlock(index: 1, commandText: "sleep 5", complete: false)
        XCTAssertEqual(block.status, .running)
        XCTAssertEqual(block.statusSymbol, "circle.dotted")
        XCTAssertEqual(block.statusLabel, "running…")
        XCTAssertNil(block.durationLabel, "no duration while running")
    }

    // MARK: Bookmark toggle (the row context menu's Star/Unstar)

    func testToggleBookmarkRoundTrips() {
        let model = makeModel()
        XCTAssertFalse(model.isBookmarked(2))
        model.toggleBookmark(index: 2)
        XCTAssertTrue(model.isBookmarked(2))
        XCTAssertEqual(model.blocks(filter: .bookmarked).map(\.index), [2])
        model.toggleBookmark(index: 2)
        XCTAssertFalse(model.isBookmarked(2))
        XCTAssertTrue(model.blocks(filter: .bookmarked).isEmpty)
    }
}
