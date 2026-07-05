import XCTest
@testable import SlopDeskInspector

/// Hook ingest: fixture PostToolUse/SubagentStop/SessionStart payloads parse into
/// typed hooks and fold into the event stream correctly.
final class HookIngestTests: XCTestCase {
    func testSessionStartHookGivesTranscriptPath() {
        let hook = HookParser.parse(Fixtures.data("hook-session-start.json"))
        guard case let .sessionStart(info)? = hook else {
            XCTFail("expected .sessionStart, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.sessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(info.model, "claude-opus-4-8")
        XCTAssertEqual(
            info.transcriptPath,
            "/Users/dev/.claude/projects/encoded-cwd/11111111-2222-3333-4444-555555555555.jsonl",
        )

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
            XCTFail("expected .postToolUse, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(use.id, "toolu_hook_01")
        XCTAssertEqual(use.name, "Write")
        XCTAssertEqual(use.input["file_path"]?.stringValue, "/tmp/out.txt")
        XCTAssertNotNil(result)

        var b = EventBuilder()
        let events = b.ingest(hook: .postToolUse(use, result))
        let cards = events.compactMap { if case let .toolCard(c) = $0 { c } else { nil } }
        XCTAssertEqual(cards.last?.status, .completed, "PostToolUse with a result → immediate completed card")
        XCTAssertEqual(cards.last?.output, "File created successfully")
    }

    func testSubagentStopHookFoldsToStoppedNode() {
        let hook = HookParser.parse(Fixtures.data("hook-subagent-stop.json"))
        guard case let .subagentStop(node)? = hook else {
            XCTFail("expected .subagentStop, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(
            HookParser.subagentTranscriptPath(Fixtures.data("hook-subagent-stop.json")),
            "/Users/dev/.claude/projects/encoded-cwd/session/subagents/agent-deadbeef.jsonl",
        )

        var b = EventBuilder()
        let events = b.ingest(hook: .subagentStop(node))
        let nodes = events.compactMap { if case let .subagentUpdated(n) = $0 { n } else { nil } }
        XCTAssertEqual(nodes.last?.id, "deadbeef")
        XCTAssertEqual(nodes.last?.status, .stopped)
        XCTAssertEqual(
            nodes.last?.lastAssistantMessage,
            "Found 2 callers of foo() in src/a.swift and src/b.swift.",
        )
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
            toolResults: [ToolResultBlock(toolUseID: "shared", content: "content", isError: false)],
        )))
        let cards = events.compactMap { if case let .toolCard(c) = $0 { c } else { nil } }
        let shared = cards.filter { $0.id == "shared" }
        XCTAssertEqual(shared.map(\.status), [.pending, .completed])
        XCTAssertEqual(shared.last?.output, "content")
    }

    func testUnknownHookYieldsNil() {
        XCTAssertNil(HookParser.parse(Data(#"{"hook_event_name":"Unknown"}"#.utf8)))
        XCTAssertNil(HookParser.parse(Data("garbage".utf8)))
    }

    // MARK: - W8: Notification / Stop / SessionEnd / UserPromptSubmit / PreToolUse

    func testNotificationPermissionHookClassifiesAsPermission() {
        let hook = HookParser.parse(Fixtures.data("hook-notification-permission.json"))
        guard case let .notification(info)? = hook else {
            XCTFail("expected .notification, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.kind, .permission)
        XCTAssertEqual(info.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(info.sessionID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    func testNotificationWaitingHookClassifiesAsWaitingForInput() {
        let hook = HookParser.parse(Fixtures.data("hook-notification-waiting.json"))
        guard case let .notification(info)? = hook else {
            XCTFail("expected .notification, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.kind, .waitingForInput)
        XCTAssertEqual(info.message, "Claude is waiting for your input")
    }

    func testNotificationOtherHookClassifiesAsOther() {
        let hook = HookParser.parse(Fixtures.data("hook-notification-other.json"))
        guard case let .notification(info)? = hook else {
            XCTFail("expected .notification, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.kind, .other)
        XCTAssertEqual(info.message, "Authentication succeeded")
    }

    func testStopHookParsesWithLastAssistantMessage() {
        let hook = HookParser.parse(Fixtures.data("hook-stop.json"))
        guard case let .stop(info)? = hook else {
            XCTFail("expected .stop, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.sessionID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(info.lastAssistantMessage, "Done — the build is green and all tests pass.")
    }

    func testSessionEndHookParses() {
        let hook = HookParser.parse(Fixtures.data("hook-session-end.json"))
        guard case let .sessionEnd(info)? = hook else {
            XCTFail("expected .sessionEnd, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.sessionID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    func testUserPromptSubmitHookParses() {
        let hook = HookParser.parse(Fixtures.data("hook-user-prompt-submit.json"))
        guard case let .userPromptSubmit(info)? = hook else {
            XCTFail("expected .userPromptSubmit, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.sessionID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    func testPreToolUseHookParsesToolName() {
        let hook = HookParser.parse(Fixtures.data("hook-pre-tool-use.json"))
        guard case let .preToolUse(use)? = hook else {
            XCTFail("expected .preToolUse, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(use.name, "Bash")
        XCTAssertEqual(use.input["command"]?.stringValue, "swift build")
    }

    func testMalformedHookIsDroppedNotTrapped() {
        // validate-then-drop: garbage JSON body returns nil, never traps.
        XCTAssertNil(HookParser.parse(Fixtures.data("hook-malformed.json")))
    }

    func testNotificationWithoutMessageDoesNotTrap() {
        // A Notification missing `message` still parses (drops to .other) — no force-unwrap.
        let hook = HookParser.parse(Data(#"{"hook_event_name":"Notification"}"#.utf8))
        guard case let .notification(info)? = hook else {
            XCTFail("expected .notification, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.kind, .other)
        XCTAssertNil(info.message)
    }
}
