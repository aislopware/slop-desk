import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// E3 WI-4 (ES-E3-4): the PURE close-confirmation policy — the `process` / `always` / `multiple_tabs`
/// truth table and the validate-then-repair `init(rawValue:)`. The store wiring (which policy a scope reads,
/// where the parked confirmation lands) is pinned separately in ``CloseConfirmationStoreTests``; here the
/// decision math is isolated from any store/UI.
final class CloseConfirmationPolicyTests: XCTestCase {
    // MARK: - shouldConfirm truth table (3 policies × {busy, idle} × {1 tab, >1 tab})

    func testProcessConfirmsOnlyWhenBusy() {
        // `.process` → mirrors `isBusy`, regardless of tab count.
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.process, isBusy: true, tabCount: 1))
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.process, isBusy: true, tabCount: 4))
        XCTAssertFalse(CloseConfirmationPolicy.shouldConfirm(.process, isBusy: false, tabCount: 1))
        XCTAssertFalse(CloseConfirmationPolicy.shouldConfirm(.process, isBusy: false, tabCount: 4))
    }

    func testAlwaysConfirmsUnconditionally() {
        // `.always` → true for every busy/tab-count combination.
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.always, isBusy: false, tabCount: 1))
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.always, isBusy: false, tabCount: 7))
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.always, isBusy: true, tabCount: 1))
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.always, isBusy: true, tabCount: 7))
    }

    func testMultipleTabsConfirmsOnlyAboveOneTab() {
        // `.multipleTabs` → keyed purely on `tabCount > 1`, independent of busy.
        XCTAssertFalse(CloseConfirmationPolicy.shouldConfirm(.multipleTabs, isBusy: false, tabCount: 1))
        XCTAssertFalse(CloseConfirmationPolicy.shouldConfirm(.multipleTabs, isBusy: true, tabCount: 1))
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.multipleTabs, isBusy: false, tabCount: 2))
        XCTAssertTrue(CloseConfirmationPolicy.shouldConfirm(.multipleTabs, isBusy: true, tabCount: 9))
        // A degenerate zero-tab count never trips `> 1`.
        XCTAssertFalse(CloseConfirmationPolicy.shouldConfirm(.multipleTabs, isBusy: true, tabCount: 0))
    }

    // MARK: - rawValue (config strings) + validate-then-repair init

    func testRawValuesMatchSlateConfigStrings() {
        XCTAssertEqual(CloseConfirmationPolicy.process.rawValue, "process")
        XCTAssertEqual(CloseConfirmationPolicy.always.rawValue, "always")
        XCTAssertEqual(CloseConfirmationPolicy.multipleTabs.rawValue, "multiple_tabs")
        XCTAssertEqual(CloseConfirmationPolicy.allCases.count, 3)
    }

    func testKnownRawValuesDecode() {
        XCTAssertEqual(CloseConfirmationPolicy(rawValue: "process"), .process)
        XCTAssertEqual(CloseConfirmationPolicy(rawValue: "always"), .always)
        XCTAssertEqual(CloseConfirmationPolicy(rawValue: "multiple_tabs"), .multipleTabs)
    }

    func testUnknownRawValueRepairsToProcess() {
        // Validate-then-repair: a stale / hostile persisted string never traps — it falls back to `.process`.
        XCTAssertEqual(CloseConfirmationPolicy(rawValue: "garbage"), .process)
        XCTAssertEqual(CloseConfirmationPolicy(rawValue: ""), .process)
        XCTAssertEqual(
            CloseConfirmationPolicy(rawValue: "multipleTabs"),
            .process,
            "camelCase ≠ the persisted raw value",
        )
    }
}

/// E3 WI-4 store wiring: ``WorkspaceStore/requestCloseWindow()`` parks ``WorkspaceStore/pendingWindowClose``
/// EXACTLY when the configured ``SettingsKey/closeConfirmWindow`` policy says so (evaluated against the
/// active session's tab count + any busy pane), and the pane-close guards now honour
/// ``SettingsKey/closeConfirmTab``. Drives a LIVE `.tree` store through the `FakePaneSession` seam.
@MainActor
final class CloseConfirmationStoreTests: XCTestCase {
    private let keys = [SettingsKey.closeConfirmTabKey, SettingsKey.closeConfirmWindowKey]

