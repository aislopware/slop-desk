import XCTest
@testable import AislopdeskWorkspaceCore

/// E13 WI-5 / ES-E13-5 "Send to Chat": pins the PURE ``SendToChatModel`` (capture selection-vs-last-output,
/// compose the VERBATIM quoted message, encode the exact PTY bytes WITHOUT ``SendKeysParser``, and resolve
/// the picker's last-used default) plus the `.sendToChat` routing toggle (tree + canvas). All headless — no
/// SwiftUI view, no socket. Revert-to-confirm-fail: the routing tests FAIL on the pre-WI-5 dead `break`.
final class SendToChatModelTests: XCTestCase {
    // MARK: - capture: selection wins over last-output

    func testCaptureUsesSelectionWhenPresent() throws {
        let ctx = try XCTUnwrap(SendToChatModel.capture(
            title: "pane", selection: "the selection", lastOutput: "the output",
        ))
        XCTAssertEqual(ctx.quoted, "the selection", "a non-blank selection is the source")
        XCTAssertEqual(ctx.title, "pane")
        XCTAssertNil(ctx.sourcePath)
    }

    func testCaptureFallsBackToLastOutputWhenNoSelection() throws {
        let ctx = try XCTUnwrap(SendToChatModel.capture(
            title: "pane", selection: nil, lastOutput: "the output",
        ))
        XCTAssertEqual(ctx.quoted, "the output", "no selection ⇒ the last command output is the source")
    }

    func testCaptureIgnoresWhitespaceOnlySelection() throws {
        let ctx = try XCTUnwrap(SendToChatModel.capture(
            title: "pane", selection: "  \n\t ", lastOutput: "the output",
        ))
        XCTAssertEqual(ctx.quoted, "the output", "a whitespace-only selection is not a real selection")
    }

    func testCaptureReturnsNilWhenNothingToSend() {
        XCTAssertNil(SendToChatModel.capture(title: "pane", selection: nil, lastOutput: nil))
        XCTAssertNil(SendToChatModel.capture(title: "pane", selection: "", lastOutput: "   "))
    }

    // MARK: - compose: quoted block + comment (VERBATIM, blockquote-then-comment shape)

    func testComposeQuotesEachLineAndAppendsComment() {
        let ctx = SendToChatContext(title: "pane", quoted: "line1\nline2")
        XCTAssertEqual(
            SendToChatModel.compose(context: ctx, comment: "rephrase it"),
            "> line1\n> line2\n\nrephrase it",
        )
    }

    func testComposeWithoutCommentIsJustTheQuotedBlock() {
        let ctx = SendToChatContext(title: "pane", quoted: "only line")
        XCTAssertEqual(
            SendToChatModel.compose(context: ctx, comment: "   "),
            "> only line",
            "a blank comment adds no trailing separator/line",
        )
    }

    func testComposePrependsSourcePathWhenPresent() {
        let ctx = SendToChatContext(title: "composer.md L3", quoted: "x", sourcePath: "/p/composer.md#L3")
        XCTAssertEqual(SendToChatModel.compose(context: ctx, comment: "c"), "/p/composer.md#L3\n> x\n\nc")
    }

    func testComposeDropsTrailingBlankLinesAndNormalizesCRLF() {
        let ctx = SendToChatContext(title: "pane", quoted: "out\r\n\r\n")
        XCTAssertEqual(
            SendToChatModel.compose(context: ctx, comment: ""),
            "> out",
            "a trailing newline must not leave a dangling '> '",
        )
    }

    // MARK: - payload: VERBATIM bytes (no SendKeysParser)

    func testPayloadSingleLineIsRawUTF8PlusCR() {
        let bytes = SendToChatModel.payload(for: "hello")
        XCTAssertEqual(
            bytes,
            Data("hello".utf8) + Data([0x0D]),
            "a single-line message is byte-identical to a typed line (UTF-8 + CR)",
        )
    }

    func testPayloadMultiLineRidesAsOneBracketedPasteBlock() {
        let bytes = SendToChatModel.payload(for: "a\nb")
        // The literal text is preserved verbatim inside DEC bracketed-paste markers, then a single CR.
        XCTAssertEqual(bytes.last, 0x0D, "ends in one CR to submit")
        let startMarker = Data(PasteTransform.bracketStart.utf8)
        let endMarker = Data(PasteTransform.bracketEnd.utf8)
        XCTAssertTrue(bytes.starts(with: startMarker), "a multi-line message is wrapped in bracketed paste START")
        let withoutCR = bytes.dropLast()
        XCTAssertTrue(
            withoutCR.suffix(endMarker.count).elementsEqual(endMarker),
            "the block closes with the bracketed END marker before the CR",
        )
        // VERBATIM: the embedded newline survives as a literal 0x0A, never SendKeysParser-translated.
        XCTAssertTrue(bytes.contains(0x0A), "the embedded newline is a literal byte, not a parsed key")
    }

