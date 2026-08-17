import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the command-palette recents ring on the store: it holds palette CATALOG IDs, fronts a repeat
/// rather than duplicating it, and caps at ``WorkspaceStore/recentCommandsCap``.
@MainActor
final class PaletteRecentsTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
    }

    func testRecordPrependsDedupsAndCaps() {
        let store = makeStore()
        store.recordRecentCommand("action.closePane")
        store.recordRecentCommand("action.toggleZoom")
        XCTAssertEqual(store.recentCommands, ["action.toggleZoom", "action.closePane"], "newest first")

        store.recordRecentCommand("action.closePane")
        XCTAssertEqual(store.recentCommands, ["action.closePane", "action.toggleZoom"], "a repeat moves to front")

        let many = [
            "action.newTerminalTab",
            "action.newDesktopTab",
            "action.reconnect",
            "action.renamePane",
            "action.splitRight",
            "action.splitDown",
        ]
        for id in many { store.recordRecentCommand(id) }
        XCTAssertEqual(store.recentCommands.count, WorkspaceStore.recentCommandsCap, "the ring is capped")
        XCTAssertEqual(store.recentCommands.first, "action.splitDown", "newest first after the cap trims")
        XCTAssertFalse(
            store.recentCommands.contains("action.closePane"),
            "the oldest entries fall off the end rather than the newest being refused",
        )
    }
}