    override func setUp() {
        super.setUp()
        for key in keys { SettingsKey.store.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in keys { SettingsKey.store.removeObject(forKey: key) }
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

    /// A single-session workspace whose active session holds `tabCount` single-pane tabs (each a distinct
    /// terminal leaf). Returns the leaf ids in tab order (`panes[0]` is the active tab's pane).
    private func multiTabWorkspace(tabCount: Int) -> (TreeWorkspace, [PaneID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        var panes: [PaneID] = []
        for i in 0..<tabCount {
            let pane = PaneID()
            panes.append(pane)
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: "T\(i)")
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), panes)
    }

    // MARK: - SettingsKey defaults + wire keys + Defaults round-trip

    func testCloseConfirmDefaultsAndKeyStringsAndRepair() {
        // Unset → default `.process` (the pre-E3 busy-only guard, byte-identical behaviour).
        XCTAssertEqual(SettingsKey.closeConfirmTab, .process)
        XCTAssertEqual(SettingsKey.closeConfirmWindow, .process)
        // The wire key strings are the single source of truth shared with the E7 Settings UI — a rename that
        // split-brained the picker from these fire-sites fails here.
        XCTAssertEqual(SettingsKey.closeConfirmTabKey, "shell.closeConfirm.tab")
        XCTAssertEqual(SettingsKey.closeConfirmWindowKey, "shell.closeConfirm.window")
        // An explicit config value round-trips through Defaults; an invalid stored value repairs.
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmTabKey)
        XCTAssertEqual(SettingsKey.closeConfirmTab, .always)
        SettingsKey.store.set("multiple_tabs", forKey: SettingsKey.closeConfirmWindowKey)
        XCTAssertEqual(SettingsKey.closeConfirmWindow, .multipleTabs)
        SettingsKey.store.set("garbage", forKey: SettingsKey.closeConfirmWindowKey)
        XCTAssertEqual(SettingsKey.closeConfirmWindow, .process, "an invalid stored value repairs to process")
    }

    // MARK: - requestCloseWindow parks per policy (ES-E3-4)

    func testProcessPolicyIdleDoesNotParkWindowClose() {
        SettingsKey.store.set("process", forKey: SettingsKey.closeConfirmWindowKey)
        let (tree, _) = multiTabWorkspace(tabCount: 3)
        let store = makeTreeStore(restoringTree: tree)

        store.requestCloseWindow()

        XCTAssertNil(store.pendingWindowClose, "process + idle → no window-close confirmation")
    }

    func testProcessPolicyBusyPaneAnywhereInSessionParksWindowClose() {
        SettingsKey.store.set("process", forKey: SettingsKey.closeConfirmWindowKey)
        let (tree, panes) = multiTabWorkspace(tabCount: 3)
        let store = makeTreeStore(restoringTree: tree)
        let sessionID = store.tree.activeSession?.id
        // A pane in a NON-active tab is busy — window scope spans the whole session, so it still parks.
        (store.handle(for: panes[2]) as? FakePaneSession)?.isShellBusy = true

        store.requestCloseWindow()

        XCTAssertEqual(store.pendingWindowClose, sessionID, "a busy pane anywhere in the session parks the close")
    }

    func testAlwaysPolicyParksEvenIdleSingleTab() {
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmWindowKey)
        let (tree, _) = multiTabWorkspace(tabCount: 1)
        let store = makeTreeStore(restoringTree: tree)
        let sessionID = store.tree.activeSession?.id

        store.requestCloseWindow()

