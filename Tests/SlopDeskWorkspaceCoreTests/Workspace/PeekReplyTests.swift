import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the P4 "Peek & Reply" pure logic + store wiring (answer a blocked agent INLINE, ⌘⇧J):
///
/// - ``PeekReplyTarget/select`` — focused-blocked-first, then the oldest-attention order, with the
///   advance-to-next exclusion.
/// - ``PeekReplyFormatter/reply(for:)`` / ``PeekReplyFormatter/quickAnswer(_:)`` — newline-terminated
///   plain / bang-shell / digit replies.
/// - ``PeekContent/recentLines(from:limit:)`` — the cheap "last N lines" stand-in off the block mirror.
/// - The ⌘⌥J chord is registered, maps to `.peekAndReply`, and is UNIQUE (no collision). (E10 re-pointed it
///   off ⌘⇧J, which Hint Mode's "Hint to Open" now owns — the carryover binding "E10 OWNS ⌘⇧J for Hint Mode".)
/// - The store glue: `peekReplyTargetPane`, `sendPeekReply` (reaches a NON-focused pane), `peekContent`,
///   and the advance-to-next exclusion.
///
/// All tests are hang-safe: no `GhosttySurface`, no `NWConnection`, no `VideoToolbox` — the pane handles
/// are recording doubles (``FakePaneSession`` / ``RecordingTerminalPaneSession``).
@MainActor
final class PeekReplyTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// A store whose panes carry REAL terminal models (so `peekContent` recent-lines resolve).
    private func makeTerminalStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        // The production `route(...)` now mints an in-pane `.chooser` pane for the new-pane verbs (pinned by
        // `PaneChooserRoutingTests`); this suite needs REAL panes, so translate those verbs to a direct
        // terminal creation. Every OTHER action routes unchanged.
        switch action {
        case .splitRight: store.splitActivePane(axis: .horizontal, kind: .terminal)
        case .splitDown: store.splitActivePane(axis: .vertical, kind: .terminal)
        case .newTab: store.newTab(kind: .terminal)
        default: WorkspaceBindingRegistry.route(action, to: store)
        }
    }

    // MARK: - PeekReplyTarget.select (pure selection)

    /// A FOCUSED pane that is itself blocked is answered FIRST (you are already on it), even when an older
    /// blocked pane exists earlier in traversal order.
    func testSelectFocusedBlockedWinsOverOlder() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission]
        // `a` is older, but `b` is focused + blocked → `b` wins.
        XCTAssertEqual(
            PeekReplyTarget.select(focused: b, status: { status[$0] ?? .none }, panes: [a, b]), b,
        )
    }

    /// A focused pane that is NOT blocked does not pre-empt the oldest-attention order.
    func testSelectFallsBackToOldestWhenFocusedNotBlocked() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .working]
        // `b` is focused but only working → fall back to the oldest blocked (`a`).
        XCTAssertEqual(
            PeekReplyTarget.select(focused: b, status: { status[$0] ?? .none }, panes: [a, b]), a,
        )
    }

    /// With no focused-blocked pane, the selection IS the AttentionJump order (needsPermission before done).
    func testSelectMatchesAttentionJumpOrdering() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .done, b: .needsPermission, c: .done]
        XCTAssertEqual(
            PeekReplyTarget.select(focused: nil, status: { status[$0] ?? .none }, panes: [a, b, c]), b,
        )
    }

    /// `nil` when nothing needs attention.
    func testSelectNilWhenNothingNeedsAttention() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .working, b: .idle]
        XCTAssertNil(PeekReplyTarget.select(focused: a, status: { status[$0] ?? .none }, panes: [a, b]))
    }

    /// The advance-to-next exclusion drops the just-answered pane from BOTH the focused-first clause and the
    /// candidate set — so even a focused, still-reported-blocked pane is skipped to the NEXT one.
    func testSelectExcludesAnsweredPaneOnAdvance() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission]
        // `a` is focused + blocked but just answered → advance to `b`.
        XCTAssertEqual(
            PeekReplyTarget.select(
                focused: a, status: { status[$0] ?? .none }, panes: [a, b], excluding: [a],
            ), b,
        )
        // Exclude both → nothing left.
        XCTAssertNil(
            PeekReplyTarget.select(
                focused: a, status: { status[$0] ?? .none }, panes: [a, b], excluding: [a, b],
            ),
        )
    }

    // MARK: - PeekReplyTarget.queuePosition (pure "N of M" counter)

    /// Two blocked panes, none yet answered: position 1 of 2.
    func testQueuePositionStartsAtOneOfTotal() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission]
        let result = PeekReplyTarget.queuePosition(
            status: { status[$0] ?? .none }, panes: [a, b], excluding: [],
        )
        XCTAssertEqual(result?.position, 1)
        XCTAssertEqual(result?.total, 2)
    }

    /// Answering one advances the position but keeps the total fixed (answered + remaining is stable).
    func testQueuePositionAdvancesWithExcluding() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission, c: .done]
        let result = PeekReplyTarget.queuePosition(
            status: { status[$0] ?? .none }, panes: [a, b, c], excluding: [a],
        )
        XCTAssertEqual(result?.position, 2, "one answered ⇒ position 2")
        XCTAssertEqual(result?.total, 3)
    }

    /// `.done` panes count toward the total exactly like `.needsPermission` — the SAME predicate
    /// `AttentionJump.oldestPane` orders by, so the counter and the chain can never disagree.
    func testQueuePositionCountsDonePanesToo() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .done]
        let result = PeekReplyTarget.queuePosition(
            status: { status[$0] ?? .none }, panes: [a, b], excluding: [],
        )
        XCTAssertEqual(result?.total, 2)
    }

    /// `.idle`/`.working`/`.none` panes never inflate the total — only the attention predicate counts.
    func testQueuePositionIgnoresNonAttentionStatuses() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .working, c: .idle]
        let result = PeekReplyTarget.queuePosition(
            status: { status[$0] ?? .none }, panes: [a, b, c], excluding: [],
        )
        XCTAssertNil(result, "only ONE attention pane ⇒ total 1 ⇒ not a queue")
    }

    /// A queue of exactly one is `nil` — the calm static caption stays, not "1 of 1".
    func testQueuePositionNilBelowTwo() {
        let a = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission]
        XCTAssertNil(
            PeekReplyTarget.queuePosition(status: { status[$0] ?? .none }, panes: [a], excluding: []),
        )
        // Zero also nils.
        XCTAssertNil(
            PeekReplyTarget.queuePosition(
                status: { _ in ClaudeStatus.none }, panes: [PaneID](), excluding: [],
            ),
        )
    }

    /// Excluding EVERY attention pane still counts them toward the total (they were answered, not erased)
    /// — the position lands past the total only when the overlay is about to close (M of M answered).
    func testQueuePositionAllAnsweredLandsAtTotal() {
        let a = PaneID(), b = PaneID()
        let status: [PaneID: ClaudeStatus] = [a: .needsPermission, b: .needsPermission]
        let result = PeekReplyTarget.queuePosition(
            status: { status[$0] ?? .none }, panes: [a, b], excluding: [a, b],
        )
        XCTAssertEqual(result?.position, 3, "both answered ⇒ position is answered+1, one past the total")
        XCTAssertEqual(result?.total, 2)
    }

    // MARK: - PeekReplyFormatter (pure formatting)

    /// A plain line gets a single trailing newline; whitespace around the whole field is trimmed.
    func testFormatPlainReply() {
        XCTAssertEqual(PeekReplyFormatter.reply(for: "yes"), "yes\n")
        XCTAssertEqual(PeekReplyFormatter.reply(for: "  approve the edit  "), "approve the edit\n")
    }

    /// A `!`-prefixed line strips the bang → a shell line + newline (just bytes to the same PTY).
    func testFormatBangShellReply() {
        XCTAssertEqual(PeekReplyFormatter.reply(for: "!ls -la"), "ls -la\n")
        XCTAssertEqual(PeekReplyFormatter.reply(for: "  ! git status "), "git status\n")
    }

    /// An empty / whitespace-only / bare-bang field sends nothing.
    func testFormatEmptyReplyIsNil() {
        XCTAssertNil(PeekReplyFormatter.reply(for: ""))
        XCTAssertNil(PeekReplyFormatter.reply(for: "   "))
        XCTAssertNil(PeekReplyFormatter.reply(for: "!"))
        XCTAssertNil(PeekReplyFormatter.reply(for: "  !  "))
    }

    /// A quick-answer digit (1–9) sends "<n>\n"; out-of-range is nil.
    func testFormatQuickAnswer() {
        XCTAssertEqual(PeekReplyFormatter.quickAnswer(1), "1\n")
        XCTAssertEqual(PeekReplyFormatter.quickAnswer(9), "9\n")
        XCTAssertNil(PeekReplyFormatter.quickAnswer(0))
        XCTAssertNil(PeekReplyFormatter.quickAnswer(10))
    }

    // MARK: - PeekContent.recentLines (pure recent-output builder)

    private struct StubBlock: PeekBlockLine {
        let commandText: String
        let statusLabel: String
    }

    /// Renders the NEWEST `limit` blocks as "<command> · <status>", oldest-first within the kept window.
    func testRecentLinesKeepsNewestInOrder() {
        let blocks = [
            StubBlock(commandText: "make", statusLabel: "exit 0"),
            StubBlock(commandText: "swift build", statusLabel: "exit 1"),
            StubBlock(commandText: "swift test", statusLabel: "running…"),
        ]
        let lines = PeekContent.recentLines(from: blocks, limit: 2)
        XCTAssertEqual(lines, ["swift build · exit 1", "swift test · running…"])
    }

    /// A block with an empty command line renders its status alone (no leading " · ").
    func testRecentLinesEmptyCommandShowsStatusOnly() {
        let blocks = [StubBlock(commandText: "   ", statusLabel: "running…")]
        XCTAssertEqual(PeekContent.recentLines(from: blocks, limit: 4), ["running…"])
    }

    /// No blocks / zero limit → empty (the view then shows the "no recent output" note).
    func testRecentLinesEmpty() {
        XCTAssertTrue(PeekContent.recentLines(from: [StubBlock](), limit: 4).isEmpty)
        XCTAssertTrue(
            PeekContent.recentLines(from: [StubBlock(commandText: "x", statusLabel: "exit 0")], limit: 0).isEmpty,
        )
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
