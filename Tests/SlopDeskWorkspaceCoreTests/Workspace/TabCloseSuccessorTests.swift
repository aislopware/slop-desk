import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Which tab is focused after a close. The rail draws tabs bucketed BY PROJECT while `session.tabs` holds
/// them in CREATION order, so "select the adjacent tab" has two different answers — and the old
/// `min(removedIndex, count - 1)` clamp walked the array, handing focus to whichever project happened to
/// own the next creation-order tab.
///
/// Pins the pure engine (``TabOrderingEngine/successorAfterClose(closing:displayOrder:projectKey:focusHistory:)``)
/// and the store wiring that feeds it, including the reported repro: open a tab in project A, one in
/// project B, return to A, ⌘T (a third tab, project A), close it — focus must stay in A.
@MainActor
final class TabCloseSuccessorTests: XCTestCase {
    // MARK: - Pure engine

    /// The repro, at engine level: creation order interleaves the projects, display order does not, and the
    /// successor must be read off the display order.
    func testSuccessorPrefersSameProjectOverCreationOrderNeighbour() {
        let a = TabID(), b = TabID(), c = TabID()
        let keys: [TabID: String] = [a: "/w/slop-desk", b: "/w/git-line-demo", c: "/w/slop-desk"]
        let creationOrder = [a, b, c]
        let display = TabOrderingEngine.projectGroupedTabOrder(creationOrder, projectKey: { keys[$0] })

        XCTAssertEqual(display, [a, c, b], "project grouping pulls the second slop-desk tab beside the first")

        // No focus history (a cold launch) — rule 2 must carry it on its own.
        XCTAssertEqual(
            TabOrderingEngine.successorAfterClose(
                closing: c, displayOrder: display, projectKey: { keys[$0] }, focusHistory: [],
            ),
            a,
            "closing the last slop-desk tab stays in slop-desk, not the creation-order neighbour",
        )
    }

    /// Rule 1 outranks rule 2: the tab you came FROM wins even when a same-project sibling sits adjacent.
    func testSuccessorPrefersMostRecentlyFocusedSurvivor() {
        let a = TabID(), b = TabID(), c = TabID()
        let keys: [TabID: String] = [a: "/w/proj", b: "/w/proj", c: "/w/proj"]
        let display = TabOrderingEngine.projectGroupedTabOrder([a, b, c], projectKey: { keys[$0] })

        XCTAssertEqual(
            TabOrderingEngine.successorAfterClose(
                closing: a, displayOrder: display, projectKey: { keys[$0] }, focusHistory: [a, c, b],
            ),
            c,
            "the newest survivor in the history wins over the adjacent sibling b",
        )
    }

    /// A history entry naming an already-closed tab must be skipped, not returned.
    func testSuccessorSkipsDeadHistoryEntries() {
        let a = TabID(), b = TabID(), ghost = TabID()
        let keys: [TabID: String] = [a: "/w/proj", b: "/w/proj"]
        XCTAssertEqual(
            TabOrderingEngine.successorAfterClose(
                closing: a, displayOrder: [a, b], projectKey: { keys[$0] }, focusHistory: [a, ghost, b],
            ),
            b,
            "a tab that is no longer in the display order is not a candidate",
        )
    }

    /// Closing a project's LAST tab has no section to stay in — rule 3 falls through to display adjacency.
    func testSuccessorFallsThroughWhenSectionDies() {
        let a = TabID(), b = TabID()
        let keys: [TabID: String] = [a: "/w/alpha", b: "/w/beta"]
        let display = TabOrderingEngine.projectGroupedTabOrder([a, b], projectKey: { keys[$0] })
        XCTAssertEqual(
            TabOrderingEngine.successorAfterClose(
                closing: a, displayOrder: display, projectKey: { keys[$0] }, focusHistory: [],
            ),
            b,
            "the only survivor is the answer even across a project boundary",
        )
    }

    /// Closing the sole tab leaves nothing to select.
    func testSuccessorNilForLastTab() {
        let a = TabID()
        XCTAssertNil(
            TabOrderingEngine.successorAfterClose(
                closing: a, displayOrder: [a], projectKey: { _ in "/w/proj" }, focusHistory: [a],
            ),
        )
    }

