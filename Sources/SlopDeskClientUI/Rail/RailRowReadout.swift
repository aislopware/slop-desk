// RailRowReadout — the row's live-detail precedence: ONE source at a time, hard cut between them.
// The resolved line is the thing you'd focus the tab to find out — since the otty reset it rides the
// row's hover TOOLTIP (the rendered row is bare: title + one trailing slot), and it EARNS its place:
// there are no structural filler rungs (cwd echoes, shell identity, shortcut hints — derivable or
// decorative), so a settled row's tooltip is path + history alone and a detail line always means
// "something is happening here". Command-shaped sources are additionally suppressed when they would
// only echo the title (a shell that titles the pane after the command it runs). Pure + static so the
// precedence is unit-pinned headlessly (no view, no store).

import Foundation
import SlopDeskWorkspaceCore

enum RailRowReadout {
    /// Resolve the row's one readout source, by precedence:
    ///   1. the blocked QUESTION (the caller gates it on `.needsPermission` + a non-empty label);
    ///   2. working + a live inspector feed → the todo SCENT (`3/5 · Editing …` — the fixed counter
    ///      prefix leads, so `.tail` can never eat it);
    ///   3. working, feed cold → the host's last assistant line (wire-27 label);
    ///   4. done-unseen → the agent's FINAL assistant line (the same label at `.done` — you read the
    ///      result without focusing the tab);
    ///   5. error → the FAILING command from the block model (the badge's `!<code>` carries the number);
    ///   6. the RUNNING command (a busy non-agent shell — the command text is what the row is doing).
    /// The command-shaped rungs (5–6) are dropped when they only echo `title`. Nothing live → `nil`:
    /// the tooltip carries no detail line — absence is the resting state, never a placeholder.
    /// Every input is pre-gated by the caller (only handed over when its state holds), so the resolver
    /// is a pure precedence ladder.
    static func resolve(
        question: String?,
        scent: String?,
        workingLabel: String?,
        doneLine: String?,
        errorLine: String?,
        commandLine: String? = nil,
        title: String = "",
    ) -> String? {
        if let question { return question }
        if let scent { return scent }
        if let workingLabel { return workingLabel }
        if let doneLine { return doneLine }
        if let errorLine, !echoesTitle(errorLine, title: title) { return errorLine }
        if let commandLine, !echoesTitle(commandLine, title: title) { return commandLine }
        return nil
    }

    /// Whether a command-shaped line would only REPEAT the title one line up: equal, or one is the
    /// other's leading word(s) (`npm` over `npm test` — the shell titled the pane by the command).
    /// Case-insensitive; word-bounded so `api` never swallows `apitool run`. Prose sources
    /// (question / scent / labels) are never gated — a sentence quoting the title is still news.
    static func echoesTitle(_ line: String, title: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !line.isEmpty, !title.isEmpty else { return false }
        return line == title || line.hasPrefix(title + " ") || title.hasPrefix(line + " ")
    }

    /// The error readout: the FAILING command (`npm test`) — the culprit's name; the exit code
    /// already rides the badge's `!<code>` reading one line up, so the pair never repeats a number.
    /// `nil` without a code (no failure evidence — the caller may not attribute a stale block) and
    /// `nil` for a blank command (the badge's reading stands alone).
    static func errorLine(exitCode: Int32?, commandText: String?) -> String? {
        guard exitCode != nil else { return nil }
        let command = commandText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? nil : command
    }
}
