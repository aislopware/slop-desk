import XCTest
@testable import AislopdeskInspector

/// A SubagentStop referencing a subagent file → the subagent node + its tool cards
/// link into the tree.
@MainActor
final class SubagentTreeTests: XCTestCase {
    func testSubagentStopLinksFileContentIntoTree() {
        var builder = EventBuilder()
        var events: [InspectorEvent] = []

        // 1. SubagentStop hook arrives (links the subagent into the tree).
        let stop = HookParser.parse(Fixtures.data("hook-subagent-stop.json"))
        guard case let .subagentStop(node)? = stop else {
            XCTFail("expected SubagentStop, got \(String(describing: stop))")
            return
        }
        XCTAssertEqual(node.id, "deadbeef")
        XCTAssertEqual(node.agentType, "Ariadne")
        XCTAssertEqual(node.status, .stopped)
        events += builder.ingest(hook: .subagentStop(node))

        // 2. The watcher tails the referenced subagent file → fold each line as the
        //    owning subagent's content.
        for raw in Fixtures.lines("subagents/agent-deadbeef.jsonl") {
            guard let line = TranscriptParser.parse(line: raw) else { continue }
            events += builder.ingestSubagent(line: line, agentID: "deadbeef")
        }

        // The node was emitted with stopped status + last message.
        let nodes = events.compactMap { if case let .subagentUpdated(n) = $0 { n } else { nil } }
        XCTAssertEqual(nodes.last?.lastAssistantMessage, "Found 2 callers of foo() in src/a.swift and src/b.swift.")

        // The subagent's Grep card paired (completed) and is tagged to the subagent.
        let saCards = events.compactMap {
            if case let .subagentToolCard(agentID, card) = $0 { (agentID, card) } else { nil }
        }
        let grep = saCards.filter { $0.1.id == "toolu_sa_01" }
        XCTAssertEqual(grep.first?.0, "deadbeef")
        XCTAssertEqual(grep.last?.1.status, .completed)
        XCTAssertEqual(grep.last?.1.name, "Grep")
        XCTAssertTrue(grep.last?.1.output?.contains("src/a.swift") ?? false)

        // Feed into the view-model and assert the tree wires up under the node.
        let vm = InspectorViewModel()
        for event in events { vm.apply(event) }
        let tree = vm.subagentTree
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].node.id, "deadbeef")
        XCTAssertEqual(tree[0].node.agentType, "Ariadne")
        XCTAssertEqual(tree[0].cards.count, 1)
        XCTAssertEqual(tree[0].cards[0].status, .completed)
    }

    func testNestedSubagentTreeNestsByParent() {
        let vm = InspectorViewModel()
        vm.apply(.subagentUpdated(SubagentNode(id: "child", parentID: "root", agentType: "worker")))
        vm.apply(.subagentUpdated(SubagentNode(id: "root", agentType: "lead")))
        let tree = vm.subagentTree
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].node.id, "root")
        XCTAssertEqual(tree[0].children.count, 1)
        XCTAssertEqual(tree[0].children[0].node.id, "child")
    }

    /// R11 (HIGH crash): a malformed subagent whose id is the EMPTY STRING groups under the same
    /// `""` root key that real top-level nodes use, so `build("")` would recurse into `build("")`
    /// forever → unbounded @MainActor stack growth → SIGSEGV from one bad id in tolerant input.
    /// The fix drops empty-id nodes from rendering AND threads a `visited` set, so this must
    /// terminate and surface only the real node.
    func testEmptyIdSubagentDoesNotRecurseInfinitely() {
        let vm = InspectorViewModel()
        vm.apply(.subagentUpdated(SubagentNode(id: "", agentType: "phantom")))
        vm.apply(.subagentUpdated(SubagentNode(id: "real", agentType: "lead")))
        let tree = vm.subagentTree // must NOT stack-overflow
        XCTAssertEqual(tree.map(\.node.id), ["real"], "empty-id node dropped; real node rendered; build terminates")
    }

    /// R11: a self-parent (`id == parentID`) groups the node under its OWN id, so it is unreachable
    /// from the `""` root — an orphan that renders nowhere. The load-bearing property is that building
    /// the tree TERMINATES (no stack overflow / hang) on this malformed input, not that the phantom
    /// node appears. (The `visited` guard additionally bounds any reachable cycle.)
    func testSelfParentSubagentDoesNotRecurseInfinitely() {
        let vm = InspectorViewModel()
        vm.apply(.subagentUpdated(SubagentNode(id: "loop", parentID: "loop", agentType: "worker")))
        let tree = vm.subagentTree // must NOT stack-overflow / hang
        XCTAssertTrue(tree.isEmpty, "a self-parented (id==parentID) node is an unreachable orphan, not a phantom root")
    }
}
