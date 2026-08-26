import XCTest
@testable import SlopDeskInspector

/// Pins the Swift FACE of `slopdesk-inspectord`'s `tool_render`.
///
/// The RULES are the crate's and are asserted there — which tool collapses to which key, how the
/// flattening sorts and renders a number, where the scent's index comes from. What is left to assert
/// on this side is that the face carries the answer across intact: the byte a status crosses as, the
/// field framing the texts are packed in, and the graft that puts a rendering onto the card the
/// decode built. Each of those is a place the two sides could disagree without either one being
/// wrong on its own.
final class PendingToolSummaryTests: XCTestCase {
    // MARK: - scent(todos:) — the statuses and the packing reach the crate intact

    /// The first `.inProgress` todo drives the scent line; `activeForm` wins over plain `content`.
    func testScentUsesFirstInProgressActiveForm() {
        let todos = [
            TodoItem(content: "write tests", status: .completed),
            TodoItem(content: "wire the view", status: .inProgress, activeForm: "Wiring the view"),
            TodoItem(content: "ship it", status: .pending),
        ]
        XCTAssertEqual(PendingToolSummary.scent(todos: todos), "2/3 · Wiring the view")
    }

    /// No `activeForm` on the in-progress item ⇒ falls back to its plain `content`. This is also the
    /// absent-packs-as-empty convention: the face sends `""`, and the crate folds it back to absence.
    func testScentFallsBackToContentWhenNoActiveForm() {
        let todos = [TodoItem(content: "wire the view", status: .inProgress)]
        XCTAssertEqual(PendingToolSummary.scent(todos: todos), "1/1 · wire the view")
    }

    /// No `.inProgress` item anywhere ⇒ `nil` (the caller renders nothing — no empty scent).
    func testScentNilWhenNoInProgressItem() {
        let todos = [
            TodoItem(content: "write tests", status: .completed),
            TodoItem(content: "ship it", status: .pending),
        ]
        XCTAssertNil(PendingToolSummary.scent(todos: todos))
    }

    /// An empty todo list ⇒ `nil`.
    func testScentNilOnEmptyTodos() {
        XCTAssertNil(PendingToolSummary.scent(todos: []))
    }

    /// The SECOND `.inProgress` item is ignored — only the FIRST drives the index and the text. The
    /// assertion that matters here is the INDEX, because it is the one thing that would survive a
    /// packing bug: a face that shuffled the two arrays would still produce a plausible line.
    func testScentUsesFirstNotLastInProgress() {
        let todos = [
            TodoItem(content: "a", status: .inProgress, activeForm: "Doing A"),
            TodoItem(content: "b", status: .inProgress, activeForm: "Doing B"),
        ]
        XCTAssertEqual(PendingToolSummary.scent(todos: todos), "1/2 · Doing A")
    }

    /// A multi-byte active form survives the packing, which four-byte length prefixes over UTF-8
    /// bytes make possible and a character count would not.
    func testScentCarriesMultiByteTextAcross() {
        let todos = [TodoItem(content: "x", status: .inProgress, activeForm: "Đang chạy · 走る")]
        XCTAssertEqual(PendingToolSummary.scent(todos: todos), "1/1 · Đang chạy · 走る")
    }

    // MARK: - line(card:) — a two-field lift over what the decode grafted on

    func testLineLiftsTheCardsOwnFields() {
        let card = ToolCard(id: "t1", name: "Bash", inputDisplay: "command: ls -la", inputSummary: "ls -la")
        let line = PendingToolSummary.line(card: card)
        XCTAssertEqual(line.name, "Bash")
        XCTAssertEqual(line.summary, "ls -la")
    }

    // MARK: - The graft — a decoded card arrives carrying its renderings

    /// The whole point of asking with the RAW bytes: the daemon's `input` never becomes a Swift tree,
    /// so an integer past `2^53` renders exactly instead of in scientific form. Decoding this event
    /// through a `JSONValue` — which is what this target did until the rendering moved — answered
    /// `n: 9.007199254740992e+15`.
    func testDecodeGraftsTheRenderingsOntoTheCard() throws {
        let json = Data("""
        {"toolCard":{"_0":{"id":"t1","name":"Bash",\
        "input":{"command":"ls","n":9007199254740993},"status":"pending"}}}
        """.utf8)
        guard case let .event(.toolCard(card)) = try InspectorCodec.event(json) else {
            XCTFail("the payload names a tool card")
            return
        }
        XCTAssertEqual(card.inputSummary, "ls")
        XCTAssertEqual(card.inputDisplay, "command: ls\nn: 9007199254740993")
    }

    /// A subagent's card takes the same graft — it is the other shape the door reads, and the two
    /// nest their card under different keys.
    func testDecodeGraftsASubagentsCardToo() throws {
        let json = Data("""
        {"subagentToolCard":{"agentID":"a1","card":{"id":"s1","name":"Read",\
        "input":{"file_path":"/tmp/x"},"status":"pending"}}}
        """.utf8)
        guard case let .event(.subagentToolCard(agentID, card)) = try InspectorCodec.event(json) else {
            XCTFail("the payload names a subagent tool card")
            return
        }
        XCTAssertEqual(agentID, "a1")
        XCTAssertEqual(card.inputSummary, "/tmp/x")
    }

    /// An event carrying no card decodes unchanged — the graft is an addition, never a gate on the
    /// event itself.
    func testAnEventWithNoCardDecodesUnchanged() throws {
        let json = Data(#"{"message":{"_0":{"role":"user","text":"hi"}}}"#.utf8)
        guard case let .event(.message(message)) = try InspectorCodec.event(json) else {
            XCTFail("the payload names a message")
            return
        }
        XCTAssertEqual(message.text, "hi")
    }
}
