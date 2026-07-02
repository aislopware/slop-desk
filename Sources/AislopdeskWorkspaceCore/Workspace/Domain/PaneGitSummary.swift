// PaneGitSummary — the compact per-pane git state the sidebar tab row renders as its SECOND LINE
// (branch + ahead/behind + changed-file count), folded from the E4 `gitStatus` metadata RPC. The full
// Git details surfaces (the inspector tab, then the auxiliary Git window) are REMOVED — this one-line
// summary in the rail is the git surface now, so it lives as a pure domain value (headlessly pinnable)
// and the store keeps a per-pane mirror refreshed on command completion / cwd change / connect.

import AislopdeskProtocol

/// The folded git state of one pane's working directory. A pure value — `Equatable` so the store's
/// mirror write is dirty-guarded (no `@Observable` churn when nothing changed).
public struct PaneGitSummary: Equatable, Sendable {
    /// Whether the pane's cwd is inside a git repository. `false` ⇒ ``compactLine`` is `nil` and the
    /// rail falls back to the plain cwd subtitle.
    public var hasRepo: Bool
    /// The current branch name (empty = detached HEAD).
    public var branch: String
    /// Commits ahead of / behind the upstream (0 when no upstream).
    public var ahead: Int
    public var behind: Int
    /// Changed files (the porcelain line count — staged + worktree + untracked).
    public var changedCount: Int

    public init(hasRepo: Bool, branch: String, ahead: Int, behind: Int, changedCount: Int) {
        self.hasRepo = hasRepo
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changedCount = changedCount
    }

    /// Folds the wire payload down to the rail's needs (drops the file list / remote / toplevel).
    public init(payload: MetadataCodec.GitStatusPayload) {
        self.init(
            hasRepo: payload.hasRepo,
            branch: payload.branch,
            ahead: Int(payload.ahead),
            behind: Int(payload.behind),
            changedCount: payload.files.count,
        )
    }

    /// The rail's one-line rendering: `main` (clean) / `main ↑1 ↓2 · 3 changed` (diverged + dirty) /
    /// `detached …` (empty branch). `nil` when the cwd is not a repo — the row then falls back to the
    /// plain cwd path, never a blank second line.
    public var compactLine: String? {
        guard hasRepo else { return nil }
        var parts: [String] = [branch.isEmpty ? "detached" : branch]
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        var line = parts.joined(separator: " ")
        if changedCount > 0 { line += " · \(changedCount) changed" }
        return line
    }
}
