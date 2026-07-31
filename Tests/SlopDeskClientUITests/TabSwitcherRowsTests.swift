// TabSwitcherRowsTests — pins what a ⌃⇥ switcher row SAYS.
//
// The regression this guards: the switcher named every row through the folder-name rung, so three panes
// opened in one repo read `slopdesk` / `slopdesk` / `slopdesk` and the ring's whole purpose (which one am
// I flipping to?) was unanswerable. `testTwoTabsInOneProjectReadDifferently` fails against that build —
// it asserts the two rows' titles DIFFER while both still name the shared project on line 2.
//
// Headless: the pure composers need no store at all; the live rows ride the same tree-model
// `WorkspaceStore` + `MountTestPaneSession` fake the rail-row tests use (no socket, no video, no Metal).

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class TabSwitcherRowsTests: XCTestCase {
    // MARK: - `place` (line 2's WHERE)

    /// A pane AT its project root prints the project's folder name — nothing more.
    func testPlaceAtProjectRootIsTheProjectName() {
        XCTAssertEqual(
            TabSwitcherRowsBuilder.place(projectKey: "/w/slopdesk", cwd: "/w/slopdesk"), "slopdesk",
        )
    }

    /// A pane that strayed INTO the project's subtree appends the relative path — the half that tells two
    /// panes of one repo apart.
    func testPlaceAppendsTheStrayedSubpath() {
        XCTAssertEqual(
            TabSwitcherRowsBuilder.place(projectKey: "/w/slopdesk", cwd: "/w/slopdesk/packages/api"),
            "slopdesk/packages/api",
        )
    }

    /// A trailing slash on the cwd is not a stray — it is the same directory.
    func testPlaceToleratesATrailingSlash() {
        XCTAssertEqual(
            TabSwitcherRowsBuilder.place(projectKey: "/w/slopdesk", cwd: "/w/slopdesk/"), "slopdesk",
        )
    }

    /// A cwd OUTSIDE the key's subtree (a stale key across an un-re-pushed `cd`) names where the pane
    /// actually is rather than claiming the project it left.
    func testPlaceOutsideTheKeyFallsBackToTheOwnFolder() {
        XCTAssertEqual(
            TabSwitcherRowsBuilder.place(projectKey: "/w/slopdesk", cwd: "/tmp/scratch"), "scratch",
        )
    }

    /// A keyless pane still says where it is.
    func testPlaceWithoutAKeyIsTheFolderName() {
        XCTAssertEqual(TabSwitcherRowsBuilder.place(projectKey: nil, cwd: "/w/slopdesk"), "slopdesk")
        XCTAssertNil(TabSwitcherRowsBuilder.place(projectKey: nil, cwd: nil))
    }

    // MARK: - `detail` (the pane count)

    /// A single-pane tab omits the count — `1 pane` on every row is noise.
    func testDetailOmitsTheCountForASinglePaneTab() {
        XCTAssertEqual(TabSwitcherRowsBuilder.detail(place: "slopdesk", paneCount: 1), "slopdesk")
    }

    /// A SPLIT tab says so: same project, different destination.
    func testDetailCarriesThePaneCountForASplitTab() {
        XCTAssertEqual(
            TabSwitcherRowsBuilder.detail(place: "slopdesk", paneCount: 3), "slopdesk · 3 panes",
        )
    }

    /// A placeless pane with a split still gets a line 2.
    func testDetailSurvivesAMissingPlace() {
        XCTAssertEqual(TabSwitcherRowsBuilder.detail(place: nil, paneCount: 2), "2 panes")
        XCTAssertNil(TabSwitcherRowsBuilder.detail(place: nil, paneCount: 1))
    }

    // MARK: - `slot` (the trailing program label)

    /// The slot keeps a bare shell — in the metadata column `zsh` answers "what is this pane running".
    func testSlotKeepsABareShell() {
        XCTAssertEqual(TabSwitcherRowsBuilder.slot(processLabel: "-zsh", title: "slopdesk"), "zsh")
    }

    /// …but never repeats the title.
    func testSlotSuppressedWhenTheTitleAlreadyNamesIt() {
        XCTAssertNil(TabSwitcherRowsBuilder.slot(processLabel: "zsh", title: "zsh"))
        XCTAssertNil(TabSwitcherRowsBuilder.slot(processLabel: "/usr/bin/make", title: "make check"))
    }

    /// A prefix that is not the whole first WORD is a different program — `makefile-lint` is not `make`.
    func testSlotSurvivesAPartialWordCollision() {
        XCTAssertEqual(
            TabSwitcherRowsBuilder.slot(processLabel: "make", title: "makefile-lint"), "make",
        )
    }

    // MARK: - Live rows

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// Put pane `id` at `cwd` inside project `key`.
    private func place(_ store: WorkspaceStore, _ id: PaneID, project key: String, cwd: String? = nil) {
        store.setLastKnownCwd(cwd ?? key, for: id)
        store.setProjectKey(key, for: id)
    }

    /// The pane of the tab at `index` in the active session.
    private func pane(_ store: WorkspaceStore, tab index: Int) throws -> PaneID {
        try XCTUnwrap(XCTUnwrap(store.tree.activeSession).tabs[index].allPaneIDs().first)
    }

    /// The switcher's rows, opened forward from the current tab.
    private func openedRows(_ store: WorkspaceStore) throws -> [TabSwitcherRow] {
        store.openOrStepTabSwitcher(forward: true, armedByModifier: true)
        return try TabSwitcherRowsBuilder.rows(for: XCTUnwrap(store.tabSwitcher), store: store)
    }

    /// THE REGRESSION: two tabs rooted in the SAME project must read differently — one by its agent's
    /// task intent, the other by its running program — while both still name the shared project on line
    /// 2. Under the folder-name-only build both titles were `slopdesk`.
    func testTwoTabsInOneProjectReadDifferently() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let first = try pane(store, tab: 0)
        let second = try pane(store, tab: 1)
        place(store, first, project: "/w/slopdesk")
        place(store, second, project: "/w/slopdesk")
        store.setForegroundProcess("claude", for: first)
        store.setAgentStatus(.working, for: first)
        store.setAgentIntent("fix the rail flash", for: first)
        store.setForegroundProcess("nvim", for: second)

        let rows = try openedRows(store)
        XCTAssertEqual(rows.count, 2)
        let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.number, $0.title) })
        XCTAssertEqual(titles[1], "fix the rail flash", "the agent tab is named by its task")
        XCTAssertEqual(titles[2], "nvim", "the other tab is named by its program")
        XCTAssertEqual(
            Set(rows.compactMap(\.detail)), ["slopdesk"],
            "both rows still name the project they share",
        )
    }

    /// A split tab's row says how many panes it holds, so it is not confused with its single-pane
    /// neighbour in the same project.
    func testSplitTabRowCarriesThePaneCount() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        for id in try XCTUnwrap(store.tree.activeSession).allPaneIDs() {
            place(store, id, project: "/w/slopdesk")
        }
        let rows = try openedRows(store)
        let split = rows.first { $0.number == 2 }
        XCTAssertEqual(split?.detail, "slopdesk · 2 panes")
        XCTAssertEqual(rows.first { $0.number == 1 }?.detail, "slopdesk", "the unsplit tab keeps one line")
    }

    /// The highlight lands on the row the ring points at — the frozen order is recency, so a forward open
    /// marks the PREVIOUS tab, not the active one.
    func testHighlightMarksExactlyTheRingsCurrentCandidate() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows = try openedRows(store)
        let switcher = try XCTUnwrap(store.tabSwitcher)
        XCTAssertEqual(rows.filter(\.isHighlighted).count, 1, "exactly one row is marked")
        XCTAssertEqual(rows.first(where: \.isHighlighted)?.id, switcher.highlighted)
    }

    /// An explicit tab RENAME outranks everything the pane is doing.
    func testATabRenameWinsOverTheLiveIdentity() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let first = try pane(store, tab: 0)
        place(store, first, project: "/w/slopdesk")
        store.setForegroundProcess("claude", for: first)
        store.setAgentIntent("fix the rail flash", for: first)
        let tabID = try XCTUnwrap(store.tree.activeSession).tabs[0].id
        store.renameTab(tabID, to: "Release prep")

        let rows = try openedRows(store)
        XCTAssertEqual(rows.first { $0.number == 1 }?.title, "Release prep")
    }
}
