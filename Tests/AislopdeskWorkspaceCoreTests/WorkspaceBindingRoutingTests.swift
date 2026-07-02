import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// The BEHAVIORAL dispatch of view-focus / window-scope actions through the production
/// ``WorkspaceBindingRegistry/route(_:to:)`` seam, observed on a ``RecordingTerminalPaneSession`` that
/// carries a REAL ``TerminalViewModel`` (so the view-focus callbacks are exercised end-to-end WITHOUT a
/// socket or a real renderer).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no GhosttySurface /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class WorkspaceBindingRoutingTests: XCTestCase {
    /// A `.tree`-live store backed by the recording (terminal-model carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The active pane's recording session.
    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    // MARK: - C4 / C5: hint-mode + copy-mode arm NUDGE first responder to the active terminal

    /// C4 — `.hintToOpen` arms hint mode AND fires the active terminal's `onRequestFocus` (the first-responder
    /// nudge). Without it, if focus was elsewhere (sidebar / settings) when ⌘⇧… fired, Escape never reaches the
    /// renderer's `keyDown` → `cancelHintMode()`, so the hint badge could never be dismissed.
    /// REVERT-TO-CONFIRM-FAIL: with the arm left `case .hintToOpen: store.activeTerminalModel?.beginHint(.open)`
    /// (no focus nudge) `focused` stays 0 and this fails.
    func testHintToOpenNudgesFocusToTheActiveTerminal() throws {
        let store = makeStore()
        let session = try activeSession(store)
        var focused = 0
        session.terminalModel?.onRequestFocus = { focused += 1 }

        WorkspaceBindingRegistry.route(.hintToOpen, to: store)
        XCTAssertEqual(focused, 1, ".hintToOpen nudges first responder to the terminal so Escape can dismiss (C4)")
    }

    /// C5 — `.toggleCopyMode` arms copy-mode AND fires the active terminal's `onRequestFocus`, so Escape reaches
    /// `keyDown` → `exitCopyMode()` even when focus was elsewhere when the chord fired (the vi/copy-mode pill
    /// could otherwise never be dismissed via Escape). REVERT-TO-CONFIRM-FAIL: with the arm left
    /// `case .toggleCopyMode: store.requestCopyModeInActivePane()` (no focus nudge) `focused` stays 0 and this fails.
    func testToggleCopyModeNudgesFocusToTheActiveTerminal() throws {
        let store = makeStore()
        let session = try activeSession(store)
        var focused = 0
        session.terminalModel?.onRequestFocus = { focused += 1 }

        WorkspaceBindingRegistry.route(.toggleCopyMode, to: store)
        XCTAssertEqual(focused, 1, ".toggleCopyMode nudges first responder to the terminal so Escape can dismiss (C5)")
    }

    // MARK: - .pinWindow (E19 ES-E19-1 / WI-3 — Pin Window)

    /// `.pinWindow` FORWARDS to the passed `togglePinWindow` closure EXACTLY once (the macOS window-level
    /// concern the live app flips `WorkspaceChromeState.pinned` from) and never mutates the tree.
    /// REVERT-TO-CONFIRM-FAIL: with the routing case left `case .pinWindow: break` the closure never fires —
    /// `fired` stays 0 and this fails.
    func testPinWindowRoutesToTheClosureOnce() {
        let store = makeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.pinWindow, to: store, togglePinWindow: { fired += 1 })
        XCTAssertEqual(fired, 1, ".pinWindow invokes togglePinWindow exactly once")
        XCTAssertEqual(store.tree, before, "pinning the window is a view affordance — the tree is unchanged")
    }

    /// `.pinWindow` WITHOUT a `togglePinWindow` closure (the headless / test / iOS default) is a graceful,
    /// non-trapping no-op — never a dead chord, never a tree mutation.
    func testPinWindowWithoutClosureIsAGracefulNoOp() {
        let store = makeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.pinWindow, to: store) // no closure ⇒ no-op
        XCTAssertEqual(store.tree, before, ".pinWindow with no closure leaves the tree unchanged (no trap)")
    }

    /// The `pinWindow` registry binding exists, has the documented id, is in the `.view` category, and is
    /// CHORD-LESS (`chord: nil`) — "View ▸ Pin Window" is intentionally unbound by default (surfaced for
    /// discoverability without binding a key). FAILS on the un-fixed code (no binding) and on a
    /// category / chord regression.
    func testPinWindowBindingExistsIsViewAndChordless() {
        let binding = WorkspaceBindingRegistry.binding(for: .pinWindow)
        XCTAssertNotNil(binding, "a binding exists for Pin Window")
        XCTAssertEqual(binding?.id, "view.pinWindow", "the Pin Window binding has id view.pinWindow")
        XCTAssertEqual(binding?.title, "Pin Window", "the Pin Window binding title is 'Pin Window'")
        XCTAssertEqual(binding?.category, .view, "the Pin Window binding is in the View category")
        XCTAssertNil(binding?.chord, "the Pin Window binding is unbound by default (chord: nil)")
        XCTAssertNil(
            WorkspaceBindingRegistry.glyph(for: .pinWindow),
            "a chord-less binding renders no key glyph (no chord registered)",
        )
    }

    /// Pin Window surfaces in the View display group (palette / cheat sheet) — so it is discoverable even
    /// though it carries no default chord (the chord-less palette/menu-only idiom).
    func testPinWindowSurfacesInTheViewDisplayGroup() {
        let view = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .view }
        let ids = Set(view?.bindings.map(\.id) ?? [])
        XCTAssertTrue(ids.contains("view.pinWindow"), "Pin Window surfaces in the View display group")
    }

    /// `.pinWindow` is a window-scope action — it must NOT require an active pane (so the palette / menu never
    /// grey it out on an empty shell), matching `.toggleSidebar`.
    func testPinWindowDoesNotRequireAnActivePane() {
        XCTAssertFalse(
            WorkspaceAction.pinWindow.requiresActivePane,
            "Pin Window is window-scope — needs no active pane",
        )
    }

    /// The CANVAS fallback path (retained-but-dead model) also FORWARDS Pin Window via the closure — pinning
    /// is a window-level concern, not tree-specific, so the canvas route must not drop it. Pins the
    /// `routeCanvas` case FORWARDS (not just compiles the exhaustive switch).
    func testPinWindowRoutesOnCanvasPath() {
        let store = WorkspaceStore(
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
        var fired = 0
        WorkspaceBindingRegistry.route(.pinWindow, to: store, togglePinWindow: { fired += 1 })
        XCTAssertEqual(fired, 1, "the canvas path also forwards Pin Window to the closure")
    }
}
