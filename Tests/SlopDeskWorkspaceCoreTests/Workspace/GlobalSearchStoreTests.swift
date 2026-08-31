import XCTest
@testable import SlopDeskWorkspaceCore

/// Store-level wiring for ⇧⌘F Global Search, observed on a ``RecordingTerminalPaneSession`` that
/// carries a REAL ``TerminalViewModel`` whose `surface` is a recording ``TerminalSurfaceActions`` — so the
/// cross-seam scrollback mirror + the libghostty-vt navigation actions are pinned WITHOUT a real `TerminalSurfaceDriver`
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
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in RecordingTerminalPaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    // MARK: - Fix #1: click-to-line

    /// Two hits in the SAME pane land DISTINCTLY via direct `scroll_to_row:<line>`: the 1st hit scrolls to
    /// row 0 and the 3rd to row 2. The amber highlight is armed through the four-mode FIND DOOR rather
    /// than through a `search:<needle>` binding string — the door carries the overlay's own mode, which the
    /// binding could not, so a case-sensitive or regex ⇧⌘F used to land with no highlight at all (gap 4).
    /// The direct scroll is used instead of an ordinal `navigate_search:next` walk because that ordinal
    /// walk is viewport-relative and wrong in case-sensitive mode (see GlobalSearchController).
    func testJumpAdvancesToClickedHitsOrdinalWithinPane() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let recorder = try XCTUnwrap(session.surfaceRecorder)
        recorder.scrollbackText = ["alpha doc", "beta doc", "gamma doc"]

        store.beginGlobalSearchSession()
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        let hits = try XCTUnwrap(store.globalSearch?.groups.first?.hits)
        XCTAssertEqual(hits.count, 3)

        recorder.resetActions()
        store.jumpToGlobalSearchResult(hits[0])
        let firstActions = recorder.actions
        let firstFind = recorder.finds.last

        recorder.resetActions()
        store.jumpToGlobalSearchResult(hits[2])
        let thirdActions = recorder.actions

        let armed = FindCall(query: "doc", caseSensitive: false, wholeWord: false, isRegex: false)
        XCTAssertEqual(firstFind, armed, "the highlight is armed through the door, in the overlay's mode")
        XCTAssertEqual(recorder.finds.last, armed)
        XCTAssertEqual(firstActions, ["scroll_to_row:0"])
        XCTAssertEqual(thirdActions, ["scroll_to_row:2"])
        XCTAssertNotEqual(
            firstActions, thirdActions,
            "two hits in one pane must produce different scroll targets (row 0 vs row 2)",
        )
    }

    /// A jump with no query armed records nothing (validate-then-drop, never traps).
    func testJumpWithEmptyQueryIsANoOp() throws {
        let store = makeStore()
        let recorder = try XCTUnwrap(activeSession(store).surfaceRecorder)
        recorder.scrollbackText = ["alpha doc"]
        store.beginGlobalSearchSession()
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        let hit = try XCTUnwrap(store.globalSearch?.groups.first?.hits.first)
        // Clear the armed query (the overlay was cleared) and jump — no actions should fire.
        store.runGlobalSearch(query: "", caseSensitive: false, isRegex: false)
        recorder.resetActions()
        let findsBefore = recorder.finds.count
        store.jumpToGlobalSearchResult(hit)
        XCTAssertEqual(recorder.actions, [], "an empty armed query arms no surface action")
        XCTAssertEqual(
            recorder.finds.count, findsBefore,
            "an empty armed query does not reach the find door either — it would clear the pane's own ⌘F highlight",
        )
    }

    // MARK: - Fix #2: snapshot once per overlay-open, not per keystroke

    /// The scrollback is mirrored across the libghostty-vt seam ONCE on overlay-open; every keystroke re-runs only
    /// the in-memory match pass and must NOT re-cross the seam. A re-open re-snapshots. Revert
    /// ``runGlobalSearch`` to gather sources on every call and the per-keystroke count assertion fails.
    func testScrollbackGatheredOncePerOverlayOpenNotPerKeystroke() throws {
        let store = makeStore()
        let recorder = try XCTUnwrap(activeSession(store).surfaceRecorder)
        recorder.scrollbackText = ["one doc", "two doc"]

        // Open: snapshot ONCE.
        store.beginGlobalSearchSession()
        XCTAssertEqual(recorder.scrollbackLinesCallCount, 1, "open crosses the seam once")

        // Three keystrokes: in-memory match pass only — the seam is not re-crossed.
        store.runGlobalSearch(query: "d", caseSensitive: false, isRegex: false)
        store.runGlobalSearch(query: "do", caseSensitive: false, isRegex: false)
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        XCTAssertEqual(
            recorder.scrollbackLinesCallCount, 1,
            "keystrokes re-run only the match pass — the scrollback seam is not re-crossed",
        )

        // Behaviour is unchanged: results are still correct over the cached sources.
        XCTAssertEqual(store.globalSearch?.totalMatches, 2)

        // A re-open re-snapshots fresh scrollback.
        store.endGlobalSearchSession()
        store.beginGlobalSearchSession()
        XCTAssertEqual(recorder.scrollbackLinesCallCount, 2, "a re-open re-snapshots")
    }

    /// Defensive: ``runGlobalSearch`` called with no active overlay session (no `begin`) still works by
    /// snapshotting on demand — identical results, just without the cache benefit.
    func testRunWithoutSessionSnapshotsOnDemand() throws {
        let store = makeStore()
        let recorder = try XCTUnwrap(activeSession(store).surfaceRecorder)
        recorder.scrollbackText = ["lone doc"]
        store.runGlobalSearch(query: "doc", caseSensitive: false, isRegex: false)
        XCTAssertEqual(store.globalSearch?.totalMatches, 1)
        XCTAssertGreaterThanOrEqual(recorder.scrollbackLinesCallCount, 1)
    }
}
