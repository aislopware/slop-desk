import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the `new-tab-position` policy — the pure
/// ``NewTabPosition/insertionIndex(activeTabIndex:tabCount:)`` math, the `at:`-aware placement both
/// ops that add a tab obey (`spawnTab` for ⌘T, `reopenClosedTab` for ⇧⌘T), and the
/// `SettingsKey.newTabPosition` Defaults bridge.
///
/// The load-bearing guarantee is that `.auto`/`.end` stay **byte-identical to the old `tabs.append`** (so
/// every existing call site is unchanged) while `.afterCurrent` lands the new tab right after the active
/// one. Pure value-type ops — no store, no `FakePaneSession`, no SwiftUI.
@MainActor
final class NewTabPositionTests: XCTestCase {
    override func setUp() { SettingsKey.store.removeObject(forKey: SettingsKey.newTabPositionKey) }
    override func tearDown() { SettingsKey.store.removeObject(forKey: SettingsKey.newTabPositionKey) }

    // MARK: - Fixtures

    /// A single-session workspace with `tabCount` single-leaf tabs (active = `active`). Returns the
    /// workspace plus the ordered tab ids so a test can assert exact placement.
    private func multiTabWorkspace(tabCount: Int, active: Int) -> (TreeWorkspace, [TabID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for _ in 0..<tabCount {
            let pid = PaneID()
            tabs.append(Tab(root: .leaf(pid), activePane: pid))
            specs[pid] = PaneSpec(kind: .terminal, title: "Terminal")
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: active, specs: specs)
        let ws = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        return (ws, tabs.map(\.id))
    }

    private func activeSession(_ ws: TreeWorkspace) throws -> Session {
        try XCTUnwrap(ws.activeSession)
    }

    // MARK: - insertionIndex (pure index math)

    func testInsertionIndexEndAndAutoAppend() {
        // Both append regardless of where the active tab sits.
        for pos in [NewTabPosition.end, .auto] {
            XCTAssertEqual(pos.insertionIndex(activeTabIndex: 0, tabCount: 3), 3, "\(pos) appends")
            XCTAssertEqual(pos.insertionIndex(activeTabIndex: 2, tabCount: 3), 3, "\(pos) appends")
            XCTAssertEqual(pos.insertionIndex(activeTabIndex: 0, tabCount: 0), 0, "\(pos) empty → 0")
        }
    }

    func testInsertionIndexAfterCurrentIsActivePlusOne() {
        let pos = NewTabPosition.afterCurrent
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: 0, tabCount: 3), 1, "after the first tab")
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: 1, tabCount: 3), 2, "after the middle tab")
        // Active is the LAST tab → after-current == append (the end index).
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: 2, tabCount: 3), 3, "after the last tab == append")
    }

    func testInsertionIndexAfterCurrentClampsHostileInput() {
        let pos = NewTabPosition.afterCurrent
        // A stale / out-of-range active index can never produce an invalid Array.insert(at:) index.
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: -5, tabCount: 3), 1, "negative active → after tab 0")
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: 99, tabCount: 3), 3, "over-range active → append")
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: 0, tabCount: 0), 0, "empty list → 0")
        XCTAssertEqual(pos.insertionIndex(activeTabIndex: 3, tabCount: -1), 0, "negative count → 0")
    }

    // MARK: - newTab(at:) placement end-to-end

    func testNewTabAfterCurrentInsertsAfterActiveTab() throws {
        let (ws, ids) = multiTabWorkspace(tabCount: 3, active: 1)
        let (next, paneID) = TreeIntent.newTab(
            in: ws,
            spec: PaneSpec(kind: .terminal, title: "New"),
            at: .afterCurrent,
        )
        let session = try activeSession(next)
        XCTAssertEqual(session.tabs.count, 4)
        XCTAssertEqual(session.activeTabIndex, 2, "the new tab becomes active at index 2")
        XCTAssertEqual(session.tabs[2].activePane, paneID, "index 2 is the freshly minted tab")
        // Ordering: original 0,1, then NEW, then the old index-2 tab.
        XCTAssertEqual(session.tabs[0].id, ids[0])
        XCTAssertEqual(session.tabs[1].id, ids[1])
        XCTAssertEqual(session.tabs[3].id, ids[2], "the old active+1 tab is pushed down one")
        XCTAssertTrue(next.isInvariantHeld())
    }

    func testNewTabEndAndAutoAppendByteIdenticalToOldBehaviour() throws {
        // With a MIDDLE tab active, `.end` and `.auto` must still append (index == old count) — the proof
        // that every default-`.end` call site is unchanged from the old `tabs.append`.
        for pos in [NewTabPosition.end, .auto] {
            let (ws, ids) = multiTabWorkspace(tabCount: 3, active: 1)
            let (next, paneID) = TreeIntent.newTab(
                in: ws,
                spec: PaneSpec(kind: .terminal, title: "New"),
                at: pos,
            )
            let session = try activeSession(next)
            XCTAssertEqual(session.tabs.count, 4)
            XCTAssertEqual(session.activeTabIndex, 3, "\(pos): appended tab is active at the end")
            XCTAssertEqual(session.tabs.prefix(3).map(\.id), ids, "\(pos): existing tabs keep their order")
            XCTAssertEqual(session.tabs[3].activePane, paneID)
            XCTAssertTrue(next.isInvariantHeld())
        }
    }

    /// The default parameter is `.end`, so the no-`at:` call site is the append path (every existing caller).
    func testNewTabDefaultsToAppend() throws {
        let (ws, ids) = multiTabWorkspace(tabCount: 2, active: 0)
        let (next, _) = TreeIntent.newTab(in: ws, spec: PaneSpec(kind: .terminal, title: "New"))
        let session = try activeSession(next)
        XCTAssertEqual(session.activeTabIndex, 2)
        XCTAssertEqual(session.tabs.prefix(2).map(\.id), ids)
    }

    // MARK: - Reopen-restore placement

    //
    // The same `at:` policy on the OTHER path that inserts a pre-built tab: ⇧⌘T. There is no way to
    // hand the document a tab it has never seen — a restored tab comes off the closed ring, which is
    // why these go close-then-reopen rather than calling an insert directly.

    func testReopenAfterCurrentPlacesAfterTheActiveTabAndRestoresItsSpec() throws {
        let (ws, ids) = multiTabWorkspace(tabCount: 4, active: 0)
        let closed = try XCTUnwrap(ws.activeSession?.tabs[3])
        let title = try XCTUnwrap(closed.root.allPaneIDs().first)
        let ringed = TreeIntent.closeTab(closed.id, in: WorkspaceTopology(tree: ws))
        XCTAssertEqual(ringed.closedTabRing, [closed.id], "the closed tab is on the ring to be restored")

        let next = TreeIntent.reopenClosedTab(0, at: .afterCurrent, in: ringed)
        let session = try activeSession(next.tree)

        XCTAssertEqual(session.tabs.count, 4)
        XCTAssertEqual(session.activeTabIndex, 1, "restored tab lands after the active (index 0) tab")
        XCTAssertEqual(session.tabs[1].id, closed.id, "the pre-built tab id is preserved")
        XCTAssertEqual(session.tabs[3].id, ids[2], "trailing tabs shift down")
        XCTAssertNotNil(next.tree.spec(for: title), "the restored spec is merged back in")
        XCTAssertTrue(next.tree.isInvariantHeld(), "specs == leafIDs holds for the restored leaves")
    }

    func testReopenEndAppends() throws {
        let (ws, _) = multiTabWorkspace(tabCount: 3, active: 1)
        let closed = try XCTUnwrap(ws.activeSession?.tabs[2])
        let ringed = TreeIntent.closeTab(closed.id, in: WorkspaceTopology(tree: ws))

        let next = TreeIntent.reopenClosedTab(0, at: .end, in: ringed)
        let session = try activeSession(next.tree)
        XCTAssertEqual(session.activeTabIndex, 2)
        XCTAssertEqual(session.tabs[2].id, closed.id)
        XCTAssertTrue(next.tree.isInvariantHeld())
    }

    // MARK: - SettingsKey + Defaults bridge

    func testNewTabPositionWireKeyAndDefault() {
        XCTAssertEqual(SettingsKey.newTabPositionKey, "shell.newTabPosition")
        XCTAssertEqual(SettingsKey.newTabPosition, .auto, "default is auto (= append)")
    }

    func testNewTabPositionDefaultsBridgeRoundTrips() {
        SettingsKey.store.set(NewTabPosition.afterCurrent.rawValue, forKey: SettingsKey.newTabPositionKey)
        XCTAssertEqual(SettingsKey.newTabPosition, .afterCurrent)
        SettingsKey.store.set(NewTabPosition.end.rawValue, forKey: SettingsKey.newTabPositionKey)
        XCTAssertEqual(SettingsKey.newTabPosition, .end)
        // A stale / invalid raw value falls back to the key default (.auto) via the RawRepresentableBridge.
        SettingsKey.store.set("garbage", forKey: SettingsKey.newTabPositionKey)
        XCTAssertEqual(SettingsKey.newTabPosition, .auto, "invalid raw value falls back to auto")
    }

    /// The raw values are the `new-tab-position` config strings — pinned so a rename can't split-brain
    /// the persisted setting from the value a future Shell-settings row writes.
    func testRawValuesMatchSlateConfig() {
        XCTAssertEqual(NewTabPosition.auto.rawValue, "auto")
        XCTAssertEqual(NewTabPosition.end.rawValue, "end")
        XCTAssertEqual(NewTabPosition.afterCurrent.rawValue, "after-current")
        XCTAssertEqual(Set(NewTabPosition.allCases.map(\.rawValue)), ["auto", "end", "after-current"])
    }
}
