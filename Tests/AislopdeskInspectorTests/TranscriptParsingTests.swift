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
        let sessions = events.compactMap { if case let .sessionStarted(info) = $0 { info } else { nil } }
        XCTAssertEqual(sessions.first?.model, "claude-opus-4-8")
        XCTAssertEqual(sessions.first?.cwd, "/Volumes/Lacie/Workspace/oss/aislopdesk")

        // User + assistant messages reached the timeline.
        let messages = events.compactMap { if case let .message(m) = $0 { m } else { nil } }
        XCTAssertTrue(messages.contains { $0.role == .user && $0.text.contains("list the files") })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text.contains("list the files first") })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text.contains("Done.") })

        // The unknown line was surfaced (not dropped, not a crash).
        let unknowns = events.compactMap { if case let .unknownLine(raw) = $0 { raw } else { nil } }
        XCTAssertEqual(unknowns.count, 1)
        XCTAssertTrue(unknowns[0].contains("some-future-event-we-do-not-know"))
    }

    func testThinkingBlockIsPlaceholderOnly() {
        let events = buildEvents(from: "main-session.jsonl")
        let thinking = events.compactMap { if case let .thinking(m) = $0 { m } else { nil } }
        XCTAssertEqual(thinking.count, 1)
        XCTAssertTrue(thinking[0].isPlaceholder, "Opus 4.x thinking text is empty → placeholder")
        XCTAssertNil(thinking[0].text, "must never fabricate thinking content")
        XCTAssertEqual(thinking[0].signature, "ABCDEF0123456789signature-fingerprint")
    }

    func testToolCardPairingFromTranscript() {
        let events = buildEvents(from: "main-session.jsonl")
        let cards = events.compactMap { if case let .toolCard(c) = $0 { c } else { nil } }

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
        let todoUpdates = events.compactMap { if case let .todosUpdated(t) = $0 { t } else { nil } }
        XCTAssertEqual(todoUpdates.count, 1)
        let todos = todoUpdates[0]
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[0].status, .completed)
        XCTAssertEqual(todos[1].status, .inProgress)
        XCTAssertEqual(todos[1].activeForm, "Implementing the parser")
        XCTAssertEqual(todos[2].status, .pending)
        XCTAssertEqual(todos[2].content, "Write tests")
    }

    func testTaskPayloadWithoutArrayDoesNotBlankTheTodoPanel() {
        var b = EventBuilder()
        let write = AssistantLine(identity: LineIdentity(uuid: "a1"), toolUses: [
            ToolUseBlock(id: "t1", name: "TodoWrite", input: .object([
                "todos": .array([
                    .object(["content": .string("Build"), "status": .string("in_progress")]),
                    .object(["content": .string("Test"), "status": .string("pending")]),
                ]),
            ])),
        ])
        _ = b.ingest(line: .assistant(write))
        XCTAssertEqual(b.todos.count, 2, "the TodoWrite populated the panel")

        // A later Task* payload carrying NEITHER `todos` nor `tasks` (e.g. a partial single-task update)
        // must NOT wipe the panel — no event, list intact.
        let partial = AssistantLine(identity: LineIdentity(uuid: "a2"), toolUses: [
            ToolUseBlock(id: "t2", name: "TaskUpdate", input: .object(["status": .string("completed")])),
        ])
        let events = b.ingest(line: .assistant(partial))
        XCTAssertFalse(
            events.contains { if case .todosUpdated = $0 { true } else { false } },
            "a payload with no todos/tasks array emits no todosUpdated event",
        )
        XCTAssertEqual(b.todos.count, 2, "the existing todo list is preserved, not blanked")

        // An EXPLICITLY empty array IS a legitimate clear.
        let clear = AssistantLine(identity: LineIdentity(uuid: "a3"), toolUses: [
            ToolUseBlock(id: "t3", name: "TodoWrite", input: .object(["todos": .array([])])),
        ])
        _ = b.ingest(line: .assistant(clear))
        XCTAssertEqual(b.todos.count, 0, "an explicit empty array clears the panel")
    }

    func testToolResultObjectBlockWithoutTextFlattensDeterministically() {
        // A tool_result content block that is an object with multiple keys but NO `text` key must render
        // deterministically (the whole object, keys sorted) — not `values.first`, whose Dictionary order
        // is randomized per process, so a different / less-informative field surfaced each run.
        let raw = #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","# +
            #""tool_use_id":"x","content":[{"alpha":"A","bravo":"B","charlie":"C"}]}]}}"#
        guard case let .user(line)? = TranscriptParser.parse(line: raw)
        else { XCTFail("should parse a user line")
            return
        }
        XCTAssertEqual(
            line.toolResults.first?.content,
            "alpha: A\nbravo: B\ncharlie: C",
            "an object block without `text` renders all keys, sorted — stable across runs",
        )
    }

    func testIgnoredInternalTypeIsClassifiedNotUnknown() {
        // The file-history-snapshot line must classify as `.ignored`, not `.unknown`.
        let raw = #"{"type":"file-history-snapshot","uuid":"x","snapshot":{}}"#
        let line = TranscriptParser.parse(line: raw)
        guard case let .ignored(type) = line else {
            XCTFail("expected .ignored, got \(String(describing: line))")
            return
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
