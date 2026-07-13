import Foundation

/// The PURE, headless formatter shared across all THREE call sites that speak "what tool call is
/// pending" / "which todo is in flight": Peek & Reply's pending-tool block (``line(name:input:)``), the
/// Peek header's todo-scent caption suffix, and the working-row tooltip's scent line (both via
/// ``scent(todos:)``). One formatter means the flattening can never diverge between the three surfaces —
/// NOT a view (no SwiftUI import), so it is unit-tested standalone and compiles on every platform.
public enum PendingToolSummary {
    /// One collapsed line for a pending ``ToolCard``: the tool's bare `name` (a LABEL — the call site
    /// renders it `.secondary`) and a one-line summary of its `input` (the thing to actually read — the
    /// call site renders it `.primary`). Kept as two separate strings rather than one joined line so the
    /// caller can apply the two-tone styling without re-parsing.
    ///
    /// `Bash` summarizes to its `command` string (the exact command that will run); the file-shaped tools
    /// (`Edit`/`Write`/`Read`/`NotebookEdit`) summarize to `file_path` (the approve/deny read, not a diff);
    /// anything else — and a missing expected key on the above — falls back to the first line of
    /// ``JSONValue/displayString`` so an unrecognised tool never renders blank.
    public static func line(name: String, input: JSONValue) -> PendingToolLine {
        let summary: String =
            switch name {
            case "Bash": input["command"]?.stringValue ?? input.displayString.firstLine
            case "Edit",
                 "Write",
                 "Read",
                 "NotebookEdit": input["file_path"]?.stringValue ?? input.displayString.firstLine
            default: input.displayString.firstLine
            }
        return PendingToolLine(name: name, summary: summary)
    }

    /// The "`i`/`n` · `activeForm`" todo-progress line: `i` = the 1-based position of the FIRST
    /// `.inProgress` item, `n` = the total todo count, and the text is that item's imperative
    /// `activeForm` (falling back to its plain `content` when absent). `nil` when no item is
    /// `.inProgress` — the caller's `.live`-feed gate is separate; this only answers "is there one, and
    /// what does it say".
    public static func scent(todos: [TodoItem]) -> String? {
        guard let index = todos.firstIndex(where: { $0.status == .inProgress }) else { return nil }
        let item = todos[index]
        return "\(index + 1)/\(todos.count) · \(item.activeForm ?? item.content)"
    }
}

/// A pending tool card's collapsed one-line summary (``PendingToolSummary/line(name:input:)``): the tool
/// NAME and the input SUMMARY, kept apart so the view can render them in two foreground weights without
/// re-splitting a combined string.
public struct PendingToolLine: Equatable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

private extension String {
    /// The first line of a possibly-multi-line string (a multi-key ``JSONValue/displayString`` flattening
    /// joins with `"\n"`) — collapses the fallback summary to one line for the caller's `lineLimit(1)`.
    var firstLine: String {
        if let newline = firstIndex(of: "\n") { return String(self[..<newline]) }
        return self
    }
}
