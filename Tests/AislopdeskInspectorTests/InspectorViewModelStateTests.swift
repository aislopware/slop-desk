import XCTest
@testable import AislopdeskInspector

/// Pins the UI-state projections added for the inspector empty-state / feed-death banner /
/// unknown-line disclosure (UI/UX pass): the placeholder gate, the live/ended/failed feed liveness,
/// and the bounded unknown-line buffer that keeps the true monotonic count.
@MainActor
final class InspectorViewModelStateTests: XCTestCase {
    // MARK: - Empty-state gate (`hasRenderableActivity`)

    func testHasRenderableActivityFalseOnFreshModelThenTrueAfterEvent() {
        let vm = InspectorViewModel()
        XCTAssertFalse(vm.hasRenderableActivity, "a fresh model has nothing to render")
        vm.apply(.subagentUpdated(SubagentNode(id: "a", agentType: "worker")))
        XCTAssertTrue(vm.hasRenderableActivity, "folding a subagent makes the timeline renderable")
    }

    /// `messages` are stored but never rendered today — they must NOT count as renderable activity,
    /// else the placeholder hides while the panel still shows a blank timeline.
    func testMessagesAloneDoNotCountAsRenderableActivity() {
        let vm = InspectorViewModel()
        vm.apply(.message(MessageEvent(role: .assistant, text: "hi")))
        XCTAssertFalse(vm.hasRenderableActivity, "a stored-but-unrendered message keeps the timeline empty")
    }

    /// `hasRenderableActivity` must agree with what `subagentTree` actually renders: a single malformed
    /// subagent (empty id, or self-parent cycle) is FILTERED out of the tree (R11), so it must NOT
    /// suppress the placeholder — otherwise the panel shows a blank void (the exact regression the
    /// empty-state feature exists to prevent). `subagentTree.isEmpty` ⟺ `hasRenderableActivity == false`.
    func testMalformedSubagentDoesNotSuppressPlaceholder() {
        let emptyID = InspectorViewModel()
        emptyID.apply(.subagentUpdated(SubagentNode(id: "")))
        XCTAssertTrue(emptyID.subagentTree.isEmpty, "an empty-id subagent renders nothing in the tree")
        XCTAssertFalse(emptyID.hasRenderableActivity, "so it must not suppress the empty-state placeholder")

        let selfParent = InspectorViewModel()
        selfParent.apply(.subagentUpdated(SubagentNode(id: "x", parentID: "x")))
        XCTAssertTrue(selfParent.subagentTree.isEmpty, "a self-parented subagent is an unreachable orphan")
        XCTAssertFalse(selfParent.hasRenderableActivity, "so it must not suppress the placeholder either")
    }

    // MARK: - Unknown-line buffer (bounded, count is the true total)

    func testUnknownLinesBufferIsBoundedAndKeepsTrueTotal() {
        let vm = InspectorViewModel()
        for i in 0..<60 { vm.apply(.unknownLine(raw: "line \(i)")) }
        XCTAssertEqual(vm.unknownLineCount, 60, "count is the true monotonic total")
        XCTAssertEqual(vm.recentUnknownLines.count, 50, "buffer is capped at 50 (drop-oldest)")
        XCTAssertEqual(vm.recentUnknownLines.last, "line 59", "newest line retained")
        XCTAssertEqual(vm.recentUnknownLines.first, "line 10", "oldest dropped")
        XCTAssertTrue(vm.hasRenderableActivity, "any unknown line makes the timeline non-empty")
    }

    // MARK: - Feed liveness (`feedState`)

    func testFeedStateEndedAfterCleanFinish() async {
        let vm = InspectorViewModel()
        let (stream, cont) = AsyncThrowingStream<InspectorEvent, Error>.makeStream()
        cont.finish()
        await vm.consume(stream)
        XCTAssertEqual(vm.feedState, .ended, "a clean close ends the feed (shows final state)")
    }

