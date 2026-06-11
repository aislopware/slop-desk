import XCTest
@testable import AislopdeskInspector

/// Parses the realistic multi-line transcript fixture and asserts the typed events,
/// tool-card pairing, todo state, thinking placeholder, and unknown-line tolerance.
final class TranscriptParsingTests: XCTestCase {
    /// Parse every fixture line then fold through the EventBuilder, returning the events.
    private func buildEvents(from fixture: String) -> [InspectorEvent] {
        var builder = EventBuilder()
        var events: [InspectorEvent] = []
        for raw in Fixtures.lines(fixture) {
            guard let line = TranscriptParser.parse(line: raw) else { continue }
            events += builder.ingest(line: line)
        }
        return events
    }

    func testFullTranscriptProducesExpectedEventTaxonomy() {
        let events = buildEvents(from: "main-session.jsonl")

        // Session metadata surfaced from the init line.
        let sessions = events.compactMap { if case let .sessionStarted(info) = $0 { return info } else { return nil } }
        XCTAssertEqual(sessions.first?.model, "claude-opus-4-8")
        XCTAssertEqual(sessions.first?.cwd, "/Volumes/Lacie/Workspace/oss/aislopdesk")

        // User + assistant messages reached the timeline.
        let messages = events.compactMap { if case let .message(m) = $0 { return m } else { return nil } }
        XCTAssertTrue(messages.contains { $0.role == .user && $0.text.contains("list the files") })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text.contains("list the files first") })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text.contains("Done.") })

        // The unknown line was surfaced (not dropped, not a crash).
        let unknowns = events.compactMap { if case let .unknownLine(raw) = $0 { return raw } else { return nil } }
        XCTAssertEqual(unknowns.count, 1)
        XCTAssertTrue(unknowns[0].contains("some-future-event-we-do-not-know"))
    }

    func testThinkingBlockIsPlaceholderOnly() {
        let events = buildEvents(from: "main-session.jsonl")
        let thinking = events.compactMap { if case let .thinking(m) = $0 { return m } else { return nil } }
        XCTAssertEqual(thinking.count, 1)
        XCTAssertTrue(thinking[0].isPlaceholder, "Opus 4.x thinking text is empty → placeholder")
        XCTAssertNil(thinking[0].text, "must never fabricate thinking content")
        XCTAssertEqual(thinking[0].signature, "ABCDEF0123456789signature-fingerprint")
    }

    func testToolCardPairingFromTranscript() {
        let events = buildEvents(from: "main-session.jsonl")
        let cards = events.compactMap { if case let .toolCard(c) = $0 { return c } else { return nil } }

        // Bash card: pending (on tool_use) then completed (on tool_result).
        let bash = cards.filter { $0.id == "toolu_001" }
        XCTAssertEqual(bash.first?.status, .pending)
        XCTAssertEqual(bash.last?.status, .completed)
        XCTAssertEqual(bash.last?.output, "total 8\ndrwxr-xr-x  Package.swift\n-rw-r--r--  README.md")
        XCTAssertEqual(bash.last?.input["command"]?.stringValue, "ls -la")

        // Read card: errored (is_error true).
        let read = cards.filter { $0.id == "toolu_003" }
        XCTAssertEqual(read.last?.status, .errored)
        XCTAssertEqual(read.last?.output, "Error: file not found")
    }

    func testTodoWriteAccumulatesLatestState() {
        let events = buildEvents(from: "main-session.jsonl")
        let todoUpdates = events.compactMap { if case let .todosUpdated(t) = $0 { return t } else { return nil } }
        XCTAssertEqual(todoUpdates.count, 1)
        let todos = todoUpdates[0]
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[0].status, .completed)
        XCTAssertEqual(todos[1].status, .inProgress)
        XCTAssertEqual(todos[1].activeForm, "Implementing the parser")
        XCTAssertEqual(todos[2].status, .pending)
        XCTAssertEqual(todos[2].content, "Write tests")
    }

    func testIgnoredInternalTypeIsClassifiedNotUnknown() {
        // The file-history-snapshot line must classify as `.ignored`, not `.unknown`.
        let raw = #"{"type":"file-history-snapshot","uuid":"x","snapshot":{}}"#
        let line = TranscriptParser.parse(line: raw)
        guard case .ignored(let type) = line else {
            return XCTFail("expected .ignored, got \(String(describing: line))")
        }
        XCTAssertEqual(type, "file-history-snapshot")
    }

    func testMalformedJSONDoesNotCrashAndBecomesUnknown() {
        // A half-written / corrupt line is tolerated (becomes .unknown).
        for bad in [#"{"type":"user""#, "not json at all", #"{broken"#, #"{"type":42}"#] {
            let line = TranscriptParser.parse(line: bad)
            XCTAssertNotNil(line)
            if case .unknown = line { /* ok */ } else {
                // `{"type":42}` parses as object but type isn't a string → unknown too.
                XCTFail("expected .unknown for \(bad), got \(String(describing: line))")
            }
        }
    }

    func testBlankLineYieldsNil() {
        XCTAssertNil(TranscriptParser.parse(line: "   "))
        XCTAssertNil(TranscriptParser.parse(line: ""))
    }
}
