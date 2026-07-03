// SidebarGitAndRenameStoreTests — pins the C3 sidebar-row store surface:
//   • BUG B: `renamePane` writes the pane spec title (so the rail's `rowTitle` precedence surfaces it) and
//     the pending-rename request flows through `requestRenameTab` / `clearTabRenameRequest`.
//   • BUG C: the git-line freshness policy — `shouldRefreshGitOnSnapshot` populates once, then re-fetches
//     ONLY a stale ACTIVE pane; `applyGitSummary` stamps freshness, dirty-guards, and FANS a fetch out to
//     same-repo sibling panes.
//
// Headless: a `.tree` store over `FakePaneSession` (no socket / video / Metal — the hang-safety rule). Every
// assertion fails on the pre-C3 store (which had no `renamePane` / `requestRenameTab` / `applyGitSummary` /
// `shouldRefreshGitOnSnapshot` / `paneGitFetchedAt`), so none is tautological.

import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

@MainActor
final class SidebarGitAndRenameStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    private func firstPane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
    }

    private func firstTab(_ store: WorkspaceStore) throws -> TabID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
    }

    // MARK: - BUG B: rename

    /// `requestRenameTab` arms the pending state for an ARBITRARY tab; `clearTabRenameRequest` clears it
    /// (escape / commit-done). No rename happens on either — the field open/close is pure view state.
    func testRequestAndClearTabRename() throws {
        let store = makeStore()
        let tab = try firstTab(store)
        XCTAssertNil(store.pendingTabRename, "no pending rename at rest")
        store.requestRenameTab(tab)
        XCTAssertEqual(store.pendingTabRename, tab, "requestRenameTab arms the pending state for that tab")
        store.clearTabRenameRequest()
        XCTAssertNil(store.pendingTabRename, "escape / commit clears the pending state")
    }

    /// `renamePane` writes the pane spec `title` so the rail's `rowTitle` precedence surfaces it (the row
    /// shows the rename, winning over the cwd folder name).
    func testRenamePaneWritesSpecTitle() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        store.setLastKnownCwd("/Users/me/project-x", for: pane)
        store.renamePane(pane, to: "  build box  ")
        XCTAssertEqual(store.tree.spec(for: pane)?.title, "build box", "trimmed rename lands on the spec title")
    }

    /// A blank / whitespace rename is a NO-OP (keeps the prior title) — the field never blanks the row back
    /// to an empty title (the folder-name fallback stays).
    func testRenamePaneBlankIsNoOp() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        store.renamePane(pane, to: "Keep")
        store.renamePane(pane, to: "   ")
        XCTAssertEqual(store.tree.spec(for: pane)?.title, "Keep", "a blank rename does not clobber the title")
    }

    /// The palette / ⌘R entry (`requestRenameActivePane`) arms the ACTIVE tab's pending rename on the tree
    /// model — the value the representative rail row keys its inline field off.
    func testRequestRenameActivePaneArmsActiveTab() throws {
        let store = makeStore()
        let tab = try firstTab(store)
        store.requestRenameActivePane()
        XCTAssertEqual(store.pendingTabRename, tab, "the active-pane rename entry arms the active tab")
    }

    // MARK: - BUG C: git-line freshness policy

    /// The snapshot edge ALWAYS populates a pane with no cached line yet (the initial connect populate).
    func testSnapshotRefreshesWhenNoEntry() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        XCTAssertTrue(store.shouldRefreshGitOnSnapshot(pane), "no entry yet ⇒ populate on the snapshot edge")
    }

    /// Once populated, a FRESH active pane is NOT re-fetched on the snapshot edge (the cadence is not a poll).
    func testSnapshotSkipsFreshActivePane() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        let now = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo", for: pane, at: now)
        XCTAssertTrue(store.isActivePane(pane), "the sole pane is active")
        XCTAssertFalse(
            store.shouldRefreshGitOnSnapshot(pane, now: now.addingTimeInterval(5)),
            "a fresh active pane is within the staleness window ⇒ no re-fetch",
        )
    }

    /// A STALE active pane (older than the staleness window) IS re-fetched on the snapshot edge — so an idle
    /// pane that never runs a command still self-heals its git line.
    func testSnapshotRefreshesStaleActivePane() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        let fetched = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo", for: pane, at: fetched)
        let later = fetched.addingTimeInterval(WorkspaceStore.gitSummaryStaleWindow + 5)
        XCTAssertTrue(
            store.shouldRefreshGitOnSnapshot(pane, now: later),
            "a stale active pane re-fetches on the snapshot edge",
        )
    }

    /// A BACKGROUND (non-active) pane is never re-fetched on the snapshot edge even when stale — the cheap
    /// bounded rule only touches the pane the user is looking at (a reconnect refreshes the rest).
    func testSnapshotSkipsStaleBackgroundPane() throws {
        let store = makeStore()
        let active = try firstPane(store)
        store.newTab(kind: .terminal, launchGrace: .zero) // a 2nd tab; the first pane is now backgrounded
        XCTAssertFalse(store.isActivePane(active), "the first pane is no longer active")
        let fetched = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo", for: active, at: fetched)
        let later = fetched.addingTimeInterval(WorkspaceStore.gitSummaryStaleWindow + 5)
        XCTAssertFalse(
            store.shouldRefreshGitOnSnapshot(active, now: later),
            "a stale BACKGROUND pane is not re-fetched on the snapshot edge",
        )
    }

    /// `applyGitSummary` stamps the freshness clock and dirty-guards the write.
    func testApplyGitSummaryStampsFetchedAt() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        let now = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo", for: pane, at: now)
        XCTAssertEqual(store.paneGitFetchedAt[pane], now, "the fetch timestamp is recorded")
        XCTAssertEqual(store.paneGitSummary[pane], repoSummary(), "the summary is written")
    }

    /// A fetch for pane X FANS out to a sibling pane in the SAME repo (matching cached toplevel) — so a
    /// sibling-pane commit is reflected without waiting for the sibling's own command edge. The dirty guard
    /// and freshness stamp apply to the fanned-to pane too.
    func testApplyGitSummaryFansToSameRepoSiblings() throws {
        let store = makeStore()
        let a = try firstPane(store)
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let panes = try XCTUnwrap(store.tree.activeSession?.activeTab?.allPaneIDs())
        let b = try XCTUnwrap(panes.first { $0 != a })
        // Both panes are in the same repo toplevel.
        store.cacheGitToplevel("/repo", for: a)
        store.cacheGitToplevel("/repo", for: b)
        let now = Date()
        let summary = repoSummary(branch: "feature", changed: 7)
        store.applyGitSummary(summary, toplevel: "/repo", for: a, at: now)
        XCTAssertEqual(store.paneGitSummary[b], summary, "the fetch fans out to the same-repo sibling")
        XCTAssertEqual(store.paneGitFetchedAt[b], now, "and stamps the sibling's freshness clock")
    }

    /// The fan-out is SCOPED to the same toplevel: a sibling in a DIFFERENT repo is left untouched.
    func testApplyGitSummaryDoesNotFanAcrossRepos() throws {
        let store = makeStore()
        let a = try firstPane(store)
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let panes = try XCTUnwrap(store.tree.activeSession?.activeTab?.allPaneIDs())
        let b = try XCTUnwrap(panes.first { $0 != a })
        store.cacheGitToplevel("/repo-a", for: a)
        store.cacheGitToplevel("/repo-b", for: b)
        store.applyGitSummary(repoSummary(), toplevel: "/repo-a", for: a, at: Date())
        XCTAssertNil(store.paneGitSummary[b], "a different-repo sibling is not touched")
    }

    /// An EMPTY toplevel ("no repo") never fans out even to a pane that also caches an empty toplevel.
    func testApplyGitSummaryEmptyToplevelDoesNotFan() throws {
        let store = makeStore()
        let a = try firstPane(store)
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let panes = try XCTUnwrap(store.tree.activeSession?.activeTab?.allPaneIDs())
        let b = try XCTUnwrap(panes.first { $0 != a })
        store.cacheGitToplevel("", for: b)
        store.applyGitSummary(repoSummary(), toplevel: "", for: a, at: Date())
        XCTAssertNil(store.paneGitSummary[b], "an empty toplevel is 'no repo', not a shared key ⇒ no fan-out")
    }

    /// A closed pane's freshness stamp is pruned on reconcile (no leak / stale freshness on a recycled id).
    func testFetchedAtPrunedWhenTabCloses() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let tab = try firstTab(store)
        let pane = try firstPane(store)
        store.applyGitSummary(repoSummary(), toplevel: "/repo", for: pane, at: Date())
        XCTAssertNotNil(store.paneGitFetchedAt[pane])
        store.closeTab(tab)
        XCTAssertNil(store.paneGitFetchedAt[pane], "a closed pane's freshness stamp is pruned")
    }

    // MARK: - Fixtures

    private func repoSummary(branch: String = "main", changed: Int = 2) -> PaneGitSummary {
        PaneGitSummary(hasRepo: true, branch: branch, ahead: 0, behind: 0, changedCount: changed)
    }
}