    // MARK: - defaultSession: last-used wins, else first

    func testDefaultSessionPrefersLastUsed() {
        let s1 = SendToChatSession(id: PaneID(), name: "A")
        let s2 = SendToChatSession(id: PaneID(), name: "B")
        XCTAssertEqual(SendToChatModel.defaultSession(in: [s1, s2], lastUsed: s2.id), s2)
    }

    func testDefaultSessionFallsBackToFirst() {
        let s1 = SendToChatSession(id: PaneID(), name: "A")
        let s2 = SendToChatSession(id: PaneID(), name: "B")
        XCTAssertEqual(SendToChatModel.defaultSession(in: [s1, s2], lastUsed: nil), s1)
        XCTAssertEqual(
            SendToChatModel.defaultSession(in: [s1, s2], lastUsed: PaneID()),
            s1,
            "an unknown last-used id falls back to the first live session",
        )
    }

    func testDefaultSessionNilWhenNoAgentPanes() {
        XCTAssertNil(
            SendToChatModel.defaultSession(in: [], lastUsed: nil),
            "no agent pane open ⇒ no default (the dialog offers only New session)",
        )
    }
}

/// The `.sendToChat` routing (E13 WI-5): ⌘⌃↩ must reach the view-owned `toggleSendToChat` closure on BOTH
/// the tree path and the canvas fallback. FAILS on the pre-WI-5 dead `break` (the closure never fired).
@MainActor
final class SendToChatRoutingTests: XCTestCase {
    func testSendToChatFiresToggleOnTreePath() {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { FakePaneSession($0) }, liveVideoCap: 2,
        )
        var fired = 0
        WorkspaceBindingRegistry.route(.sendToChat, to: store, toggleSendToChat: { fired += 1 })
        XCTAssertEqual(fired, 1, "the tree path forwarded .sendToChat to the dialog toggle")
    }

    func testSendToChatFiresToggleOnCanvasPath() {
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        var fired = 0
        WorkspaceBindingRegistry.route(.sendToChat, to: store, toggleSendToChat: { fired += 1 })
        XCTAssertEqual(fired, 1, "the canvas path forwarded .sendToChat to the dialog toggle")
    }
}

/// The store seam ``WorkspaceStore/sendChatMessage(_:to:)`` (E13 WI-5): a Send routes the composed message
/// VERBATIM through the CHOSEN pane's ``ComposerModel`` ordered-OUT sink AND auto-switches focus to it (the
/// spec's final-frame tab switch). Exercised over a ``RecordingTerminalPaneSession`` carrying a real
/// ``ComposerModel`` (no socket / renderer). FAILS without the seam (the bytes never reach the sink).
@MainActor
final class SendToChatStoreTests: XCTestCase {
    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) }, liveVideoCap: 2,
        )
    }

    func testSendChatMessageRoutesVerbatimBytesToTargetComposerAndAutoSwitchesFocus() throws {
        let store = makeTreeStore()
        // Two panes: target the NON-active one to prove the send auto-switches focus to the chosen pane.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let ids = store.tree.allPaneIDs()
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let target = try XCTUnwrap(ids.first { $0 != active })
        let targetSession = try XCTUnwrap(store.handle(for: target) as? RecordingTerminalPaneSession)

        XCTAssertTrue(store.sendChatMessage("hello\nworld", to: target), "a live composer accepted the message")
        XCTAssertEqual(
            targetSession.sentInput, [SendToChatModel.payload(for: "hello\nworld")],
            "the composed message reaches the target composer's ordered-OUT sink as VERBATIM bytes",
        )
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, target,
            "Send auto-switches focus to the chosen agent pane",
        )
    }

    func testSendChatMessageIsAGracefulNoOpForAnUnknownTarget() {
        let store = makeTreeStore()
        XCTAssertFalse(store.sendChatMessage("x", to: PaneID()), "an unknown / no-composer target is a no-op")
    }
}

