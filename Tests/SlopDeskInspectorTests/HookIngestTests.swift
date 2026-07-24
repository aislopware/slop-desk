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

    // MARK: - Notification / Stop / SessionEnd / UserPromptSubmit / PreToolUse

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

    /// The idle "waiting for your input" nudge (fired ~60 s after a turn ends, with the agent simply
    /// resting at its prompt) is INFORMATIONAL, not a blocking class — it must never re-raise the
    /// act-now hand on a pane the user already read. Genuine blocks classify through their own
    /// signals (`PermissionRequest`, `agent_needs_input`, `AskUserQuestion`).
    func testIdleWaitingNudgeClassifiesAsOther() {
        let hook = HookParser.parse(Fixtures.data("hook-notification-waiting.json"))
        guard case let .notification(info)? = hook else {
            XCTFail("expected .notification, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.kind, .other)
        XCTAssertEqual(info.message, "Claude is waiting for your input")
    }

    /// The structured types that mean "the agent is genuinely blocked on the human answering"
    /// still classify as the blocking waiting-for-input kind.
    func testAgentNeedsInputTypeClassifiesAsWaitingForInput() {
        for type in ["agent_needs_input", "elicitation_dialog"] {
            let hook = HookParser.parse(Data(
                #"{"hook_event_name":"Notification","notification_type":"\#(type)","message":"?"}"#.utf8,
            ))
            guard case let .notification(info)? = hook else {
                XCTFail("expected .notification for \(type), got \(String(describing: hook))")
                return
            }
            XCTAssertEqual(info.kind, .waitingForInput, "\(type) is a genuine block")
        }
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
        guard case let .userPromptSubmit(info, prompt)? = hook else {
            XCTFail("expected .userPromptSubmit, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.sessionID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        // The raw `prompt` rides along — the host's agent-session INTENT source (wire type 36).
        XCTAssertEqual(prompt, "refactor the parser")
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

    /// The structured `notification_type` decides the class: a known informational type wins even
    /// over alarming message text ("wants to" would text-classify as permission), while an UNKNOWN
    /// type falls through to the text heuristics (a future blocking class is not silently demoted).
    func testNotificationTypeFieldOutranksTextHeuristics() {
        let idle = HookParser.parse(Data(
            #"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hm"}"#.utf8,
        ))
        guard case let .notification(idleInfo)? = idle else {
            XCTFail("expected .notification, got \(String(describing: idle))")
            return
        }
        XCTAssertEqual(idleInfo.kind, .other, "idle_prompt is presence, never a block")

        let done = HookParser.parse(Data(
            (#"{"hook_event_name":"Notification","notification_type":"agent_completed","# +
                #""message":"Claude wants to share results"}"#).utf8,
        ))
        guard case let .notification(doneInfo)? = done else {
            XCTFail("expected .notification, got \(String(describing: done))")
            return
        }
        XCTAssertEqual(doneInfo.kind, .other, "a known informational type beats the text rules")

        let future = HookParser.parse(Data(
            (#"{"hook_event_name":"Notification","notification_type":"permission_prompt_v2","# +
                #""message":"Claude needs your permission to use Bash"}"#).utf8,
        ))
        guard case let .notification(futureInfo)? = future else {
            XCTFail("expected .notification, got \(String(describing: future))")
            return
        }
        XCTAssertEqual(futureInfo.kind, .permission, "an unknown type falls through to the text rules")
    }

    func testPermissionRequestHookParsesToolName() {
        let hook = HookParser.parse(Data(
            #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#.utf8,
        ))
        guard case let .permissionRequest(use)? = hook else {
            XCTFail("expected .permissionRequest, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(use.name, "Bash")
        XCTAssertEqual(use.input["command"]?.stringValue, "rm -rf build")
        // Malformed (no tool name) → dropped, never traps (the parallel Notification still blocks).
        XCTAssertNil(HookParser.parse(Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8)))
    }

    func testStopFailureHookParsesErrorMessage() {
        let hook = HookParser.parse(Data(
            (#"{"hook_event_name":"StopFailure","session_id":"s1","error_type":"api_error","# +
                #""error_message":"API connection error"}"#).utf8,
        ))
        guard case let .stopFailure(info)? = hook else {
            XCTFail("expected .stopFailure, got \(String(describing: hook))")
            return
        }
        XCTAssertEqual(info.sessionID, "s1")
        XCTAssertEqual(info.lastAssistantMessage, "API connection error")
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