    func testFeedStateFailedAfterError() async {
        struct Boom: Error {}
        let vm = InspectorViewModel()
        let (stream, cont) = AsyncThrowingStream<InspectorEvent, Error>.makeStream()
        cont.finish(throwing: Boom())
        await vm.consume(stream)
        XCTAssertEqual(vm.feedState, .failed, "a transport error marks the feed failed (disconnected banner)")
    }

    func testFeedStateLiveByDefault() {
        XCTAssertEqual(InspectorViewModel().feedState, .live, "a model that never consumed is live (no stale banner)")
    }

    // MARK: - Resume full-replay idempotency (R12 #4)

    /// An iOS pause/resume reuses the SAME model and re-subscribes `fromSeq: 0`, so the host replays
    /// its ENTIRE history again. Cards/subagents self-dedupe by id, but the monotonic accumulators
    /// (thinking / unknown-line counts, message timeline) did NOT — a resume DOUBLED them. `consume()`
    /// resets them on entry so a full replay rebuilds, not inflates, them.
    func testFullReplayReconsumeDoesNotDoubleCountThinkingOrUnknownLines() async {
        let vm = InspectorViewModel()
        func replay() -> AsyncThrowingStream<InspectorEvent, Error> {
            let (stream, cont) = AsyncThrowingStream<InspectorEvent, Error>.makeStream()
            cont.yield(.thinking(ThinkingMarker(isPlaceholder: true)))
            cont.yield(.unknownLine(raw: "a"))
            cont.yield(.unknownLine(raw: "b"))
            cont.yield(.message(MessageEvent(role: .assistant, text: "hi")))
            cont.yield(.toolCard(ToolCard(id: "t1", name: "Read", input: .string("x"))))
            cont.finish()
            return stream
        }
        await vm.consume(replay())
        XCTAssertEqual(vm.thinkingCount, 1)
        XCTAssertEqual(vm.unknownLineCount, 2)
        XCTAssertEqual(vm.recentUnknownLines, ["a", "b"])
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.toolCards.count, 1)

