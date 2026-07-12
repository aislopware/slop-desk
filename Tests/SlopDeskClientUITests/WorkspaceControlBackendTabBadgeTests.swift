// WorkspaceControlBackendTabBadgeTests — pins the `tab badge --kind` write path on the REAL
// `WorkspaceControlBackend` (not the dispatcher's FAKE backend, whose `recordedBadgeKind` masks this gap).
// The pre-fix backend dropped `kind` entirely and only checked the tab existed, so `setTabBadge` reported
// success while no badge was ever set; each assertion below fails on that pre-fix backend (the override is
// never written), so none is tautological.
//
// Hang-safe (CLAUDE.md rule #6): a tree-model store over the `MountTestPaneSession` fake, an isolated
// `PreferencesStore` + a temp-file `FolderFrecencyStore` — no socket, no GUI, no video/SCStream/Metal.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class WorkspaceControlBackendTabBadgeTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    private func makeBackend(_ store: WorkspaceStore, _ name: String = #function) -> WorkspaceControlBackend {
        let suite = "WorkspaceControlBackendTabBadgeTests." + name
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        let folders = FolderFrecencyStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("frecency-\(UUID().uuidString).json"),
        )
        return WorkspaceControlBackend(store: store, preferences: prefs, folders: folders)
    }

    /// `tab badge --kind` with NO tab id targets the FOCUSED tab and WRITES the per-tab override the rail +
    /// `tab list` read — not merely a `true` return. Pre-fix this fails (the backend discarded `kind`).
    func testSetTabBadgeWritesFocusedTabOverride() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)

        XCTAssertTrue(backend.setTabBadge(tabId: nil, kind: .error), "the focused tab resolves")
        XCTAssertEqual(
            store.tabBadgeOverride(for: focused), .error,
            "setTabBadge writes the store-side override, not a silent no-op",
        )
    }

    /// An EXPLICIT `--tab <id>` targets THAT tab (even when it is not focused) and leaves the focused tab
    /// untouched — proving `kind` lands on the resolved tab, not the active one.
    func testSetTabBadgeWritesExplicitTabOverride() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let firstTab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        store.newTab(kind: .terminal, launchGrace: .zero) // a 2nd, now-focused tab
        let secondTab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        XCTAssertNotEqual(firstTab, secondTab)

        XCTAssertTrue(backend.setTabBadge(tabId: firstTab.raw.uuidString, kind: .running))
        XCTAssertEqual(store.tabBadgeOverride(for: firstTab), .running, "the targeted (unfocused) tab is badged")
        XCTAssertNil(store.tabBadgeOverride(for: secondTab), "the focused tab is untouched")
    }

    /// An UNKNOWN tab id resolves to nothing → `false` (the dispatcher turns this into `tab not found`) and
    /// writes NO override. An honest failure, never a lying success for a no-op.
    func testSetTabBadgeUnknownTabReturnsFalseAndWritesNothing() {
        let store = makeStore()
        let backend = makeBackend(store)
        XCTAssertFalse(backend.setTabBadge(tabId: UUID().uuidString, kind: .error), "unknown tab → not found")
        XCTAssertTrue(store.tabBadgeOverrides.isEmpty, "no override is written for a missing tab")
    }

    /// The written override surfaces in `listTabs` (the `tab list` badge column) as its canonical token,
    /// winning over the derived (all-clear) badge — the end-to-end CLI surface, not just the store dict.
    func testListTabsReportsTheManualBadge() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        XCTAssertNil(backend.listTabs(windowId: nil).first?.badge, "all-clear before the override")

        XCTAssertTrue(backend.setTabBadge(tabId: nil, kind: .awaitingInput))
        let tab = try XCTUnwrap(backend.listTabs(windowId: nil).first { $0.id == focused.raw.uuidString })
        XCTAssertEqual(tab.badge, "awaiting-input", "tab list reports the manual badge token")
    }
}
