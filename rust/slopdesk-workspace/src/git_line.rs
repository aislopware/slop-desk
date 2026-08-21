//! The project header's git DIALECT — which runs a git line has, in what order, and what each one
//! means.
//!
//! `main ↑2 ↓1 +3 !4 ?5 ~1 $2` is a language, not a label. The branch comes first, then only the
//! NON-ZERO sigils in a fixed order, each carrying a role that decides its ink and its weight, and
//! a shedding ladder decides which of them give up their place when a real sidebar column runs out
//! of width. All of that is decision. None of it is drawing.
//!
//! ## Why a sigil is here and a string is not
//!
//! A run answers as a role, a SIGIL and a count — never as text. The sigil is the part that can be
//! got wrong: a dead second renderer in Swift spelled a conflict `=` where this one spells it `~`,
//! and the two disagreed for as long as both compiled. Concatenating `↑` with `2` is not a
//! decision anyone can disagree with, so it stays where the glyphs are already being laid out. The
//! branch run carries no sigil at all — it is a NAME, which is why it truncates instead of
//! compacting, and why its text is the caller's own string rather than anything this module holds.
//!
//! ## Why nothing here allocates
//!
//! A git line is at most [`MAX_RUNS`] runs and the ceiling is structural: one branch plus one per
//! count, and there are seven counts of which two share a role. [`GitRuns`] is that array and a
//! length, so the fold, the shed and the crossing all move the same fixed-size value — the sidebar
//! header re-folds its line on every git tick, and a `Vec` per tick would buy nothing back.

/// What one run of the git line MEANS — the axis its ink and weight are chosen on.
///
/// Roles, not colours: the palette belongs to whichever framework is drawing.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GitInk {
    /// The branch name — identity, not a count.
    Branch,
    /// `↑`/`↓` — where this branch sits against its upstream.
    Divergence,
    /// `+` — staged and ready to commit.
    Staged,
    /// `!` — unstaged worktree changes.
    Modified,
    /// `?` — files git does not know about yet.
    Untracked,
    /// `~` — an unmerged state. The one run that genuinely needs a human.
    Conflicted,
    /// `$` — parked work.
    Stash,
}

/// The three weights a run is set at.
///
/// A second channel the palette cannot supply, and the one that survives the hue set's CVD
/// collapse — under protanopia `+staged` and `~conflicted` land close enough to be
/// indistinguishable by hue alone.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GitWeight {
    /// The branch — identity, kept light so the counts read as a group.
    Regular,
    /// Every count. The readout, and thin at 10 pt mono unless it is set heavy.
    Semibold,
    /// A conflict alone. One rung further on IMPORTANCE, not on hue.
    Bold,
}

/// The counts one git line is folded from — the per-pane git state, with the branch NAME left
/// behind.
///
/// `detached` rather than the name itself: the only thing the dialect asks of a branch string is
/// whether it is empty, and carrying the bytes across a boundary to answer that would be a copy
/// per tick for one bit.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct GitCounts {
    /// Whether the pane's directory is inside a repository at all. `false` ⇒ there is no line.
    pub has_repo: bool,
    /// Whether HEAD is detached — an empty branch name on the near side.
    pub detached: bool,
    /// Commits ahead of the upstream; `0` when there is no upstream.
    pub ahead: u32,
    /// Commits behind it.
    pub behind: u32,
    /// Files whose INDEX has a change.
    pub staged: u32,
    /// Files whose WORKTREE has an unstaged one. A file can be both.
    pub modified: u32,
    /// Files git does not know about yet.
    pub untracked: u32,
    /// Files in an unmerged state.
    pub conflicted: u32,
    /// The repo's stash depth — repo-global, not per-file.
    pub stash: u32,
}

/// One run of the git line: its role, the glyph that opens it, and the number that follows.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GitRun {
    /// What this run means.
    pub ink: GitInk,
    /// The run's opening glyph, or `None` for the branch — which has no sigil, and therefore no
    /// compact form.
    pub sigil: Option<char>,
    /// The count the sigil introduces. Meaningless for the branch, and zero there.
    pub count: u32,
    /// Whether HEAD is detached. Set on the branch run only; the near side spells the fallback.
    pub detached: bool,
}

impl GitRun {
    /// The weight this run is set at, on three rungs.
    ///
    /// Every COUNT is set heavy: the sigil runs are the readout, and at 10 pt mono a regular weight
    /// leaves them thin enough that the colour is doing all the work. The BRANCH stays regular — it
    /// is the line's identity, not a status, and keeping it light is what lets the counts read as a
    /// group. `~conflicted` goes one rung further still, on IMPORTANCE: one of these seven states
    /// is the one that stops work, said in a channel free of the palette.
    #[must_use]
    pub const fn weight(self) -> GitWeight {
        match self.ink {
            GitInk::Branch => GitWeight::Regular,
            GitInk::Conflicted => GitWeight::Bold,
            GitInk::Divergence | GitInk::Modified | GitInk::Staged | GitInk::Stash | GitInk::Untracked => {
                GitWeight::Semibold
            },
        }
    }

