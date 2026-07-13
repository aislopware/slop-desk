import XCTest
@testable import SlopDeskInspector

/// Pins ``PendingToolSummary`` — the ONE headless formatter routed through all three
/// call sites (the Peek & Reply pending-tool block, the Peek header's todo-scent caption suffix, and the
/// working-row tooltip's scent line) so the flattening can never diverge between them.
final class PendingToolSummaryTests: XCTestCase {
    // MARK: - line(name:input:) — pending tool call summarization

    /// `Bash` summarizes to its `command` string (the thing to actually read).
    func testBashSummarizesToCommand() {
        let line = PendingToolSummary.line(name: "Bash", input: .object(["command": .string("npm install")]))
        XCTAssertEqual(line.name, "Bash")
        XCTAssertEqual(line.summary, "npm install")
    }

    /// The file-shaped tools summarize to `file_path`, not the whole payload.
    func testFileShapedToolsSummarizeToFilePath() {
        for name in ["Edit", "Write", "Read", "NotebookEdit"] {
            let line = PendingToolSummary.line(
                name: name,
                input: .object(["file_path": .string("/tmp/main.swift"), "old_string": .string("junk")]),
            )
            XCTAssertEqual(line.name, name)
            XCTAssertEqual(line.summary, "/tmp/main.swift", "\(name) must summarize to file_path, not the whole input")
        }
    }

    /// Any other tool falls back to the first line of the compact `JSONValue.displayString` flattening —
    /// a multi-line payload collapses to its head (the caller's `lineLimit(1)` + middle-truncation carries
    /// the rest; this formatter never wraps or joins beyond line one).
    func testUnknownToolFallsBackToFirstLineOfDisplayString() {
        let line = PendingToolSummary.line(
            name: "Glob",
            input: .object(["pattern": .string("**/*.swift")]),
        )
        XCTAssertEqual(line.name, "Glob")
        XCTAssertEqual(line.summary, "pattern: **/*.swift")
    }

    /// A multi-key object's `displayString` is multi-line (sorted keys); the fallback keeps ONLY the
    /// first line.
    func testFallbackCollapsesMultilineDisplayStringToOneLine() {
        let line = PendingToolSummary.line(
            name: "Grep",
            input: .object(["pattern": .string("TODO"), "path": .string("/repo")]),
        )
        XCTAssertEqual(line.name, "Grep")
        // Sorted keys: "path" < "pattern" — the first line is the "path" entry.
        XCTAssertEqual(line.summary, "path: /repo")
    }

    /// `Bash` missing a `command` key falls back to the displayString flattening rather than crashing/blank.
    func testBashMissingCommandFallsBackToDisplayString() {
        let line = PendingToolSummary.line(name: "Bash", input: .object(["foo": .string("bar")]))
        XCTAssertEqual(line.summary, "foo: bar")
    }

    // MARK: - scent(todos:) — the "i/n · activeForm" todo-progress line

    /// The first `.inProgress` todo drives the scent line; `activeForm` wins over plain `content`.
    func testScentUsesFirstInProgressActiveForm() {
        let todos = [
            TodoItem(content: "write tests", status: .completed),
            TodoItem(content: "wire the view", status: .inProgress, activeForm: "Wiring the view"),
            TodoItem(content: "ship it", status: .pending),
        ]
        XCTAssertEqual(PendingToolSummary.scent(todos: todos), "2/3 · Wiring the view")
    }

    /// No `activeForm` on the in-progress item ⇒ falls back to its plain `content`.
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

    /// The SECOND `.inProgress` item (an already-parked earlier one) is ignored — only the FIRST drives
    /// the index + text, matching the index math ("i" = position of the item actually reported).
    func testScentUsesFirstNotLastInProgress() {
        let todos = [
            TodoItem(content: "a", status: .inProgress, activeForm: "Doing A"),
            TodoItem(content: "b", status: .inProgress, activeForm: "Doing B"),
        ]
        XCTAssertEqual(PendingToolSummary.scent(todos: todos), "1/2 · Doing A")
    }
}
