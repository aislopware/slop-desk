// JumpBreadcrumbTests — pins the "JUMPED · session ▸ tab" cue's honesty rules: `jumpToPaneTree` fires
// `onCrossTabJump` ONLY when the landing actually crossed a tab boundary (a same-tab focus, a re-jump to
// the already-active pane, and a gone pane all stay silent — absent, never wrong), and the pure
// `JumpBreadcrumb` title precedence / session-qualification never drift.

import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class JumpBreadcrumbTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// One session ("Local") with one single-leaf tab per title, first tab active — the same shape the
    /// reopen tests use, so a cross-TAB jump inside one session is easy to stage.
    private func tabbedWorkspace(_ titles: [String], sessionName: String = "Local") -> (TreeWorkspace, [PaneID]) {
        let (session, paneIDs) = makeSession(named: sessionName, tabTitles: titles)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), paneIDs)
    }

    private func makeSession(named name: String, tabTitles: [String]) -> (Session, [PaneID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        var paneIDs: [PaneID] = []
        for title in tabTitles {
            let pane = PaneID()
            tabs.append(Tab(title: title, root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: title)
            paneIDs.append(pane)
        }
        return (Session(name: name, tabs: tabs, activeTabIndex: 0, specs: specs), paneIDs)
    }

    // MARK: - Store: when the hook fires

    func testCrossTabJumpFiresTheBreadcrumbOnce() {
        let (ws, paneIDs) = tabbedWorkspace(["A", "B"])
        let store = makeTreeStore(restoringTree: ws)
        var crumbs: [String] = []
        store.onCrossTabJump = { crumbs.append($0) }

        store.jumpToPaneTree(paneIDs[1])
        XCTAssertEqual(crumbs, ["B"], "landing on another tab announces the destination")

        store.jumpToPaneTree(paneIDs[1])
        XCTAssertEqual(crumbs, ["B"], "re-jumping to the already-active pane changes nothing — silent")
    }

    func testSameTabFocusStaysSilent() {
        let (ws, paneIDs) = tabbedWorkspace(["A"])
        let store = makeTreeStore(restoringTree: ws)
        store.splitPaneTree(paneIDs[0], axis: .horizontal, kind: .terminal)
        let sibling = store.tree.activeSession?.activeTab?.allPaneIDs().first { $0 != paneIDs[0] }
        var crumbs: [String] = []
        store.onCrossTabJump = { crumbs.append($0) }

        // Bounce focus between the two panes of the SAME tab — the viewport never swaps wholesale.
        store.jumpToPaneTree(paneIDs[0])
        if let sibling { store.jumpToPaneTree(sibling) }
        XCTAssertEqual(crumbs, [], "a within-tab focus is just a focus — no breadcrumb")
    }

    func testGonePaneIsANoOp() {
        let (ws, _) = tabbedWorkspace(["A", "B"])
        let store = makeTreeStore(restoringTree: ws)
        var crumbs: [String] = []
        store.onCrossTabJump = { crumbs.append($0) }

        store.jumpToPaneTree(PaneID()) // never existed (≈ closed before the notification click landed)
        XCTAssertEqual(crumbs, [], "a jump to a gone pane does nothing, so it announces nothing")
    }

    func testMultiSessionJumpQualifiesWithTheSessionName() {
        let (local, _) = makeSession(named: "Local", tabTitles: ["A"])
        let (remote, remotePanes) = makeSession(named: "herdr", tabTitles: ["build"])
        let ws = TreeWorkspace(sessions: [local, remote], activeSessionID: local.id)
        let store = makeTreeStore(restoringTree: ws)
        var crumbs: [String] = []
        store.onCrossTabJump = { crumbs.append($0) }

        store.jumpToPaneTree(remotePanes[0])
        XCTAssertEqual(crumbs, ["herdr ▸ build"], "several sessions ⇒ the crumb names WHICH one you landed in")
    }

    // MARK: - Pure: title precedence + session qualification

    func testTabDisplayTitlePrecedence() {
        let pane = PaneID()
        var spec = PaneSpec(kind: .terminal, title: "spec-title")
        let named = Tab(title: "renamed", root: .leaf(pane), activePane: pane)
        XCTAssertEqual(
            JumpBreadcrumb.tabDisplayTitle(tab: named, specs: [pane: spec]), "renamed",
            "an explicit tab title always wins",
        )

        let derived = Tab(root: .leaf(pane), activePane: pane)
        spec.lastKnownTitle = "osc-title"
        XCTAssertEqual(
            JumpBreadcrumb.tabDisplayTitle(tab: derived, specs: [pane: spec]), "osc-title",
            "an untitled tab derives from the active pane's last-known OSC title",
        )

        spec.lastKnownTitle = nil
        XCTAssertEqual(
            JumpBreadcrumb.tabDisplayTitle(tab: derived, specs: [pane: spec]), "spec-title",
            "no OSC title yet ⇒ the spec title",
        )

        XCTAssertEqual(
            JumpBreadcrumb.tabDisplayTitle(tab: derived, specs: [:]), "Tab",
            "nothing known ⇒ the placeholder — the chip must still name SOMETHING",
        )
    }

    func testBreadcrumbTextSessionQualification() {
        XCTAssertEqual(JumpBreadcrumb.text(sessionName: "Local", tabTitle: "build", includeSession: false), "build")
        XCTAssertEqual(
            JumpBreadcrumb.text(sessionName: "Local", tabTitle: "build", includeSession: true),
            "Local ▸ build",
        )
        XCTAssertEqual(
            JumpBreadcrumb.text(sessionName: "", tabTitle: "build", includeSession: true), "build",
            "an empty session name degrades to the tab-only form, never a dangling separator",
        )
    }
}
