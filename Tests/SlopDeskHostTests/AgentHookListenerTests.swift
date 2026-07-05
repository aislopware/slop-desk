import SlopDeskAgentDetect
import SlopDeskInspector
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// W10 — the PURE ``AgentHookHandler`` core (no real socket; the `UnixSocketAcceptor` shim is
/// compiled + code-reviewed only). Feeds REAL Claude Code hook JSON bytes directly and asserts
/// the correct type-27 ``WireMessage/claudeStatus`` emission + the embedded machine state, plus
/// validate-then-drop on malformed bytes.
final class AgentHookListenerTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: real hook JSON → type-27

    func testSessionStartEmitsIdle() {
        var h = AgentHookHandler()
        let msg = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        XCTAssertEqual(h.status, .idle)
        XCTAssertEqual(msg, .claudeStatus(state: 1, kind: 0, label: ""), "SessionStart → idle (urgency 1), kind none")
    }

    func testUserPromptSubmitEmitsWorking() {
        var h = AgentHookHandler()
        _ = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        let msg = h.handle(bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#), at: 1)
        XCTAssertEqual(h.status, .working)
        XCTAssertEqual(msg, .claudeStatus(state: 3, kind: 0, label: ""), "UserPromptSubmit → working (urgency 3)")
    }

    func testNotificationPermissionEmitsBlockedWithKindAndLabel() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .needsPermission)
        XCTAssertEqual(
            msg,
            .claudeStatus(state: 4, kind: 1, label: "Claude needs your permission to use Bash"),
            "permission Notification → needsPermission (urgency 4), kind permission (1), label = message",
        )
    }

    func testNotificationWaitingEmitsKind2() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .needsPermission)
        guard case let .claudeStatus(state, kind, _)? = msg else { XCTFail("expected claudeStatus")
            return
        }
        XCTAssertEqual(state, 4)
        XCTAssertEqual(kind, 2, "waiting-for-input Notification maps to kind 2")
    }

    func testStopEmitsDoneWithLabel() {
        var h = AgentHookHandler()
        let body = #"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"All tests pass."}"#
        let msg = h.handle(bytes: json(body), at: 0)
        XCTAssertEqual(h.status, .done)
        XCTAssertEqual(
            msg,
            .claudeStatus(state: 2, kind: 0, label: "All tests pass."),
            "Stop → done (urgency 2), kind none, label = last_assistant_message",
        )
    }

    func testSessionEndEmitsNone() {
        var h = AgentHookHandler()
        _ = h.handle(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        let msg = h.handle(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 1)
        XCTAssertEqual(h.status, .none)
        XCTAssertEqual(msg, .claudeStatus(state: 0, kind: 0, label: ""), "SessionEnd → none (urgency 0)")
    }

    // MARK: validate-then-drop on malformed / unknown bytes

    func testMalformedBytesAreDropped() {
        var h = AgentHookHandler()
        let msg = h.handle(bytes: json("not json at all {{{"), at: 0)
        XCTAssertNil(msg, "malformed bytes must be dropped (validate-then-drop), not crash")
        XCTAssertEqual(h.status, .none, "a dropped payload changes nothing")
    }

    func testEmptyBytesAreDropped() {
        var h = AgentHookHandler()
        XCTAssertNil(h.handle(bytes: Data(), at: 0))
        XCTAssertEqual(h.status, .none)
    }

    func testUnknownHookEventIsDropped() {
        var h = AgentHookHandler()
        let msg = h.handle(bytes: json(#"{"hook_event_name":"SomethingNew","session_id":"s1"}"#), at: 0)
        XCTAssertNil(msg, "an unrecognized hook event parses to nil → dropped")
    }

    // MARK: dedupe

    func testIdenticalStatusIsNotReEmitted() {
        var h = AgentHookHandler()
        let m1 = h.handle(bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#), at: 0)
        let m2 = h.handle(bytes: json(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#), at: 1)
        XCTAssertNotNil(m1, "first working transition emits")
        // PreToolUse is also working (same state, same kind, same empty label) → deduped.
        XCTAssertNil(m2, "a second working transition with the same triple is deduped")
        XCTAssertEqual(h.status, .working)
    }

    // MARK: done → idle decay via injected clock (no wall clock)

    func testDoneDecaysToIdleOnTick() {
        var h = AgentHookHandler(doneToIdleTimeout: 5)
        _ = h.handle(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#), at: 0)
        XCTAssertEqual(h.status, .done)
        let early = h.tick(at: 4) // before the timeout
        XCTAssertNil(early, "still done before the timeout — no new status")
        let decayed = h.tick(at: 6) // past the timeout
        XCTAssertEqual(h.status, .idle)
        XCTAssertEqual(decayed, .claudeStatus(state: 1, kind: 0, label: ""), "done → idle decay emits type 27")
    }

    // MARK: payload → event mapping unit (the W10 adapter)

    func testNotificationKindByteMapping() {
        XCTAssertEqual(AgentHookHandler.notificationKindByte(.permission), 1)
        XCTAssertEqual(AgentHookHandler.notificationKindByte(.waitingForInput), 2)
        XCTAssertEqual(AgentHookHandler.notificationKindByte(.other), 3)
    }

    func testStopPayloadMapsToStopEventKindZero() {
        let payload = HookPayload.stop(StopInfo(sessionID: "s", lastAssistantMessage: "done"))
        let (event, kind) = AgentHookHandler.mapToHookEvent(payload)
        XCTAssertEqual(event, .stop(sessionID: "s", label: "done"))
        XCTAssertEqual(kind, 0)
    }

    // MARK: record framing split (pane= header + JSON) — the pure routing piece

    func testRecordSplitParsesPaneHeaderAndJSON() {
        let record = Data("pane=conn-1:3\n{\"hook_event_name\":\"Stop\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertEqual(paneID, "conn-1:3")
        XCTAssertEqual(body, Data("{\"hook_event_name\":\"Stop\"}".utf8))
    }

    func testRecordSplitEmptyPaneHeaderIsNil() {
        let record = Data("pane=\n{\"hook_event_name\":\"Stop\"}".utf8)
        let (paneID, _) = AgentHookRecord.split(record)
        XCTAssertNil(paneID, "an empty pane id routes nowhere (dropped)")
    }

    func testRecordSplitWithoutHeaderTreatsWholeAsJSON() {
        let record = Data("{\"hook_event_name\":\"Stop\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertNil(paneID, "no pane header → no pane id")
        XCTAssertEqual(body, record, "the whole record is the JSON")
    }

    /// End-to-end over the pure pieces: split a real framed record, then feed the JSON to the
    /// handler → the right type-27. (The socket shim is not touched — hang-safety.)
    func testSplitThenHandleProducesStatus() {
        let record = Data("pane=p1\n{\"hook_event_name\":\"UserPromptSubmit\"}".utf8)
        let (paneID, body) = AgentHookRecord.split(record)
        XCTAssertEqual(paneID, "p1")
        var h = AgentHookHandler()
        let msg = h.handle(bytes: body, at: 0)
        XCTAssertEqual(msg, .claudeStatus(state: 3, kind: 0, label: ""), "framed UserPromptSubmit → working")
    }
}
