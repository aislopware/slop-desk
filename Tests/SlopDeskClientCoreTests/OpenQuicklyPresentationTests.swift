// OpenQuicklyPresentationTests — pins what the ⌘⇧O picker IS, below both platforms.
//
// The picker is drawn twice since docs/56 stage D: an `NSPanel` on the Mac, a card on the phone. The
// piece worth the most pinning is the VERB TABLE — which ⌘K actions a row offers, and what ↩ runs —
// because a verb table is the kind of thing that drifts without failing: one half quietly grows an
// action the other has not got, and nothing is red until a user notices the picker is different on
// their phone. So the tables are asserted by title, in order, per source.
//
// It replaces `OpenQuicklyFolderActionsTests`, which pinned the Folder set alone through a static on
// the SwiftUI view — the seam that moved here.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class OpenQuicklyPresentationTests: XCTestCase {
    private func store() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func item(
        kind: OpenQuicklyKind, title: String = "row", subtitle: String? = nil,
        act: OpenQuicklyItem.Act,
    ) -> OpenQuicklyItem {
        OpenQuicklyItem(
            id: "id-\(title)", kind: kind, title: title, subtitle: subtitle, timestamp: nil,
            searchText: title, act: act,
        )
    }

    // MARK: - The verb tables

    /// The Folder set, in table order. Split Right / Down open a fresh terminal rooted at the folder;
    /// "Open in New Window" is absent on purpose (N/A in the single-window rail model, pinned in
    /// `docs/DECISIONS.md`) rather than being a dead row.
    func testTheFolderTableIsTheFullSetInOrder() {
        let titles = OpenQuicklyActions.folderActions(
            path: "/Users/me/proj", store: store(), model: nil, folders: nil,
        ).map(\.title)
        XCTAssertEqual(titles, [
            "Split Right", "Split Down", "Change Directory Here", "Reveal in Finder", "Copy Path",
        ])
    }

    /// "Forget This Folder" appears only when a frecency store backs the list — without one there is
    /// nothing to forget it from, and an inert row is worse than an absent one.
    func testForgetThisFolderNeedsAFrecencyStore() {
        let folders = FolderFrecencyStore()
        let titles = OpenQuicklyActions.folderActions(
            path: "/Users/me/proj", store: store(), model: nil, folders: folders,
        ).map(\.title)
        XCTAssertEqual(titles.last, "Forget This Folder")
    }

    /// A Current COMMAND row gets the verbatim re-run pair rather than the generic jump-to+copy the
    /// shared Jump-To table returns: the row IS a command that already ran.
    func testACurrentCommandRowGetsTheReRunPair() {
        let row = item(kind: .command, title: "make quick", act: .jumpTo(.block(index: 3)))
        let titles = OpenQuicklyActions.rowActions(
            for: row, store: store(), model: nil, folders: nil,
        ).map(\.title)
        XCTAssertEqual(titles, ["Re-Run in Current Pane", "Copy Command"])
    }

    /// A pane row's cwd rows are CONTINGENT on there being a cwd: a pane the host has not answered
    /// for yet offers Close alone rather than two verbs that would reveal and copy nothing.
    func testAPaneRowsCwdVerbsFollowItsCwd() {
        let paneID = PaneID()
        let bare = item(kind: .pane, title: "zsh", act: .focusPane(paneID))
        XCTAssertEqual(
            OpenQuicklyActions.rowActions(for: bare, store: store(), model: nil, folders: nil)
                .map(\.title),
            ["Close Pane"],
        )
        let sited = item(kind: .pane, title: "zsh", subtitle: "/tmp", act: .focusPane(paneID))
        XCTAssertEqual(
            OpenQuicklyActions.rowActions(for: sited, store: store(), model: nil, folders: nil)
                .map(\.title),
            ["Close Pane", "Reveal CWD in Finder", "Copy CWD Path"],
        )
    }

    /// An agent row always offers its session id, and its project path only when it has one.
    func testAnAgentRowAlwaysOffersItsSessionID() {
        let projectless = item(kind: .agent, act: .resumeAgent(sessionID: "abc", cwd: ""))
        XCTAssertEqual(
            OpenQuicklyActions.rowActions(for: projectless, store: store(), model: nil, folders: nil)
                .map(\.title),
            ["Resume Session", "Copy Session ID"],
        )
        let sited = item(kind: .agent, act: .resumeAgent(sessionID: "abc", cwd: "/tmp/p"))
        XCTAssertEqual(
            OpenQuicklyActions.rowActions(for: sited, store: store(), model: nil, folders: nil)
                .map(\.title),
            ["Resume Session", "Copy Project Path", "Copy Session ID"],
        )
    }

    // MARK: - The list, flattened

    /// Headers appear under ALL and nowhere else — on a specific pill the pill IS the label — and the
    /// selectable index counts ROWS ONLY, which is the whole reason the flattening is shared: a half
    /// that paired them itself would be one off the moment a header appeared mid-list.
    func testHeadersDrawUnderAllAndNeverCountAsSelectable() {
        let sections = [
            OpenQuicklySection(filter: .opened, items: [
                item(kind: .pane, title: "a", act: .focusPane(PaneID())),
                item(kind: .pane, title: "b", act: .focusPane(PaneID())),
            ]),
            OpenQuicklySection(filter: .folders, items: [
                item(kind: .folder, title: "c", act: .openFolder(path: "/c")),
            ]),
        ]
        let all = OpenQuicklyPresentation.displayEntries(sections, filter: .all)
        XCTAssertEqual(all.count, 5, "two headers over three rows")
        XCTAssertEqual(selectableIndices(all), [0, 1, 2])

        let opened = OpenQuicklyPresentation.displayEntries(sections, filter: .opened)
        XCTAssertEqual(opened.count, 3, "no headers off the ALL pill")
        XCTAssertEqual(selectableIndices(opened), [0, 1, 2])
    }

    /// An EMPTY source draws no header under ALL either — a caps label over nothing is a promise the
    /// list does not keep.
    func testAnEmptySourceDrawsNoHeader() {
        let sections = [
            OpenQuicklySection(filter: .opened, items: []),
            OpenQuicklySection(filter: .folders, items: [
                item(kind: .folder, title: "c", act: .openFolder(path: "/c")),
            ]),
        ]
        let entries = OpenQuicklyPresentation.displayEntries(sections, filter: .all)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.id, "header:folders")
    }

    private func selectableIndices(_ entries: [OpenQuicklyDisplayEntry]) -> [Int] {
        entries.compactMap { entry in
            if case let .row(_, index) = entry.kind { return index }
            return nil
        }
    }

    // MARK: - The words

    /// Three zero-state answers, and the ORDER between them is the decision: a typed query that
    /// matched nothing says so about the query, even while an Agents fetch is still in flight.
    func testTheZeroStateAnswersTheQueryFirst() {
        XCTAssertEqual(
            OpenQuicklyPresentation.emptyMessage(query: "zz", filter: .agents, agentsLoading: true),
            "No matches",
        )
        XCTAssertEqual(
            OpenQuicklyPresentation.emptyMessage(query: "", filter: .agents, agentsLoading: true),
            "Loading agents…",
        )
        XCTAssertEqual(
            OpenQuicklyPresentation.emptyMessage(query: " ", filter: .agents, agentsLoading: false),
            OpenQuicklyFilter.agents.emptyMessage,
        )
    }

    /// The ↩ verb is the ROW's: a footer that read "Open" for all six sources would be wrong for four
    /// of them.
    func testTheReturnVerbFollowsTheRow() {
        XCTAssertEqual(OpenQuicklyPresentation.defaultActionLabel(for: .pane), "Switch to")
        XCTAssertEqual(OpenQuicklyPresentation.defaultActionLabel(for: .recentTab), "Reopen")
        XCTAssertEqual(OpenQuicklyPresentation.defaultActionLabel(for: .folder), "Change Directory")
        XCTAssertEqual(OpenQuicklyPresentation.defaultActionLabel(for: .agent), "Resume")
        XCTAssertEqual(OpenQuicklyPresentation.defaultActionLabel(for: .command), "Jump to")
        XCTAssertEqual(OpenQuicklyPresentation.defaultActionLabel(for: nil), "Open")
    }

    // MARK: - The ⌘ table

    /// ⌘1–9 arrives 1-BASED, as typed — the conversion to a row index is the model's, and a chord
    /// that handed over a 0-based digit would silently pick the row above the one asked for.
    ///
    /// ⌘0 is NOT the tenth row: zero is outside the quick-pick range and falls through to the pill
    /// table, where it is the ALL pill. That fallthrough is why the digit branch is allowed to run
    /// first at all.
    func testTheDigitChordsStayOneBasedAndZeroIsAPill() {
        XCTAssertEqual(OpenQuicklyPresentation.commandChord("1"), .quickPick(1))
        XCTAssertEqual(OpenQuicklyPresentation.commandChord("9"), .quickPick(9))
        XCTAssertEqual(OpenQuicklyPresentation.commandChord("0"), .selectPill(.all))
    }

    /// Every pill has a chord and every chord reaches its pill, in both cases — a table with a hole
    /// in it is a key that does nothing rather than a key that is free.
    func testEveryPillIsReachableByItsOwnChord() {
        for pill in OpenQuicklyFilter.pickerPills {
            guard let character = pill.pickerChordKey.first else {
                XCTFail("\(pill) has no chord key")
                continue
            }
            XCTAssertEqual(
                OpenQuicklyPresentation.commandChord(character), .selectPill(pill),
                "⌘\(character) must reach \(pill)",
            )
        }
    }

    /// ⌘K is the action sheet's, in either case — a caps-lock user must not lose it.
    func testTheActionsChordIsCaseBlind() {
        XCTAssertEqual(OpenQuicklyPresentation.commandChord("k"), .toggleActions)
        XCTAssertEqual(OpenQuicklyPresentation.commandChord("K"), .toggleActions)
    }

    /// A key the picker does not claim comes back `nil` rather than as a guess, so the caller can let
    /// it walk on instead of swallowing it.
    func testAnUnclaimedChordIsRefused() {
        XCTAssertNil(OpenQuicklyPresentation.commandChord("q"))
    }

    // MARK: - The measurements

    /// The ⇞/⇟ stride is derived from the viewport, and a zero row height reads as one row rather
    /// than dividing by zero — a page that advances by nothing is a key that appears broken.
    func testThePageStrideFollowsTheViewportAndNeverStalls() {
        XCTAssertEqual(
            OpenQuicklyMetrics.pageStride(rowHeight: 44),
            Int(OpenQuicklyMetrics.resultsMaxHeight / 44),
        )
        XCTAssertEqual(OpenQuicklyMetrics.pageStride(rowHeight: 0), 1)
        XCTAssertEqual(OpenQuicklyMetrics.pageStride(rowHeight: 10000), 1)
    }
}
