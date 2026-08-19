//! The project header's git dialect, in C.
//!
//! The rules are `slopdesk_workspace::git_line`; what is here is the marshalling. Two doors, both
//! filling a caller's array of fixed-size records — no arena, no spans, nothing borrowed back.
//!
//! ## Why no text crosses
//!
//! Every other list door in this crate hands text over through a blob, because its records ARE
//! text. A git run is not: it is a role, one glyph and a number. The glyph crosses as its Unicode
//! scalar and the number as itself, so the near side spells `↑` beside `2` where it is already
//! laying out glyphs. What the near side may never do is CHOOSE the glyph — a dead second Swift
//! renderer once spelled a conflict `=` against this dialect's `~`, and both compiled for months.
//!
//! ## Why the buffer is the caller's
//!
//! A line is at most [`SLOPDESK_GIT_MAX_RUNS`] runs, structurally, so both doors are answered from
//! a stack array on the near side too. Neither can overflow one: they write at most `cap` records
//! and return how many there were, which is §4's protocol at a size that never needs the retry.

use slopdesk_workspace::git_line::{self, GitCounts, GitInk, GitRun, GitRuns, GitWeight, MAX_RUNS};

/// The most runs one git line can have — the branch plus one per non-zero count.
pub const SLOPDESK_GIT_MAX_RUNS: usize = MAX_RUNS;

/// The role of a run whose text is the BRANCH NAME.
pub const SLOPDESK_GIT_INK_BRANCH: u8 = 0;
/// `↑`/`↓` against the upstream.
pub const SLOPDESK_GIT_INK_DIVERGENCE: u8 = 1;
/// `+` staged.
pub const SLOPDESK_GIT_INK_STAGED: u8 = 2;
/// `!` unstaged worktree changes.
pub const SLOPDESK_GIT_INK_MODIFIED: u8 = 3;
/// `?` untracked.
pub const SLOPDESK_GIT_INK_UNTRACKED: u8 = 4;
/// `~` unmerged.
pub const SLOPDESK_GIT_INK_CONFLICTED: u8 = 5;
/// `$` stash depth.
pub const SLOPDESK_GIT_INK_STASH: u8 = 6;

/// The branch's weight.
pub const SLOPDESK_GIT_WEIGHT_REGULAR: u8 = 0;
/// Every count's.
pub const SLOPDESK_GIT_WEIGHT_SEMIBOLD: u8 = 1;
/// A conflict's.
pub const SLOPDESK_GIT_WEIGHT_BOLD: u8 = 2;

/// What [`SlopDeskGitRun::sigil`] holds for the branch, which has none.
pub const SLOPDESK_GIT_NO_SIGIL: u32 = 0;

/// The counts one git line is folded from, with the branch NAME left on the near side.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskGitCounts {
    /// Whether the directory is inside a repository at all.
    pub has_repo: bool,
    /// Whether HEAD is detached — an empty branch name on the near side.
    pub detached: bool,
    /// Commits ahead of the upstream.
    pub ahead: u32,
    /// Commits behind it.
    pub behind: u32,
    /// Files whose index has a change.
    pub staged: u32,
    /// Files whose worktree has an unstaged one.
    pub modified: u32,
    /// Files git does not know about yet.
    pub untracked: u32,
    /// Files in an unmerged state.
    pub conflicted: u32,
    /// The repo's stash depth.
    pub stash: u32,
}

/// One run of the line: what it means, how it is set, and what it says.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SlopDeskGitRun {
    /// One of the `SLOPDESK_GIT_INK_*` roles.
    pub ink: u8,
    /// One of the `SLOPDESK_GIT_WEIGHT_*` rungs, carried alongside so a caller laying out one run
    /// never asks twice for the same run.
    pub weight: u8,
    /// The run's opening glyph as a Unicode scalar, or [`SLOPDESK_GIT_NO_SIGIL`] for the branch.
    pub sigil: u32,
    /// The count the sigil introduces; zero on the branch, which has none.
    pub count: u32,
    /// Whether HEAD is detached. Set on the branch run alone.
    pub detached: bool,
}

