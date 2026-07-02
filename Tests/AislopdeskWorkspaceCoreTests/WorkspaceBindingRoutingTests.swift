import Foundation
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
/// and `testPromptQueueActionOpensActivePaneComposer` both fail. `.sendToChat` (E13 WI-5) forwards to the
/// VIEW-owned dialog toggle, so with NO toggle passed here it must have no composer side-effect (a guard).
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

    // MARK: - .sendToChat (E13 WI-5 — forwards to the view dialog toggle, no direct composer effect)

    /// `.sendToChat` (E13 WI-5) opens the view-owned Send-to-Chat DIALOG via a passed-in toggle — it never
    /// touches the active pane's composer directly. So routing it with NO toggle (this call) has no composer
    /// effect and fires no composer/queue callback (the dialog, not this action, drives any composer send).
    func testSendToChatHasNoDirectComposerEffect() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var anyCallback = 0
        session.terminalModel?.onRequestComposer = { anyCallback += 1 }
        session.terminalModel?.onRequestPromptQueue = { anyCallback += 1 }

        WorkspaceBindingRegistry.route(.sendToChat, to: store) // no toggle ⇒ graceful no-op
        XCTAssertFalse(composer.isVisible, ".sendToChat has no DIRECT composer effect (it opens the dialog)")
        XCTAssertEqual(anyCallback, 0, ".sendToChat fires no composer/queue callback")
    }

    /// `.sendToChat` WITH a `toggleSendToChat` closure FORWARDS to it EXACTLY once (the live wiring the app
    /// threads from `WorkspaceKeyDispatcher` / `WorkspaceCommands` so ⌘⌃↩ + the Agents ▸ Send to Chat menu row
    /// actually open the dialog). REVERT-TO-CONFIRM-FAIL: with the route arm left `case .sendToChat: break` the
    /// closure never fires — `fired` stays 0 and this fails. Pairs with the no-toggle guard above: together they
    /// prove the chord is LIVE when wired and a graceful no-op when not (never a dead chord).
    func testSendToChatRoutesToTheToggleOnce() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        let before = store.tree
        var fired = 0

        WorkspaceBindingRegistry.route(.sendToChat, to: store, toggleSendToChat: { fired += 1 })

        XCTAssertEqual(fired, 1, ".sendToChat invokes toggleSendToChat exactly once")
        XCTAssertFalse(composer.isVisible, "...and STILL has no direct composer effect (the dialog owns the send)")
        XCTAssertEqual(store.tree, before, "opening the dialog is a view affordance — the tree is unchanged")
    }

    // MARK: - E13 WI-5: capture → agentChatSessions() → sendChatMessage() → focus (the full store flow)

    /// THE integration pin (ES-E13-5): the active pane's SELECTION is captured, the Claude-only agent panes are
    /// the only `agentChatSessions()` targets, and `sendChatMessage(_:to:)` delivers the VERBATIM payload to the
    /// CHOSEN target's composer out-sink AND auto-switches focus to it — leaving the source pane untouched. This
    /// is the seam the Send-to-Chat dialog binds; it FAILS on the un-wired code (no capture method, an empty
    /// picker, or a send that never reached the composer / never re-focused).
    func testCaptureAgentSessionsSendAndFocusEndToEnd() throws {
        let store = makeStore()
        // The active (first) pane is the SOURCE — stage a mouse-made selection to quote.
        let source = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let sourceSession = try XCTUnwrap(store.handle(for: source) as? RecordingTerminalPaneSession)
        sourceSession.surfaceRecorder?.selectionText = "let answer = 42"

        // A SECOND pane that hosts a live Claude agent — the only valid Send-to-Chat target.
        store.newTab(kind: .terminal)
        let target = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let targetSession = try XCTUnwrap(store.handle(for: target) as? RecordingTerminalPaneSession)
        targetSession.agentActive = true
        store.focusPaneTree(source) // capture reads the ACTIVE pane's selection

        // Capture: the active pane's selection wins (the primary capture path).
        let context = try XCTUnwrap(store.captureSendToChatContext(), "a live selection yields a capture")
        XCTAssertEqual(context.quoted, "let answer = 42", "the captured quote is the verbatim selection")

        // Picker: ONLY the live agent pane is offered (the non-agent source is excluded; Claude-only badge).
        let sessions = store.agentChatSessions()
        XCTAssertEqual(sessions.map(\.id), [target], "only the live agent pane is a Send-to-Chat target")
        XCTAssertEqual(sessions.first?.agentLabel, "Claude Code", "the picker badge is Claude-only")

        // Send: the composed message lands on the TARGET's composer out-sink VERBATIM, and focus switches there.
        let message = SendToChatModel.compose(context: context, comment: "please review")
        XCTAssertTrue(store.sendChatMessage(message, to: target), "the live agent composer accepted the message")
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, target,
            "sendChatMessage auto-switches focus to the target pane (the spec's final-frame tab switch)",
        )
        XCTAssertEqual(
            targetSession.sentInput.last, SendToChatModel.payload(for: message),
            "the VERBATIM Send-to-Chat payload landed on the chosen agent pane's ordered-OUT sink",
        )
        XCTAssertTrue(sourceSession.sentInput.isEmpty, "nothing was injected into the SOURCE pane")
    }

    /// The SYNCHRONOUS capture is SELECTION-ONLY: with no selection it returns `nil` even when a completed
    /// command block exists, because the spec's no-selection fallback is the last command's OUTPUT body — which
    /// is fetched ASYNCHRONOUSLY (OSC-133 wire round-trip, see `captureSendToChatLastOutput`), never quoted from
    /// the command LINE (that would send the command you typed, not its output). So `captureSendToChatContext()`
    /// stays selection-gated; a no-output (`outputLen: 0`) block is no quote on either path.
    /// REVERT-TO-CONFIRM-FAIL: making the synchronous capture quote `blocks.latest?.commandText` would return a
    /// non-nil context quoting "npm test" — the second `XCTAssertNil` fails.
    func testSynchronousCaptureIsSelectionOnlyEvenWithACommandBlock() throws {
        let store = makeStore()
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)

        // No selection, no block → nothing to quote synchronously.
        session.surfaceRecorder?.selectionText = nil
        XCTAssertNil(store.captureSendToChatContext(), "no selection + no command block ⇒ no synchronous capture")

        // A completed command block must NOT become a (wrong) command-LINE quote on the synchronous path.
        model.blocks.upsert(
            index: 1, commandText: "npm test", exitCode: 0, durationMS: 10, complete: true, outputLen: 0,
        )
        XCTAssertNil(
            store.captureSendToChatContext(),
            "no selection ⇒ still no synchronous capture: the command LINE is the wrong text",
        )

        // The selection path (the faithful common case) is unchanged — a real selection still captures.
        session.surfaceRecorder?.selectionText = "let answer = 42"
        let captured = try XCTUnwrap(store.captureSendToChatContext(), "a live selection still yields a capture")
        XCTAssertEqual(captured.quoted, "let answer = 42", "the selection path is untouched by the fallback fix")
    }

    /// The ASYNC no-selection fallback (the send-to-chat fix): with NO selection but a PRESENT last-output block,
    /// `captureSendToChatLastOutput` fetches the real OSC-133 `D`-block OUTPUT body (wire 15→29) and yields a
    /// NON-NIL context quoting it — matching ES-E13-5's "selection OR last command output". The block must hold
    /// output (`outputLen > 0`, the same "has output" gate the copy affordance uses) and a live block-output
    /// sink must be wired (production wires it on connect); the reply is delivered via `blocks.resolveOutput`.
    /// REVERT-TO-CONFIRM-FAIL: the pre-fix code had no output fallback at all (the no-selection path was a hard
    /// no-op), so this `XCTUnwrap` of a non-nil context fails.
    func testNoSelectionCapturesRealLastCommandOutput() throws {
        let store = makeStore()
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)

        // No selection — force the no-selection path.
        session.surfaceRecorder?.selectionText = nil
        // A completed command block that HOLDS output (outputLen > 0 is the "has output" gate).
        model.blocks.upsert(
            index: 7, commandText: "ls", exitCode: 0, durationMS: 4, complete: true, outputLen: 12,
        )
        // A live block-output sink (production wires this on connect) so `copyBlockOutput` fires the request.
        var requested: [UInt32] = []
        model.requestBlockOutputSink = { requested.append($0) }

        var captured: SendToChatContext?
        var resolved = false
        store.captureSendToChatLastOutput { context in
            captured = context
            resolved = true
        }
        // The fetch fired a type-15 request for the newest block; deliver the host's type-29 reply.
        XCTAssertEqual(requested, [7], "the no-selection fallback requests the newest block's output")
        model.blocks.resolveOutput(index: 7, output: Data("README.md\n".utf8))

        XCTAssertTrue(resolved, "the fallback resolves once the host reply lands")
        let context = try XCTUnwrap(captured, "no selection + a present last-output block ⇒ a NON-NIL capture")
        XCTAssertEqual(
            context.quoted, "README.md\n",
            "the captured quote is the real OSC-133 D-block OUTPUT body (verbatim, VT-stripped)",
        )
        XCTAssertNotEqual(context.quoted, "ls", "the quote is the OUTPUT body, never the command LINE")
    }

    /// The async fallback is an HONEST no-op when there is nothing to quote: a block with NO output
    /// (`outputLen == 0`) is not worth a fetch (`onResult(nil)`, no wire request), and an UNAVAILABLE reply
    /// (empty type-29 = evicted / no live connection) resolves to `nil` too — so the caller can surface a toast
    /// rather than an empty dialog. Pins that the fallback never fabricates a quote.
    func testNoSelectionFallbackIsNilWhenNoOutputAvailable() throws {
        let store = makeStore()
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)
        session.surfaceRecorder?.selectionText = nil

        // Capture the most recent fallback result + a resolved flag (the fallback always calls back).
        var lastResult: SendToChatContext?
        var resolvedCount = 0
        func runFallback() {
            store.captureSendToChatLastOutput { context in
                lastResult = context
                resolvedCount += 1
            }
        }
        var requested: [UInt32] = []
        model.requestBlockOutputSink = { requested.append($0) }

        // No block at all → nil, no request fired.
        runFallback()
        XCTAssertEqual(resolvedCount, 1, "no block ⇒ resolved synchronously")
        XCTAssertNil(lastResult, "no block ⇒ nil capture")
        XCTAssertTrue(requested.isEmpty, "no block ⇒ no wire request")

        // A block with NO output is not worth a fetch either.
        model.blocks.upsert(
            index: 3, commandText: "true", exitCode: 0, durationMS: 1, complete: true, outputLen: 0,
        )
        runFallback()
        XCTAssertEqual(resolvedCount, 2, "an outputLen==0 block ⇒ resolved synchronously")
        XCTAssertNil(lastResult, "an outputLen==0 block ⇒ nil capture")
        XCTAssertTrue(requested.isEmpty, "an empty block ⇒ still no wire request")

        // A block WITH output but an UNAVAILABLE reply (empty type-29) resolves to nil (not an empty quote).
        model.blocks.upsert(
            index: 4, commandText: "cat x", exitCode: 1, durationMS: 2, complete: true, outputLen: 9,
        )
        runFallback()
        XCTAssertEqual(requested, [4], "a block with output fires a fetch")
        model.blocks.resolveOutput(index: 4, output: Data()) // empty == evicted/unavailable
        XCTAssertEqual(resolvedCount, 3, "the host reply resolves the fetch")
        XCTAssertNil(lastResult, "an unavailable reply ⇒ nil capture (no empty quote)")
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
