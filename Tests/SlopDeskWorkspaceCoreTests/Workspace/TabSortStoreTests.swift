import Foundation
import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// The STORE wiring of the E6 sidebar hamburger (ES-E6-4 / ES-E6-5, plan WI-3/WI-6): the grouping/sort
/// selection mutates ``WorkspaceStore`` (the single source of truth for row order) and PERSISTS through the
/// Defaults-backed ``SettingsKey`` seam; the rendered sections are a pure derivation via
/// ``WorkspaceStore/orderedTabGroups(now:)``; `selectTab` stamps recency so the `.updated` sort re-orders;
/// a manual drag flips the sort to `.manual`. Drives a LIVE `.tree` store through the `FakePaneSession`
/// seam — never a real socket. The pure engine math is pinned in `TabOrderingEngineTests`; this pins that
/// the store actually reads/writes it (preventing a regression to a hardcoded order / local `@State`).
@MainActor
final class TabSortStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        super.tearDown()
    }

    // `nonisolated` so the setUp/tearDown overrides stay isolation-compatible with XCTestCase's
    // nonisolated `setUp()` (a @MainActor helper call would force main-actor isolation on the override →
    // "sending self risks data races"). UserDefaults is thread-safe, so the keys clear off any actor.
    private nonisolated func clearKeys() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.tabGroupingKey)
        UserDefaults.standard.removeObject(forKey: SettingsKey.tabSortKey)
    }

    // MARK: - Fixtures

    /// A one-session `.tree` store with three single-pane tabs carrying distinct cwds (so By-Project yields
    /// three sections). Returns the store + the tab ids in array order.
    private func makeStore() -> (WorkspaceStore, [TabID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        let cwds = ["/Users/me/alpha", "/Users/me/beta", "/Users/me/gamma"]
        for i in 0..<3 {
            let pane = PaneID()
            var spec = PaneSpec(kind: .terminal, title: "T\(i)")
            spec.lastKnownCwd = cwds[i]
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = spec
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
        return (store, tabs.map(\.id))
    }

    /// A one-session `.tree` store whose single tab holds a 2-pane horizontal split (so `breakPaneToTab`
    /// is NOT a no-op). Returns the store + the pane to break out into a new tab.
    private func makeSplitStore() -> (WorkspaceStore, PaneID) {
        let a = PaneID()
        let tab = Tab(root: .leaf(a), activePane: a)
        let session = Session(
            name: "Local", tabs: [tab], activeTabIndex: 0, specs: [a: PaneSpec(kind: .terminal, title: "A")],
        )
        let base = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let (split, b) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "B"), in: base,
        )
        let store = WorkspaceStore(
            restoringTree: split,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
        return (store, b)
    }

    // MARK: - Grouping mutates the store-derived order (ES-E6-4)

    func testSetTabGroupingChangesDerivedSections() {
        let (store, _) = makeStore()
        store.setTabGrouping(.none)
        XCTAssertEqual(store.orderedTabGroups().count, 1, ".none ⇒ one flat section")
        XCTAssertNil(store.orderedTabGroups()[0].header)

        store.setTabGrouping(.byProject)
        let groups = store.orderedTabGroups()
        XCTAssertEqual(
            groups.map(\.header),
            ["alpha", "beta", "gamma"],
            "By-Project regroups by the panes' cwds (last path component), store-derived",
        )
    }

    func testSetTabGroupingIsIdempotentAndPersisted() {
        let (store, _) = makeStore()
        store.setTabGrouping(.byDate)
        XCTAssertEqual(store.tabGrouping, .byDate)
        // Persisted: a fresh store hydrates the same choice from Defaults.
        let (store2, _) = makeStore()
        XCTAssertEqual(store2.tabGrouping, .byDate, "the grouping choice persists + hydrates on a new store")
    }

    // MARK: - By-Project git-toplevel cache invalidation on a cwd change (ES-E6-4)

    /// A cached git toplevel (E6 WI-7) must take precedence over the cwd for By-Project — but the moment the
    /// pane's cwd CHANGES (a `cd` across repos in the SAME live pane), the cache is stale and must be dropped
    /// so the group FOLLOWS the new cwd. FAILS on the un-fixed store: `setLastKnownCwd` never touched
    /// `paneGitToplevel` and the reconcile prune only drops CLOSED leaves, so `paneProjectKey` kept returning
    /// the old repo root and By-Project silently lied.
    func testCwdChangeInvalidatesStaleGitToplevelCache() {
        let (store, _) = makeStore()
        store.setTabGrouping(.byProject)
        guard let pane = store.tree.activeSession?.tabs[0].activePane else {
            XCTFail("tab 0 has an active pane")
            return
        }

        // Seed a precise repo root for pane 0 (cwd `/Users/me/alpha`) — it must WIN over the cwd fallback.
        store.cacheGitToplevel("/repo/root", for: pane)
        XCTAssertEqual(
            store.paneProjectKey(pane), "/repo/root",
            "the cached git toplevel takes precedence over the cwd",
        )
        XCTAssertEqual(
            store.orderedTabGroups().map(\.header),
            ["root", "beta", "gamma"],
            "By-Project groups pane 0 by the cached repo root (last path component), not its cwd",
        )

        // The pane `cd`s into a DIFFERENT repo — the cached toplevel is now stale and must be invalidated so
        // the group follows the new cwd-derived key. (Post-`cd` assertions FAIL on the un-fixed store.)
        store.setLastKnownCwd("/Users/me/delta", for: pane)
        XCTAssertEqual(
            store.paneProjectKey(pane), "/Users/me/delta",
            "after a cwd change the stale cache is dropped ⇒ paneProjectKey falls back to the fresh cwd",
        )
        XCTAssertEqual(
            store.orderedTabGroups().map(\.header),
            ["delta", "beta", "gamma"],
            "By-Project now groups pane 0 by its NEW cwd, no longer the stale repo root",
        )
    }

    /// A re-stamp of the SAME cwd is not a change ⇒ the cached toplevel must SURVIVE (the dirty guard short-
    /// circuits before the invalidation), so an idempotent cwd write can't churn the By-Project sections.
    func testSameCwdReStampKeepsGitToplevelCache() {
        let (store, _) = makeStore()
        store.setTabGrouping(.byProject)
        guard let pane = store.tree.activeSession?.tabs[0].activePane else {
            XCTFail("tab 0 has an active pane")
            return
        }
        store.cacheGitToplevel("/repo/root", for: pane)
        store.setLastKnownCwd("/Users/me/alpha", for: pane) // identical to the seeded cwd ⇒ no change
        XCTAssertEqual(
            store.paneProjectKey(pane), "/repo/root",
            "an unchanged cwd write does not invalidate the cache (the dirty guard short-circuits)",
        )
    }

    // MARK: - selectTab stamps recency and flips Updated order (ES-E6-5)

    func testSelectTabBumpsRecencyAndFlipsUpdatedOrder() {
        let (store, ids) = makeStore()
        store.setTabSort(.updated)
        // No recency yet ⇒ Updated falls back to array order (all nil, stable).
        XCTAssertEqual(store.orderedTabGroups()[0].tabIDs, ids, "no recency ⇒ array order")

        store.selectTab(2) // tab 2 becomes the most-recently-active
        XCTAssertNotNil(store.tabLastActiveAt[ids[2]], "selectTab stamps the newly-active tab")
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs.first,
            ids[2],
            "Updated floats the just-selected tab to the front",
        )
    }

    func testSelectTabDoesNotReorderCreatedSort() {
        let (store, ids) = makeStore()
        store.setTabSort(.created)
        store.selectTab(2)
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs,
            ids,
            "Created ignores recency — order stays the array order even after a select",
        )
    }

    /// `newTab` is the single most common "tab became active" gesture (⌘T): it creates AND selects a new
    /// tab, so WI-6 must stamp its recency. FAILS on the un-fixed store (`newTab` set the tree but never
    /// stamped) — the just-opened tab sorted LAST under `.updated` on a nil recency.
    func testNewTabStampsRecencyAndFloatsItUpdated() {
        let (store, ids) = makeStore()
        store.setTabSort(.updated)
        XCTAssertEqual(store.orderedTabGroups()[0].tabIDs, ids, "no recency yet ⇒ array order")

        store.newTab(kind: .terminal)
        guard let newTabID = store.tree.activeSession?.activeTab?.id else {
            XCTFail("the freshly-created tab is the active tab")
            return
        }
        XCTAssertNotNil(store.tabLastActiveAt[newTabID], "newTab stamps the new (now-active) tab's recency")
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs.first,
            newTabID,
            "Updated floats the just-opened tab to the front, not the bottom",
        )
    }

    /// Under By-Date, the just-opened tab must land in "Today" (a fresh stamp), not "Earlier" (the nil-recency
    /// bucket). FAILS on the un-fixed store where `newTab` left the tab unstamped ⇒ it fell into "Earlier".
    func testNewTabLandsInTodayUnderByDate() {
        let (store, _) = makeStore()
        store.setTabGrouping(.byDate)
        store.newTab(kind: .terminal)
        guard let newTabID = store.tree.activeSession?.activeTab?.id else {
            XCTFail("the freshly-created tab is the active tab")
            return
        }
        let today = store.orderedTabGroups().first { $0.header == "Today" }
        XCTAssertNotNil(today, "By-Date shows a Today section for the just-opened tab")
        XCTAssertTrue(
            today?.tabIDs.contains(newTabID) ?? false,
            "the just-opened tab is bucketed under Today, not Earlier",
        )
    }

    /// Reopen-last-closed (⇧⌘T) restores a tab AND selects it (`insertTab` sets `activeTabIndex`), so WI-6
    /// stamps its recency too. FAILS on the un-fixed store where the restored tab came back unstamped and
    /// sank to the bottom under `.updated`.
    func testReopenLastClosedTabStampsRecencyAndFloatsItUpdated() {
        let (store, ids) = makeStore()
        store.setTabSort(.updated)
        store.closeTab(ids[0]) // record it on the reopen LIFO

        store.reopenLastClosedPane()
        guard let restoredTabID = store.tree.activeSession?.activeTab?.id else {
            XCTFail("the reopened tab is the active tab")
            return
        }
        XCTAssertEqual(restoredTabID, ids[0], "the original TabID is restored")
        XCTAssertNotNil(store.tabLastActiveAt[restoredTabID], "reopen stamps the restored (now-active) tab")
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs.first,
            restoredTabID,
            "Updated floats the just-reopened tab to the front",
        )
    }

    // MARK: - Manual drag flips the sort + reorders (ES-E6-5)

    func testMoveTabFlipsSortToManualAndReorders() {
        let (store, ids) = makeStore()
        store.setTabSort(.created)
        store.moveTab(from: 0, to: 2)
        XCTAssertEqual(store.tabSort, .manual, "a manual drag sets Sort = Manual")
        XCTAssertEqual(
            store.tree.activeSession?.tabs.map(\.id),
            [ids[1], ids[2], ids[0]],
            "the drag permutes the tabs array",
        )
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs,
            [ids[1], ids[2], ids[0]],
            "Manual renders the (permuted) array order",
        )
    }

    func testNoOpMoveDoesNotFlipSort() {
        let (store, _) = makeStore()
        store.setTabSort(.created)
        store.moveTab(from: 1, to: 1) // same index ⇒ no-op
        XCTAssertEqual(store.tabSort, .created, "a no-op move must not flip the sort to Manual")
    }

    // MARK: - WYSIWYG rendered drag (moveTabRendered): rendered order ≠ array order under .updated

    /// The fix: a drag under ``TabSort/updated`` must be WYSIWYG against the RENDERED order — only the dragged
    /// row moves, the rest stay where the recency order put them. FAILS on the old absolute-index drag, which
    /// flipped the whole list to array(manual) order at once (reshuffling every row, not just the dragged one).
    func testMoveTabRenderedIsWYSIWYGUnderUpdated() {
        let (store, ids) = makeStore()
        store.setTabSort(.updated)
        // Make the rendered order differ from the array order [t0, t1, t2]: float t2 then t0 to the front.
        store.selectTab(2)
        store.selectTab(0)
        let rendered = store.orderedTabGroups()[0].tabIDs
        XCTAssertEqual(rendered, [ids[0], ids[2], ids[1]], "precondition: rendered (recency) order ≠ array order")

        // Drag the row at rendered position 0 (t0) to rendered position 2.
        store.moveTabRendered(from: 0, to: 2)
        XCTAssertEqual(store.tabSort, .manual, "a real drag converts the live order to Manual")
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs, [ids[2], ids[1], ids[0]],
            "only the dragged row moves, relative to the rendered order (WYSIWYG), not the array reshuffle",
        )
    }

    /// Manual reorder is a FLAT-LIST affordance: a drag while a grouping is active must be a NO-OP (you cannot
    /// hand-order across derived buckets). The store guards it so a stray drop can't silently reshuffle.
    func testMoveTabRenderedIsANoOpUnderGrouping() {
        let (store, ids) = makeStore()
        store.setTabGrouping(.byProject) // three distinct cwds ⇒ three single-tab buckets
        let sortBefore = store.tabSort
        store.moveTabRendered(from: 0, to: 2)
        XCTAssertEqual(
            store.tree.activeSession?.tabs.map(\.id), ids,
            "a drag under grouping leaves the tab array untouched (no cross-bucket hand-ordering)",
        )
        XCTAssertEqual(store.tabSort, sortBefore, "a no-op grouped drag must not flip the sort to Manual")
    }

    // MARK: - Leaf set unchanged by a reorder (reconcile no-op — no surface teardown)

    func testManualReorderLeavesLeafSetUnchanged() {
        let (store, _) = makeStore()
        let before = Set(store.tree.allPaneIDs())
        store.moveTab(from: 0, to: 2)
        XCTAssertEqual(
            Set(store.tree.allPaneIDs()),
            before,
            "reorder permutes tabs only — the leaf set (hence the registry) is unchanged",
        )
    }

    // MARK: - WI-6 recency-stamping completeness (every became-active / activity path)

    /// `breakPaneToTab` ejects a pane into a NEW tab and selects it — WI-6 stamps that newly-active tab's
    /// recency so the `.updated` sort floats it first. FAILS on the un-fixed store (the break did not stamp).
    func testBreakPaneToTabStampsNewTabAndFloatsItUpdated() {
        let (store, b) = makeSplitStore()
        store.setTabSort(.updated)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "precondition: one multi-pane tab")

        store.breakPaneToTab(b)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "the break ejects b into a NEW, selected tab")
        guard let newTabID = store.tree.activeSession?.activeTab?.id else {
            XCTFail("the freshly-broken tab is the active tab")
            return
        }
        XCTAssertNotNil(store.tabLastActiveAt[newTabID], "breakPaneToTab stamps the new tab's recency")
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs.first,
            newTabID,
            "Updated floats the freshly-broken tab to the front",
        )
    }

    /// A no-op break (the pane is its tab's only leaf) must NOT stamp — there is no new tab and the tree is
    /// unchanged, so recency stays empty (otherwise a no-op would spuriously reorder Updated).
    func testNoOpBreakDoesNotStamp() {
        let (store, ids) = makeStore() // single-pane tabs ⇒ break is a no-op
        let pane = store.tree.activeSession?.tabs[0].activePane
        store.breakPaneToTab(pane ?? PaneID())
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 3, "a lone-leaf break creates no new tab")
        XCTAssertTrue(
            ids.allSatisfy { store.tabLastActiveAt[$0] == nil },
            "a no-op break stamps nothing",
        )
    }

    /// A genuine agent-status change stamps the OWNING tab's recency and flips the `.updated` order — the
    /// stamp rides the `setAgentStatus` chokepoint (WI-6), so it fires for ANY status-write source, not only
    /// the wire-signal funnel. FAILS on the un-fixed store (the chokepoint did not stamp).
    func testAgentStatusChangeStampsOwningTabAndFlipsUpdatedOrder() {
        let (store, ids) = makeStore()
        store.setTabSort(.updated)
        XCTAssertEqual(store.orderedTabGroups()[0].tabIDs, ids, "no recency yet ⇒ array order")

        guard let pane = store.tree.activeSession?.tabs[2].activePane else {
            XCTFail("tab 2 has an active pane")
            return
        }
        store.setAgentStatus(.working, for: pane)

        XCTAssertNotNil(store.tabLastActiveAt[ids[2]], "an agent-status change stamps the owning tab")
        XCTAssertEqual(
            store.orderedTabGroups()[0].tabIDs.first,
            ids[2],
            "Updated floats the tab whose agent just changed status to the front",
        )
    }

    /// An idempotent agent-status write (same status) is NOT a change ⇒ it must not stamp (the chokepoint's
    /// guard short-circuits before the stamp). Guards against a heartbeat re-write spuriously reordering.
    func testIdempotentAgentStatusWriteDoesNotStamp() {
        let (store, ids) = makeStore()
        guard let pane = store.tree.activeSession?.tabs[1].activePane else {
            XCTFail("tab 1 has an active pane")
            return
        }
        store.setAgentStatus(.working, for: pane)
        let firstStamp = store.tabLastActiveAt[ids[1]]
        XCTAssertNotNil(firstStamp, "the first (real) transition stamps")

        store.setAgentStatus(.working, for: pane) // same status ⇒ no change ⇒ no new stamp
        XCTAssertEqual(
            store.tabLastActiveAt[ids[1]], firstStamp,
            "an unchanged status write does not re-stamp (the chokepoint guard short-circuits)",
        )
    }
}
