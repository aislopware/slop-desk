import CSlopDeskFFI
import Foundation

/// The Swift FACE of `slopdesk-inspectord`'s `tool_render` — what a pending tool call reads as.
///
/// Shared by all THREE surfaces that ask "what is in flight": Peek & Reply's pending-tool block
/// (``line(card:)``), the Peek header's todo-scent caption suffix, and the working-row tooltip's
/// scent line (both via ``scent(todos:)``). NOT a view — no SwiftUI import — so it compiles on every
/// platform and is unit-tested standalone.
///
/// ## What moved
///
/// Both rules did. The per-tool summary — `Bash` collapses to its `command`, the file-shaped tools
/// to their `file_path`, everything else to the first line of the flattening — is the crate's, and
/// its answer arrives on the card itself: ``InspectorCodec/event(_:)`` asks for it beside the
/// decode, with the raw event bytes, which is what makes an integer past `2^53` render exactly. So
/// ``line(card:)`` is a two-field lift and holds no rule at all.
///
/// The todo scent is the crate's too, and it still takes an argument, because the todo list is a
/// value this side holds rather than something that arrived attached to a card.
public enum PendingToolSummary {
    /// One collapsed line for a pending ``ToolCard``: the tool's bare `name` (a LABEL — the call
    /// site renders it `.secondary`) and the one-line summary of its input (the thing to actually
    /// read — rendered `.primary`). Two strings rather than one joined line, so the caller applies
    /// the two-tone styling without re-splitting.
    public static func line(card: ToolCard) -> PendingToolLine {
        PendingToolLine(name: card.name, summary: card.inputSummary)
    }

    /// The "`i`/`n` · `activeForm`" todo-progress line, or `nil` when nothing is in flight.
    ///
    /// The caller's `.live`-feed gate is separate; this only answers "is there one, and what does it
    /// say".
    public static func scent(todos: [TodoItem]) -> String? {
        let statuses = todos.map(\.status.ffiByte)
        // An absent active form packs as an EMPTY field — the crate folds `""` back to absence, so
        // the two say the same thing and the fallback to `content` answers both.
        let blob = InspectorCodec.packFields(todos.map(\.content) + todos.map { $0.activeForm ?? "" })
        return statuses.withUnsafeBufferPointer { states in
            blob.withUnsafeBufferPointer { texts in
                let needed = slopdesk_inspector_todo_scent(
                    states.baseAddress, states.count, texts.baseAddress, texts.count, nil, 0,
                )
                guard needed > 0 else { return nil }
                var out = [UInt8](repeating: 0, count: needed)
                let written = out.withUnsafeMutableBufferPointer {
                    slopdesk_inspector_todo_scent(
                        states.baseAddress, states.count, texts.baseAddress, texts.count,
                        $0.baseAddress, $0.count,
                    )
                }
                guard written == needed else { return nil }
                return String(bytes: out, encoding: .utf8)
            }
        }
    }
}

/// A pending tool card's collapsed one-line summary (``PendingToolSummary/line(card:)``): the tool
/// NAME and the input SUMMARY, kept apart so the view can render them in two foreground weights
/// without re-splitting a combined string.
public struct PendingToolLine: Equatable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

extension TodoItem.Status {
    /// The byte the crate names this status by.
    var ffiByte: UInt8 {
        switch self {
        case .pending: UInt8(SLOPDESK_INSPECTOR_TODO_PENDING)
        case .inProgress: UInt8(SLOPDESK_INSPECTOR_TODO_IN_PROGRESS)
        case .completed: UInt8(SLOPDESK_INSPECTOR_TODO_COMPLETED)
        }
    }
}
