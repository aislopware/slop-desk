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
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

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

    // MARK: - BUG C (project-scoped): git freshness policy on the section header

    /// The snapshot edge ALWAYS populates a project with no cached entry yet (the initial connect
    /// populate) — through ANY of its panes.
    func testSnapshotRefreshesWhenProjectHasNoEntry() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        store.setProjectKey("/repo", for: pane)
        XCTAssertTrue(store.shouldRefreshGitOnSnapshot(pane), "no entry yet ⇒ populate on the snapshot edge")
    }

    /// A pane with NO section identity at all (no key, no cwd) books nothing and never fires.
    func testSnapshotSkipsKeylessPane() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        XCTAssertNil(store.tree.spec(for: pane)?.lastKnownCwd, "precondition: no cwd")
        XCTAssertFalse(store.shouldRefreshGitOnSnapshot(pane), "no section identity ⇒ no git bookkeeping")
    }

    /// Once populated, the ACTIVE project is re-fetched only past its (tight) window — fresh skips,
    /// stale fires. The active window is deliberately TIGHTER than the background one.
    func testSnapshotActiveProjectUsesTightWindow() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        store.setProjectKey("/repo", for: pane)
        let now = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo", fallbackKey: nil, at: now)
        XCTAssertTrue(store.isActiveProject("/repo"), "the sole pane's project is active")
        XCTAssertFalse(
            store.shouldRefreshGitOnSnapshot(pane, now: now.addingTimeInterval(5)),
            "fresh within the active window ⇒ no re-fetch",
        )
        XCTAssertTrue(
            store.shouldRefreshGitOnSnapshot(
                pane, now: now.addingTimeInterval(WorkspaceStore.gitSummaryStaleWindowActiveProject + 1),
            ),
            "past the ACTIVE window the focused project self-heals (external edits land within seconds)",
        )
        XCTAssertLessThan(
            WorkspaceStore.gitSummaryStaleWindowActiveProject, WorkspaceStore.gitSummaryStaleWindow,
            "the active project's window is tighter than the background one",
        )
    }

    /// A BACKGROUND project (no pane of it focused) now self-heals too — past the (longer)
    /// background window. THE core fix for "git status only updates on focus": before, a
    /// non-active pane was never re-fetched on this edge at all.
    func testSnapshotRefreshesStaleBackgroundProject() throws {
        let store = makeStore()
        let background = try firstPane(store)
        store.setProjectKey("/repo", for: background)
        store.newTab(kind: .terminal, launchGrace: .zero) // a 2nd tab; the first pane is now backgrounded
        let active = try firstPane(store)
        store.setProjectKey("/other", for: active)
        XCTAssertFalse(store.isActiveProject("/repo"), "the first pane's project is backgrounded")
        let fetched = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo", fallbackKey: nil, at: fetched)
        XCTAssertFalse(
            store.shouldRefreshGitOnSnapshot(background, now: fetched.addingTimeInterval(30)),
            "fresh within the background window ⇒ no re-fetch (the cadence is not a poll)",
        )
        XCTAssertTrue(
            store.shouldRefreshGitOnSnapshot(
                background, now: fetched.addingTimeInterval(WorkspaceStore.gitSummaryStaleWindow + 5),
            ),
            "a stale BACKGROUND project re-fetches — the inactive section header stays honest",
        )
    }

    /// `applyGitSummary` books under the reply's TOPLEVEL (normalized), stamps the clock, and — while
    /// the probed pane is still sectioned by a cwd-fallback ALIAS — mirrors the entry there too, so
    /// the interim section's header is already correct.
    func testApplyGitSummaryBooksUnderToplevelAndAlias() {
        let store = makeStore()
        let now = Date()
        store.applyGitSummary(repoSummary(), toplevel: "/repo/", fallbackKey: "/repo/sub", at: now)
        XCTAssertEqual(store.projectGitSummary["/repo"], repoSummary(), "booked under the NORMALIZED toplevel")
        XCTAssertEqual(store.projectGitFetchedAt["/repo"], now, "the fetch timestamp is recorded")
        XCTAssertEqual(
            store.projectGitSummary["/repo/sub"], repoSummary(),
            "the cwd-fallback alias section renders the same truth during the type-34 window",
        )
    }

    /// A NO-REPO reply (empty toplevel) books under the probed pane's own section key — the
    /// scheduler backs off for plain-directory sections too instead of re-probing every edge.
    func testApplyGitSummaryEmptyToplevelBooksUnderFallback() {
        let store = makeStore()
        let now = Date()
        let summary = PaneGitSummary(hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0)
        store.applyGitSummary(summary, toplevel: "", fallbackKey: "/scratch", at: now)
        XCTAssertEqual(store.projectGitSummary["/scratch"], summary, "booked under the section key")
        store.applyGitSummary(summary, toplevel: "", fallbackKey: nil, at: now)
        XCTAssertEqual(store.projectGitSummary.count, 1, "no key at all ⇒ nothing to book under")
    }

    /// The alias may NEVER cross repos: a fallback key OUTSIDE the reply's toplevel subtree (a
    /// stale host key across an un-re-pushed cross-repo `cd`) books nothing — booking repoB's
    /// summary under "/repoA" would overwrite an unrelated section's genuinely-correct header.
    func testApplyGitSummaryNeverAliasesAcrossRepos() {
        let store = makeStore()
        let repoA = repoSummary(branch: "a-truth")
        store.applyGitSummary(repoA, toplevel: "/repoA", fallbackKey: nil, at: Date())
        store.applyGitSummary(
            repoSummary(branch: "b-imposter"), toplevel: "/repoB", fallbackKey: "/repoA", at: Date(),
        )
        XCTAssertEqual(
            store.projectGitSummary["/repoA"], repoA,
            "a foreign fallback key (not inside /repoB's subtree) must not be overwritten",
        )
        XCTAssertEqual(store.projectGitSummary["/repoB"]?.branch, "b-imposter", "the toplevel booking stands")
    }

    /// A reading raced into a transient plugin-cache dir is dropped WHOLESALE (never poisons a header).
    func testApplyGitSummaryDropsPluginPoison() {
        let store = makeStore()
        store.applyGitSummary(
            repoSummary(),
            toplevel: "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions",
            fallbackKey: "/repo",
            at: Date(),
        )
        XCTAssertTrue(store.projectGitSummary.isEmpty, "a plugin-cache toplevel is dropped, alias included")
    }

    /// A HOST PUSH (wire type 35) books the summary AND the push clock; while the push is fresh the
    /// snapshot poll backs off to the (long) push-grace window instead of the active/background one.
    func testPushedSummaryBooksAndBacksOffThePoll() throws {
        let store = makeStore()
        let pane = try firstPane(store)
        store.setProjectKey("/repo", for: pane)
        let now = Date()
        store.applyPushedProjectGitSummary(repoSummary(branch: "push"), repoRoot: "/repo", at: now)
        XCTAssertEqual(store.projectGitSummary["/repo"], repoSummary(branch: "push"), "the push lands")
        XCTAssertFalse(
            store.shouldRefreshGitOnSnapshot(
                pane, now: now.addingTimeInterval(WorkspaceStore.gitSummaryStaleWindow + 5),
            ),
            "while pushes are fresh the poll stands down (the watcher owns freshness)",
        )
        XCTAssertTrue(
            store.shouldRefreshGitOnSnapshot(
                pane, now: now.addingTimeInterval(WorkspaceStore.gitSummaryPushGraceWindow + 5),
            ),
            "pushes stopped arriving ⇒ the poll re-arms as the safety net",
        )
    }

    /// A closed project's entries are pruned on reconcile — and KEPT while any live pane still
    /// sections under the key (no leak, no premature drop).
    func testProjectEntriesPrunedWhenLastPaneCloses() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let tab = try firstTab(store)
        let pane = try firstPane(store)
        store.setProjectKey("/repo", for: pane)
        store.applyGitSummary(repoSummary(), toplevel: "/repo", fallbackKey: nil, at: Date())
        XCTAssertNotNil(store.projectGitSummary["/repo"])
        store.closeTab(tab)
        XCTAssertNil(store.projectGitSummary["/repo"], "the last pane closing prunes the project entry")
        XCTAssertNil(store.projectGitFetchedAt["/repo"], "clock pruned with it")
    }

    // MARK: - Fixtures

    private func repoSummary(branch: String = "main", changed: Int = 2) -> PaneGitSummary {
        PaneGitSummary(hasRepo: true, branch: branch, ahead: 0, behind: 0, changedCount: changed)
    }
}