/// The "New session" branch ``WorkspaceStore/sendChatToNewSession(_:)`` (E13 WI-5): a fresh terminal tab is a
/// bare login SHELL with no live Claude, so the composed prompt must NOT be injected straight in (the shell
/// would try to RUN the quoted-markdown block). Claude is LAUNCHED first (`claude\n`, VERBATIM), then the
/// prompt is delivered once its TUI is up. Exercised over a `FakePaneSession` (which records `sendBytes`).
@MainActor
final class SendToChatNewSessionStoreTests: XCTestCase {
    /// A single-pane workspace whose active pane carries NO inherited cwd, so the new tab sends no deferred
    /// `cd` — the new pane's injected bytes are then deterministic: [Claude launch, prompt payload].
    private func makeNoCwdStore() -> (WorkspaceStore, PaneID) {
        let pane = PaneID()
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: nil)]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
        return (store, pane)
    }

    /// REVERT-TO-CONFIRM-FAIL: the prior code injected `SendToChatModel.payload(for:)` as the FIRST (and only)
    /// thing sent into the fresh shell — so `sentBytes.first == payload` and Claude was never launched. With
    /// the fix, the launch is sent FIRST and the payload SECOND (after Claude is up).
    func testNewSessionLaunchesClaudeBeforeDeliveringThePrompt() async throws {
        let (store, _) = makeNoCwdStore()
        let message = SendToChatModel.compose(
            context: SendToChatContext(title: "CC | proj", quoted: "let x = 1\nlet y = 2"),
            comment: "review please",
        )
        // A 0 ms grace so the deferred launch + delivery land without a 1.4 s wall-clock wait.
        let spawned = try XCTUnwrap(store.sendChatToNewSession(message, launchGrace: .zero), "a pane materialized")
        let fake = try XCTUnwrap(store.handle(for: spawned) as? FakePaneSession)

        // Wait for BOTH injects (the launch, then the prompt) to land.
        for _ in 0..<400 where fake.sentBytes.count < 2 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let payload = Array(SendToChatModel.payload(for: message))
        XCTAssertEqual(fake.sentBytes.count, 2, "the new session is launched THEN handed the prompt (two injects)")
        XCTAssertEqual(
            fake.sentBytes.first, Array("claude\n".utf8),
            "Claude is LAUNCHED first (VERBATIM `claude\\n`) — the bare shell is never handed the raw prompt",
        )
        XCTAssertEqual(
            fake.sentBytes.last, payload,
            "the composed prompt is delivered to Claude's input AFTER it is up (VERBATIM payload)",
        )
        XCTAssertNotEqual(
            fake.sentBytes.first, payload,
            "the prompt must NOT be the first thing sent (the bug: a bare shell tries to run the markdown)",
        )
    }

    /// REVERT-TO-CONFIRM-FAIL: the prior code slept a fixed grace and then unconditionally called
    /// `sendBytes` — it never checked whether the pane was actually connected, so a slow/unreachable host
    /// silently dropped the `claude\n` launch AND the composed prompt with no error. With the readiness
    /// gate, a pane that never becomes ready is detected (bounded by `readyTimeout`) and `onDeliveryFailed`
    /// fires instead of the message vanishing — and crucially NOTHING is sent to the still-disconnected pane.
    func testNewSessionCallsOnDeliveryFailedWhenPaneNeverBecomesReady() async throws {
        let pane = PaneID()
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: nil)]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            liveModel: .tree,
            makeSession: { spec in
                let fake = FakePaneSession(spec)
                fake.isReadyForInput = false // simulate a pane that never connects
                return fake
            },
            liveVideoCap: 2,
            persistence: nil,
        )
        let message = SendToChatModel.compose(
            context: SendToChatContext(title: "CC | proj", quoted: "x"), comment: "y",
        )
        var failed = 0
        let spawned = try XCTUnwrap(
            store.sendChatToNewSession(
                message, launchGrace: .zero, readyTimeout: .milliseconds(50),
                onDeliveryFailed: { failed += 1 },
            ),
            "a pane materialized",
        )
        let fake = try XCTUnwrap(store.handle(for: spawned) as? FakePaneSession)

        // Wait past the bounded readiness timeout for the failure callback to fire.
        for _ in 0..<400 where failed == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(failed, 1, "a pane that never becomes ready reports the delivery failure exactly once")
        XCTAssertTrue(
            fake.sentBytes.isEmpty,
            "neither the Claude launch nor the composed message is sent to a pane that never connected",
        )
    }
}
