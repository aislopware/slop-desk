// GitInk — what one run of the project header's git line MEANS.
//
// The DIALECT is `SlopDeskClientCore/Rail/SidebarGitLine.swift`, which asks
// `slopdesk_workspace::git_line` for the runs and spells each one. Only the ROLE descended, and only
// because `SlopDeskSlate` resolves it to an ink (`Slate.Native.gitInk(_:)`): the design floor may
// name the axis a hue is chosen on without naming the whole navigator reading that produces it.
//
// Roles, not colours. The palette resolution belongs to whichever framework is drawing, and the
// second channel a role carries — ``GitWeight`` — stays with the dialect, because a weight is
// something the RULE fills in on the crossing rather than something a renderer looks up.

/// What one run of the git line MEANS — the axis its ink and weight are chosen on.
package enum GitInk: CaseIterable, Sendable {
    /// The branch name — identity, not a count.
    case branch
    /// `↑`/`↓` — where this branch sits against its upstream.
    case divergence
    /// `+` — staged and ready to commit.
    case staged
    /// `!` — unstaged worktree changes.
    case modified
    /// `?` — files git does not know about yet.
    case untracked
    /// `~` — an unmerged state. The one run that genuinely needs a human.
    case conflicted
    /// `$` — parked work.
    case stash
}
