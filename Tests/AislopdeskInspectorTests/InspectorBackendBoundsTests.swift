import XCTest
@testable import AislopdeskInspector

/// R17 INSP-LEAK-1: the EventBuilder per-subagent maps are keyed by agentID and were never evicted on
/// the agentID DIMENSION — a long session (or an adversarial transcript declaring many distinct
/// subagent ids) grew them for the host's lifetime. A drop-oldest agent cap (the host analogue of the
/// client's R13 #4) bounds them.
final class EventBuilderAgentCapTests: XCTestCase {
    func testSubagentAgentIDDimensionIsBounded() {
        var builder = EventBuilder()
        let n = EventBuilder.maxAgents + 500
        for i in 0..<n {
            _ = builder.updateSubagent(SubagentNode(id: "agent-\(i)", agentType: "w"))
        }
        XCTAssertLessThanOrEqual(
            builder.trackedAgentCount,
            EventBuilder.maxAgents,
            "distinct subagent ids must drop-oldest at the cap",
        )
        XCTAssertGreaterThanOrEqual(
            builder.trackedAgentCount,
            EventBuilder.agentRetainTarget,
            "a batch eviction retains at least the retain target",
        )
    }

    func testReTouchingKnownAgentDoesNotGrowCount() {
        var builder = EventBuilder()
        _ = builder.updateSubagent(SubagentNode(id: "a"))
        let c1 = builder.trackedAgentCount
        _ = builder.updateSubagent(SubagentNode(id: "a", status: .stopped)) // already known
        XCTAssertEqual(builder.trackedAgentCount, c1, "re-updating a known agent adds no new entry")
    }
}

/// R17 INSP-WIRE-1: when the replay log dropped the oldest events (retention overflow) before the
/// prefix a subscriber asked for, the replay must PREPEND a `.historyTruncated` marker so the client
/// knows the timeline starts mid-transcript, rather than silently presenting a truncated history as
/// complete.
final class InspectorReplayTruncationTests: XCTestCase {
    func testReplayAfterRetentionDropPrependsTruncationMarker() async {
        let log = InspectorReplayLog(maxRetained: 100, retainTarget: 75)
        for i in 0..<150 { await log.append(.unknownLine(raw: "e\(i)")) } // forces baseSeq > 0

        let stream = await log.subscribe(fromSeq: 0)
        var first: InspectorEvent?
        for await event in stream { first = event
            break
        }

        guard case let .historyTruncated(dropped)? = first else {
            XCTFail("expected a historyTruncated marker first, got \(String(describing: first))")
            return
        }
        XCTAssertGreaterThan(dropped, 0, "the dropped-prefix count is surfaced to the client")
    }

    func testNoTruncationMarkerWhenNothingDropped() async {
        let log = InspectorReplayLog(maxRetained: 100, retainTarget: 75)
        for i in 0..<10 { await log.append(.unknownLine(raw: "e\(i)")) } // well under the cap → no drop

        let stream = await log.subscribe(fromSeq: 0)
        var first: InspectorEvent?
        for await event in stream { first = event
            break
        }

        guard let firstEvent = first else { XCTFail("expected a replayed event")
            return
        }
        if case .historyTruncated = firstEvent {
            XCTFail("no truncation marker must be emitted when nothing was dropped")
        }
        XCTAssertEqual(firstEvent, .unknownLine(raw: "e0"), "the real first event leads the replay")
    }
}
