import XCTest
@testable import SlopDeskWorkspaceCore

/// E17 ES-E17-2 / WI-5 — the CONTEXTUAL `⌘/` binding + the ``WorkspaceStore/toggleViKeyHintsInActivePane()``
/// store seam that the vi key-hint bar (the `ViKeyHintBar` view) reads through
/// ``TerminalViewModel/showViKeyHints``.
///
/// The single point under test is ``WorkspaceBindingRegistry/route(_:to:)``'s `.cheatSheet` case: while the
/// active pane is in vi / copy-mode it must toggle THAT pane's vi key-hint bar (NOT the global keyboard cheat
/// sheet); out of copy-mode it must fall through to the view-owned cheat-sheet toggle (the existing behaviour).
/// One binding, contextual behaviour — no new chord.
///
/// Driven over ``RecordingTerminalPaneSession`` (a headless double carrying a REAL ``TerminalViewModel``) so the
/// store↔model drive runs end-to-end WITHOUT a socket or renderer (the hang-safety rule). NO SwiftUI view is
/// constructed — `route(_:to:)` is the exact seam a menu `Button` / palette row / chord dispatch invokes.
@MainActor
final class ViKeyHintsRoutingTests: XCTestCase {
    /// A `.tree`-live store whose active pane carries a REAL terminal model.
    private func makeRecordingStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) }, liveVideoCap: 2,
        )
    }

    /// The live terminal model behind the active pane.
    private func activeModel(_ store: WorkspaceStore) -> TerminalViewModel? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return (store.handle(for: id) as? RecordingTerminalPaneSession)?.terminalModel
    }

    // MARK: - The store seam drives the active model's hint bar

    /// `toggleViKeyHintsInActivePane()` flips the active pane's observable ``TerminalViewModel/showViKeyHints``
    /// (the bar's visibility gate) and is its own inverse. Fails before the seam exists (won't compile).
    func testToggleViKeyHintsInActivePaneDrivesTheModel() throws {
        let store = makeRecordingStore()
        let model = try XCTUnwrap(activeModel(store))
        XCTAssertFalse(model.showViKeyHints, "the hint bar is off by default")

        store.toggleViKeyHintsInActivePane()
        XCTAssertTrue(model.showViKeyHints, "the store seam flips the active model's hint bar on")

        store.toggleViKeyHintsInActivePane()
        XCTAssertFalse(model.showViKeyHints, "and the toggle is its own inverse")
    }

    // MARK: - ⌘/ is contextual on the route

    /// In vi / copy-mode, routing `.cheatSheet` (the `⌘/` action) toggles the active pane's vi key-hint bar and
    /// does NOT open the global cheat sheet. Revert-to-fail: the un-fixed `case .cheatSheet: toggles.cheatSheet?()`
    /// would open the cheat sheet (count 1) and never touch ``TerminalViewModel/showViKeyHints``.
    func testCheatSheetRoutesToViHintsWhileInCopyMode() throws {
        let store = makeRecordingStore()
        let model = try XCTUnwrap(activeModel(store))
        model.enterCopyMode()
        XCTAssertTrue(model.isCopyMode, "precondition: the active pane is in vi mode")

        var cheatSheetToggles = 0
        WorkspaceBindingRegistry.route(.cheatSheet, to: store, toggleCheatSheet: { cheatSheetToggles += 1 })

        XCTAssertTrue(model.showViKeyHints, "in vi mode, ⌘/ toggles the vi key-hint bar")
        XCTAssertEqual(cheatSheetToggles, 0, "and does NOT open the global keyboard cheat sheet")
    }

    /// E17 ES-E17-2 / WI-5: the DISCOVERABLE "Vi Mode Key Hints" command (`.toggleViKeyHints`, palette / menu —
    /// distinct from the contextual `⌘/`) routes to the active pane's hint-bar toggle and is its own inverse, so
    /// the bar is reachable WITHOUT first being in vi mode via the contextual chord. Revert-to-fail: before the
    /// action / route existed this case won't compile (and there was no palette-discoverable hint-bar command).
    func testViKeyHintsCommandRoutesToActivePaneHintBar() throws {
        let store = makeRecordingStore()
        let model = try XCTUnwrap(activeModel(store))
        XCTAssertFalse(model.showViKeyHints, "the hint bar is off by default")

        WorkspaceBindingRegistry.route(.toggleViKeyHints, to: store)
        XCTAssertTrue(model.showViKeyHints, "the Vi Mode Key Hints command toggles the active pane's hint bar on")

        WorkspaceBindingRegistry.route(.toggleViKeyHints, to: store)
        XCTAssertFalse(model.showViKeyHints, "and the command is its own inverse")
    }

    /// Out of vi mode, routing `.cheatSheet` opens the global cheat sheet (the view-owned toggle) and leaves the
    /// vi key-hint bar untouched — the contextual branch only fires inside copy-mode.
    func testCheatSheetRoutesToGlobalSheetOutsideCopyMode() throws {
        let store = makeRecordingStore()
        let model = try XCTUnwrap(activeModel(store))
        XCTAssertFalse(model.isCopyMode, "precondition: the active pane is NOT in vi mode")

        var cheatSheetToggles = 0
        WorkspaceBindingRegistry.route(.cheatSheet, to: store, toggleCheatSheet: { cheatSheetToggles += 1 })

        XCTAssertEqual(cheatSheetToggles, 1, "out of vi mode, ⌘/ opens the global keyboard cheat sheet")
        XCTAssertFalse(model.showViKeyHints, "and never touches the vi key-hint bar")
    }
}
