import XCTest
@testable import AislopdeskInspector

/// Hook ingest: fixture PostToolUse/SubagentStop/SessionStart payloads parse into
/// typed hooks and fold into the event stream correctly.
final class HookIngestTests: XCTestCase {
    func testSessionStartHookGivesTranscriptPath() {
        let hook = HookParser.parse(Fixtures.data("hook-session-start.json"))
        guard case let .sessionStart(info)? = hook else {
            return XCTFail("expected .sessionStart, got \(String(describing: hook))")
        }
        XCTAssertEqual(info.sessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(info.model, "claude-opus-4-8")
        XCTAssertEqual(info.transcriptPath,
                       "/Users/dev/.claude/projects/encoded-cwd/11111111-2222-3333-4444-555555555555.jsonl")

        var b = EventBuilder()
        let events = b.ingest(hook: .sessionStart(info))
        XCTAssertEqual(events.count, 1)
        if case let .sessionStarted(emitted) = events[0] {
            XCTAssertEqual(emitted.transcriptPath, info.transcriptPath)
        } else {
            XCTFail("expected .sessionStarted")
        }
    }

    func testPostToolUseHookFoldsToCompletedCard() {
        let hook = HookParser.parse(Fixtures.data("hook-post-tool-use.json"))
        guard case let .postToolUse(use, result)? = hook else {
            return XCTFail("expected .postToolUse, got \(String(describing: hook))")
        }
        XCTAssertEqual(use.id, "toolu_hook_01")
        XCTAssertEqual(use.name, "Write")
        XCTAssertEqual(use.input["file_path"]?.stringValue, "/tmp/out.txt")
        XCTAssertNotNil(result)

        var b = EventBuilder()
        let events = b.ingest(hook: .postToolUse(use, result))
        let cards = events.compactMap { if case let .toolCard(c) = $0 { return c } else { return nil } }
        XCTAssertEqual(cards.last?.status, .completed, "PostToolUse with a result → immediate completed card")
        XCTAssertEqual(cards.last?.output, "File created successfully")
    }

    func testSubagentStopHookFoldsToStoppedNode() {
        let hook = HookParser.parse(Fixtures.data("hook-subagent-stop.json"))
        guard case let .subagentStop(node)? = hook else {
            return XCTFail("expected .subagentStop, got \(String(describing: hook))")
        }
        XCTAssertEqual(HookParser.subagentTranscriptPath(Fixtures.data("hook-subagent-stop.json")),
                       "/Users/dev/.claude/projects/encoded-cwd/session/subagents/agent-deadbeef.jsonl")

        var b = EventBuilder()
        let events = b.ingest(hook: .subagentStop(node))
        let nodes = events.compactMap { if case let .subagentUpdated(n) = $0 { return n } else { return nil } }
        XCTAssertEqual(nodes.last?.id, "deadbeef")
        XCTAssertEqual(nodes.last?.status, .stopped)
        XCTAssertEqual(nodes.last?.lastAssistantMessage,
                       "Found 2 callers of foo() in src/a.swift and src/b.swift.")
    }

    func testPostToolUseHookBeforeJSONLDedupsOnCardID() {
        // doc 16: a PostToolUse hook can arrive BEFORE the JSONL flush. The later
        // JSONL tool_use (same id) must update the SAME card, not append a duplicate.
        var b = EventBuilder()
        let hookUse = ToolUseBlock(id: "shared", name: "Read", input: .object([:]))
        var events = b.ingest(hook: .postToolUse(hookUse, nil)) // pending card from hook
        // Later, the JSONL tool_result arrives for the same id.
        events += b.ingest(line: .user(UserLine(
            identity: LineIdentity(uuid: "r1"),
            toolResults: [ToolResultBlock(toolUseID: "shared", content: "content", isError: false)]
        )))
        let cards = events.compactMap { if case let .toolCard(c) = $0 { return c } else { return nil } }
        let shared = cards.filter { $0.id == "shared" }
        XCTAssertEqual(shared.map(\.status), [.pending, .completed])
        XCTAssertEqual(shared.last?.output, "content")
    }

    func testUnknownHookYieldsNil() {
        XCTAssertNil(HookParser.parse(Data(#"{"hook_event_name":"Unknown"}"#.utf8)))
        XCTAssertNil(HookParser.parse(Data("garbage".utf8)))
    }
}
