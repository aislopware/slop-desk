import XCTest
@testable import AislopdeskInspector

/// Tool-card pairing edge cases: out-of-order result, missing result (stays pending),
/// error result (isError true).
final class ToolCardPairingTests: XCTestCase {
    private func toolUseLine(id: String, name: String = "Bash") -> TranscriptLine {
        .assistant(AssistantLine(
            identity: LineIdentity(uuid: "u-\(id)"),
            toolUses: [ToolUseBlock(id: id, name: name, input: .object(["x": .string("y")]))]
        ))
    }

    private func toolResultLine(id: String, output: String, isError: Bool) -> TranscriptLine {
        .user(UserLine(
            identity: LineIdentity(uuid: "r-\(id)"),
            toolResults: [ToolResultBlock(toolUseID: id, content: output, isError: isError)]
        ))
    }

    private func cards(_ events: [InspectorEvent]) -> [ToolCard] {
        events.compactMap { if case let .toolCard(c) = $0 { return c } else { return nil } }
    }

    func testInOrderResultCompletesCard() {
        var b = EventBuilder()
        var events = b.ingest(line: toolUseLine(id: "a"))
        events += b.ingest(line: toolResultLine(id: "a", output: "ok", isError: false))
        let c = cards(events)
        XCTAssertEqual(c.map(\.status), [.pending, .completed])
        XCTAssertEqual(c.last?.output, "ok")
    }

    func testOutOfOrderResultBeforeUseResolvesOnce() {
        var b = EventBuilder()
        // Result arrives FIRST (no card yet) → held, emits nothing.
        var events = b.ingest(line: toolResultLine(id: "a", output: "early", isError: false))
        XCTAssertTrue(cards(events).isEmpty, "result before tool_use must emit no card")
        // tool_use arrives → card emitted ALREADY resolved (single emission, completed).
        events += b.ingest(line: toolUseLine(id: "a"))
        let c = cards(events)
        XCTAssertEqual(c.count, 1, "card emitted exactly once, already resolved")
        XCTAssertEqual(c[0].status, .completed)
        XCTAssertEqual(c[0].output, "early")
    }

    func testMissingResultStaysPending() {
        var b = EventBuilder()
        let events = b.ingest(line: toolUseLine(id: "a"))
        let c = cards(events)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].status, .pending, "no result → stays pending, no crash")
        XCTAssertNil(c[0].output)
    }

    func testErrorResultMarksErrored() {
        var b = EventBuilder()
        var events = b.ingest(line: toolUseLine(id: "a"))
        events += b.ingest(line: toolResultLine(id: "a", output: "boom", isError: true))
        XCTAssertEqual(cards(events).last?.status, .errored)
    }

    func testDuplicateLineIsDeduped() {
        var b = EventBuilder()
        let use = toolUseLine(id: "a")
        var events = b.ingest(line: use)
        events += b.ingest(line: use) // same uuid → second ingest emits nothing
        XCTAssertEqual(cards(events).count, 1, "re-read tail must not double-emit")
    }

    // MARK: - Unbounded-map bound (R9 fix)

    /// After a use+result pair completes, the full pair re-fed (truncation re-read)
    /// must STILL dedup — even though the open card was dropped to bound memory. The
    /// line-uuid dedup carries the contract; the dropped card is never looked up again.
    func testCompletedPairReReadStillDedups() {
        var b = EventBuilder()
        let use = toolUseLine(id: "a")
        let res = toolResultLine(id: "a", output: "ok", isError: false)
        var events = b.ingest(line: use)
        events += b.ingest(line: res)
        XCTAssertEqual(cards(events).map(\.status), [.pending, .completed])
        // Full re-read of the same two physical lines (same uuids) → zero new cards.
        var reread = b.ingest(line: use)
        reread += b.ingest(line: res)
        XCTAssertTrue(cards(reread).isEmpty, "completed pair re-read must not re-emit")
    }

    /// Driving thousands of complete pairs through one builder must not retain an open
    /// card per pair (the leak). We can't read the private map, but a re-read of an
    /// early pair must still dedup, proving the dedup contract survives the drop.
    func testManyCompletedPairsKeepDedupContract() {
        var b = EventBuilder()
        let first = toolUseLine(id: "first")
        let firstRes = toolResultLine(id: "first", output: "ok", isError: false)
        _ = b.ingest(line: first)
        _ = b.ingest(line: firstRes)
        for i in 0 ..< 5_000 {
            _ = b.ingest(line: toolUseLine(id: "c\(i)"))
            _ = b.ingest(line: toolResultLine(id: "c\(i)", output: "ok", isError: false))
        }
        // Re-read the very first pair: must dedup (its uuid is well within the cap).
        var reread = b.ingest(line: first)
        reread += b.ingest(line: firstRes)
        XCTAssertTrue(cards(reread).isEmpty, "early pair must still dedup after many pairs")
    }
}