        // Resume: a second full replay of the SAME history must NOT double the counters.
        await vm.consume(replay())
        XCTAssertEqual(vm.thinkingCount, 1, "thinking count rebuilt, not doubled")
        XCTAssertEqual(vm.unknownLineCount, 2, "unknown-line count rebuilt, not doubled")
        XCTAssertEqual(vm.recentUnknownLines, ["a", "b"], "unknown lines rebuilt, not duplicated")
        XCTAssertEqual(vm.messages.count, 1, "messages rebuilt, not appended twice")
        XCTAssertEqual(vm.toolCards.count, 1, "cards still dedupe by id (upsert)")
    }

    // MARK: - Bounded card / message growth (R12 #7)

    /// `toolCards` drop-oldest at the cap, and the lookup index is REBUILT after eviction so a later
    /// upsert of a surviving id still resolves in place (no duplicate append) — the part that breaks if
    /// the index is left pointing at pre-eviction offsets.
    func testToolCardsAreBoundedAndIndexStaysValidAfterEviction() throws {
        let vm = InspectorViewModel()
        let n = InspectorViewModel.toolCardCap + 100
        for i in 0..<n { vm.apply(.toolCard(ToolCard(id: "t\(i)", name: "x", input: .string("\(i)")))) }
        XCTAssertLessThanOrEqual(vm.toolCards.count, InspectorViewModel.toolCardCap, "drop-oldest enforces the cap")
        XCTAssertEqual(vm.toolCards.last?.id, "t\(n - 1)", "newest card retained")
        XCTAssertFalse(vm.toolCards.contains { $0.id == "t0" }, "oldest card evicted")

        let survivor = try XCTUnwrap(vm.toolCards.last?.id)
        let before = vm.toolCards.count
        vm.apply(.toolCard(ToolCard(id: survivor, name: "x", input: .string("u"), output: "done")))
        XCTAssertEqual(vm.toolCards.count, before, "upsert of a surviving id does not append (index rebuilt)")
        XCTAssertEqual(vm.toolCards.count(where: { $0.id == survivor }), 1, "exactly one card with that id")
        XCTAssertEqual(vm.toolCards.first(where: { $0.id == survivor })?.output, "done", "updated in place")
    }

    func testSubagentCardsBoundedPerAgent() throws {
        let vm = InspectorViewModel()
        let n = InspectorViewModel.subagentCardCap + 100
        for i in 0..<n {
            vm.apply(.subagentToolCard(
                agentID: "agent",
                card: ToolCard(id: "s\(i)", name: "x", input: .string("\(i)")),
            ))
        }
        let cards = vm.subagentCards["agent"] ?? []
        XCTAssertLessThanOrEqual(
            cards.count,
            InspectorViewModel.subagentCardCap,
            "per-agent cards drop-oldest at the cap",
        )
        XCTAssertEqual(cards.last?.id, "s\(n - 1)", "newest retained")

        let survivor = try XCTUnwrap(cards.last?.id)
        vm.apply(.subagentToolCard(
            agentID: "agent",
            card: ToolCard(id: survivor, name: "x", input: .string("u"), output: "done"),
        ))
        let after = vm.subagentCards["agent"] ?? []
        XCTAssertEqual(after.count(where: { $0.id == survivor }), 1, "exactly one card for the survivor id")
        XCTAssertEqual(after.first(where: { $0.id == survivor })?.output, "done", "updated in place (index rebuilt)")
    }

    /// UI/UX pass-3 #9: the drop-oldest cap records how many early cards it evicted, so the UI can show a
    /// "N earlier steps hidden" banner instead of silently truncating the start of a long session.
    func testEvictedToolCardCountTracksTruncation() {
        let vm = InspectorViewModel()
        XCTAssertEqual(vm.evictedToolCardCount, 0, "nothing evicted on a fresh model")
        let n = InspectorViewModel.toolCardCap + 100
        for i in 0..<n { vm.apply(.toolCard(ToolCard(id: "t\(i)", name: "x", input: .string("\(i)")))) }
        XCTAssertGreaterThan(vm.evictedToolCardCount, 0, "eviction is recorded for the truncation banner")
        XCTAssertEqual(vm.evictedToolCardCount, n - vm.toolCards.count, "evicted count == cards dropped")
    }

    func testMessagesAreBounded() {
        let vm = InspectorViewModel()
        let n = InspectorViewModel.messageCap + 50
        for i in 0..<n { vm.apply(.message(MessageEvent(role: .assistant, text: "m\(i)"))) }
        XCTAssertLessThanOrEqual(vm.messages.count, InspectorViewModel.messageCap, "messages drop-oldest at the cap")
        XCTAssertEqual(vm.messages.last?.text, "m\(n - 1)", "newest message retained")
    }

    /// R13 #4: the OUTER agent-count dimension is bounded too — distinct agentIDs drop-oldest, and an
    /// evicted agent's node + cards + index are removed TOGETHER so `subagentTree` never orphans.
    func testDistinctAgentIDsAreBounded() {
        let vm = InspectorViewModel()
        let n = InspectorViewModel.maxAgents + 100
        for i in 0..<n {
            vm.apply(.subagentToolCard(
                agentID: "agent\(i)",
                card: ToolCard(id: "c\(i)", name: "x", input: .string("\(i)")),
            ))
        }
        XCTAssertLessThanOrEqual(vm.subagents.count, InspectorViewModel.maxAgents, "distinct-agent count is bounded")
        XCTAssertNotNil(vm.subagents["agent\(n - 1)"], "newest agent retained")
        XCTAssertNil(vm.subagents["agent0"], "oldest agent evicted")
        XCTAssertNil(vm.subagentCards["agent0"], "evicted agent's cards removed together (no orphan)")
        for node in vm.subagentTree {
            XCTAssertNotNil(vm.subagents[node.id], "every rendered tree node has a live subagents entry")
        }
    }
}