impl From<SlopDeskGitCounts> for GitCounts {
    fn from(counts: SlopDeskGitCounts) -> Self {
        Self {
            has_repo: counts.has_repo,
            detached: counts.detached,
            ahead: counts.ahead,
            behind: counts.behind,
            staged: counts.staged,
            modified: counts.modified,
            untracked: counts.untracked,
            conflicted: counts.conflicted,
            stash: counts.stash,
        }
    }
}

impl From<GitRun> for SlopDeskGitRun {
    fn from(run: GitRun) -> Self {
        Self {
            ink: ink_wire(run.ink),
            weight: weight_wire(run.weight()),
            sigil: run.sigil.map_or(SLOPDESK_GIT_NO_SIGIL, u32::from),
            count: run.count,
            detached: run.detached,
        }
    }
}

const fn ink_wire(ink: GitInk) -> u8 {
    match ink {
        GitInk::Branch => SLOPDESK_GIT_INK_BRANCH,
        GitInk::Divergence => SLOPDESK_GIT_INK_DIVERGENCE,
        GitInk::Staged => SLOPDESK_GIT_INK_STAGED,
        GitInk::Modified => SLOPDESK_GIT_INK_MODIFIED,
        GitInk::Untracked => SLOPDESK_GIT_INK_UNTRACKED,
        GitInk::Conflicted => SLOPDESK_GIT_INK_CONFLICTED,
        GitInk::Stash => SLOPDESK_GIT_INK_STASH,
    }
}

const fn weight_wire(weight: GitWeight) -> u8 {
    match weight {
        GitWeight::Regular => SLOPDESK_GIT_WEIGHT_REGULAR,
        GitWeight::Semibold => SLOPDESK_GIT_WEIGHT_SEMIBOLD,
        GitWeight::Bold => SLOPDESK_GIT_WEIGHT_BOLD,
    }
}

/// Writes as much of `line` as fits and answers how many runs it HAS.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`SlopDeskGitRun`]s for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's array IS the boundary this module documents"
)]
unsafe fn place(line: &GitRuns, out: *mut SlopDeskGitRun, cap: usize) -> usize {
    if out.is_null() {
        return line.len();
    }
    for (index, run) in line.iter().take(cap).enumerate() {
        // SAFETY: `index < cap` by the `take`, and the caller's obligation makes `out` writable for
        // `cap` records for this call.
        unsafe { out.add(index).write(SlopDeskGitRun::from(run)) };
    }
    line.len()
}

/// The runs `counts` folds to, in dialect order. Answers how many there are; a non-repo summary is
/// zero, because a plain directory has no git concept to report.
///
/// # Safety
/// `counts` must be null or one live [`SlopDeskGitCounts`], and `out` null or writable for `cap`
/// [`SlopDeskGitRun`]s — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_git_line_runs(
    counts: *const SlopDeskGitCounts,
    out: *mut SlopDeskGitRun,
    cap: usize,
) -> usize {
    if counts.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let counts = unsafe { *counts };
    let line = git_line::runs(&counts.into());
    // SAFETY: the caller's obligation on `out` is this function's, restated on `place`.
    unsafe { place(&line, out, cap) }
}

/// The READOUT alone — the branch dropped — after giving up `level` rungs of the shed ladder.
///
/// Folded from the same counts rather than from a caller's run array: a run list handed back would
/// have to be validated field by field to be trusted, and the counts it was folded from are three
/// words the caller is already holding. Answers how many runs survive.
///
/// # Safety
/// The same obligation [`slopdesk_git_line_runs`] carries, on the same two pointers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_git_line_shed(
    counts: *const SlopDeskGitCounts,
    level: usize,
    out: *mut SlopDeskGitRun,
    cap: usize,
) -> usize {
    if counts.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let counts = unsafe { *counts };
    let line = git_line::runs(&counts.into());
    // SAFETY: the caller's obligation on `out` is this function's, restated on `place`.
    unsafe { place(&git_line::shed(&line.status(), level), out, cap) }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    unsafe_code,
    reason = "calling the boundary IS what these tests are for, and a door that answered a short line has \
              already failed — the panic IS the assertion"
)]
mod tests {
    use super::{
        SLOPDESK_GIT_INK_BRANCH, SLOPDESK_GIT_INK_CONFLICTED, SLOPDESK_GIT_MAX_RUNS, SLOPDESK_GIT_NO_SIGIL,
        SLOPDESK_GIT_WEIGHT_BOLD, SLOPDESK_GIT_WEIGHT_REGULAR, SlopDeskGitCounts, SlopDeskGitRun,
        slopdesk_git_line_runs, slopdesk_git_line_shed,
    };

