import XCTest
@testable import AislopdeskWorkspaceCore

/// E12 — the BEHAVIORAL dispatch of the Composer (`⌘⇧E`) / Prompt Queue (`⌘⇧M`) actions through the
/// production ``WorkspaceBindingRegistry/route(_:to:)`` seam, observed on a
/// ``RecordingTerminalPaneSession`` that carries a REAL ``ComposerModel`` + ``TerminalViewModel`` (so the
/// `ComposerProviding` resolution + the `onRequestComposer` / `onRequestPromptQueue` view-focus callbacks
/// are exercised end-to-end WITHOUT a socket or a real renderer).
///
/// REVERT-TO-CONFIRM-FAIL: with the routing stubs left as `case .composer: break` / `.promptQueue: break`
/// the composer never opens and the callbacks never fire — `testComposerActionTogglesActivePaneComposer`
/// and `testPromptQueueActionOpensActivePaneComposer` both fail. `.sendToChat` is the deliberate inert E13
/// stub (a guard test, unchanged before/after).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no GhosttySurface /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class WorkspaceBindingRoutingTests: XCTestCase {
    /// A `.tree`-live store backed by the recording (composer + terminal-model carrying) session seam.
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

    // MARK: - .composer (⌘⇧E)

    /// `.composer` TOGGLES the active pane's durable composer visible AND fires the pane's
    /// `onRequestComposer` (the view-focus nudge). A second route toggles it back hidden.
    func testComposerActionTogglesActivePaneComposer() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var requested = 0
        session.terminalModel?.onRequestComposer = { requested += 1 }

        XCTAssertFalse(composer.isVisible, "precondition: the composer starts hidden")

        WorkspaceBindingRegistry.route(.composer, to: store)
        XCTAssertTrue(composer.isVisible, ".composer toggles the active pane's composer VISIBLE")
        XCTAssertEqual(requested, 1, ".composer also fires the pane's onRequestComposer (focus nudge)")

        WorkspaceBindingRegistry.route(.composer, to: store) // ⌘⇧E again
        XCTAssertFalse(composer.isVisible, ".composer again toggles it HIDDEN")
        XCTAssertEqual(requested, 2, "each ⌘⇧E re-fires the focus nudge")
    }

    // MARK: - .promptQueue (⌘⇧M)

    /// `.promptQueue` OPENS (not toggles) the active pane's composer in queue-input mode AND fires the
    /// pane's `onRequestPromptQueue`. A second route leaves it open (open, not toggle).
    func testPromptQueueActionOpensActivePaneComposer() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var queueOpened = 0
        session.terminalModel?.onRequestPromptQueue = { queueOpened += 1 }

        WorkspaceBindingRegistry.route(.promptQueue, to: store)
        XCTAssertTrue(composer.isVisible, ".promptQueue opens the active pane's composer (queue-input mode)")
        XCTAssertEqual(queueOpened, 1, ".promptQueue fires the pane's onRequestPromptQueue")

        WorkspaceBindingRegistry.route(.promptQueue, to: store) // ⌘⇧M again
        XCTAssertTrue(composer.isVisible, ".promptQueue is OPEN (not toggle) — stays visible on repeat")
        XCTAssertEqual(queueOpened, 2, "each ⌘⇧M re-fires the queue-mode focus nudge")
    }

    // MARK: - .sendToChat (E13 — stays inert here)

    /// `.sendToChat` is the deliberate inert E13 stub: routing it has NO composer effect and fires no
    /// composer/queue callback (E12 ships ONLY composer + prompt-queue input mechanics, per E12-carryovers).
    func testSendToChatStaysInert() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var anyCallback = 0
        session.terminalModel?.onRequestComposer = { anyCallback += 1 }
        session.terminalModel?.onRequestPromptQueue = { anyCallback += 1 }

        WorkspaceBindingRegistry.route(.sendToChat, to: store)
        XCTAssertFalse(composer.isVisible, ".sendToChat is an inert stub (E13) — no composer effect")
        XCTAssertEqual(anyCallback, 0, ".sendToChat fires no composer/queue callback")
    }
}
