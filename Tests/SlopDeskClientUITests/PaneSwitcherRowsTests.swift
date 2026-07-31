// PaneSwitcherRowsTests — pins what a ⌃⇥ switcher row SAYS, both halves of it: the identity, and the
// PLACE line under it that each row now carries for itself instead of borrowing from a section header.
//
// The regression this guards: the switcher named every row through the folder-name rung, so three panes
// opened in one repo read `slopdesk` / `slopdesk` / `slopdesk` and the ring's whole purpose (which one am
// I flipping to?) was unanswerable. `testTwoPanesInOneProjectReadDifferently` fails against that build —
// it asserts the two rows' titles DIFFER while both still resolve to the one project they share.
//
// Headless: the pure composers need no store at all; the live rows ride the same tree-model
// `WorkspaceStore` + `MountTestPaneSession` fake the rail-row tests use (no socket, no video, no Metal).

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneSwitcherRowsTests: XCTestCase {
    // MARK: - `projectName` (the first half of a row's place line)

    /// The project is its folder name, whatever the pane's own cwd is below it.
    func testProjectNameIsTheProjectFolderName() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.projectName(
                projectKey: "/w/slopdesk", cwd: "/w/slopdesk/packages/api",
            ),
            "slopdesk",
        )
    }

    /// A pane with no project key yet still names a place — its own folder.
    func testProjectNameWithoutAKeyIsTheOwnFolder() {
        XCTAssertEqual(PaneSwitcherRowsBuilder.projectName(projectKey: nil, cwd: "/w/scratch"), "scratch")
        XCTAssertNil(PaneSwitcherRowsBuilder.projectName(projectKey: nil, cwd: nil))
    }

    // MARK: - `relativePath` / `note` (the quiet remainder)

    /// A pane AT its project root adds nothing — the project half of the line already said the place.
    func testRootPaneHasNoNote() {
        XCTAssertNil(PaneSwitcherRowsBuilder.relativePath(projectKey: "/w/slopdesk", cwd: "/w/slopdesk"))
        XCTAssertNil(PaneSwitcherRowsBuilder.note(projectKey: "/w/slopdesk", cwd: "/w/slopdesk"))
    }

    /// A trailing slash on the cwd is not a stray — it is the same directory.
    func testRelativePathToleratesATrailingSlash() {
        XCTAssertNil(PaneSwitcherRowsBuilder.relativePath(projectKey: "/w/slopdesk", cwd: "/w/slopdesk/"))
    }

    /// A pane that strayed INTO the project's subtree carries the path after the root.
    func testStrayedPaneCarriesTheSubPath() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.note(projectKey: "/w/slopdesk", cwd: "/w/slopdesk/packages/api"),
            "packages/api",
        )
    }

    /// A cwd OUTSIDE the key's subtree (a stale key across an un-re-pushed `cd`) names where the pane
    /// actually is rather than hiding it.
    func testCwdOutsideTheKeyStillNamesItself() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.note(projectKey: "/w/slopdesk", cwd: "/tmp/scratch"),
            "scratch",
        )
    }

    /// The note is the SUB-PATH and nothing else. A tab's pane count used to ride here, back when a row
    /// was a tab; a row is now one of those panes, so the count would describe the row's neighbours.
    func testTheNoteIsOnlyEverTheSubPath() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.note(projectKey: "/w/slopdesk", cwd: "/w/slopdesk/docs"), "docs",
        )
    }

    // MARK: - `unrepeated` (a title must not restate the project under it)

    /// A row whose identity fell all the way through to the folder name would say its own place line
    /// twice — it yields to the pane's program instead.
    func testATitleThatRestatesTheProjectYieldsToTheProgram() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated(
                "slopdesk", project: "slopdesk", note: nil, processLabel: "-zsh",
            ),
            "zsh",
        )
    }

    /// ⚠️ THE NOTE COUNTS TOO. A shell deep in a project titles itself by its folder name, which is the
    /// last thing its own place line already says — photographed as `Overlays` sitting over
    /// `slopdesk › Sources/SlopDeskClientUI/Overlays`. The section-header era could not see this,
    /// because the path was not on the row.
    func testATitleThatRestatesTheNotesLastComponentAlsoYields() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated(
                "Overlays", project: "slopdesk", note: "Sources/SlopDeskClientUI/Overlays",
                processLabel: "-zsh",
            ),
            "zsh",
        )
    }

    /// …but only the LAST component: a title that happens to match a directory higher up the path is
    /// saying something the eye does not read as a repeat.
    func testATitleMatchingAnInnerPathComponentIsLeftAlone() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated(
                "Sources", project: "slopdesk", note: "Sources/SlopDeskClientUI/Overlays",
                processLabel: "-zsh",
            ),
            "Sources",
        )
    }

    /// …and only when it has a program to yield to: a blank line says less than a redundant one.
    func testATitleRestatingTheProjectSurvivesWithNoProgram() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated(
                "slopdesk", project: "slopdesk", note: nil, processLabel: nil,
            ),
            "slopdesk",
        )
    }

    /// A real identity is never touched, even when a program is known.
    func testARealTitleIsNeverReplaced() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated(
                "make check", project: "slopdesk", note: "docs", processLabel: "make",
            ),
            "make check",
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

    /// The switcher's rows, opened forward from the current pane.
    private func openedRows(_ store: WorkspaceStore) throws -> [PaneSwitcherRow] {
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        return try PaneSwitcherRowsBuilder.rows(for: XCTUnwrap(store.paneSwitcher), store: store)
    }

    /// THE REGRESSION: two panes rooted in the SAME project must read differently — one by its agent's
    /// task intent, the other by its running program — while both sit under the one shared header.
    /// Under the folder-name-only build both titles were `slopdesk`.
    func testTwoPanesInOneProjectReadDifferently() throws {
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
        XCTAssertEqual(titles[1], "fix the rail flash", "the agent pane is named by its task")
        XCTAssertEqual(titles[2], "nvim", "the other pane is named by its program")
        XCTAssertEqual(
            rows.compactMap(\.project), ["slopdesk", "slopdesk"],
            "each row says the project for itself — there is no header to borrow it from",
        )
        XCTAssertEqual(rows.compactMap(\.note), [], "a pane at its project root adds nothing")
    }

    /// ⚠️ NO GROUPING, NO RE-SORT. Panes interleave across projects in a recency ring, so the rows keep
    /// the ring's order and each one carries its own project — the shape that replaced the section
    /// headers, which under this order would have captioned nearly every row.
    func testInterleavedProjectsKeepTheRingsOrderAndEachRowNamesItsOwn() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.newTab(kind: .terminal, launchGrace: .zero)
        let panes = try (0..<3).map { try pane(store, tab: $0) }
        place(store, panes[0], project: "/w/slopdesk")
        place(store, panes[1], project: "/w/otty")
        place(store, panes[2], project: "/w/slopdesk", cwd: "/w/slopdesk/docs")
        for id in panes { store.setForegroundProcess("zsh", for: id) }

        // Visit them in an order that interleaves the two projects, so the ring is A, B, A.
        store.revealPaneTree(panes[2])
        store.revealPaneTree(panes[1])
        store.revealPaneTree(panes[0])

        let rows = try openedRows(store)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(
            rows.map(\.project), ["slopdesk", "otty", "slopdesk"],
            "the project alternates down the card — one header per row is what this replaced",
        )
        XCTAssertEqual(
            Set(rows.map(\.number)), [1, 2, 3], "the numbers are still the session's flat pane order",
        )
        XCTAssertEqual(
            rows.compactMap(\.note), ["docs"],
            "only the strayed pane adds a sub-path; the two at their roots stay quiet",
        )
    }

    /// A pane with NO project (its cwd has not landed) has no place lead-in to say — the row must not
    /// invent one, and its note stands alone.
    func testAPaneWithoutAProjectCarriesNoProjectAtAll() throws {
        let store = makeStore()
        let first = try pane(store, tab: 0)
        store.newTab(kind: .terminal, launchGrace: .zero)
        let second = try pane(store, tab: 1)
        place(store, second, project: "/w/slopdesk")
        store.setForegroundProcess("zsh", for: first)

        let rows = try openedRows(store)
        let orphan = try XCTUnwrap(rows.first { $0.id == first })
        XCTAssertNil(orphan.project, "no cwd ⇒ no project half")
        XCTAssertNil(orphan.note, "and nothing below it either")
    }

    /// A SPLIT gets its own row, and the numbers are the session's flat pane order — so the second pane
    /// of tab two wears ⌘3, not a second ⌘2. Under a tab-keyed builder the split was invisible: one row
    /// stood in for both panes.
    func testASplitTabContributesOneRowPerPaneNumberedFlat() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        for id in try XCTUnwrap(store.tree.activeSession).allPaneIDs() {
            place(store, id, project: "/w/slopdesk")
        }
        let rows = try openedRows(store)
        XCTAssertEqual(rows.count, 3, "one row per PANE, not per tab")
        XCTAssertEqual(Set(rows.map(\.number)), [1, 2, 3], "numbered in the session's flat pane order")
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "and each row names a distinct pane")
    }

    /// An idle shell at its project root would title itself by the folder — i.e. by the very word its
    /// own place line carries. It yields to its program instead, so the row is not one word twice.
    func testAnIdleRootShellDoesNotRestateItsProject() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let first = try pane(store, tab: 0)
        place(store, first, project: "/w/slopdesk")
        store.setForegroundProcess("zsh", for: first)

        let rows = try openedRows(store)
        let row = try XCTUnwrap(rows.first { $0.number == 1 })
        XCTAssertEqual(row.project, "slopdesk")
        XCTAssertEqual(row.title, "zsh")
    }

    /// The highlight lands on the row the ring points at — the frozen order is recency, so a forward open
    /// marks the PREVIOUS pane, not the active one.
    func testHighlightMarksExactlyTheRingsCurrentCandidate() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows = try openedRows(store)
        let switcher = try XCTUnwrap(store.paneSwitcher)
        XCTAssertEqual(rows.filter(\.isHighlighted).count, 1, "exactly one row is marked")
        XCTAssertEqual(rows.first(where: \.isHighlighted)?.id, switcher.highlighted)
    }

    /// ⚠️ A TAB rename does NOT name a pane. The tab is a container; taking its name for every pane it
    /// holds is exactly how three panes of one repo came to read the same thing. The row keeps the pane's
    /// own live identity — which is also what the sidebar shows for it.
    func testATabRenameDoesNotOverrideThePanesOwnIdentity() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let first = try pane(store, tab: 0)
        place(store, first, project: "/w/slopdesk")
        store.setForegroundProcess("claude", for: first)
        store.setAgentIntent("fix the rail flash", for: first)
        let tabID = try XCTUnwrap(store.tree.activeSession).tabs[0].id
        store.renameTab(tabID, to: "Release prep")

        let rows = try openedRows(store)
        XCTAssertEqual(rows.first { $0.number == 1 }?.title, "fix the rail flash")
    }

    // MARK: - `PaneSwitcherMetrics` (how big the card is for the window it floats in)

    /// The MEASURED band: 400 shows a real command untruncated, 640 is the app's widest list rung, and
    /// between them the card takes a share of the window rather than a constant.
    func testWidthTracksTheWindowBetweenTheMeasuredBounds() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 1280), 1280 * 0.42, accuracy: 0.5)
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 1000), 420, accuracy: 0.5)
    }

    /// A wide display does not get a wide card: past ~75 characters the eye loses the line, so the
    /// measure caps even as the window keeps growing.
    func testWidthStopsAtTheMaximumOnAWideWindow() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 1920), PaneSwitcherMetrics.maxWidth)
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 3840), PaneSwitcherMetrics.maxWidth)
    }

    /// ⚠️ THE WINDOW OUTRANKS THE FLOOR. On a narrow window the minimum would draw a card wider than
    /// its host — an overlay that cannot be an overlay. The share ceiling wins.
    func testANarrowWindowShrinksTheCardBelowItsMinimum() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 500), 500 * 0.66, accuracy: 0.5)
        XCTAssertLessThan(PaneSwitcherMetrics.width(container: 500), PaneSwitcherMetrics.minWidth)
        XCTAssertLessThanOrEqual(PaneSwitcherMetrics.width(container: 320), 320)
    }

    /// A short title must not drag the card below the floor — the floor is about the LINE, and only the
    /// window overrides it.
    func testAMidSizedWindowKeepsTheFloor() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 800), PaneSwitcherMetrics.minWidth)
    }

    /// A session with more panes than the window is tall gets a scrolling card, never one taller than its
    /// host.
    func testHeightIsCappedToAShareOfTheWindow() {
        XCTAssertEqual(PaneSwitcherMetrics.maxHeight(container: 900), 630, accuracy: 0.5)
        XCTAssertLessThan(PaneSwitcherMetrics.maxHeight(container: 900), 900)
    }

    /// A zero container (a first layout pass) must not collapse the card to nothing.
    func testAnUnmeasuredContainerFallsBackToTheFloor() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 0), PaneSwitcherMetrics.minWidth)
        XCTAssertEqual(PaneSwitcherMetrics.maxHeight(container: 0), .infinity)
    }
}
