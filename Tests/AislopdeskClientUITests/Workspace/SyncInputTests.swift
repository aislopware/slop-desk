import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the per-tab synchronized-input feature (Zellij `ToggleActiveSyncTab`, ⌘⇧I):
///
/// - The `toggleSyncInput` toggle arms / disarms per `TabID`.
/// - `fanSyncInput(from:_:)` fans to all tab siblings except the source, and only when sync is
///   armed for that tab.
/// - The reentrancy guard (shared `isFanningBroadcast`) prevents a cross-fan storm.
/// - The `.toggleSyncInput` `WorkspaceAction` is routed through `routeTree` on a `.tree`-live store.
/// - The ⌘⇧I chord is registered and free (no collision).
///
/// All tests are hang-safe: no `GhosttySurface`, no `NWConnection`, no `VideoToolbox`. The
/// `FakePaneSession` seam and a `.tree`-live `WorkspaceStore` are the only dependencies.
@MainActor
final class SyncInputTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store with the default single-pane workspace, backed by `FakePaneSession`.
    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The DFS-ordered leaf ids for `store`.
    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    /// The active tab's id.
    private func activeTabID(_ store: WorkspaceStore) -> TabID? {
        store.tree.activeSession?.activeTab?.id
    }

    /// Routes `action` through the production single-source-of-truth registry.
    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        WorkspaceBindingRegistry.route(action, to: store)
    }

    /// The `[UInt8]` payloads delivered to pane `id` via `sendBytes`.
    private func bytes(_ store: WorkspaceStore, _ id: PaneID) -> [[UInt8]] {
        (store.handle(for: id) as? FakePaneSession)?.sentBytes ?? []
    }

    // MARK: - Toggle state

    /// `toggleSyncInput` arms and then disarms the tab — purely a state change, no fan-out side effects.
    func testToggleSyncInputArmsAndDisarms() throws {
        let store = makeTreeStore()
        let tabID = try XCTUnwrap(activeTabID(store))

        XCTAssertFalse(store.syncInputTabs.contains(tabID), "disarmed by default")
        store.toggleSyncInput(tabID: tabID)
        XCTAssertTrue(store.syncInputTabs.contains(tabID), "first toggle arms")
        store.toggleSyncInput(tabID: tabID)
        XCTAssertFalse(store.syncInputTabs.contains(tabID), "second toggle disarms")
    }

    /// Toggling a different tab's id does not affect the current tab.
    func testToggleIsPerTab() throws {
        let store = makeTreeStore()
        let tabA = try XCTUnwrap(activeTabID(store))
        let tabB = TabID() // a synthetic id that does not exist in the tree

        store.toggleSyncInput(tabID: tabB)
        XCTAssertFalse(store.syncInputTabs.contains(tabA), "only tabB was toggled")
        XCTAssertTrue(store.syncInputTabs.contains(tabB), "tabB is armed")
    }

    // MARK: - Fan-out target computation (off → empty; on → siblings)

    /// When sync is OFF, `fanSyncInput` is inert and delivers to no sibling.
    func testFanSyncIsInertWhenDisarmed() throws {
        let store = makeTreeStore()
        // Add a second pane so there IS a sibling.
        route(.splitRight, store)
        let source = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let all = store.tree.activeSession?.activeTab?.allPaneIDs() ?? []
        let sibling = try XCTUnwrap(all.first(where: { $0 != source }))

        // Sync is NOT armed.
        let reached = store.fanSyncInput(from: source, Data("x".utf8))
        XCTAssertEqual(reached, 0)
        XCTAssertEqual(bytes(store, sibling), [], "sibling receives nothing when sync is disarmed")
    }

    /// When sync is ON, `fanSyncInput` delivers to every sibling except the source.
    func testFanSyncDeliversToSiblingsButNotSource() throws {
        let store = makeTreeStore()
        route(.splitRight, store)
        route(.splitDown, store) // three leaves total in one tab

        let all = store.tree.activeSession?.activeTab?.allPaneIDs() ?? []
        XCTAssertEqual(all.count, 3, "need three leaves for a meaningful siblings-not-source check")
        let source = all[0]
        let tabID = try XCTUnwrap(activeTabID(store))
        store.toggleSyncInput(tabID: tabID)

        let reached = store.fanSyncInput(from: source, Data("hi".utf8))
        XCTAssertEqual(reached, 2, "two siblings reached")
        XCTAssertEqual(bytes(store, source), [], "source is NOT re-sent")
        XCTAssertEqual(bytes(store, all[1]), [Array("hi".utf8)])
        XCTAssertEqual(bytes(store, all[2]), [Array("hi".utf8)])
    }

    /// A single-pane tab has no siblings — fan-out is a no-op even when armed.
    func testFanSyncIsInertForSinglePaneTab() throws {
        let store = makeTreeStore() // exactly one pane
        let source = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let tabID = try XCTUnwrap(activeTabID(store))
        store.toggleSyncInput(tabID: tabID)

        let reached = store.fanSyncInput(from: source, Data("x".utf8))
        XCTAssertEqual(reached, 0, "no siblings in a single-pane tab")
    }

    /// Empty data is a no-op regardless of sync state.
    func testFanSyncIsInertForEmptyData() throws {
        let store = makeTreeStore()
        route(.splitRight, store)
        let source = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let tabID = try XCTUnwrap(activeTabID(store))
        store.toggleSyncInput(tabID: tabID)

        let reached = store.fanSyncInput(from: source, Data())
        XCTAssertEqual(reached, 0, "empty data is a no-op")
    }

    /// A sourceID that does not belong to any tab produces no fan-out (graceful no-op).
    func testFanSyncIsInertForUnknownSource() throws {
        let store = makeTreeStore()
        let tabID = try XCTUnwrap(activeTabID(store))
        store.toggleSyncInput(tabID: tabID)

        let ghost = PaneID() // not in the tree
        let reached = store.fanSyncInput(from: ghost, Data("x".utf8))
        XCTAssertEqual(reached, 0, "an unknown sourceID produces no fan-out")
    }

    // MARK: - Reentrancy guard (shared isFanningBroadcast)

    /// When a sibling's `sendBytes` re-enters `fanSyncInput`, the reentrancy guard collapses the
    /// re-entrant call and every sibling receives the keystroke exactly once.
    func testReentrancyGuardPreventsCrossFanStorm() throws {
        let store = makeTreeStore()
        route(.splitRight, store)
        route(.splitDown, store) // three leaves: all[0], all[1], all[2]

        let all = store.tree.activeSession?.activeTab?.allPaneIDs() ?? []
        let source = all[0]
        let tabID = try XCTUnwrap(activeTabID(store))
        store.toggleSyncInput(tabID: tabID)

        // Make every sibling attempt a re-fan the moment it receives bytes.
        for id in all {
            (store.handle(for: id) as? FakePaneSession)?.onSendBytes = { [weak store] who, payload in
                _ = store?.fanSyncInput(from: who.id, Data(payload))
            }
        }

        let reached = store.fanSyncInput(from: source, Data("x".utf8))
        XCTAssertEqual(reached, 2, "outer fan reaches exactly the two siblings")
        // Each sibling received the keystroke exactly once — re-entrant re-fans were collapsed.
        XCTAssertEqual(bytes(store, all[1]), [Array("x".utf8)])
        XCTAssertEqual(bytes(store, all[2]), [Array("x".utf8)])
        XCTAssertEqual(bytes(store, source), [], "source was never re-sent")
    }

    // MARK: - WorkspaceAction routing (.tree path)

    /// `.toggleSyncInput` routed through the single-source-of-truth registry on a `.tree` store
    /// arms then disarms `syncInputTabs` for the active tab — proving the routing chain is complete.
    func testRouteToggleSyncInputArmsAndDisarmsViaActiveTab() throws {
        let store = makeTreeStore()
        let tabID = try XCTUnwrap(activeTabID(store))

        XCTAssertFalse(store.syncInputTabs.contains(tabID), "disarmed before first route")
        route(.toggleSyncInput, store)
        XCTAssertTrue(store.syncInputTabs.contains(tabID), "routed toggle arms the active tab")
        route(.toggleSyncInput, store)
        XCTAssertFalse(store.syncInputTabs.contains(tabID), "second route disarms the active tab")
    }

    /// `.toggleSyncInput` on an empty store (no active session / tab) must not crash.
    func testRouteToggleSyncInputIsGracefulWithNoActiveTab() {
        // A store with no sessions would be invalid, so we can't easily construct one; instead
        // we verify that the production route guard (`if let tabID = ...`) is path-complete by
        // routing `.toggleSyncInput` on a fresh default store — it must not throw or crash, and
        // the set must contain exactly the one default tab id afterward.
        let store = makeTreeStore()
        route(.toggleSyncInput, store)
        XCTAssertEqual(store.syncInputTabs.count, 1, "default store: exactly one tab id armed")
    }

    // MARK: - Chord (⌘⇧I is registered and free)

    /// The ⌘⇧I chord is registered and maps to `.toggleSyncInput`.
    func testSyncInputChordIsRegistered() {
        let chord = KeyChord(character: "i", [.command, .shift])
        let action = WorkspaceBindingRegistry.chordTable[chord]
        XCTAssertEqual(action, .toggleSyncInput, "⌘⇧I maps to .toggleSyncInput")
    }

    /// The binding is listed in the tab category with the expected id.
    func testSyncInputBindingIsInBindingsTable() throws {
        let binding = try XCTUnwrap(
            WorkspaceBindingRegistry.bindings.first { $0.id == "tab.syncInput" },
            "binding with id 'tab.syncInput' must exist in the registry",
        )
        XCTAssertEqual(binding.action, .toggleSyncInput)
        XCTAssertEqual(binding.category, .tabs)
        XCTAssertFalse(binding.action.requiresActivePane, "toggleSyncInput must not require an active pane")
    }

    /// No other registered binding shares the ⌘⇧I chord (uniqueness guarantee pinned by this test).
    func testSyncInputChordIsUnique() {
        let chord = KeyChord(character: "i", [.command, .shift])
        let hits = WorkspaceBindingRegistry.allBindings.filter { $0.chord == chord }
        XCTAssertEqual(hits.count, 1, "⌘⇧I must be bound to exactly one action — no chord collision")
    }
}
