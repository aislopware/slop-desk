import XCTest
@testable import AislopdeskClientUI

/// Pins the command-palette recents ring on the store (dedup-to-front, capped).
@MainActor
final class PaletteRecentsTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) })
    }

    func testRecordPrependsDedupsAndCaps() {
        let store = makeStore()
        store.recordRecentCommand(.tidy)
        store.recordRecentCommand(.centerAll)
        XCTAssertEqual(store.recentCommands, [.centerAll, .tidy])
        store.recordRecentCommand(.tidy)
        XCTAssertEqual(store.recentCommands, [.tidy, .centerAll], "a repeat moves to front")

        let many: [WorkspaceCommand] = [
            .newGroup,
            .toggleZoom,
            .toggleOverview,
            .reopenClosedPane,
            .duplicatePane,
            .centerFocusedPane,
        ]
        for c in many { store.recordRecentCommand(c) }
        XCTAssertEqual(store.recentCommands.count, WorkspaceStore.recentCommandsCap)
        XCTAssertEqual(store.recentCommands.first, .centerFocusedPane, "newest first")
    }

    /// The menu-bar action verbs (Group Selected Panes, Arrange align/distribute, Save Current Layout)
    /// must route through `apply(_:to:)` so they populate the recents ring — they used to call the store
    /// directly, bypassing the one chokepoint where recents are recorded.
    func testMenuActionVerbsRoutedThroughApplyPopulateRecents() {
        let store = makeStore()
        apply(.groupSelection, to: store)
        apply(.align(.left), to: store)
        apply(.distribute(horizontal: true), to: store)
        apply(.saveLayout, to: store)
        XCTAssertTrue(store.recentCommands.contains(.groupSelection), "Group Selected Panes is a recent")
        XCTAssertTrue(store.recentCommands.contains(.align(.left)), "Align is a recent")
        XCTAssertTrue(store.recentCommands.contains(.distribute(horizontal: true)), "Distribute is a recent")
        XCTAssertTrue(store.recentCommands.contains(.saveLayout), "Save Current Layout is a recent")
    }

    /// ⌘N (.newPaneDefault) opens a pane of the user's default kind, but the palette catalog has no
    /// .newPaneDefault entry — recording it verbatim silently dropped it from the recents block AND wasted
    /// a ring slot. apply() must record the RESOLVED .newPane(kind) so it resolves in the catalog and names
    /// what was actually created.
    func testNewPaneDefaultRecordsResolvedKindNotTheUnshowableDefault() {
        let store = makeStore()
        apply(.newPaneDefault, to: store)
        XCTAssertFalse(
            store.recentCommands.contains(.newPaneDefault),
            ".newPaneDefault is never recorded verbatim (no catalog entry → would vanish + waste a slot)",
        )
        XCTAssertEqual(
            store.recentCommands.first,
            .newPane(SettingsKey.defaultPaneKind),
            "the resolved default kind is recorded so the recent resolves in the catalog",
        )
    }

    /// The negative control that proves the routing matters: calling the store methods DIRECTLY (the old
    /// menu wiring) records nothing — recents live only at the `apply()` chokepoint.
    func testDirectStoreCallsBypassRecents() {
        let store = makeStore()
        _ = store.groupSelection()
        store.alignPanes(to: .left)
        store.distributePanes(horizontal: true)
        store.requestSaveLayout()
        XCTAssertTrue(
            store.recentCommands.isEmpty,
            "bypassing apply() must not record recents — that is the bug this routing fixes",
        )
    }
}
