// PaneSwitcherRowsTests — pins what a ⌃⇥ switcher row SAYS, both halves of it: the identity, and the
// PLACE line under it that each row now carries for itself instead of borrowing from a section header.
//
// The regression this guards: the switcher named every row through the folder-name rung, so three panes
// opened in one repo read `slopdesk` / `slopdesk` / `slopdesk` and the ring's whole purpose (which one am
// I flipping to?) was unanswerable. `testTwoPanesInOneProjectReadDifferently` fails against that build —
// it asserts the two rows' titles DIFFER while both still resolve to the one project they share.
//
// The composing itself — the project name, the note, the title that must not restate either — is the
// crate's, tested there; what is left here is what only Swift can answer: the rows a live store yields,
// and the answers the doors give back. Headless: the same tree-model `WorkspaceStore` +
// `MountTestPaneSession` fake the rail-row tests use (no socket, no video, no Metal).

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneSwitcherRowsTests: XCTestCase {
    // MARK: - Live rows

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
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
        XCTAssertEqual(
            titles[1], "\(RailRowsBuilder.agentTitleMark) fix the rail flash",
            "the agent pane is named by its task, led by the static agent mark",
        )
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
        XCTAssertEqual(
            rows.first { $0.number == 1 }?.title,
            "\(RailRowsBuilder.agentTitleMark) fix the rail flash",
        )
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
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 1920), PaneSwitcherMetrics.width(container: 3840))
        XCTAssertLessThan(PaneSwitcherMetrics.width(container: 3840), 1920 * 0.42)
    }

    /// ⚠️ THE WINDOW OUTRANKS THE FLOOR. On a narrow window the minimum would draw a card wider than
    /// its host — an overlay that cannot be an overlay. The share ceiling wins.
    func testANarrowWindowShrinksTheCardBelowItsMinimum() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 500), 500 * 0.66, accuracy: 0.5)
        XCTAssertLessThan(PaneSwitcherMetrics.width(container: 500), PaneSwitcherMetrics.width(container: 800))
        XCTAssertLessThanOrEqual(PaneSwitcherMetrics.width(container: 320), 320)
    }

    /// A short title must not drag the card below the floor — the floor is about the LINE, and only the
    /// window overrides it.
    func testAMidSizedWindowKeepsTheFloor() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 800), 400, accuracy: 0.5)
        XCTAssertGreaterThan(PaneSwitcherMetrics.width(container: 800), 800 * 0.42)
    }

    /// A session with more panes than the window is tall gets a scrolling card, never one taller than its
    /// host.
    func testHeightIsCappedToAShareOfTheWindow() {
        XCTAssertEqual(PaneSwitcherMetrics.maxHeight(container: 900), 630, accuracy: 0.5)
        XCTAssertLessThan(PaneSwitcherMetrics.maxHeight(container: 900), 900)
    }

    /// A zero container (a first layout pass) must not collapse the card to nothing.
    func testAnUnmeasuredContainerFallsBackToTheFloor() {
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 0), PaneSwitcherMetrics.width(container: 800))
        XCTAssertEqual(PaneSwitcherMetrics.maxHeight(container: 0), .infinity)
    }

    // MARK: - The COMPACT rung (the phone's card, on a screen with no "behind")

    /// ⚠️ THE PHONE TAKES THE WIDTH IT IS OFFERED. Both of the window band's bounds are unavailable
    /// here: the 400 floor is wider than the whole screen, and the two-thirds ceiling — whose premise is
    /// the workspace BEHIND the card — would answer a 390pt phone with a 257pt card, every row
    /// truncated.
    func testCompactWidthTakesTheWholeScreenOnAPhone() {
        XCTAssertEqual(PaneSwitcherMetrics.compactWidth(container: 390), 390)
        XCTAssertLessThan(PaneSwitcherMetrics.width(container: 390), PaneSwitcherMetrics.compactWidth(container: 390))
    }

    /// The ONE bound that was never about the window survives: past ~75 characters the eye loses the
    /// line, so an iPad's card caps exactly where the Mac's does.
    func testCompactWidthStillStopsAtTheMeasureCap() {
        let cap = PaneSwitcherMetrics.compactWidth(container: 640)
        XCTAssertEqual(PaneSwitcherMetrics.compactWidth(container: 1024), cap)
        XCTAssertEqual(PaneSwitcherMetrics.width(container: 3840), cap)
    }

    /// An unmeasured container yields the CAP, not the floor: the phone's frame is a `maxWidth`, so the
    /// enclosing margin still bounds it — where 400 would ask a 390pt screen for a card wider than
    /// itself.
    func testAnUnmeasuredCompactContainerFallsBackToTheCap() {
        XCTAssertEqual(
            PaneSwitcherMetrics.compactWidth(container: 0),
            PaneSwitcherMetrics.compactWidth(container: 1024),
        )
    }

    /// The rows stand at their TRUE height until the ceiling, which is what the Mac reads off a laid-out
    /// stack and SwiftUI cannot be asked for — a `ScrollView` claims every point it is offered, so
    /// without this a two-row card stands 70% of the screen tall.
    func testListHeightIsTheRowsOwnHeightUntilTheCeiling() {
        XCTAssertEqual(
            PaneSwitcherMetrics.listHeight(rows: 3, rowHeight: 48, container: 900), 144, accuracy: 0.5,
        )
        XCTAssertEqual(
            PaneSwitcherMetrics.listHeight(rows: 40, rowHeight: 48, container: 900),
            PaneSwitcherMetrics.maxHeight(container: 900), accuracy: 0.5,
        )
        XCTAssertLessThan(PaneSwitcherMetrics.listHeight(rows: 40, rowHeight: 48, container: 900), 40 * 48)
    }

    /// An unmeasured container has no ceiling to impose, so the rows keep their own height rather than
    /// collapsing to nothing.
    func testListHeightWithoutAContainerIsJustTheRows() {
        XCTAssertEqual(
            PaneSwitcherMetrics.listHeight(rows: 2, rowHeight: 48, container: 0), 96, accuracy: 0.5,
        )
    }

    // MARK: - `walk` (what a TAP is, on a device with no modifier to release)

    /// The short way round the frozen ring, in both directions — the count is the number of previews a
    /// single tap costs, so walking the long way is not a neutral choice.
    func testWalkTakesTheShorterWayRoundTheRing() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 0, to: 1, count: 5), PaneSwitcherWalk(forward: true, steps: 1),
        )
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 0, to: 4, count: 5), PaneSwitcherWalk(forward: false, steps: 1),
        )
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 3, to: 0, count: 5), PaneSwitcherWalk(forward: true, steps: 2),
        )
    }

    /// A tap on the row that is ALREADY highlighted is a bare commit — no step, so no preview write.
    func testWalkToTheHighlightIsNoStepsAtAll() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 2, to: 2, count: 5), PaneSwitcherWalk(forward: true, steps: 0),
        )
    }

    /// The tie — the row exactly opposite on an even ring — goes FORWARD, the direction a bare ⇥ walks.
    func testWalkBreaksTheEvenRingTieForward() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 0, to: 2, count: 4), PaneSwitcherWalk(forward: true, steps: 2),
        )
    }

    /// A ring that cannot be walked (one candidate, or none) answers with zero steps rather than a
    /// modulo by zero.
    func testWalkOnAnUnwalkableRingIsZeroSteps() {
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 0, to: 0, count: 1), PaneSwitcherWalk(forward: true, steps: 0),
        )
        XCTAssertEqual(
            PaneSwitcherRowsBuilder.walk(from: 0, to: 3, count: 0), PaneSwitcherWalk(forward: true, steps: 0),
        )
    }

    /// ⚠️ THE WALK IS IN CANDIDATE SPACE. Over the live gesture it lands on the ring's index, which is
    /// what ``PaneSwitcher/step(forward:)`` moves — the ROW index can differ, because a row whose pane
    /// closed under the gesture is dropped from the drawn list and not from the frozen ring.
    func testWalkOverTheLiveGestureCountsCandidatesNotRows() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        let switcher = try XCTUnwrap(store.paneSwitcher)
        let target = switcher.candidates[2]

        let walk = try XCTUnwrap(PaneSwitcherRowsBuilder.walk(to: target, in: switcher))
        XCTAssertEqual(walk, PaneSwitcherRowsBuilder.walk(from: switcher.highlightIndex, to: 2, count: 3))
    }

    /// A pane the ring never held — a row tapped in the same frame its pane closed — is a no-op, never a
    /// walk toward nowhere.
    func testWalkToAPaneOutsideTheRingIsNil() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: true)
        let switcher = try XCTUnwrap(store.paneSwitcher)
        XCTAssertNil(PaneSwitcherRowsBuilder.walk(to: PaneID(), in: switcher))
    }

    // MARK: - The words

    /// ⚠️ ONE NAME FOR THE SURFACE AND THE COMMAND THAT SUMMONS IT. The phone's card is titled (the Mac's
    /// 200ms readout is not), and the palette row is the phone's only touch entry point into the
    /// gesture — a card that called itself something else would be a second name for one thing.
    func testTheCardIsTitledExactlyAsThePaletteRowThatOpensIt() {
        XCTAssertEqual(
            PaneSwitcherCopy.title,
            WorkspaceBindingRegistry.binding(for: .paneSwitcher)?.title,
        )
    }
}
