// PaneGitSummary — the per-pane git state the sidebar tab row renders as its SECOND LINE (branch +
// ahead/behind + the porcelain breakdown), folded from the E4 `gitStatus` metadata RPC. The full Git
// details surfaces (the inspector tab, then the auxiliary Git window) are REMOVED — the one line in
// the rail is the git surface now, so this lives as a pure domain value (headlessly pinnable) and the
// store keeps a per-pane mirror refreshed on command completion / cwd change / connect.
//
// A VALUE, NOT A RENDERING. It used to carry a `compactLine` that folded itself into one string, and
// that was a SECOND renderer for the one surface: `SidebarGitLine.segments` is what the rail actually
// draws, it emits per-segment ink rather than a flat string, and the two disagreed on a sigil (`~` vs
// `=` for a conflict) for as long as both compiled. Nothing outside its own tests ever called it, so
// the tests were the only thing keeping the wrong spelling alive — both are gone (docs/56 increment
// 45). Anything that needs a git line reads the counts here and renders them where it draws.

import SlopDeskProtocol

/// The folded git state of one pane's working directory. A pure value — `Equatable` so the store's
/// mirror write is dirty-guarded (no `@Observable` churn when nothing changed).
public struct PaneGitSummary: Equatable, Sendable {
    /// Whether the pane's cwd is inside a git repository. `false` ⇒ the rail falls back to the plain
    /// cwd subtitle instead of drawing a git line.
    public var hasRepo: Bool
    /// The current branch name (empty = detached HEAD).
    public var branch: String
    /// Commits ahead of / behind the upstream (0 when no upstream).
    public var ahead: Int
    public var behind: Int
    /// Changed files (the porcelain line count — staged + worktree + untracked). Kept as the aggregate
    /// dirty count (search / "is this repo dirty" at a glance); the breakdown below drives the rail's line.
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

    /// Folds the wire payload down to the rail's needs (drops the file list / remote / toplevel) via
    /// the shared porcelain fold (``MetadataCodec/GitStatusPayload/foldedCounts`` — one rule for the
    /// RPC pull and the host's type-35 push alike).
    public init(payload: MetadataCodec.GitStatusPayload) {
        let counts = payload.foldedCounts
        self.init(
            hasRepo: payload.hasRepo,
            branch: payload.branch,
            ahead: Int(payload.ahead),
            behind: Int(payload.behind),
            changedCount: payload.files.count,
            staged: counts.staged,
            modified: counts.modified,
            untracked: counts.untracked,
            conflicted: counts.conflicted,
            stash: Int(payload.stashCount),
        )
    }

    /// Folds a HOST-PUSHED type-35 summary (wire ``WireMessage/ProjectGitStatus`` — counts already
    /// folded host-side by the same shared rule). A push only ever describes a repo (`hasRepo` true
    /// by construction: the watcher watches repo toplevels).
    public init(pushed status: WireMessage.ProjectGitStatus) {
        self.init(
            hasRepo: true,
            branch: status.branch,
            ahead: Int(status.ahead),
            behind: Int(status.behind),
            changedCount: Int(status.changedCount),
            staged: Int(status.staged),
            modified: Int(status.modified),
            untracked: Int(status.untracked),
            conflicted: Int(status.conflicted),
            stash: Int(status.stashCount),
        )
    }
}
