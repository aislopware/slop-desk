// RailRowReadout — the row's line-2 precedence: ONE source at a time, hard cut between them. The line
// used to be a cwd/git duplicate of what the section header already says; it is now the row's agent
// READOUT — the thing you'd focus the tab to find out — with the structural strayed-cwd as the lowest
// rung. Pure + static so the precedence is unit-pinned headlessly (no view, no store).

import Foundation
import SlopDeskWorkspaceCore

enum RailRowReadout {
    /// Line-2 truncation, kept SwiftUI-free so the resolver stays headless: prose keeps its head
    /// (`.tail`), a path keeps both ends (`.middle`). The view maps this onto `Text.TruncationMode`.
    enum Truncation: Equatable {
        case tail
        case middle
    }

    /// One resolved line-2: the text + how it truncates.
    struct Line: Equatable {
        let text: String
        let truncation: Truncation
    }

    /// Resolve the row's one line-2 source, by precedence:
    ///   1. the blocked QUESTION (the caller gates it on `.needsPermission` + a non-empty label);
    ///   2. working + a live inspector feed → the todo SCENT (`3/5 · Editing …` — the fixed counter
    ///      prefix leads, so `.tail` can never eat it);
    ///   3. working, feed cold → the host's last assistant line (wire-27 label);
    ///   4. done-unseen → the agent's FINAL assistant line (the same label at `.done` — it crosses the
    ///      wire today and was discarded; now you read the result without focusing the tab);
    ///   5. error → the `exit N · command` line from the block model;
    ///   6. the strayed relative cwd (structural — any live agent state displaces it, it returns when
    ///      the row settles);
    ///   7. nothing (an agent row's reserved blank line — absence, no placeholder).
    /// Every input is pre-gated by the caller (only handed over when its state holds), so the resolver
    /// is a pure precedence ladder.
    static func resolve(
        question: String?,
        scent: String?,
        workingLabel: String?,
        doneLine: String?,
        errorLine: String?,
        strayedCwd: String?,
    ) -> Line? {
        if let question { return Line(text: question, truncation: .tail) }
        if let scent { return Line(text: scent, truncation: .tail) }
        if let workingLabel { return Line(text: workingLabel, truncation: .tail) }
        if let doneLine { return Line(text: doneLine, truncation: .tail) }
        if let errorLine { return Line(text: errorLine, truncation: .tail) }
        if let strayedCwd { return Line(text: strayedCwd, truncation: .middle) }
        return nil
    }

    /// The error readout: `exit 137 · npm test` — the exit code + the command that produced it, so the
    /// failure is diagnosable from the rail. `nil` without a code; a blank command keeps just the code.
    static func errorLine(exitCode: Int32?, commandText: String?) -> String? {
        guard let exitCode else { return nil }
        let command = commandText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? "exit \(exitCode)" : "exit \(exitCode) · \(command)"
    }
}
