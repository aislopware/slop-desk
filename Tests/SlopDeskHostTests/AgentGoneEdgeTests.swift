import SlopDeskAgentDetect
import SlopDeskInspector
import XCTest
@testable import SlopDeskHost

/// The AGENT-GONE edge as the rest of the host sees it — the ctl supervision stream, the sniffer's
/// title coalescing, and the `Stop` payload's live-work count.
final class AgentGoneEdgeTests: XCTestCase {
    // MARK: The bit the four-state vocabulary cannot carry

    /// `.none` and `.idle` are the same supervision word, so the `events` dedupe (keyed on the
    /// state string) swallowed the agent-gone transition entirely: a subscriber watching a pane go
    /// `idle → gone` saw one `"idle"` and then silence forever. `presence(from:)` is that lost bit.
    func testPresenceSeparatesGoneFromIdle() {
        XCTAssertEqual(AgentControlState.string(from: .none), AgentControlState.string(from: .idle))
        XCTAssertFalse(AgentControlState.presence(from: .none), "no agent in the pane")
        XCTAssertTrue(AgentControlState.presence(from: .idle), "an agent at rest is still an agent")
        XCTAssertTrue(AgentControlState.presence(from: .working))
        XCTAssertTrue(AgentControlState.presence(from: .done))
        XCTAssertTrue(AgentControlState.presence(from: .needsPermission))
    }

    /// The dedupe key the events pump builds must distinguish the two `"idle"`s — otherwise the
    /// fix above is invisible downstream.
    func testEventDedupeKeyDistinguishesIdleFromGone() {
        func key(_ status: ClaudeStatus) -> String {
            "\(AgentControlState.string(from: status))|\(AgentControlState.presence(from: status))"
        }
        XCTAssertNotEqual(key(.idle), key(.none), "idle → gone must survive consecutive-dupe dedupe")
        XCTAssertEqual(key(.idle), key(.idle), "a genuinely repeated idle still dedupes")
    }

    // MARK: The sniffer's coalescing anchor

    //
    // The anchor itself lives in superd now (`rust/slopdesk-superd/src/sniffer.rs`), and so do the
    // two cases that used to sit here — that retiring it lets a byte-identical `✳ Claude Code`
    // through again, and that retiring it does NOT weaken the empty-title guard it is built around.
    // What stays hostd's, and is covered above, is WHEN the retirement is asked for.

    // MARK: Stop — the work that outlives the turn

    /// `background_tasks` rides the real `Stop` payload (verified against the shipped CLI), already
    /// filtered producer-side to running/pending backgrounded tasks.
    func testStopParsesBackgroundTaskCount() {
        let body = #"""
        {"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"done",
         "background_tasks":[{"id":"a","type":"local_bash","status":"running","description":"npm run dev"},
                             {"id":"b","type":"local_agent","status":"pending","description":"review"}]}
        """#
        guard case let .stop(info)? = HookParser.parse(Data(body.utf8)) else {
            XCTFail("expected a Stop payload")
            return
        }
        XCTAssertEqual(info.backgroundTaskCount, 2)
        XCTAssertEqual(info.lastAssistantMessage, "done")
    }

    /// Tolerant on an undocumented seam: absent, null or a wrong-shaped value all read `0` rather
    /// than failing the parse of an otherwise good Stop.
    func testMissingOrMalformedBackgroundTasksCountZero() {
        for body in [
            #"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#,
            #"{"hook_event_name":"Stop","background_tasks":null}"#,
            #"{"hook_event_name":"Stop","background_tasks":{"a":1}}"#,
            #"{"hook_event_name":"Stop","background_tasks":7}"#,
        ] {
            guard case let .stop(info)? = HookParser.parse(Data(body.utf8)) else {
                XCTFail("expected a Stop payload for \(body)")
                continue
            }
            XCTAssertEqual(info.backgroundTaskCount, 0, "tolerated: \(body)")
        }
    }

    /// A turn that SPOKE keeps its own words — the count is a fallback, never a prefix that buries
    /// the assistant's message.
    func testStopLabelPrefersTheAssistantMessage() {
        let info = StopInfo(lastAssistantMessage: "Fixed the parser", backgroundTaskCount: 3)
        XCTAssertEqual(AgentHookHandler.stopLabel(info), "Fixed the parser")
    }

    /// A silent turn that left work running says so, instead of showing an empty done chip.
    func testStopLabelFallsBackToLiveWork() {
        XCTAssertEqual(
            AgentHookHandler.stopLabel(StopInfo(backgroundTaskCount: 3)),
            "3 background tasks running",
        )
        XCTAssertEqual(
            AgentHookHandler.stopLabel(StopInfo(lastAssistantMessage: "   ", backgroundTaskCount: 1)),
            "1 background task running",
        )
        XCTAssertNil(AgentHookHandler.stopLabel(StopInfo()), "nothing to say stays nothing")
    }
}