    fn busy() -> SlopDeskGitCounts {
        SlopDeskGitCounts {
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

    fn empty() -> [SlopDeskGitRun; SLOPDESK_GIT_MAX_RUNS] {
        [SlopDeskGitRun {
            ink: 0,
            weight: 0,
            sigil: 0,
            count: 0,
            detached: false,
        }; SLOPDESK_GIT_MAX_RUNS]
    }

    /// The written line, spelled the way a near side spells it.
    fn spelled(runs: &[SlopDeskGitRun]) -> String {
        runs.iter()
            .map(|run| {
                // The sentinel is tested BEFORE the decode: NUL is a scalar like any other, so
                // `char::from_u32(0)` answers `Some('\0')` and would spell a branch as a blank.
                if run.sigil == SLOPDESK_GIT_NO_SIGIL {
                    return "main".to_owned();
                }
                char::from_u32(run.sigil)
                    .map_or_else(|| "?".to_owned(), |sigil| format!("{sigil}{}", run.count))
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn the_whole_dialect_crosses_as_glyphs_and_numbers() {
        let counts = busy();
        let mut runs = empty();
        // SAFETY: both pointers name live locals for the duration of the call.
        let written = unsafe { slopdesk_git_line_runs(&raw const counts, runs.as_mut_ptr(), runs.len()) };
        assert_eq!(written, SLOPDESK_GIT_MAX_RUNS);
        assert_eq!(spelled(&runs), "main ↑2 ↓1 +3 !4 ?5 ~6 $7");
        assert_eq!(runs[0].ink, SLOPDESK_GIT_INK_BRANCH);
        assert_eq!(runs[0].sigil, SLOPDESK_GIT_NO_SIGIL);
        assert_eq!(runs[0].weight, SLOPDESK_GIT_WEIGHT_REGULAR);
        let conflict = runs
            .iter()
            .find(|run| run.ink == SLOPDESK_GIT_INK_CONFLICTED)
            .expect("the busy line has a conflict");
        assert_eq!(conflict.weight, SLOPDESK_GIT_WEIGHT_BOLD);
    }

    #[test]
    fn the_shed_door_drops_the_branch_and_then_the_ladder() {
        let counts = busy();
        let mut runs = empty();
        // SAFETY: both pointers name live locals for the duration of the call.
        let written = unsafe { slopdesk_git_line_shed(&raw const counts, 2, runs.as_mut_ptr(), runs.len()) };
        assert_eq!(spelled(&runs[..written]), "+3 !4 ?5 ~6");
    }

    #[test]
    fn a_null_summary_is_no_line_and_a_null_buffer_still_counts() {
        let counts = busy();
        // SAFETY: a null pair is exactly what the doors are documented to accept.
        unsafe {
            assert_eq!(
                slopdesk_git_line_runs(core::ptr::null(), core::ptr::null_mut(), 0),
                0
            );
            assert_eq!(
                slopdesk_git_line_runs(&raw const counts, core::ptr::null_mut(), 0),
                SLOPDESK_GIT_MAX_RUNS
            );
        }
    }

    #[test]
    fn a_short_buffer_takes_what_fits_and_reports_the_whole_length() {
        let counts = busy();
        let mut runs = empty();
        // SAFETY: the pointer names a live local, and `cap` under-reports it on purpose.
        let written = unsafe { slopdesk_git_line_runs(&raw const counts, runs.as_mut_ptr(), 3) };
        assert_eq!(written, SLOPDESK_GIT_MAX_RUNS);
        assert_eq!(spelled(&runs[..3]), "main ↑2 ↓1");
    }
}
