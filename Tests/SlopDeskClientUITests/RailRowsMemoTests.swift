// RailRowsMemoTests — pins the sidebar perf fix (NavigatorColumn rebuilt the WHOLE rail model on
// every per-pane status tick, because `RailRowsBuilder.rows(for:)` reads every volatile store dictionary
// inside the view body). The fix is Option B memoization:
//   • `RailRowsMemo` caches the built `[RailRow]` keyed by a STRUCTURAL fingerprint (tab/pane ids, specs,
//     project keys, the title-process fallback) — a VOLATILE tick (agent status, completion badge,
//     git summary, OSC 9;4 progress, read-only flip, foreground process of a cwd-titled pane) is a cache
//     HIT (no O(panes) rebuild, and crucially no volatile-dict READ, so Observation stops invalidating the
//     sidebar body on those ticks), while a STRUCTURAL change (tab open/close, cwd, rename) rebuilds;
//   • the row VIEW reads its own pane's volatile chrome live via `RailRowsBuilder.liveChrome(for:store:)`,
//     so what the user sees never goes stale even though the cached model does.
// SwiftUI render counts are not headlessly testable — the cache-hit `buildCount` assertions plus the
// stale-cache-vs-fresh-chrome assertions are the invalidation-shape proxy.
//
// Headless: same `MountTestPaneSession` tree-model store as `RailRowBuilderTests` (no socket / video /
// Metal).

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class RailRowsMemoTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// A rich store: three tabs across two projects, one split tab, plus seeded statuses/git/process — the
    /// same shape `RailRowBuilderTests.makeThreeProjectStore` pins, with volatile chrome layered on.
    private func makeRichStore() -> WorkspaceStore {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab 2
        store.newTab(kind: .terminal, launchGrace: .zero) // tab 3
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/Users/me/alpha", for: rows[0].id)
        store.setLastKnownCwd("/Users/me/alpha", for: rows[1].id)
        store.setLastKnownCwd("/Users/me/beta", for: rows[2].id)
        store.setAgentStatus(.working, for: rows[0].id)
        store.setForegroundProcess("caffeinate", for: rows[1].id)
        store.paneGitSummary[rows[2].id] = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 1, behind: 0, changedCount: 2, modified: 2,
        )
        return store
    }

    /// ⌘T chooser → pick Terminal — the rail row must retitle
    /// from "New Pane" to the cwd folder name on the very next memo read.
    func testNewPaneMintRebuildsMemoRowTitle() throws {
        let store = makeStore()
        let source = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.setLastKnownCwd("/Users/me/projects/slop-desk/Sources/CSlopDeskSIMD", for: source)
        let memo = RailRowsMemo()
        _ = memo.rows(for: store)

        store.newTerminalPane(.newTab)
        let added = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let rowsAfter = memo.rows(for: store)
        XCTAssertEqual(
            rowsAfter.first { $0.id == added }?.title, "Sources/CSlopDeskSIMD",
            "the new terminal inherits the cwd and titles by folder name (parent-qualified against the source pane collision)",
        )
    }

    // MARK: - Output parity (the memo must be invisible to the model the sidebar renders)

    /// A memo MISS (first build) returns exactly what the pure builder returns — rows AND the per-pane
    /// By-Project sectioning derived from them. Any divergence would silently change the sidebar layout.
    func testMemoMatchesBuilderOutput() {
        let store = makeRichStore()
        let memo = RailRowsMemo()
        let viaMemo = memo.rows(for: store)
        let direct = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(viaMemo, direct, "the memoized rows are the builder's rows, field for field")
        XCTAssertEqual(
            RailRowsBuilder.sectionedByProject(viaMemo, tabOrder: store.flatOrderedTabIDs(), query: ""),
            RailRowsBuilder.sectionedByProject(direct, tabOrder: store.flatOrderedTabIDs(), query: ""),
            "sectioning over the memoized rows is unchanged",
        )
        XCTAssertEqual(memo.buildCount, 1, "one build for the first read")
    }

    // MARK: - Cache HIT on volatile ticks (the perf claim)

    /// Every VOLATILE mutation the audit lists (agent status, completion badge, git summary, OSC 9;4
    /// progress, read-only flip, foreground process of a cwd-titled pane, rename-mode flag) is a cache HIT:
    /// `buildCount` stays 1 and the returned array is the SAME cached snapshot (== the pre-tick rows). This
    /// is the invalidation-shape pin — a key that accidentally read a volatile dict would rebuild here.
    func testVolatileTicksAreCacheHits() {
        let store = makeRichStore()
        let memo = RailRowsMemo()
        let before = memo.rows(for: store)
        let pane = before[0].id

        store.setAgentStatus(.needsPermission, for: pane)
        store.setCompletionBadge(.failure, for: pane)
        store.paneGitSummary[pane] = PaneGitSummary(
            hasRepo: true, branch: "dev", ahead: 0, behind: 3, changedCount: 1, modified: 1,
        )
        store.handleProgress(.determinate(percent: 40), for: pane)
        store.setPaneReadOnly(pane, true)
        store.setForegroundProcess("vim", for: pane) // pane HAS a cwd → its title never reads the process
        store.requestRenameTab(before[0].tabID)

        let after = memo.rows(for: store)
        XCTAssertEqual(memo.buildCount, 1, "volatile ticks must NOT rebuild the row model")
        XCTAssertEqual(after, before, "a cache hit returns the same (stale-by-design) snapshot")
    }

    // MARK: - Structural changes rebuild

    /// Opening a tab, changing a cwd (retitles + resections), and an explicit rename each MISS the cache
    /// and rebuild — the rows the sidebar diffs are fresh whenever the structure genuinely changed.
    func testStructuralChangesRebuild() {
        let store = makeRichStore()
        let memo = RailRowsMemo()
        _ = memo.rows(for: store)

        store.newTab(kind: .terminal, launchGrace: .zero)
        let afterNewTab = memo.rows(for: store)
        XCTAssertEqual(memo.buildCount, 2, "a new tab is a structural change → rebuild")
        XCTAssertEqual(afterNewTab.count, 5, "the new tab's pane row is present")

        store.setLastKnownCwd("/Users/me/gamma", for: afterNewTab[4].id)
        let afterCwd = memo.rows(for: store)
        XCTAssertEqual(memo.buildCount, 3, "a cwd change retitles/resections → rebuild")
        XCTAssertEqual(afterCwd[4].title, "gamma", "and the rebuilt row carries the new folder-name title")

        store.renamePane(afterCwd[4].id, to: "deploy box")
        let afterRename = memo.rows(for: store)
        XCTAssertEqual(memo.buildCount, 4, "an explicit rename → rebuild")
        XCTAssertEqual(afterRename[4].title, "deploy box")
    }

    /// Title-resolution asymmetry: a CWD-LESS pane titles itself by its foreground process, so a process change on such a
    /// pane IS structural (rebuild, new title) — while the same mutation on a cwd-titled pane stays a cache
    /// hit (pinned above). This is the one volatile dict the key may read, and only for panes that need it.
    func testForegroundProcessRebuildsOnlyForCwdlessPaneTitle() {
        let store = makeStore() // single fresh pane, NO cwd
        let memo = RailRowsMemo()
        let before = memo.rows(for: store)
        XCTAssertNotEqual(
            before[0].title,
            "vim",
            "a cwd-less pane has no folder-name title yet, only the generic chain",
        )

        store.setForegroundProcess("vim", for: before[0].id)
        let after = memo.rows(for: store)
        XCTAssertEqual(memo.buildCount, 2, "the pane is TITLED by its process → the change is structural")
        XCTAssertEqual(after[0].title, "vim", "and the rebuilt row shows it")
    }

    // MARK: - Search path (perf audit follow-up: an active query must NOT bypass the memo)

    /// The sidebar's search path composes `filtered`/`sectionedByProject(query:)` over the MEMOIZED rows
    /// (`NavigatorColumn.renderedRows` no longer falls back to a direct `RailRowsBuilder.rows(for:)` while
    /// a query is active — that re-registered every volatile dict on the body and re-ran the full O(panes)
    /// build per tick). Two pins: (1) a volatile tick while a query is up stays a cache HIT (`buildCount`
    /// frozen, same array snapshot), and (2) a structural change while searching still rebuilds and the
    /// new row is reachable through the filter.
    func testActiveQueryVolatileTickIsCacheHitAndStructuralChangeStillRebuilds() throws {
        let store = makeRichStore()
        let memo = RailRowsMemo()
        let query = "alpha"
        let before = RailRowsBuilder.filtered(memo.rows(for: store), query: query)
        XCTAssertEqual(memo.buildCount, 1)
        XCTAssertFalse(before.isEmpty, "the query matches the /Users/me/alpha rows")

        // Volatile ticks with the query active: NO rebuild — the exact storm the old bypass re-created.
        store.setAgentStatus(.needsPermission, for: before[0].id)
        store.handleProgress(.determinate(percent: 40), for: before[0].id)
        store.paneGitSummary[before[0].id] = PaneGitSummary(
            hasRepo: true, branch: "dev", ahead: 2, behind: 0, changedCount: 1, modified: 1,
        )
        let afterTicks = RailRowsBuilder.filtered(memo.rows(for: store), query: query)
        XCTAssertEqual(memo.buildCount, 1, "volatile ticks during search must NOT rebuild the row model")
        XCTAssertEqual(afterTicks, before, "the search filter serves the same cached snapshot")

        // A structural change (new tab landing in the searched project) rebuilds and surfaces via the filter.
        store.newTab(kind: .terminal, launchGrace: .zero)
        let newPane = try XCTUnwrap(memo.rows(for: store).map(\.id).last)
        XCTAssertEqual(memo.buildCount, 2, "a structural change during search still rebuilds")
        store.setLastKnownCwd("/Users/me/alpha", for: newPane)
        let afterStructural = RailRowsBuilder.filtered(memo.rows(for: store), query: query)
        XCTAssertEqual(memo.buildCount, 3, "the cwd change re-keys the memo")
        XCTAssertEqual(afterStructural.count, before.count + 1, "the new pane is reachable through the filter")
    }

    /// Behaviour parity for the search path: filtering + sectioning the memoized rows equals what the old
    /// direct-builder arm produced, for a representative store (statuses, git lines, process labels, a
    /// split tab) — including a subtitle (git line) match and a hidden cwd-key match.
    func testFilteredAndSectionedOverMemoEqualsDirectBuilderOutput() {
        let store = makeRichStore()
        let memo = RailRowsMemo()
        for query in ["", "alpha", "beta", "main", "caffeinate", "zzz-no-match"] {
            let viaMemo = RailRowsBuilder.filtered(memo.rows(for: store), query: query)
            let direct = RailRowsBuilder.filtered(RailRowsBuilder.rows(for: store), query: query)
            XCTAssertEqual(viaMemo, direct, "filtered parity for query '\(query)'")
            XCTAssertEqual(
                RailRowsBuilder.sectionedByProject(
                    memo.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: query,
                ),
                RailRowsBuilder.sectionedByProject(
                    RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: query,
                ),
                "sectioned parity for query '\(query)'",
            )
        }
    }

    // MARK: - liveChrome (the row view's fresh read over the stale cached model)

    /// After a volatile tick the CACHED row is stale by design, but `liveChrome(for:store:)` — what the row
    /// VIEW renders — reflects the store: badge, git-line subtitle, read-only lock, and rename mode.
    func testLiveChromeReflectsVolatileTicksOverStaleCache() {
        let store = makeRichStore()
        let memo = RailRowsMemo()
        let cached = memo.rows(for: store)
        let row = cached[1] // the caffeinate pane: at-rest badge is `.caffeinate`

        store.setAgentStatus(.needsPermission, for: row.id)
        store.setPaneReadOnly(row.id, true)
        store.paneGitSummary[row.id] = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 5, modified: 5,
        )
        store.requestRenameTab(row.tabID)

        let stale = memo.rows(for: store)[1]
        XCTAssertEqual(stale.badge, .caffeinate, "the cached row is stale (cache hit)")
        XCTAssertFalse(stale.readOnly)

        let live = RailRowsBuilder.liveChrome(for: row, store: store)
        XCTAssertEqual(live.badge, .awaitingInput, "the row view's badge is fresh")
        XCTAssertTrue(live.readOnly, "the lock is fresh")
        XCTAssertEqual(live.subtitle, "main !5", "the git-line subtitle is fresh")
        XCTAssertEqual(live.status, .needsPermission)
        XCTAssertTrue(live.isEditing, "the representative row opens its rename field live")
    }

    /// On a FRESH build, `liveChrome` agrees with the builder's own per-row fields for EVERY row (split
    /// tabs, video-less terminals, badges, process labels) — one resolution rule, two call sites, no drift.
    func testLiveChromeParityWithFreshBuild() {
        let store = makeRichStore()
        store.setTabBadgeOverride(.error, for: RailRowsBuilder.rows(for: store)[2].tabID)
        for row in RailRowsBuilder.rows(for: store) {
            let live = RailRowsBuilder.liveChrome(for: row, store: store)
            XCTAssertEqual(live.status, row.status, "status parity for \(row.title)")
            XCTAssertEqual(live.badge, row.badge, "badge parity for \(row.title)")
            XCTAssertEqual(live.subtitle, row.subtitle, "subtitle parity for \(row.title)")
            XCTAssertEqual(live.gitSummary, row.gitSummary, "git parity for \(row.title)")
            XCTAssertEqual(live.processLabel, row.processLabel, "process parity for \(row.title)")
            XCTAssertEqual(live.readOnly, row.readOnly, "lock parity for \(row.title)")
            XCTAssertEqual(live.isEditing, row.isEditing, "rename-mode parity for \(row.title)")
        }
    }

    /// The manual per-tab badge override lands on the REPRESENTATIVE pane row only — through
    /// `liveChrome`, exactly as through the builder (the split-tab pin from `RailRowBuilderTests`).
    func testLiveChromeManualOverrideOnRepresentativeOnly() {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        store.setTabBadgeOverride(.error, for: rows[0].tabID)
        let representative = store.tree.activeSession?.activeTab?.activePane
        let badged = rows.filter { RailRowsBuilder.liveChrome(for: $0, store: store).badge == .error }
        XCTAssertEqual(badged.map(\.id), representative.map { [$0] } ?? [], "override on the representative only")
    }

    // MARK: - `RailStructureKey.titledByProcess`

    /// Pins the pure escape-order guard shared by the memo AND the titlebar / window-title reads
    /// (``SlateTitlebar``'s `activeTitle`, `WorkspaceRootView.windowTitle(for:)`): only a terminal pane with
    /// a spec, no cwd folder name, and no non-empty user rename would actually resolve its title from the
    /// foreground-process dict — every OTHER shape must return `false` so those call sites can skip the
    /// dict read entirely without changing what the user sees.
    func testTitledByProcessGuard() {
        let bareTerminal = PaneSpec(kind: .terminal, title: "")
        XCTAssertTrue(
            RailStructureKey.titledByProcess(kind: .terminal, spec: bareTerminal),
            "a cwd-less, non-renamed terminal pane titles itself by the foreground process",
        )

        let cwdSpec = PaneSpec(kind: .terminal, title: "", lastKnownCwd: "/Users/me/alpha")
        XCTAssertFalse(
            RailStructureKey.titledByProcess(kind: .terminal, spec: cwdSpec),
            "a known cwd folder name always wins — the process dict is irrelevant once it's known",
        )

        let renamedSpec = PaneSpec(kind: .terminal, title: "deploy box", userRenamed: true)
        XCTAssertFalse(
            RailStructureKey.titledByProcess(kind: .terminal, spec: renamedSpec),
            "an explicit user rename wins — it never falls back to the process",
        )

        XCTAssertFalse(
            RailStructureKey.titledByProcess(kind: .remoteGUI, spec: bareTerminal),
            "only a terminal pane's title chain ever escapes to the process fallback",
        )

        XCTAssertFalse(
            RailStructureKey.titledByProcess(kind: .terminal, spec: nil),
            "a spec-less pane has no title chain to resolve, structural or otherwise",
        )
    }
}
