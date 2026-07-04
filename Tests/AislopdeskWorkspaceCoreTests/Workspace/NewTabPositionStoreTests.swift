import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E7 carry-over #6 (ES-E3-3): the STORE wiring of the `new-tab-position` policy — a new tab lands where
/// ``SettingsKey/newTabPosition`` says, evaluated against the active session's tab list. The pure placement
/// math is pinned in `NewTabPositionTests`; here we pin that the ⌘T fire-sites (`newTab(kind:)` AND the
/// primary `openChooserPane(.newTab)` chooser flow) actually READ the setting — preventing a silent
/// regression to a hardcoded `.end` append. Drives a LIVE `.tree` store through the `FakePaneSession` seam.
@MainActor
final class NewTabPositionStoreTests: XCTestCase {
    private let key = SettingsKey.newTabPositionKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
    }

    /// A single-session workspace with three single-pane tabs, the `activeIndex`-th tab selected. Returns the
    /// per-tab leaf ids in tab order.
    private func threeTabSession(activeIndex: Int) -> (TreeWorkspace, [PaneID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        var panes: [PaneID] = []
        for i in 0..<3 {
            let pane = PaneID()
            panes.append(pane)
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: "T\(i)")
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: activeIndex, specs: specs)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), panes)
    }

    /// The index of the active session's tab that owns `pane`, or `nil` when none does.
    private func tabIndex(of pane: PaneID, in store: WorkspaceStore) -> Int? {
        store.tree.activeSession?.tabs.firstIndex { $0.contains(pane) }
    }

    /// The single new leaf minted by an op (the set difference vs. `before`).
    private func newLeaf(_ store: WorkspaceStore, since before: Set<PaneID>) throws -> PaneID {
        try XCTUnwrap(Set(store.tree.allPaneIDs()).subtracting(before).first, "the op mints exactly one new leaf")
    }

    // MARK: - after-current: insert immediately after the active (middle) tab + select it

    func testNewTabAfterCurrentLandsAfterMiddleActiveTab() throws {
        UserDefaults.standard.set("after-current", forKey: key)
        let (tree, _) = threeTabSession(activeIndex: 1) // MIDDLE tab active (index 1 of 0,1,2)
        let store = makeTreeStore(restoringTree: tree)
        let before = Set(store.tree.allPaneIDs())

        store.newTab(kind: .terminal)

        let added = try newLeaf(store, since: before)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 4, "a tab was added")
        XCTAssertEqual(tabIndex(of: added, in: store), 2, "after-current inserts at activeIndex+1 (2), not the end (3)")
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "the inserted tab is selected")
    }

    /// The PRIMARY ⌘T flow routes through `openChooserPane(.newTab)` (a `.chooser` pane), NOT
    /// `newTab(kind: .terminal)` — so it must read the SAME placement policy. Pins that the dominant gesture
    /// honours `after-current` (a regression that hardcoded `.end` on the chooser path would slip past the
    /// direct-`newTab` test above).
    func testChooserNewTabAfterCurrentLandsAfterMiddleActiveTab() throws {
        UserDefaults.standard.set("after-current", forKey: key)
        let (tree, _) = threeTabSession(activeIndex: 1)
        let store = makeTreeStore(restoringTree: tree)
        let before = Set(store.tree.allPaneIDs())

        store.openChooserPane(.newTab) // the real ⌘T gesture

        let added = try newLeaf(store, since: before)
        XCTAssertEqual(store.tree.spec(for: added)?.kind, .chooser, "⌘T mints a chooser pane")
        XCTAssertEqual(tabIndex(of: added, in: store), 2, "the chooser tab also lands after the active (middle) tab")
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "and is selected")
    }

    // MARK: - end: append even with a middle-active tab

    func testNewTabEndAppendsEvenWithMiddleActiveTab() throws {
        UserDefaults.standard.set("end", forKey: key)
        let (tree, _) = threeTabSession(activeIndex: 1) // middle active, but `.end` ignores it
        let store = makeTreeStore(restoringTree: tree)
        let before = Set(store.tree.allPaneIDs())

        store.newTab(kind: .terminal)

        let added = try newLeaf(store, since: before)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 4, "a tab was added")
        XCTAssertEqual(tabIndex(of: added, in: store), 3, "the .end policy appends to the end (index 3)")
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 3, "the appended tab is selected")
    }
}