    /// Keyless tabs share the "Other" bucket rather than each becoming its own section, and a key differing
    /// only by a trailing slash is the SAME section (``TabOrderingEngine/normalizedProjectKey(_:)``).
    func testGroupedOrderBucketsKeylessTogetherAndNormalizesSlashes() {
        let a = TabID(), b = TabID(), c = TabID(), d = TabID()
        // `a` and `c` are absent from the map, so their lookup yields the keyless (`nil`) case.
        let keys: [TabID: String] = [b: "/w/proj", d: "/w/proj/"]
        XCTAssertEqual(
            TabOrderingEngine.projectGroupedTabOrder([a, b, c, d], projectKey: { keys[$0] }),
            [a, c, b, d],
            "both keyless tabs bucket together; the trailing slash does not fork a second section",
        )
    }

    // MARK: - Store wiring

    private func makeStore(_ tree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
            persistence: nil,
        )
    }

    /// One session whose tabs each hold a single pane in `project` (the sectioning source). The keys
    /// themselves are seeded onto the STORE by ``seedProjects(_:in:)`` — they are document facts.
    private func workspace(projects: [String]) -> (TreeWorkspace, [TabID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for _ in projects {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: "Terminal")
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), tabs.map(\.id))
    }

    /// Stamps each pane's `pane/cwd` + `pane/projectKey`, in the tree's own pane order.
    private func seedProjects(_ projects: [String], in store: WorkspaceStore) {
        for (pane, project) in zip(store.tree.allPaneIDs(), projects) {
            store.setLastKnownCwd(project, for: pane)
            store.setProjectKey(project, for: pane)
        }
    }

    private func activeTab(_ store: WorkspaceStore) -> TabID? {
        store.tree.activeSession?.activeTab?.id
    }

    /// THE REPORTED BUG, end to end through the store: slop-desk, git-line-demo, back to slop-desk, ⌘T
    /// (a slop-desk tab), close it. Focus must land on the slop-desk tab — before the fix it landed on
    /// git-line-demo, because the new tab appended to index 2 and the clamp resolved index 1.
    func testClosingNewTabReturnsToOriginatingProjectTab() throws {
        let projects = ["/w/slop-desk", "/w/git-line-demo"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)
        let slopDesk = tabs[0], gitLineDemo = tabs[1]

        store.selectTab(1) // visit git-line-demo…
        store.selectTab(0) // …then come back to slop-desk
        XCTAssertEqual(activeTab(store), slopDesk)

        store.newTab(kind: .terminal) // ⌘T — inherits slop-desk's cwd, appends at index 2
        let fresh = try XCTUnwrap(activeTab(store))
        XCTAssertNotEqual(fresh, slopDesk)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 3)

        store.closeTab(fresh)

        XCTAssertEqual(
            activeTab(store), slopDesk,
            "closing a fresh slop-desk tab returns to the slop-desk tab it was opened from",
        )
        XCTAssertNotEqual(activeTab(store), gitLineDemo, "must not jump to the other project")
    }

    /// Closing a BACKGROUND tab is not a focus change — the user dismissed something they were not looking
    /// at. The old clamp re-pointed the selection at the removed tab's index regardless.
    func testClosingBackgroundTabLeavesFocusAlone() {
        let projects = ["/w/alpha", "/w/beta", "/w/gamma"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)

        store.selectTab(2)
        XCTAssertEqual(activeTab(store), tabs[2])

        store.closeTab(tabs[0])

        XCTAssertEqual(activeTab(store), tabs[2], "closing a background tab keeps the active tab active")
    }

    /// Focus history is recorded through `reconcileTree()`, so it follows ANY gesture that changes the
    /// active tab — and a repeat reconcile for the same tab must not evict the genuinely-previous one.
    func testFocusHistoryTracksSwitchesWithoutFloodingOnRepeats() {
        let projects = ["/w/alpha", "/w/beta", "/w/gamma"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)

        store.selectTab(1)
        store.selectTab(2)
        store.reconcileTree() // a no-op reconcile (spec update / badge clear) for the SAME tab
        store.reconcileTree()

        XCTAssertEqual(
            store.tabFocusHistory, [tabs[2], tabs[1], tabs[0]],
            "most-recent first, one entry per tab, repeats collapsed",
        )

        store.closeTab(tabs[2])
        XCTAssertEqual(activeTab(store), tabs[1], "close returns to the previously-focused tab")
    }

    /// A tab can be closed in a session the user is not looking at (a second window). The successor must be
    /// resolved against the OWNING session — reading the active session's tabs would not find the closing
    /// tab at all and would silently fall back to the index clamp.
    func testSuccessorResolvesAgainstOwningSessionNotActiveOne() throws {
        let projects = ["/w/slop-desk", "/w/git-line-demo", "/w/slop-desk"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)
        let background = try XCTUnwrap(store.tree.activeSession?.id)

        // A second session becomes active; the first keeps its own active tab (index 0).
        store.newSession(name: "Second", kind: .terminal)
        XCTAssertNotEqual(store.tree.activeSessionID, background)

        // Close a BACKGROUND session's tab that is not its active tab.
        store.closeTab(tabs[2])

        let owning = try XCTUnwrap(store.tree.sessions.first { $0.id == background })
        XCTAssertEqual(owning.tabs.count, 2)
        XCTAssertEqual(
            owning.activeTab?.id, tabs[0],
            "the background session keeps its own active tab rather than clamping to the removed index",
        )
    }

    /// By-Project sectioning must resolve for a session that is NOT the active one. The close path runs
    /// there — a tab can be closed in a background window — so a resolver that only consults
    /// `tree.activeSession` would return nil for every pane, collapsing the whole rail into "Other" and
    /// degrading `successorAfterClose`'s same-section rule to the plain display order.
    func testPaneProjectKeyResolvesForANonActiveSession() throws {
        let projects = ["/w/alpha", "/w/beta"]
        let (tree, _) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)
        let background = try XCTUnwrap(store.tree.activeSession)

        // A SECOND session becomes the active one; `background` is now nobody's active session.
        store.newSession(name: "Second", kind: .terminal)
        XCTAssertNotEqual(store.tree.activeSessionID, background.id, "precondition: it is not active")

        for (pane, project) in zip(background.allPaneIDs(), projects) {
            XCTAssertEqual(
                WorkspaceStore.paneProjectKey(
                    pane, projectKey: { store.projectKey(for: $0) }, cwd: { store.paneCwd(for: $0) },
                ),
                project,
                "a background session's panes still bucket by their own project",
            )
        }
        XCTAssertEqual(
            WorkspaceStore.tabProjectKey(
                background.tabs[1].id, in: background,
                projectKey: { store.projectKey(for: $0) }, cwd: { store.paneCwd(for: $0) },
            ),
            "/w/beta",
            "and so does the TAB key the close path resolves successors against",
        )
    }

    /// A split tab straddling two projects has a row in EACH section, so no single key describes it. The
    /// close path uses the FOCUSED pane's key — the section the user was actually reading.
    func testSplitTabAcrossProjectsSectionsByItsFocusedPane() {
        let slopA = PaneID(), slopB = PaneID(), split = PaneID(), other = PaneID()
        var specs: [PaneID: PaneSpec] = [:]
        let projects: [(PaneID, String)] = [
            (slopA, "/w/slop-desk"), (slopB, "/w/slop-desk"),
            (split, "/w/git-line-demo"), (other, "/w/git-line-demo"),
        ]
        for (pane, _) in projects { specs[pane] = PaneSpec(kind: .terminal, title: "Terminal") }
        // Tab 1 is the split: a slop-desk pane AND a git-line-demo pane, focused on the git-line-demo one.
        let tab0 = Tab(root: .leaf(slopA), activePane: slopA)
        let tab1 = Tab(
            root: .split(id: SplitNodeID(), axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(slopB)),
                WeightedChild(weight: .flex(1), node: .leaf(split)),
            ]),
            activePane: split,
        )
        let tab2 = Tab(root: .leaf(other), activePane: other)
        let session = Session(name: "Local", tabs: [tab0, tab1, tab2], activeTabIndex: 0, specs: specs)
        let store = makeStore(TreeWorkspace(sessions: [session], activeSessionID: session.id))
        for (pane, project) in projects {
            store.setLastKnownCwd(project, for: pane)
            store.setProjectKey(project, for: pane)
        }

        XCTAssertEqual(
            WorkspaceStore.tabProjectKey(
                tab1.id, in: session,
                projectKey: { store.projectKey(for: $0) }, cwd: { store.paneCwd(for: $0) },
            ),
            "/w/git-line-demo",
            "the FOCUSED pane decides the section, not the tab's first leaf",
        )

        store.selectTab(1)
        store.selectTab(2) // land on the other git-line-demo tab…
        store.selectTab(1) // …and come back to the split
        store.closeTab(tab1.id)

        XCTAssertEqual(
            activeTab(store), tab2.id,
            "closing the split returns to the git-line-demo tab it was last visited from",
        )
    }

    /// A cold launch has no focus history at all — every tab but the restored active one is unvisited. Rule 2
    /// (the neighbour INSIDE the closing tab's project section) is the only thing keeping focus in the
    /// project then, so it has to hold through the store, not just the engine.
    func testColdLaunchWithoutHistoryStaysInsideProjectSection() {
        let projects = ["/w/slop-desk", "/w/git-line-demo", "/w/slop-desk"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)

        XCTAssertTrue(
            store.tabFocusHistory.allSatisfy { $0 == tabs[0] },
            "nothing has been visited yet, so rule 1 has no survivor to offer",
        )

        store.closeTab(tabs[0])

        XCTAssertEqual(
            activeTab(store), tabs[2],
            "the other slop-desk tab, not the git-line-demo tab the array index would have landed on",
        )
    }

    /// ⌘⇧W under an `.always` / `.multipleTabs` policy PARKS the close behind a confirmation and resolves it
    /// later through `confirmPendingClose()`. The successor is computed at confirm time, so the rule has to
    /// survive the park round-trip rather than being decided (and lost) when the dialog was armed.
    func testParkedTabCloseHonoursSuccessorRuleOnConfirm() throws {
        let projects = ["/w/slop-desk", "/w/git-line-demo"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)

        store.selectTab(1)
        store.selectTab(0)
        store.newTab(kind: .terminal) // ⌘T — a third tab, appended past git-line-demo
        let fresh = try XCTUnwrap(activeTab(store))

        // Park directly rather than flipping the global close-confirmation default: which policy ARMS the
        // dialog is pinned elsewhere; what matters here is that confirming resolves through the same rule.
        store.parkTabClose(fresh)
        XCTAssertEqual(store.pendingTabCloseID, fresh)
        XCTAssertEqual(activeTab(store), fresh, "parking must not close anything on its own")

        store.confirmPendingClose()

        XCTAssertNil(store.pendingTabCloseID)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2)
        XCTAssertEqual(
            activeTab(store), tabs[0],
            "a confirmed park lands where an immediate close would have",
        )
        XCTAssertNotEqual(activeTab(store), tabs[1], "must not jump to the other project")
    }

    /// ⇧⌘T restores a closed tab under its ORIGINAL ``TabID``. That id was pruned out of the focus ring when
    /// it died, so the reopened tab has to re-enter the ring on its own — otherwise the second close of the
    /// same tab would find no MRU survivor and fall back a rule.
    func testReopenedTabRejoinsFocusHistoryAndClosesBackToItsOrigin() {
        let projects = ["/w/slop-desk", "/w/git-line-demo", "/w/slop-desk"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)

        store.selectTab(2)
        store.closeTab(tabs[2])
        XCTAssertEqual(activeTab(store), tabs[0])
        XCTAssertFalse(store.tabFocusHistory.contains(tabs[2]), "a dead tab is not a successor candidate")

        store.reopenLastClosedPane() // ⇧⌘T

        XCTAssertEqual(activeTab(store), tabs[2], "the reopened tab takes focus")
        XCTAssertEqual(store.tabFocusHistory.first, tabs[2], "…and re-enters the ring at the head")

        store.closeTab(tabs[2])

        XCTAssertEqual(
            activeTab(store), tabs[0],
            "closing the reopened tab returns to the same origin as the first close",
        )
    }

    /// Closing a tab's LAST pane cascades the tab away, and that cascade must honour the same successor
    /// rule as an explicit `closeTab` (the sidebar `×` and a PTY exit both route through `closePaneTree`).
    func testClosingLastPaneOfTabUsesSameSuccessorRule() throws {
        let projects = ["/w/slop-desk", "/w/git-line-demo", "/w/slop-desk"]
        let (tree, tabs) = workspace(projects: projects)
        let store = makeStore(tree)
        seedProjects(projects, in: store)

        store.selectTab(0)
        store.selectTab(2) // now on the second slop-desk tab
        let pane = try XCTUnwrap(store.tree.activeSession?.tabs[2].activePane)

        store.closePaneTree(pane)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2)
        XCTAssertEqual(
            activeTab(store), tabs[0],
            "the cascade returns to the previously-focused slop-desk tab, not the creation-order neighbour",
        )
    }
}
