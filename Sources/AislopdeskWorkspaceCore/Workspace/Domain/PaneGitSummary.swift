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
    /// Changed files (the porcelain line count — staged + worktree + untracked). Kept as the aggregate
    /// dirty count (search / "is this repo dirty" at a glance); the breakdown below drives the compact line.
    public var changedCount: Int
    /// The porcelain breakdown, derived from the per-file `XY` status codes (each counts INDEPENDENTLY —
    /// a `MM` file is BOTH staged and modified). `staged` = index has a change (X ≠ space, not untracked/
    /// conflict), `modified` = worktree has an unstaged change (Y ≠ space), `untracked` = `??`, `conflicted`
    /// = an unmerged state (`U` in X or Y, or `AA`/`DD`). Counts are bounded by the host's file-list cap.
    public var staged: Int
    public var modified: Int
    public var untracked: Int
    public var conflicted: Int
    /// The repo's stash depth (`git stash list` count) — repo-global, straight off the wire.
    public var stash: Int

    public init(
        hasRepo: Bool,
        branch: String,
        ahead: Int,
        behind: Int,
        changedCount: Int,
        staged: Int = 0,
        modified: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        stash: Int = 0,
    ) {
        self.hasRepo = hasRepo
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changedCount = changedCount
        self.staged = staged
        self.modified = modified
        self.untracked = untracked
        self.conflicted = conflicted
        self.stash = stash
    }

    /// Folds the wire payload down to the rail's needs (drops the file list / remote / toplevel), deriving
    /// the porcelain breakdown from each file's packed `XY` status code (high nibble = X / index, low = Y /
    /// worktree; space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9 — the ``HostMetadataProbe`` packing).
    public init(payload: MetadataCodec.GitStatusPayload) {
        var staged = 0, modified = 0, untracked = 0, conflicted = 0
        for file in payload.files {
            let x = file.statusCode >> 4, y = file.statusCode & 0x0F
            if x == 7, y == 7 {
                untracked += 1 // ??
            } else if x == 6 || y == 6 || (x == 2 && y == 2) || (x == 3 && y == 3) {
                conflicted += 1 // unmerged: U in either side, or the AA / DD both-changed states
            } else {
                if x != 0 { staged += 1 } // index change (X not space)
                if y != 0 { modified += 1 } // worktree change (Y not space)
            }
        }
        self.init(
            hasRepo: payload.hasRepo,
            branch: payload.branch,
            ahead: Int(payload.ahead),
            behind: Int(payload.behind),
            changedCount: payload.files.count,
            staged: staged,
            modified: modified,
            untracked: untracked,
            conflicted: conflicted,
            stash: Int(payload.stashCount),
        )
    }

    /// The rail's one-line rendering, each state a SINGLE sigil + count (oh-my-zsh vocabulary), space-
    /// separated and only present when non-zero: `↑`ahead `↓`behind `+`staged `!`modified `?`untracked
    /// `=`conflicts `$`stash. A clean tracking branch is JUST the branch (e.g. `main`); a busy one reads
    /// `main ↑1 +2 !3 ?1 $1`. `nil` when the cwd is not a repo — the row falls back to the plain cwd path.
    public var compactLine: String? {
        guard hasRepo else { return nil }
        var parts: [String] = [branch.isEmpty ? "detached" : branch]
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        if staged > 0 { parts.append("+\(staged)") }
        if modified > 0 { parts.append("!\(modified)") }
        if untracked > 0 { parts.append("?\(untracked)") }
        if conflicted > 0 { parts.append("=\(conflicted)") }
        if stash > 0 { parts.append("$\(stash)") }
        return parts.joined(separator: " ")
    }
}
