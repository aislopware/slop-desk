// PaneSwitcherRowsTests — pins what a ⌃⇥ switcher row SAYS and where the section headers fall.
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
    // MARK: - `header` (the section a row sits under)

    /// The header is the PROJECT's folder name, whatever the pane's own cwd is below it.
    func testHeaderIsTheProjectFolderName() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.header(projectKey: "/w/slopdesk", cwd: "/w/slopdesk/packages/api"),
            "slopdesk",
        )
    }

    /// A pane with no project key yet still lands under a place — its own folder.
    func testHeaderWithoutAKeyIsTheOwnFolder() {
        XCTAssertEqual(PaneSwitcherRowsBuilder.header(projectKey: nil, cwd: "/w/scratch"), "scratch")
        XCTAssertNil(PaneSwitcherRowsBuilder.header(projectKey: nil, cwd: nil))
    }

    // MARK: - `relativePath` / `note` (the quiet remainder)

    /// A pane AT its project root adds nothing — the header already said the place.
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

    // MARK: - `unrepeated` (a title must not restate its header)

    /// A row whose identity fell all the way through to the folder name would say the header twice —
    /// it yields to the pane's program instead.
    func testATitleThatRestatesTheHeaderYieldsToTheProgram() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated("slopdesk", header: "slopdesk", processLabel: "-zsh"),
            "zsh",
        )
    }

    /// …but only when it has a program to yield to: a blank line says less than a redundant one.
    func testATitleRestatingTheHeaderSurvivesWithNoProgram() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated("slopdesk", header: "slopdesk", processLabel: nil),
            "slopdesk",
        )
    }

    /// A real identity is never touched, even when a program is known.
    func testARealTitleIsNeverReplaced() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.unrepeated("make check", header: "slopdesk", processLabel: "make"),
            "make check",
        )
    }

    // MARK: - `items` (headers fall on run boundaries, order untouched)

    private func row(_ title: String, project: String?, number: Int = 1) -> PaneSwitcherRow {
        PaneSwitcherRow(
            id: PaneID(), number: number, title: title, note: nil, project: project,
            isHighlighted: false,
        )
    }

    /// Panes of ONE project get NO header — the card IS that project, and a caption over a run with
    /// nothing to be distinguished from is a label on a box holding one thing.
    func testOneProjectGetsNoHeaderAtAll() {
        let items = PaneSwitcherRowsBuilder.items([
            row("fix the rail flash", project: "slopdesk"),
            row("nvim main.swift", project: "slopdesk"),
            row("make check", project: "slopdesk"),
        ])
        XCTAssertEqual(items.count, 3, "three rows, no header")
        XCTAssertEqual(
            items.filter { if case .section = $0.content { true } else { false } }.count, 0,
        )
    }

    /// ⚠️ THE ORDER IS THE RING'S. A project that comes back after another one heads a SECOND run rather
    /// than pulling its rows up — re-sorting would make the ⇥ highlight jump around the card.
    func testAReturningProjectHeadsASecondRunRatherThanReordering() {
        let items = PaneSwitcherRowsBuilder.items([
            row("fix the rail flash", project: "slopdesk"),
            row("zsh", project: "otty"),
            row("nvim main.swift", project: "slopdesk"),
        ])
        let sections = items.compactMap { item -> String? in
            if case let .section(name) = item.content { name } else { nil }
        }
        XCTAssertEqual(sections, ["slopdesk", "otty", "slopdesk"])
        let titles = items.compactMap { item -> String? in
            if case let .row(row) = item.content { row.title } else { nil }
        }
        XCTAssertEqual(
            titles, ["fix the rail flash", "zsh", "nvim main.swift"], "row order is the ring's, untouched",
        )
        XCTAssertEqual(items.map(\.id), Array(0..<items.count), "ids are positions — names repeat")
    }

    /// A projectless row (a video pane, a cwd that has not landed) opens no section — it continues the
    /// run above it instead of scattering an "Other" bucket through a recency-ordered list.
    func testAProjectlessRowOpensNoSection() {
        let items = PaneSwitcherRowsBuilder.items([
            row("fix the rail flash", project: "slopdesk"),
            row("Safari", project: nil),
            row("nvim main.swift", project: "slopdesk"),
            row("zsh", project: "otty"),
        ])
        let sections = items.compactMap { item -> String? in
            if case let .section(name) = item.content { name } else { nil }
        }
        XCTAssertEqual(
            sections, ["slopdesk", "otty"], "the projectless row neither heads nor breaks the run",
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
            Set(rows.compactMap(\.project)), ["slopdesk"], "both sit under the project they share",
        )
        XCTAssertEqual(rows.compactMap(\.note), [], "a pane at its project root adds nothing")
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.items(rows).filter {
                if case .section = $0.content { true } else { false }
            }.count,
            0,
            "one project — the card is the project, so no header",
        )
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

    /// An idle shell at its project root would title itself by the folder — i.e. by its own header. It
    /// yields to its program instead, so the row is not the header printed twice.
    func testAnIdleRootShellDoesNotRestateItsHeader() throws {
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