    /// Whether this run is part of the READOUT rather than the line's identity — everything the
    /// compact form keeps and the ladder is allowed to shed.
    #[must_use]
    const fn is_status(self) -> bool {
        self.sigil.is_some()
    }
}

/// The most runs a git line can have: the branch, `↑`, `↓`, `+`, `!`, `?`, `~`, `$`.
pub const MAX_RUNS: usize = 8;

/// A git line's runs, in order.
///
/// A fixed array and a length rather than a `Vec`, for the reason this module's header gives.
/// Every operation on one answers another, so a fold, a compaction and a shed all cost the same
/// nothing.
#[derive(Clone, Copy, Debug)]
pub struct GitRuns {
    runs: [Option<GitRun>; MAX_RUNS],
    len: usize,
}

impl Default for GitRuns {
    fn default() -> Self {
        Self {
            runs: [None; MAX_RUNS],
            len: 0,
        }
    }
}

impl GitRuns {
    /// Appends one run, or drops it if the line is somehow already full. Never a panic: the ceiling
    /// is structural, so a full line here would be a bug in this file rather than bad input, and a
    /// sidebar that traps is worse than one missing a sigil.
    fn push(&mut self, run: GitRun) {
        if let Some(slot) = self.runs.get_mut(self.len) {
            *slot = Some(run);
            self.len += 1;
        }
    }

    /// Appends one run per non-zero count.
    fn push_count(&mut self, count: u32, sigil: char, ink: GitInk) {
        if count > 0 {
            self.push(GitRun {
                ink,
                sigil: Some(sigil),
                count,
                detached: false,
            });
        }
    }

    /// How many runs the line has.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Whether the line has no runs at all — a directory that is not a repository.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Every run in order.
    pub fn iter(&self) -> impl Iterator<Item = GitRun> + '_ {
        self.runs.iter().take(self.len).flatten().copied()
    }

    /// The READOUT alone — the branch dropped, which is the line's compact form: the counts go with
    /// their runs' text on the near side, the roles stay, so a squeezed line still says exactly
    /// WHICH states are live.
    #[must_use]
    pub fn status(&self) -> Self {
        let mut kept = Self::default();
        for run in self.iter().filter(|run| run.is_status()) {
            kept.push(run);
        }
        kept
    }

    /// Whether the line holds a run of this role.
    fn holds(&self, ink: GitInk) -> bool {
        self.iter().any(|run| run.ink == ink)
    }

    /// This line with every run of `ink` removed.
    fn without(&self, ink: GitInk) -> Self {
        let mut kept = Self::default();
        for run in self.iter().filter(|run| run.ink != ink) {
            kept.push(run);
        }
        kept
    }
}

/// The order the status runs GIVE UP their place when the branch runs out of room, least important
/// first.
///
/// It is a ranking of "how much does knowing this right now change what I do next": `$` stash is
/// work you parked on purpose. `↑↓` divergence is bookkeeping against a remote — unpushed commits
/// are safely committed, and pushing is a thing you do on your own schedule. `?` untracked is
/// usually build output and scratch files. Those three are worth a glance when there is room and
/// worth nothing when there isn't. What survives is the WORKTREE: `+staged`, `!modified`,
/// `~conflicted` — uncommitted work and broken merges, the states that decide whether this project
/// is safe to leave.
const SHED_LADDER: [GitInk; 6] = [
    GitInk::Stash,
    GitInk::Divergence,
    GitInk::Untracked,
    GitInk::Staged,
    GitInk::Modified,
    GitInk::Conflicted,
];

/// The git line SPLIT into its runs — one per sigil, in the dialect's fixed order.
///
/// The order is the one every git prompt theme already taught the eye: `↑`/`↓` divergence, `+`
/// staged, `!` modified, `?` untracked, `~` merge conflicts, `$` stash. Empty for a non-repo
/// summary, because a plain directory has no git concept to report.
#[must_use]
pub fn runs(counts: &GitCounts) -> GitRuns {
    let mut line = GitRuns::default();
    if !counts.has_repo {
        return line;
    }
    line.push(GitRun {
        ink: GitInk::Branch,
        sigil: None,
        count: 0,
        detached: counts.detached,
    });
    line.push_count(counts.ahead, '↑', GitInk::Divergence);
    line.push_count(counts.behind, '↓', GitInk::Divergence);
    line.push_count(counts.staged, '+', GitInk::Staged);
    line.push_count(counts.modified, '!', GitInk::Modified);
    line.push_count(counts.untracked, '?', GitInk::Untracked);
    line.push_count(counts.conflicted, '~', GitInk::Conflicted);
    line.push_count(counts.stash, '$', GitInk::Stash);
    line
}

