import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The store-side launch-preset apply + CRUD (docs/42 W14 #9): applying a preset opens a new tab whose
/// pane(s) materialize through the `FakePaneSession` factory; CRUD mutates `tree.launchPresets`. Drives a
/// LIVE `.tree` store. The keystroke EXPANSION is unit-tested in `LaunchPresetEngineTests`; here we pin
/// that the panes are created + materialized and the CRUD round-trips.
@MainActor
final class LaunchPresetStoreTests: XCTestCase {
    private func treeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: TreeWorkspace.defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            persistence: nil,
        )
    }

    // MARK: Defaults seeded

    func testDefaultWorkspaceSeedsBuiltInLaunchPresets() {
        let store = treeStore()
        XCTAssertEqual(store.launchPresets.map(\.name), ["Claude Code", "htop", "Git log"])
    }

    // MARK: Apply

    func testApplySinglePanePresetOpensTabAndMaterializesPane() {
        let store = treeStore()
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let preset = LaunchPreset(name: "htop", command: "htop")
        let ids = store.applyLaunchPreset(preset)
        XCTAssertEqual(ids.count, 1)
        // A new tab was added and selected.
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore + 1)
        // The created pane is live in the registry (materialized via adopt).
        XCTAssertNotNil(store.handle(for: ids[0]))
        XCTAssertEqual((store.handle(for: ids[0]) as? FakePaneSession)?.events.first, .adopt(ids[0]))
        // Its spec carries the preset name as the title.
        XCTAssertEqual(store.tree.spec(for: ids[0])?.title, "htop")
    }

    func testApplySplitPresetCreatesTwoMaterializedPanes() {
        let store = treeStore()
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .",
            split: .init(axis: .horizontal, secondaryCommand: "npm run watch"),
        )
        let ids = store.applyLaunchPreset(preset)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotNil(store.handle(for: ids[0]))
        XCTAssertNotNil(store.handle(for: ids[1]))
        // Both panes live in the SAME (new) tab.
        let owner0 = store.tree.tab(containing: ids[0])?.1
        let owner1 = store.tree.tab(containing: ids[1])?.1
        XCTAssertNotNil(owner0)
        XCTAssertEqual(owner0, owner1)
    }

    func testApplyUnknownIDIsNoOp() {
        let store = treeStore()
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let ids = store.applyLaunchPreset(UUID())
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore)
    }

    func testApplyByIdResolvesABuiltIn() throws {
        let store = treeStore()
        let claude = try XCTUnwrap(LaunchPreset.builtIns.first { $0.name == "Claude Code" })
        let ids = store.applyLaunchPreset(claude.id)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(store.tree.spec(for: ids[0])?.title, "Claude Code")
    }

    // MARK: CRUD

    func testUpsertAddsThenReplaces() {
        let store = treeStore()
        let id = UUID()
        store.upsertLaunchPreset(LaunchPreset(id: id, name: "Mine", command: "ls"))
        XCTAssertEqual(store.launchPresets.first { $0.id == id }?.command, "ls")
        store.upsertLaunchPreset(LaunchPreset(id: id, name: "Mine", command: "ls -la"))
        XCTAssertEqual(store.launchPresets.first { $0.id == id }?.command, "ls -la")
        // Replace, not duplicate.
        XCTAssertEqual(store.launchPresets.count(where: { $0.id == id }), 1)
    }

    func testRemoveDeletesById() throws {
        let store = treeStore()
        let target = try XCTUnwrap(store.launchPresets.first { $0.name == "htop" })
        store.removeLaunchPreset(target.id)
        XCTAssertFalse(store.launchPresets.contains { $0.id == target.id })
    }

    func testResetRestoresBuiltIns() {
        let store = treeStore()
        store.upsertLaunchPreset(LaunchPreset(name: "Mine", command: "x"))
        store.resetLaunchPresetsToBuiltIns()
        XCTAssertEqual(store.launchPresets.map(\.name), ["Claude Code", "htop", "Git log"])
    }
}
