import CSlopDeskFFI
import Foundation
import SlopDeskArena

// `slopdesk --help` — the Swift face of `rust/slopdesk-cli`'s `vocabulary`.
//
// The subcommand LIST, each verb's AVAILABILITY and its HELP TEXT are one table, and that table is
// the crate's. This file marshals two answers across the door and writes down neither.
//
// It exists because they used to be four separate lists that nothing tied together: the completion
// array in the crate, the `printUsage()` prose in `Sources/slopdesk/main.swift`, the dispatch
// `switch` a few hundred lines below it, and a hand-authored golden in the test suite. The drift
// that produced was user-visible — `open`, `import`, `export`, `features`, `state:claude` and `ipc`
// tab-completed in all five shells and then exited 2 with "not available yet", so a user was
// offered six commands that could not run. Availability now travels beside the name, the
// completions can only see the runnable half, and the help text is rendered from the same rows.

public enum CLIUsage {
    /// The complete `--help` text, terminated by a trailing newline: the synopsis, every section of
    /// the subcommand table, the `config` note and the global flags.
    ///
    /// `programName` is `argv[0]`'s last component, so a renamed or symlinked binary describes
    /// itself by the name the user actually typed.
    public static func text(programName: String) -> String {
        let bytes = Array(programName.utf8)
        return bytes.withUnsafeBufferPointer { name in
            CLICompletions.answer { out, cap in
                slopdesk_cli_usage(name.baseAddress, name.count, out, cap)
            }
        }
    }

    /// The verbs the vocabulary DOCUMENTS but does not implement, in table order.
    ///
    /// The dispatcher's only use for this is to tell a user who typed a planned verb that it is
    /// coming, apart from a user who made a typo. Nothing may offer it for completion — that is
    /// ``CLICompletions/subcommands``, and the two lists are disjoint because one table produces
    /// both.
    public static let planned: [String] = {
        let shape = slopdesk_cli_planned_subcommands(nil, 0, nil, 0)
        let room = shape.count
        guard room > 0 else { return [] }
        var spans = [SlopDeskByteSpan](repeating: SlopDeskByteSpan(), count: shape.count)
        var arena = Data(count: shape.arena_len)
        spans.withUnsafeMutableBufferPointer { out in
            arena.withUnsafeMutableBytes { pool in
                _ = slopdesk_cli_planned_subcommands(out.baseAddress, out.count, pool.baseAddress, pool.count)
            }
        }
        return spans.map { span in
            ArenaText.text(arena, offset: Int(span.offset), length: Int(span.length))
        }
    }()
}
