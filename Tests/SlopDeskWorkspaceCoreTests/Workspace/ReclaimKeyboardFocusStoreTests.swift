import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins ``WorkspaceStore/reclaimKeyboardFocusInActivePane()`` — the hand-back a closing floating card makes
/// so the keyboard returns to the pane the user was working in.
///
/// The bug it exists for: the overlays are IN-WINDOW cards, so a card with a text field holds the window's
/// first responder while it is up and leaves the WINDOW holding it on teardown. The pane's own reclaim paths
/// (the focus didSet, mount, mouseDown, focus-follows-mouse) all gate on a focus TRANSITION or a click, and
/// the workspace focus never changed while the card was open — so nothing fired and the pane stayed deaf
/// until it was clicked.
///
/// Driven over ``RecordingTerminalPaneSession`` (a headless double carrying a REAL ``TerminalViewModel``) and
/// ``FakePaneSession`` (no terminal model), so both the wired and the model-less paths are covered without a
/// renderer or a socket.
@MainActor
final class ReclaimKeyboardFocusStoreTests: XCTestCase {
    private func makeRecordingStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { seed in RecordingTerminalPaneSession(seed.spec) }, liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func model(_ store: WorkspaceStore, _ id: PaneID) -> TerminalViewModel? {
        (store.handle(for: id) as? RecordingTerminalPaneSession)?.terminalModel
    }

    /// The hand-back reaches the ACTIVE pane's live model — the renderer wires
    /// ``TerminalViewModel/onReclaimKeyboardFocus`` to `makeFirstResponder`, so firing it IS the keyboard
    /// coming home. Fails before the seam exists (won't compile) and if the store fires nothing.
    func testReclaimFiresTheActivePanesModel() throws {
        let store = makeRecordingStore()
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let m = try XCTUnwrap(model(store, active))
        var fired = 0
        m.onReclaimKeyboardFocus = { fired += 1 }

        store.reclaimKeyboardFocusInActivePane()
        XCTAssertEqual(fired, 1, "the closing card handed the keyboard back to the active pane")
    }

    /// It targets whichever pane is active AT THE MOMENT OF THE CALL, not the one that was active when the
    /// card opened — a card that changes the focus on its way out (a palette split, an Open Quickly jump)
    /// must leave the keyboard on the pane it landed on, and must NOT yank it back to the pane the user left.
    func testReclaimTargetsTheCurrentlyActivePaneOnly() throws {
        let store = makeRecordingStore()
        let first = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNotEqual(first, second, "the split produced a second pane and focused it")

        var firstFired = 0, secondFired = 0
        try XCTUnwrap(model(store, first)).onReclaimKeyboardFocus = { firstFired += 1 }
        try XCTUnwrap(model(store, second)).onReclaimKeyboardFocus = { secondFired += 1 }

        store.reclaimKeyboardFocusInActivePane()
        XCTAssertEqual(secondFired, 1, "the keyboard went to the pane that is active now")
        XCTAssertEqual(firstFired, 0, "…and not to the pane that was active when the card opened")
    }

    /// A pane with no live terminal model (a `.desktop` pane, a headless handle) is a graceful no-op — the
    /// host calls this on EVERY card dismissal, so it must never depend on the active pane being a terminal.
    func testReclaimIsANoOpWithoutALiveTerminalModel() {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) }, liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        store.reclaimKeyboardFocusInActivePane() // must not trap
    }
}
