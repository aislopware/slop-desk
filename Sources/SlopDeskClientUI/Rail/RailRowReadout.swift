// RailRowReadout — the row's line-2 precedence: ONE source at a time, hard cut between them. The line
// is the row's agent READOUT — the thing you'd focus the tab to find out — with structural rungs
// below (strayed cwd, last completed command, shell identity, the `⌘N` hint) so the second line is
// ALWAYS filled with something useful that never repeats the title or the section header. Pure +
// static so the precedence is unit-pinned headlessly (no view, no store).

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
    ///   6. the RUNNING command (a busy non-agent shell — the command text is what the row is doing);
    ///   7. the strayed relative cwd (structural — any live state displaces it, it returns when the
    ///      row settles);
    ///   8. the LAST COMPLETED command line (`make check · 12s · ✓` — what last happened here, the
    ///      settled row's most useful fact);
    ///   9. the shell identity (`zsh` — the caller suppresses it when it would repeat the title, e.g.
    ///      an at-root agent row titled `claude`);
    ///  10. the tab's `⌘N` shortcut hint — the floor: a brand-new pane still fills its second line
    ///      with something actionable, so the two-line shape never shows a blank.
    /// Every input is pre-gated by the caller (only handed over when its state holds), so the resolver
    /// is a pure precedence ladder.
    static func resolve(
        question: String?,
        scent: String?,
        workingLabel: String?,
        doneLine: String?,
        errorLine: String?,
        commandLine: String? = nil,
        strayedCwd: String?,
        lastCommandLine: String? = nil,
        shellLabel: String? = nil,
        shortcutHint: String? = nil,
    ) -> Line? {
        if let question { return Line(text: question, truncation: .tail) }
        if let scent { return Line(text: scent, truncation: .tail) }
        if let workingLabel { return Line(text: workingLabel, truncation: .tail) }
        if let doneLine { return Line(text: doneLine, truncation: .tail) }
        if let errorLine { return Line(text: errorLine, truncation: .tail) }
        if let commandLine { return Line(text: commandLine, truncation: .tail) }
        if let strayedCwd { return Line(text: strayedCwd, truncation: .middle) }
        if let lastCommandLine { return Line(text: lastCommandLine, truncation: .tail) }
        if let shellLabel { return Line(text: shellLabel, truncation: .tail) }
        if let shortcutHint { return Line(text: shortcutHint, truncation: .tail) }
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
