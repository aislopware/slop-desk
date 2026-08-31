import SlopDeskAgentDetect
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the P4 "Peek & Reply" CROSSING + store wiring (answer a blocked agent INLINE, ⌘⌥J).
///
/// The selection order, the counter's predicate, the reply shapes and the transcript-tail fold are
/// `slopdesk_agent::attention` and `slopdesk_workspace::peek_reply`, and asserted there. What is left
/// here is what only this side can be wrong about:
///
/// - a POSITION answer maps back to the right ``PaneID``, and the focused answer comes back as the
///   focused pane rather than as a position into a list it need not be in;
/// - the counter arrives as a pair, and its absence as `nil` rather than as a zero;
/// - a reply and a quick answer arrive as text, and "nothing to send" as `nil`;
/// - the tail's multi-byte punctuation survives the length words it crosses under.
///
/// Plus the parts that were never a rule: the ⌘⌥J chord is registered, maps to `.peekAndReply`, and is
/// UNIQUE (E10 re-pointed it off ⌘⇧J, which Hint Mode's "Hint to Open" now owns), and the store glue —
/// `peekReplyTargetPane`, `sendPeekReply` (reaches a NON-focused pane), `peekContent`, and the
/// advance-to-next exclusion.
///
/// All tests are hang-safe: no `TerminalSurfaceDriver`, no `NWConnection`, no `VideoToolbox` — the pane handles
/// are recording doubles (``FakePaneSession`` / ``RecordingTerminalPaneSession``).
@MainActor
final class PeekReplyTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTreeStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// A store whose panes carry REAL terminal models (so `peekContent` recent-lines resolve).
    private func makeTerminalStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in RecordingTerminalPaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        // The production `route(...)` mints a terminal directly for the new-pane verbs (pinned by
        // `NewTerminalPaneTests`); this suite needs kind-controlled panes, so translate those verbs to a direct
        // terminal creation. Every OTHER action routes unchanged.
        switch action {
        case .splitRight: store.splitActivePane(axis: .horizontal, kind: .terminal)
        case .splitDown: store.splitActivePane(axis: .vertical, kind: .terminal)
        case .newTab: store.newTab(kind: .terminal)
        default: WorkspaceBindingRegistry.route(action, to: store)
        }
    }

    // MARK: - The crossing: a position, a flag, or nothing

    /// A pane picked out of the list comes back as the PaneID that list holds — the answer is a
    /// position, and mapping it wrong is the one failure this side owns.
    func testAPositionAnswerMapsBackToItsPane() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .done, b: .needsPermission, c: .done]
        XCTAssertEqual(
            PeekReplyTarget.select(focused: nil, status: { status[$0] ?? .none }, panes: [a, b, c]), b,
        )
    }

    /// The focused pane crosses as a FLAG, not a position — it need not be in `panes` at all, and a
    /// position would have to name some other pane.
    func testTheFocusedAnswerIsTheFocusedPaneEvenWhenItIsNotInTheList() {
        let a = PaneID(), offscreen = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, offscreen: .needsPermission]
        XCTAssertEqual(
            PeekReplyTarget.select(focused: offscreen, status: { status[$0] ?? .none }, panes: [a]),
            offscreen,
        )
    }

    /// Nothing waiting crosses as absent, which must not read as position zero.
    func testNothingWaitingCrossesAsNil() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .working, b: .idle]
        XCTAssertNil(PeekReplyTarget.select(focused: a, status: { status[$0] ?? .none }, panes: [a, b]))
    }

    /// The exclusion set crosses as one flag per pane, so the advance lands the NEXT pane.
    func testTheExclusionSetCrossesAsFlags() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission]
        XCTAssertEqual(
            PeekReplyTarget.select(
                focused: a, status: { status[$0] ?? .none }, panes: [a, b], excluding: [a],
            ), b,
        )
        XCTAssertNil(
            PeekReplyTarget.select(
                focused: a, status: { status[$0] ?? .none }, panes: [a, b], excluding: [a, b],
            ),
        )
    }

    /// The counter comes back as a pair, and its absence as `nil` — never as `(0, 0)`.
    func testTheCounterCrossesAsAPairOrAsNil() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission, c: .done]
        let result = PeekReplyTarget.queuePosition(
            status: { status[$0] ?? .none }, panes: [a, b, c], excluding: [a],
        )
        XCTAssertEqual(result?.position, 2)
        XCTAssertEqual(result?.total, 3)
        XCTAssertNil(
            PeekReplyTarget.queuePosition(status: { status[$0] ?? .none }, panes: [a], excluding: []),
            "one waiting pane is not a queue",
        )
    }

    // MARK: - The crossing: text out

    /// Each reply shape arrives as text, and "nothing to send" as `nil` rather than as `""`.
    func testTheReplyShapesCrossAsTextAndNothingCrossesAsNil() {
        XCTAssertEqual(PeekReplyFormatter.reply(for: "  approve the edit  "), "approve the edit\n")
        XCTAssertEqual(PeekReplyFormatter.reply(for: "  ! git status "), "git status\n")
        XCTAssertEqual(PeekReplyFormatter.quickAnswer(7), "7\n")
        XCTAssertNil(PeekReplyFormatter.reply(for: "   "))
        XCTAssertNil(PeekReplyFormatter.quickAnswer(0))
    }

    // MARK: - The crossing: the transcript tail

    private struct StubBlock: PeekBlockLine {
        let commandText: String
        let statusLabel: String
    }

    /// The tail crosses as two parallel blobs and comes back under length WORDS: the separator and
    /// the ellipsis are multi-byte, so a length counted in characters would cut both.
    func testTheTailCrossesWithItsMultiBytePunctuationIntact() {
        let blocks = [
            StubBlock(commandText: "make", statusLabel: "exit 0"),
            StubBlock(commandText: "swift build", statusLabel: "exit 1"),
            StubBlock(commandText: "swift test", statusLabel: "running…"),
        ]
        XCTAssertEqual(
            PeekContent.recentLines(from: blocks, limit: 2),
            ["swift build · exit 1", "swift test · running…"],
        )
        XCTAssertTrue(PeekContent.recentLines(from: [StubBlock](), limit: 4).isEmpty)
    }

    // MARK: - Chord (⌘⇧J registered, mapped, unique)

    func testPeekReplyChordIsRegistered() {
        let chord = KeyChord(character: "j", [.command, .option])
        XCTAssertEqual(WorkspaceBindingRegistry.chordTable[chord], .peekAndReply, "⌘⌥J maps to .peekAndReply")
        // The old ⌘⇧J is now Hint to Open (E10 re-point), NOT peek-and-reply.
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "j", [.command, .shift])], .hintToOpen,
            "⌘⇧J moved to Hint to Open — peek-and-reply no longer owns it",
        )
    }

    func testPeekReplyBindingIsInTable() throws {
        let binding = try XCTUnwrap(
            WorkspaceBindingRegistry.allBindings.first { $0.id == "view.peekReply" },
            "binding 'view.peekReply' must exist",
        )
        XCTAssertEqual(binding.action, .peekAndReply)
        XCTAssertFalse(binding.action.requiresActivePane, "peekAndReply acts globally — no active pane required")
    }

    func testPeekReplyChordIsUnique() {
        let chord = KeyChord(character: "j", [.command, .option])
        let hits = WorkspaceBindingRegistry.allBindings.filter { $0.chord == chord }
        XCTAssertEqual(hits.count, 1, "⌘⌥J must be bound to exactly one action — no chord collision")
    }

    /// The whole registry stays chord-unique after re-pointing peek-and-reply to ⌘⌥J + adding the hint chords.
    func testNoTwoBindingsShareAChord() {
        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "no two bindings share a chord after the E10 hint re-point")
    }

    // MARK: - Store glue: peekReplyTargetPane

    /// Targets the blocked pane in a BACKGROUND tab when the focused pane is not blocked.
    func testStoreTargetsOldestBlockedAcrossTabs() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        let secondPane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNotEqual(firstPane, secondPane)
        store.setAgentStatus(.needsPermission, for: firstPane)
        XCTAssertEqual(store.peekReplyTargetPane(), firstPane, "targets the blocked pane across tabs")
    }

    /// The FOCUSED pane wins when it is itself blocked.
    func testStoreTargetsFocusedWhenItIsBlocked() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        let secondPane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        // Both blocked; the FOCUSED (second) pane is answered first even though the first is older.
        store.setAgentStatus(.needsPermission, for: firstPane)
        store.setAgentStatus(.needsPermission, for: secondPane)
        XCTAssertEqual(store.peekReplyTargetPane(), secondPane, "focused blocked pane wins")
    }

    /// No-attention → nil target.
    func testStoreTargetNilWhenNothingNeedsAttention() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentStatus(.working, for: pane)
        XCTAssertNil(store.peekReplyTargetPane())
    }

    // MARK: - Store glue: sendPeekReply (reaches a NON-focused pane)

    /// A reply is delivered to a SPECIFIC pane that is NOT the focused one — the parallelism win.
    func testStoreSendReplyReachesNonFocusedPane() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store) // focus moves to a new second pane
        let secondPane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNotEqual(firstPane, secondPane)

        store.sendPeekReply("approve\n", to: firstPane)

        let firstHandle = try XCTUnwrap(store.handle(for: firstPane) as? FakePaneSession)
        let secondHandle = try XCTUnwrap(store.handle(for: secondPane) as? FakePaneSession)
        XCTAssertEqual(firstHandle.sentText, ["approve\n"], "the reply reached the UN-focused target pane")
        XCTAssertEqual(secondHandle.sentText, [], "the focused pane received nothing")
    }

    /// An empty reply string is a no-op (the formatter already returned nil upstream; this guards the sink).
    func testStoreSendReplyEmptyIsNoOp() throws {
        let store = makeTreeStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.sendPeekReply("", to: pane)
        let handle = try XCTUnwrap(store.handle(for: pane) as? FakePaneSession)
        XCTAssertEqual(handle.sentText, [])
    }

    // MARK: - Store glue: advance-to-next exclusion

    /// After answering the focused blocked pane, the advance EXCLUDES it (even though it still reports
    /// blocked) and targets the NEXT blocked pane.
    func testStoreAdvanceExcludesAnswered() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store)
        let secondPane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.setAgentStatus(.needsPermission, for: firstPane)
        store.setAgentStatus(.needsPermission, for: secondPane)
        // Focused = second; it is answered first, then the advance excludes it → the first pane is next.
        XCTAssertEqual(store.peekReplyTargetPane(), secondPane)
        XCTAssertEqual(
            store.peekReplyTargetPane(excluding: [secondPane]), firstPane,
            "advance skips the just-answered pane (still reported blocked) and lands the next one",
        )
        // Both answered → nothing left.
        XCTAssertNil(store.peekReplyTargetPane(excluding: [firstPane, secondPane]))
    }

    // MARK: - Store glue: peekContent

    /// The peek DTO carries the pane title, the host label as the question, and the block-mirror tail.
    func testStorePeekContent() throws {
        let store = makeTerminalStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentLabel("Allow edit to main.swift?", for: pane)
        let session = try XCTUnwrap(store.handle(for: pane) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)
        model.blocks.upsert(
            index: 0,
            commandText: "swift build",
            exitCode: 0,
            durationMS: 10,
            complete: true,
            outputLen: 0,
        )
        model.blocks.upsert(
            index: 1,
            commandText: "swift test",
            exitCode: nil,
            durationMS: nil,
            complete: false,
            outputLen: 0,
        )

        let content = store.peekContent(for: pane, recentLimit: 4)
        XCTAssertEqual(content.question, "Allow edit to main.swift?")
        XCTAssertEqual(content.recent, ["swift build · exit 0", "swift test · running…"])
        XCTAssertFalse(content.title.isEmpty)
    }

    /// With no label + no blocks the DTO has nil question + empty recent (the view shows "no recent output").
    func testStorePeekContentEmpty() throws {
        let store = makeTerminalStore()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        let content = store.peekContent(for: pane)
        XCTAssertNil(content.question)
        XCTAssertTrue(content.recent.isEmpty)
    }
}
