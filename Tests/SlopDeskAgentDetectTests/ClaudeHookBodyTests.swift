import Foundation
import XCTest
@testable import SlopDeskAgentDetect

/// One hook body in, one event out — asserted through the door, over the real bodies Claude Code
/// writes.
///
/// The reading itself is `rust/slopdesk-hookevent`, which tests the mapping table exhaustively.
/// What these assert is the part Rust cannot: that the blob crosses the FFI intact, that ABSENT
/// stays apart from EMPTY, and that a fixture captured from the producer still maps to the case the
/// state machine expects.
final class ClaudeHookBodyTests: XCTestCase {
    private func read(_ name: String) -> ClaudeHookBody.Reading? {
        ClaudeHookBody.read(Fixtures.data(name))
    }

    private func read(literal: String) -> ClaudeHookBody.Reading? {
        ClaudeHookBody.read(Data(literal.utf8))
    }

    func testSessionStartCarriesTheEnvelopeSession() {
        let reading = read("hook-session-start.json")
        XCTAssertEqual(reading?.event, .sessionStart(sessionID: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(reading?.kindByte, 0, "a session opening is not a block")
        XCTAssertNil(reading?.prompt)
    }

    func testAToolCallCarriesItsNameAndItsPairingID() {
        let reading = read("hook-post-tool-use.json")
        XCTAssertEqual(
            reading?.event,
            .postToolUse(sessionID: nil, tool: "Write", toolUseID: "toolu_hook_01"),
        )
    }

    /// The id is what the block ledger pairs on. A body that sent none must arrive as `nil` — a
    /// minted one would be a DIFFERENT string on each half of a Pre/Post pair, so the ledger entry
    /// it opened could never be resolved.
    func testAnIDLessCallArrivesWithoutOne() {
        let reading =
            read(literal: #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        XCTAssertEqual(reading?.event, .preToolUse(sessionID: nil, tool: "Bash", toolUseID: nil))
    }

    /// ABSENT and EMPTY are different answers, which is what the presence mask in the blob is for:
    /// a session id nobody sent must not read as one that is the empty string, because the empty
    /// string would attribute the record to a pane rather than to nobody.
    func testAnAbsentFieldIsNotAnEmptyOne() {
        let absent = read(literal: #"{"hook_event_name":"SessionStart"}"#)
        XCTAssertEqual(absent?.event, .sessionStart(sessionID: nil))
        let empty = read(literal: #"{"hook_event_name":"SessionStart","session_id":""}"#)
        XCTAssertEqual(empty?.event, .sessionStart(sessionID: ""))
    }

    func testTheThreeNotificationClassesAndTheirKindBytes() {
        let permission = read("hook-notification-permission.json")
        XCTAssertEqual(
            permission?.event,
            .notification(
                kind: .permission,
                label: "Claude needs your permission to use Bash",
                toolUseID: nil,
                sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            ),
        )
        XCTAssertEqual(permission?.kindByte, 1)

        // A GENUINE block on the human answering — announced by its type, never inferred.
        for type in ["agent_needs_input", "elicitation_dialog"] {
            let waiting =
                read(literal: #"{"hook_event_name":"Notification","notification_type":"\#(type)","message":"?"}"#)
            guard case let .notification(kind, _, _, _)? = waiting?.event else {
                XCTFail("expected a notification for \(type), got \(String(describing: waiting?.event))")
                return
            }
            XCTAssertEqual(kind, .waitingForInput, "\(type) is a genuine block")
            XCTAssertEqual(waiting?.kindByte, 2)
        }

        // ⚠️ The idle nudge ("Claude is waiting for your input", emitted when the agent is simply
        // resting at its prompt) is INFORMATIONAL. It must never re-raise the act-now hand on a
        // pane the human already read.
        let nudge = read("hook-notification-waiting.json")
        guard case let (.notification(idle, label, _, _))? = nudge?.event else {
            XCTFail("expected a notification, got \(String(describing: nudge?.event))")
            return
        }
        XCTAssertEqual(idle, .other)
        XCTAssertEqual(label, "Claude is waiting for your input")

        let other = read("hook-notification-other.json")
        guard case let .notification(informational, _, _, _)? = other?.event else {
            XCTFail("expected a notification, got \(String(describing: other?.event))")
            return
        }
        XCTAssertEqual(informational, .other, "an auth success raises no hand")
        XCTAssertEqual(other?.kindByte, 3)
    }

    func testAStopCarriesTheLastAssistantMessageAsItsLabel() {
        XCTAssertEqual(
            read("hook-stop.json")?.event,
            .stop(
                sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                label: "Done — the build is green and all tests pass.",
            ),
        )
    }

    func testSessionEndAndPreToolUse() {
        XCTAssertEqual(
            read("hook-session-end.json")?.event,
            .sessionEnd(sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        )
        XCTAssertEqual(
            read("hook-pre-tool-use.json")?.event,
            .preToolUse(sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", tool: "Bash", toolUseID: nil),
        )
    }

    /// A subagent belongs to whichever session owns it and changes no coarse status, so it crosses
    /// stripped: attributing it would let a nested run's subagent claim a free pane.
    func testASubagentStopIsAnonymous() {
        XCTAssertEqual(read("hook-subagent-stop.json")?.event, .subagentStop(agentID: nil))
    }

    /// The prompt rides BESIDE the event: the status fold never reads it (a turn beginning is a
    /// turn beginning), but the host's session intent (wire type 36) titles the session from it.
    func testAPromptRidesBesideTheEventAndNowhereElse() {
        let reading = read("hook-user-prompt-submit.json")
        XCTAssertEqual(
            reading?.event,
            .userPromptSubmit(sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        )
        XCTAssertEqual(reading?.prompt, "refactor the parser")
        XCTAssertNil(read("hook-stop.json")?.prompt, "only a prompt submission carries one")
    }

    /// `AskUserQuestion` is a BLOCK, not a call: the human is being asked something, and the
    /// question text is what the client shows.
    func testAskUserQuestionArrivesAsAWaitingBlock() {
        let reading = read(literal: """
        {"hook_event_name":"PreToolUse","session_id":"s1","tool_use_id":"t9","tool_name":"AskUserQuestion",\
        "tool_input":{"questions":[{"question":"Which database?"}]}}
        """)
        XCTAssertEqual(
            reading?.event,
            .notification(
                kind: .waitingForInput,
                label: "Which database?",
                toolUseID: "t9",
                sessionID: "s1",
            ),
        )
        XCTAssertEqual(reading?.kindByte, 2)
    }

    /// An interrupt fires no `Stop` — this is the only announcement the turn is over.
    func testAnInterruptedCallIsAFinishedTurn() {
        let reading = read(literal: """
        {"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","is_interrupt":true}
        """)
        XCTAssertEqual(reading?.event, .interrupted(sessionID: "s1"))
    }

    /// Validate-then-drop: the body is written by whatever forked the agent's hook, so anything
    /// this build cannot defend an answer for changes nothing.
    func testABodyThisBuildDoesNotAnswerIsDropped() {
        XCTAssertNil(read("hook-malformed.json"), "not JSON")
        XCTAssertNil(read(literal: "garbage"))
        XCTAssertNil(read(literal: #"{"hook_event_name":"Unknown"}"#), "an event nothing knows")
        XCTAssertNil(read(literal: #"{"hook_event_name":"PreToolUse","session_id":"s1"}"#), "no tool name")
        XCTAssertNil(read(literal: "[]"), "not an object")
    }

    /// The first FFI buffer is a kilobyte; a label past it must still arrive whole, through the
    /// size-then-read retry rather than truncated.
    func testALabelPastTheFirstBufferSurvivesTheRetry() {
        let long = String(repeating: "x", count: 4096)
        let reading =
            read(literal: #"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"\#(long)"}"#)
        XCTAssertEqual(reading?.event, .stop(sessionID: "s1", label: long))
    }
}
