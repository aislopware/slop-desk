import XCTest
@testable import SlopDeskWorkspaceCore

/// Store-level wiring for ⇧⌘F Global Search, observed on a ``RecordingTerminalPaneSession`` that
/// carries a REAL ``TerminalViewModel`` whose `surface` is a recording ``TerminalSurfaceActions`` — so the
/// cross-seam scrollback mirror + the libghostty navigation actions are pinned WITHOUT a real GhosttySurface
/// (the hang-safety rule: no VideoToolbox / Metal / SCStream / real window server).
///
/// Covers the two functional polish fixes:
///  1. CLICK-TO-LINE: ``WorkspaceStore/jumpToGlobalSearchResult(_:)`` advances to the CLICKED hit's ordinal
///     within its pane group, so distinct rows produce distinct navigation intent (not a single shared next).
///  2. PER-OVERLAY SNAPSHOT: the scrollback is mirrored across the seam ONCE per overlay-open, not per keystroke.
@MainActor
final class GlobalSearchStoreTests: XCTestCase {
    /// A `.tree`-live store backed by the recording (terminal-model-carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    // MARK: - Fix #1: click-to-line

    /// Two hits in the SAME pane land DISTINCTLY via direct `scroll_to_row:<line>`: the 1st hit scrolls to
    /// row 0 and the 3rd to row 2. The amber highlight is armed by the leading `search:` action (literal +
    /// case-insensitive mode). The direct scroll is used instead of an ordinal `navigate_search:next` walk
    /// because that ordinal walk is viewport-relative and wrong in case-sensitive mode (see GlobalSearchController).
    func testJumpAdvancesToClickedHitsOrdinalWithinPane() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let recorder = try XCTUnwrap(session.surfaceRecorder)
        recorder.scrollbackLines = ["alpha doc", "beta doc", "gamma doc"]

        store.beginGlobalSearchSession()
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        let hits = try XCTUnwrap(store.globalSearch?.groups.first?.hits)
        XCTAssertEqual(hits.count, 3)

        recorder.resetActions()
        store.jumpToGlobalSearchResult(hits[0])
        let firstActions = recorder.actions

        recorder.resetActions()
        store.jumpToGlobalSearchResult(hits[2])
        let thirdActions = recorder.actions

        XCTAssertEqual(firstActions, ["search:doc", "scroll_to_row:0"])
        XCTAssertEqual(thirdActions, ["search:doc", "scroll_to_row:2"])
        XCTAssertNotEqual(
            firstActions, thirdActions,
            "two hits in one pane must produce different scroll targets (row 0 vs row 2)",
        )
    }

    /// A jump with no query armed records nothing (validate-then-drop, never traps).
    func testJumpWithEmptyQueryIsANoOp() throws {
        let store = makeStore()
        let recorder = try XCTUnwrap(activeSession(store).surfaceRecorder)
        recorder.scrollbackLines = ["alpha doc"]
        store.beginGlobalSearchSession()
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        let hit = try XCTUnwrap(store.globalSearch?.groups.first?.hits.first)
        // Clear the armed query (the overlay was cleared) and jump — no actions should fire.
        store.runGlobalSearch(query: "", caseSensitive: false, isRegex: false)
        recorder.resetActions()
        store.jumpToGlobalSearchResult(hit)
        XCTAssertEqual(recorder.actions, [], "an empty armed query arms no surface action")
    }

    // MARK: - Fix #2: snapshot once per overlay-open, not per keystroke

    /// The scrollback is mirrored across the libghostty seam ONCE on overlay-open; every keystroke re-runs only
    /// the in-memory match pass and must NOT re-cross the seam. A re-open re-snapshots. Revert
    /// ``runGlobalSearch`` to gather sources on every call and the per-keystroke count assertion fails.
    func testScrollbackGatheredOncePerOverlayOpenNotPerKeystroke() throws {
        let store = makeStore()
        let recorder = try XCTUnwrap(activeSession(store).surfaceRecorder)
        recorder.scrollbackLines = ["one doc", "two doc"]

        // Open: snapshot ONCE.
        store.beginGlobalSearchSession()
        XCTAssertEqual(recorder.scrollbackTextLinesCallCount, 1, "open crosses the seam once")

        // Three keystrokes: in-memory match pass only — the seam is not re-crossed.
        store.runGlobalSearch(query: "d", caseSensitive: false, isRegex: false)
        store.runGlobalSearch(query: "do", caseSensitive: false, isRegex: false)
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        XCTAssertEqual(
            recorder.scrollbackTextLinesCallCount, 1,
            "keystrokes re-run only the match pass — the scrollback seam is not re-crossed",
        )

        // Behaviour is unchanged: results are still correct over the cached sources.
        XCTAssertEqual(store.globalSearch?.totalMatches, 2)

        // A re-open re-snapshots fresh scrollback.
        store.endGlobalSearchSession()
        store.beginGlobalSearchSession()
        XCTAssertEqual(recorder.scrollbackTextLinesCallCount, 2, "a re-open re-snapshots")
    }

    /// Defensive: ``runGlobalSearch`` called with no active overlay session (no `begin`) still works by
    /// snapshotting on demand — identical results, just without the cache benefit.
    func testRunWithoutSessionSnapshotsOnDemand() throws {
        let store = makeStore()
        let recorder = try XCTUnwrap(activeSession(store).surfaceRecorder)
        recorder.scrollbackLines = ["lone doc"]
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        XCTAssertEqual(store.globalSearch?.totalMatches, 1)
        XCTAssertGreaterThanOrEqual(recorder.scrollbackTextLinesCallCount, 1)
    }
}
