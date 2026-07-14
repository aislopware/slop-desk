import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the fix ensuring the LIVE tree-shell features — which had been silently routing to the
/// retained-but-dead canvas (a guarded-no-op `reconcile()` under `.tree`) — now act on the TREE. Each test
/// below fails against the regressed code (the canvas path early-returns for a tree id, so the feature
/// becomes a no-op): busy-pane close + confirm, system-dialog auto-panes + app-launch presets, chrome-close
/// busy guard, ⌘⇧R tab rename, plus the parking-branch and live init-branch coverage.
///
/// Built on the spec-only `FakePaneSession` seam with `liveModel: .tree` so init reconciles the TREE — no
/// SwiftUI view, no real client/host (the hang-safety rule).
@MainActor
final class WorkspaceStoreTreeHardeningTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func fake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    private func dialogLeaves(_ store: WorkspaceStore) -> [PaneID] {
        // The Stage re-scope: a system dialog is a STAGE pane (the tree is terminal-only).
        store.tree.allStagePaneIDs().filter { store.tree.spec(for: $0)?.kind == .systemDialog }
    }

    // MARK: - Busy-pane close + confirm closes the TREE leaf (was a no-op on .tree)

    /// Parking a busy close on a tree leaf then CONFIRMING must close that leaf + tear its handle down.
    /// A regression here routes back through the canvas `closePane(id)`, which `guard`s on
    /// `workspace.canvas.contains(id)` → early-returns for a tree id, leaving the pane stuck registered.
    func testConfirmBusyCloseClosesTreeLeafAndTearsDown() async throws {
        let store = makeTreeStore()
        // Two leaves in one tab so closing one is a clean leaf-close (not a last-pane re-seed).
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let target = try XCTUnwrap(activePane(store))
        let targetFake = try XCTUnwrap(fake(store, target))
        targetFake.isShellBusy = true

        // Park the busy close via the active-pane request (mid-command ⌘W).
        store.requestCloseActivePaneTree()
        XCTAssertEqual(store.pendingClose, target, "a busy close PARKS rather than closing")
        XCTAssertNotNil(store.handle(for: target), "still registered while parked")

        // Confirm — the parked tree leaf must actually close now.
        store.confirmPendingClose()
        XCTAssertNil(store.pendingClose, "the confirmation is consumed")
        XCTAssertNil(store.handle(for: target), "the confirmed tree leaf is removed from the registry")
        XCTAssertFalse(store.tree.contains(target), "the leaf is gone from the tree")
        await store.quiesce()
        XCTAssertEqual(targetFake.teardownCount, 1, "the closed tree leaf was torn down exactly once")
    }

    /// `pendingCloseSpec` resolves from the TREE under `.tree` so the confirmation dialog can name the leaf.
    /// A regression here has the view read `workspace.canvas.spec(for:)` → nil for a tree id → a generic "Close Pane?".
    func testPendingCloseSpecResolvesFromTree() throws {
        let store = makeTreeStore()
        store.splitActivePane(axis: .horizontal, kind: .remoteGUI)
        let target = try XCTUnwrap(activePane(store))
        fake(store, target)?.isShellBusy = true
        store.requestCloseActivePaneTree()

        let spec = try XCTUnwrap(store.pendingCloseSpec, "the pending-close spec is resolved from the tree")
        XCTAssertEqual(spec.kind, .remoteGUI, "the spec is the parked TREE leaf's, not a canvas fallback")
    }

    // MARK: - requestCloseActivePaneTree PARKS (not closes) a busy pane

    /// An idle active pane closes immediately; a mid-command one PARKS. Pins both branches of the
    /// busy-shell guard so the parking path the confirm test above exercises is asserted independently.
    func testRequestCloseActivePaneTreeParksWhenBusyClosesWhenIdle() throws {
        let store = makeTreeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)

        // Busy → parks.
        let busy = try XCTUnwrap(activePane(store))
        fake(store, busy)?.isShellBusy = true
        store.requestCloseActivePaneTree()
        XCTAssertEqual(store.pendingClose, busy, "a busy active pane parks")
        XCTAssertTrue(store.tree.contains(busy), "and is NOT closed yet")

        // Cancel, mark idle, request again → closes immediately.
        store.cancelPendingClose()
        fake(store, busy)?.isShellBusy = false
        store.requestCloseActivePaneTree()
        XCTAssertNil(store.pendingClose, "an idle active pane does not park")
        XCTAssertFalse(store.tree.contains(busy), "an idle active pane closes immediately")
    }

    // MARK: - Chrome-style busy guard parks (requestClosePaneTree)

    /// `requestClosePaneTree(_:)` (the chrome close button's route) PARKS a busy-shell leaf instead of
    /// closing it raw. A regression here has the chrome call `closePaneTree` directly, skipping the guard.
    func testRequestClosePaneTreeParksBusyLeaf() throws {
        let store = makeTreeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let leaf = try XCTUnwrap(activePane(store))
        let leafFake = try XCTUnwrap(fake(store, leaf))
        leafFake.isShellBusy = true

        store.requestClosePaneTree(leaf)

        XCTAssertEqual(store.pendingClose, leaf, "the chrome-route close PARKS the busy leaf")
        XCTAssertTrue(store.tree.contains(leaf), "the busy leaf is not closed immediately")
        XCTAssertEqual(leafFake.teardownCount, 0, "nothing torn down while parked")
    }

    /// An idle leaf through the same route closes immediately (no spurious park).
    func testRequestClosePaneTreeClosesIdleLeaf() throws {
        let store = makeTreeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let leaf = try XCTUnwrap(activePane(store))
        store.requestClosePaneTree(leaf) // idle by default

        XCTAssertNil(store.pendingClose, "no park for an idle leaf")
        XCTAssertFalse(store.tree.contains(leaf), "the idle leaf closed immediately")
    }

    // MARK: - System-dialog auto-pane materializes IN THE STAGE (the Stage re-scope)

    /// `addSystemDialogPane(...)` on a `.tree` store inserts an ephemeral `.systemDialog` pane into the
    /// active session's STAGE (selected — a surfacing SecurityAgent prompt demands attention) + the
    /// registry. The split tree stays terminal-only.
    func testSystemDialogPaneMaterializesInStage() {
        let store = makeTreeStore()
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        XCTAssertTrue(dialogLeaves(store).isEmpty, "no dialog pane initially")

        let id = store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "sudo", isSecure: true)

        XCTAssertTrue(store.stagePaneIDs.contains(id), "the dialog pane is in the STAGE")
        XCTAssertFalse(store.tree.contains(id), "never a split-tree leaf — the tree is terminal-only")
        XCTAssertEqual(store.tree.spec(for: id)?.kind, .systemDialog, "it is an ephemeral system-dialog pane")
        XCTAssertEqual(store.tree.spec(for: id)?.video?.windowID, 1966, "it streams the dialog's host windowID")
        XCTAssertEqual(store.activeStagePaneID, id, "the surfacing prompt's tab is selected")
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore, "the tree's tab strip is untouched")
        XCTAssertNotNil(store.handle(for: id) as? FakePaneSession, "and is materialized in the registry")
    }

    /// `closeSystemDialogPane(_:)` removes a stage dialog pane (the dialog-gone path), and the liveness
    /// probe `isSystemDialogPaneLive(_:)` reflects the stage.
    func testSystemDialogPaneRemovedFromStage() {
        let store = makeTreeStore()
        let id = store.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "", isSecure: false)
        XCTAssertTrue(store.isSystemDialogPaneLive(id), "live after spawn")

        store.closeSystemDialogPane(id)

        XCTAssertFalse(store.stagePaneIDs.contains(id), "the dialog pane is gone from the stage")
        XCTAssertFalse(store.isSystemDialogPaneLive(id), "and the liveness probe reflects it")
        XCTAssertTrue(dialogLeaves(store).isEmpty, "no system-dialog panes remain")
    }

    /// END-TO-END via the actual `SystemDialogMonitor` diff (the production caller): a dialog appearing →
    /// a stage pane materialized; the dialog leaving → it is removed.
    func testSystemDialogMonitorDrivesTheTreeShell() {
        let store = makeTreeStore()
        let monitor = SystemDialogMonitor(store: store, isConnected: { true }, target: { .default })

        monitor.reconcileForTesting([
            SystemDialogInfo(
                windowID: 1,
                owner: "SecurityAgent",
                title: "sudo",
                width: 400,
                height: 200,
                isSecure: true,
            ),
        ])
        XCTAssertEqual(dialogLeaves(store).count, 1, "a present dialog materialized a stage pane")

        monitor.reconcileForTesting([]) // dialog gone host-side
        XCTAssertEqual(dialogLeaves(store).count, 0, "the stage pane was removed when the dialog left")
    }

    /// AppLaunchMonitor side: `liveLayoutPresets` resolves from the TREE under `.tree`, and
    /// `presetForLaunchedApp` matches against it — so a tree-carried trigger preset is reachable while a
    /// canvas one is dead. A regression here has the monitor read `workspace.layoutPresets` (the dead canvas's, empty).
    func testLiveLayoutPresetsResolveFromTree() {
        var tree = TreeWorkspace.defaultWorkspace()
        tree.layoutPresets = [LayoutPreset(
            name: "monitoring",
            canvas: Canvas(items: []),
            groups: [],
            focusedPane: nil,
            triggerAppName: "Grafana",
        )]
        let store = makeTreeStore(restoringTree: tree)

        XCTAssertEqual(store.liveLayoutPresets.map(\.name), ["monitoring"], "live presets come from the tree")
        XCTAssertEqual(store.presetForLaunchedApp("grafana")?.name, "monitoring", "the trigger matches the tree preset")
        XCTAssertNil(store.presetForLaunchedApp("nope"), "no spurious match")
    }

    // MARK: - ⌘⇧R renames the active TAB (was a dead-end on .tree)

    /// Routing `.renamePane` on a `.tree` store records the active TAB as the pending rename target (the
    /// `TabBarView` inline field opens) — NOT `pendingRename` (the canvas pane rename, which no tree view
    /// observes). A regression here sets `pendingRename` to a PaneID that nothing on the tree shell consumes.
    func testRenameActionTargetsActiveTabOnTree() throws {
        let store = makeTreeStore()
        let activeTab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let treeBefore = store.tree

        WorkspaceBindingRegistry.route(.renamePane, to: store)

        XCTAssertEqual(store.pendingTabRename, activeTab, "the active tab is the pending tab-rename target")
        XCTAssertNil(store.pendingRename, "the dead canvas pane-rename request is NOT set on the tree shell")
        XCTAssertEqual(store.tree, treeBefore, "the rename request never mutates the tree")
    }

    /// `clearTabRenameRequest()` consumes the pending tab-rename (the strip opened its field).
    func testClearTabRenameRequestConsumesIt() {
        let store = makeTreeStore()
        store.requestRenameActivePane()
        XCTAssertNotNil(store.pendingTabRename)
        store.clearTabRenameRequest()
        XCTAssertNil(store.pendingTabRename, "the request is consumed")
    }

    // MARK: - One default-session-name source

    /// The store's `defaultSessionName` is the single source every session-minting path (agent control
    /// backend, session templates) names through — "Session N", N one past the count.
    func testDefaultSessionNameIsSessionN() {
        let store = makeTreeStore()
        XCTAssertEqual(store.defaultSessionName, "Session 2", "one session ⇒ next is Session 2")
        store.newSession(name: store.defaultSessionName, kind: .terminal)
        XCTAssertEqual(store.defaultSessionName, "Session 3", "two sessions ⇒ next is Session 3")
    }

    // MARK: - The live tree branches of bootstrap + commitConnectionTarget

    /// `bootstrapFromEnvironment(.tree)` reshapes the TREE from the autoconnect env (one session/tab/leaf
    /// carrying the spec + the per-session connection) and materializes it — not the canvas.
    func testBootstrapFromEnvironmentTreeBranch() throws {
        let store = makeTreeStore()
        store.bootstrapFromEnvironment([
            "SLOPDESK_AUTOCONNECT_HOST": "10.0.0.5",
            "SLOPDESK_AUTOCONNECT_PORT": "7420",
        ])

        XCTAssertEqual(store.tree.sessions.count, 1, "one bootstrap session")
        let leaves = store.tree.allPaneIDs()
        XCTAssertEqual(leaves.count, 1, "one bootstrap leaf")
        let leaf = try XCTUnwrap(leaves.first)
        XCTAssertEqual(store.tree.spec(for: leaf)?.kind, .terminal, "a terminal bootstrap pane")
        XCTAssertEqual(store.tree.activeSession?.connection?.host, "10.0.0.5", "the per-session connection is stamped")
        XCTAssertNotNil(store.handle(for: leaf) as? FakePaneSession, "init reconciled the bootstrapped tree")
    }

    /// `commitConnectionTarget(.tree)` stamps the target onto the ACTIVE SESSION (the gate-prefill source),
    /// not the dead canvas `workspace.connection`.
    func testCommitConnectionTargetTreeBranch() {
        let store = makeTreeStore()
        let target = ConnectionTarget(host: "192.168.1.9", port: 7777)
        store.commitConnectionTarget(target)

        XCTAssertEqual(store.tree.activeSession?.connection, target, "the active session carries the committed target")
        // It is a no-op if already equal (no churn).
        let sessionsBefore = store.tree.sessions
        store.commitConnectionTarget(target)
        XCTAssertEqual(store.tree.sessions, sessionsBefore, "an identical re-commit is a no-op")
    }
}