/// The status runs left after giving up `level` RUNGS of [`SHED_LADDER`].
///
/// A rung is a ROLE, not a run: `↑` and `↓` are one fact about one remote and leave together, and a
/// role the line never had costs no rung — otherwise a clean-but-diverged repo would spend its
/// whole ladder shedding sigils it does not have, and the rungs would stop narrowing the readout.
///
/// The last runs standing are never shed: a git line that reports nothing is not a tighter readout,
/// it is a missing one. A repo whose only dirt is `↑2` keeps its `↑` however narrow the rail gets.
#[must_use]
pub fn shed(status: &GitRuns, level: usize) -> GitRuns {
    let mut kept = *status;
    let mut shed = 0;
    for ink in SHED_LADDER {
        if shed >= level {
            break;
        }
        if !kept.holds(ink) {
            continue; // the line never had this role
        }
        let remaining = kept.without(ink);
        if remaining.is_empty() {
            break; // shedding it would leave nothing to read
        }
        kept = remaining;
        shed += 1;
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::{GitCounts, GitInk, GitWeight, MAX_RUNS, runs, shed};

    fn busy() -> GitCounts {
        GitCounts {
            has_repo: true,
            detached: false,
            ahead: 2,
            behind: 1,
            staged: 3,
            modified: 4,
            untracked: 5,
            conflicted: 6,
            stash: 7,
        }
    }

    /// The written form a near side would spell, so the order and the sigils are readable in one
    /// assertion rather than seven.
    fn spelled(line: &super::GitRuns) -> Vec<String> {
        line.iter()
            .map(|run| {
                match run.sigil {
                    Some(sigil) => format!("{sigil}{}", run.count),
                    None if run.detached => "detached".to_owned(),
                    None => "main".to_owned(),
                }
            })
            .collect()
    }

    #[test]
    fn every_non_zero_count_gets_its_sigil_in_dialect_order() {
        assert_eq!(spelled(&runs(&busy())), [
            "main", "↑2", "↓1", "+3", "!4", "?5", "~6", "$7"
        ]);
        assert_eq!(runs(&busy()).len(), MAX_RUNS);
    }

    #[test]
    fn a_clean_repo_is_its_branch_alone_and_a_plain_directory_is_nothing() {
        let clean = GitCounts {
            has_repo: true,
            ..GitCounts::default()
        };
        assert_eq!(spelled(&runs(&clean)), ["main"]);
        assert!(runs(&GitCounts::default()).is_empty());
    }

    #[test]
    fn a_detached_head_is_flagged_rather_than_named() {
        let detached = GitCounts {
            has_repo: true,
            detached: true,
            ..GitCounts::default()
        };
        assert_eq!(spelled(&runs(&detached)), ["detached"]);
    }

    #[test]
    fn the_branch_is_the_one_run_with_no_sigil_and_the_status_form_drops_it() {
        let line = runs(&busy());
        assert_eq!(line.status().len(), line.len() - 1);
        assert!(line.status().iter().all(super::GitRun::is_status));
    }

    #[test]
    fn counts_are_heavy_the_branch_is_not_and_a_conflict_is_heavier_still() {
        let line = runs(&busy());
        let weight = |ink: GitInk| line.iter().find(|run| run.ink == ink).map(super::GitRun::weight);
        assert_eq!(weight(GitInk::Branch), Some(GitWeight::Regular));
        assert_eq!(weight(GitInk::Conflicted), Some(GitWeight::Bold));
        for ink in [
            GitInk::Divergence,
            GitInk::Staged,
            GitInk::Modified,
            GitInk::Untracked,
            GitInk::Stash,
        ] {
            assert_eq!(weight(ink), Some(GitWeight::Semibold), "{ink:?} is a count");
        }
    }

    #[test]
    fn each_rung_sheds_one_role_and_divergence_leaves_as_a_pair() {
        let status = runs(&busy()).status();
        let sigils = |level| {
            shed(&status, level)
                .iter()
                .filter_map(|run| run.sigil)
                .collect::<String>()
        };
        assert_eq!(sigils(0), "↑↓+!?~$");
        assert_eq!(sigils(1), "↑↓+!?~");
        assert_eq!(sigils(2), "+!?~");
        assert_eq!(sigils(3), "+!~");
    }

    #[test]
    fn a_role_the_line_never_had_costs_no_rung() {
        let no_stash = GitCounts {
            has_repo: true,
            modified: 4,
            untracked: 5,
            ..GitCounts::default()
        };
        let status = runs(&no_stash).status();
        // Rung one is the stash, which this line does not have — so it spends the rung on the next
        // role it DOES have rather than on nothing.
        assert_eq!(
            shed(&status, 1)
                .iter()
                .filter_map(|run| run.sigil)
                .collect::<String>(),
            "!"
        );
    }

    #[test]
    fn the_last_run_standing_is_never_shed() {
        let only_ahead = GitCounts {
            has_repo: true,
            ahead: 2,
            ..GitCounts::default()
        };
        let status = runs(&only_ahead).status();
        assert_eq!(
            shed(&status, 99)
                .iter()
                .filter_map(|run| run.sigil)
                .collect::<String>(),
            "↑"
        );
    }
}