        XCTAssertEqual(store.pendingWindowClose, sessionID, "always parks regardless of tab count / busy")
    }

    func testMultipleTabsPolicyParksOnlyAboveOneTab() {
        SettingsKey.store.set("multiple_tabs", forKey: SettingsKey.closeConfirmWindowKey)

        // 1 tab → no park (closing a single-tab window loses nothing the policy guards).
        let single = makeTreeStore(restoringTree: multiTabWorkspace(tabCount: 1).0)
        single.requestCloseWindow()
        XCTAssertNil(single.pendingWindowClose, "multiple_tabs + 1 tab → no confirmation")

        // 2 tabs → park.
        let multi = makeTreeStore(restoringTree: multiTabWorkspace(tabCount: 2).0)
        let multiSession = multi.tree.activeSession?.id
        multi.requestCloseWindow()
        XCTAssertEqual(multi.pendingWindowClose, multiSession, "multiple_tabs + >1 tab → confirmation parks")
    }

    // MARK: - confirm / cancel resolve the parked window close

    func testConfirmPendingWindowCloseConsumesThePark() {
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmWindowKey)
        let (tree, _) = multiTabWorkspace(tabCount: 2)
        let store = makeTreeStore(restoringTree: tree)
        store.requestCloseWindow()
        XCTAssertNotNil(store.pendingWindowClose)

        store.confirmPendingWindowClose()

        XCTAssertNil(store.pendingWindowClose, "confirm consumes the parked window close")
    }

    func testCancelPendingWindowCloseClearsWithoutClosing() {
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmWindowKey)
        let (tree, panes) = multiTabWorkspace(tabCount: 2)
        let store = makeTreeStore(restoringTree: tree)
        store.requestCloseWindow()
        XCTAssertNotNil(store.pendingWindowClose)

        store.cancelPendingWindowClose()

        XCTAssertNil(store.pendingWindowClose, "cancel clears the park")
        // The session (its tabs/panes) is untouched by a cancel.
        XCTAssertEqual(Set(store.tree.allPaneIDs()), Set(panes), "cancel leaves the session intact")
    }

    // MARK: - pane-close guard now honours the tab policy (was busy-only)

    func testAlwaysTabPolicyParksAnIdlePaneClose() {
        // PRE-FIX: `requestCloseActivePaneTree` parked ONLY on a busy shell; an idle pane closed immediately.
        // With the tab policy = always, an idle close must now PARK behind `pendingClose`.
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmTabKey)
        let (tree, panes) = multiTabWorkspace(tabCount: 2)
        let store = makeTreeStore(restoringTree: tree)

        store.requestCloseActivePaneTree() // the active pane is idle

        XCTAssertEqual(store.pendingClose, panes[0], "always policy parks even an idle pane close")
        XCTAssertEqual(Set(store.tree.allPaneIDs()), Set(panes), "the parked pane is not yet closed")
    }

    func testDefaultProcessPolicyIdlePaneClosesImmediately() {
        // The default (unset) `.process` policy preserves the pre-E3 behaviour: an idle pane closes without
        // a confirmation (only a busy shell parks).
        let (tree, panes) = multiTabWorkspace(tabCount: 2)
        let store = makeTreeStore(restoringTree: tree)

        store.requestCloseActivePaneTree() // idle

        XCTAssertNil(store.pendingClose, "process + idle → close immediately (no park)")
        XCTAssertEqual(store.tree.allPaneIDs().count, panes.count - 1, "the idle pane was closed")
    }

    // MARK: - pane close gates by the Tab policy ONLY on a CASCADING close (E7 carry-over #8)

    /// A NON-cascading mid-tab pane close (the pane has tiled siblings, so its tab SURVIVES) must fall back to
    /// the `.process` busy-shell guard ALONE — it must NOT inherit the Tab policy. REVERT-TO-CONFIRM-FAIL: the
    /// pre-fix `.pane` arm read `closeConfirmTab` unconditionally, so `.always` returned `true` even for an idle
    /// non-cascading close; with the fix an idle non-cascading pane close needs no confirmation under `.always`.
    func testNonCascadingPaneCloseUsesProcessGuardOnly() throws {
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmTabKey)
        // One tab split into TWO panes, so closing the active pane leaves the tab alive (a non-cascading close).
        let store = makeTreeStore(restoringTree: multiTabWorkspace(tabCount: 1).0)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.allPaneIDs().count, 2, "the tab holds two tiled panes")

        XCTAssertFalse(
            store.closeConfirmationNeeded(scope: .pane, pane: active),
            "an idle non-cascading pane close uses the .process guard ALONE — no confirmation under .always",
        )
    }

    /// A CASCADING pane close (the pane is its tab's SOLE leaf, so closing it drops the whole tab) DOES gate by
    /// the Tab policy — under `.always` an idle sole-leaf pane close confirms. The complement of the
    /// non-cascading case: the cascade branch still honours the configured Tab policy.
    func testCascadingPaneCloseUsesTabPolicy() {
        SettingsKey.store.set("always", forKey: SettingsKey.closeConfirmTabKey)
        // Two single-pane tabs; the active tab's pane is its tab's sole leaf → closing it cascades the tab away.
        let (tree, panes) = multiTabWorkspace(tabCount: 2)
        let store = makeTreeStore(restoringTree: tree)
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.allPaneIDs(), [panes[0]],
            "the active tab's pane is its sole (cascading) leaf",
        )

        XCTAssertTrue(
            store.closeConfirmationNeeded(scope: .pane, pane: panes[0]),
            "a cascading sole-leaf pane close confirms under the .always Tab policy",
        )
    }

    // MARK: - Close Tab (⌘⇧W) confirmation closes the WHOLE tab, not just the active pane

    /// REGRESSION (review finding): a confirmed ``WorkspaceStore/closeActiveTab()`` on a MULTI-PANE tab must
    /// drop the entire tab — both panes — not just one leaf. Fires under the DEFAULT `.process` policy as
    /// soon as a pane in the tab is busy (a split coding tab running a command). PRE-FIX `closeActiveTab`
    /// parked the tab as its active LEAF (`pendingClose`) and `confirmPendingClose` resolved it through
    /// `closePaneTree`, closing ONE pane and leaving the sibling alive (the tab survived).
    func testCloseActiveTabConfirmClosesWholeMultiPaneTab() throws {
        // Two single-pane tabs; the active tab becomes a 2-pane split below so a sibling tab survives the
        // close (a clean "the tab is gone" assertion, no last-tab re-seed).
        let store = makeTreeStore(restoringTree: multiTabWorkspace(tabCount: 2).0)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        let tabID = tab.id
        let panes = tab.allPaneIDs()
        XCTAssertEqual(panes.count, 2, "the active tab now holds two panes")
        // One pane mid-command → default `.process` policy requires a confirmation for the tab close.
        (store.handle(for: panes[0]) as? FakePaneSession)?.isShellBusy = true

        store.closeActiveTab()

        XCTAssertEqual(store.pendingTabCloseID, tabID, "Close Tab parks the whole TAB, not a single leaf")
        XCTAssertNil(store.pendingClose, "a tab close must not masquerade as a single-pane close")
        XCTAssertTrue(
            store.tree.contains(panes[0]) && store.tree.contains(panes[1]),
            "nothing is closed while the confirmation is parked",
        )

        store.confirmPendingClose()

        XCTAssertNil(store.pendingTabCloseID, "the tab-close confirmation is consumed")
        XCTAssertFalse(store.tree.contains(panes[0]), "the first pane of the tab is gone")
        XCTAssertFalse(store.tree.contains(panes[1]), "the sibling pane of the tab is ALSO gone")
        XCTAssertNil(
            store.tree.activeSession?.tabs.first(where: { $0.id == tabID }),
            "the whole tab is closed, not just the active pane",
        )
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "the sibling tab survives")
    }

    /// Cancelling the parked tab close leaves the whole tab (both panes) intact and clears the park.
    func testCancelPendingTabCloseLeavesTabIntact() throws {
        let store = makeTreeStore(restoringTree: multiTabWorkspace(tabCount: 2).0)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        let panes = tab.allPaneIDs()
        (store.handle(for: panes[0]) as? FakePaneSession)?.isShellBusy = true

        store.closeActiveTab()
        XCTAssertNotNil(store.pendingTabCloseID, "the busy tab close parked")

        store.cancelPendingClose()

        XCTAssertNil(store.pendingTabCloseID, "cancel clears the tab-close park")
        XCTAssertTrue(store.tree.contains(panes[0]) && store.tree.contains(panes[1]), "cancel keeps both panes")
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "cancel keeps the tab")
    }

    /// A re-park MUST be mutually exclusive: parking a single-PANE close after a tab close was parked clears
    /// the stale tab park, so confirming closes only the pane (no leaked tab-scope close).
    func testPaneCloseReparkClearsStaleTabClosePark() throws {
        let store = makeTreeStore(restoringTree: multiTabWorkspace(tabCount: 2).0)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab)
        let active = try XCTUnwrap(tab.activePane)
        // The ACTIVE leaf is busy → both the tab close and the subsequent active-pane close park.
        (store.handle(for: active) as? FakePaneSession)?.isShellBusy = true

        store.closeActiveTab() // parks the TAB
        XCTAssertNotNil(store.pendingTabCloseID)

        // Now park a single-pane close — the active leaf is still busy → parks.
        store.requestCloseActivePaneTree()
        XCTAssertNil(store.pendingTabCloseID, "the stale tab park is cleared by a pane re-park")
        XCTAssertEqual(store.pendingClose, active, "the pane close is parked instead")

        store.confirmPendingClose()
        XCTAssertEqual(store.tree.allPaneIDs(filter: tab).count, 1, "only one pane of the tab was closed")
        XCTAssertNotNil(
            store.tree.activeSession?.tabs.first(where: { $0.id == tab.id }),
            "the tab itself survives a single-pane close",
        )
    }
}

private extension TreeWorkspace {
    /// The live pane ids of `tab` still present in this workspace (test helper).
    func allPaneIDs(filter tab: Tab) -> [PaneID] {
        tab.allPaneIDs().filter { contains($0) }
    }
}
