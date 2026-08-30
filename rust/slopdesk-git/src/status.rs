//! The whole answer for one directory, from one opened repository.
//!
//! Four subprocesses became four method calls on one handle. What is gone with them is not only the
//! spawns: `git status --porcelain -b` also had to be PARSED — a branch header with a bracket in
//! it, a rename arrow inside a path, a count that might not be a number — and every one of those
//! parses was a place to be wrong about someone else's repository.
//!
//! ## Best-effort, question by question
//!
//! Seven questions share one answer struct and they fail INDEPENDENTLY. A branch with no upstream
//! has no divergence, a repository with no `origin` has no remote URL, a bare repository has no
//! worktree — none of those is an error, and none of them may cost the other six their answers.
//! This is the behaviour the four subprocesses already had (each was `capture_text(...)` with a
//! `None` fallback), kept deliberately rather than tightened: the metadata RPC has ONE reply for
//! "could not tell", so distinguishing the causes would only be a distinction the caller discards.
//!
//! ## What is deliberately NOT here
//!
//! Ignored files. `git status --porcelain` without `--ignored` does not list them, so
//! [`StatusOptions::include_ignored`] stays false and the `!` nibble is a table entry nothing
//! currently emits. Turning it on would change a count the wire is pinned to.

use std::path::Path;

use git2::{ErrorCode, Repository, RepositoryOpenFlags, StatusOptions, StatusShow};
use slopdesk_wire::metadata::{GitFileChange, GitStatusPayload};

use crate::porcelain;

/// The changed-file cap.
///
/// A second backstop under the frame builder's own: a repository mid-rebase with a hundred thousand
/// touched paths must not be able to build a frame nobody can send. Unchanged from the subprocess
/// era, and it is a cap on the ENTRIES kept rather than on the walk — libgit2 has already visited
/// the worktree by the time the list is iterable, so stopping early saves the copies, not the scan.
pub const MAX_FILES: usize = 4096;

/// The full status of `path`.
///
/// Discovery walks UP from `path` the way `git` itself does, and stops at a filesystem boundary —
/// a pane sitting in a directory that is not a repository must not find one three mounts above it.
/// A path that is not in a repository answers [`GitStatusPayload::no_repo`], which is the same
/// answer a missing `git` binary used to give and means the same thing.
#[must_use]
pub fn of_path(path: &str) -> GitStatusPayload {
    // `RepositoryOpenFlags::empty()` is the searching open — `NO_SEARCH` would require `path` to be
    // the repository itself, and a pane's directory is usually a subdirectory of one.
    let Ok(repository) = Repository::open_ext(
        Path::new(path),
        RepositoryOpenFlags::empty(),
        Vec::<String>::new(),
    ) else {
        return GitStatusPayload::no_repo();
    };
    let mut status = GitStatusPayload {
        has_repo: true,
        ..GitStatusPayload::no_repo()
    };
    read_head(&repository, &mut status);
    status.remote_url = remote_url(&repository);
    status.repo_root = repository
        .workdir()
        .and_then(|root| root.to_str())
        .map(|root| root.trim_end_matches('/').to_owned())
        .unwrap_or_default();
    status.stash_count = stash_depth(&repository);
    status.files = changed_files(&repository);
    status
}

/// The branch name and the divergence from its upstream.
///
/// Both come off HEAD, and both are absent in ordinary situations rather than exceptional ones: a
/// detached HEAD has no name, and a freshly-created branch has no upstream to be ahead of. An
/// UNBORN head — a repository initialised but never committed to — is the one case where `head()`
/// itself fails, and it is a real repository with a real branch name, so the name is recovered from
/// the reference HEAD points at rather than being lost with the error.
fn read_head(repository: &Repository, status: &mut GitStatusPayload) {
    let head = match repository.head() {
        Ok(head) => head,
        Err(error) => {
            if error.code() == ErrorCode::UnbornBranch {
                status.branch = unborn_branch(repository);
            }
            return;
        },
    };
    if !head.is_branch() {
        return; // detached: there is no name to show
    }
    let Ok(name) = head.shorthand() else {
        return;
    };
    name.clone_into(&mut status.branch);

    let Some(local) = head.target() else {
        return;
    };
    let Ok(upstream) = repository
        .find_branch(name, git2::BranchType::Local)
        .and_then(|branch| branch.upstream())
    else {
        return; // no tracking branch — divergence is not a question this repo can answer
    };
    let Some(upstream_id) = upstream.get().target() else {
        return;
    };
    if let Ok((ahead, behind)) = repository.graph_ahead_behind(local, upstream_id) {
        status.ahead = i32::try_from(ahead).unwrap_or(i32::MAX);
        status.behind = i32::try_from(behind).unwrap_or(i32::MAX);
    }
}

/// The branch name of an UNBORN head, read from the symbolic reference itself.
///
/// `git status` prints `## main...` for a repository with no commits, and the sidebar should say
/// `main` there too — the alternative reads as a detached HEAD, which is a different and alarming
/// state.
fn unborn_branch(repository: &Repository) -> String {
    repository
        .find_reference("HEAD")
        .ok()
        .and_then(|head| head.symbolic_target().ok().flatten().map(str::to_owned))
        .and_then(|target| target.strip_prefix("refs/heads/").map(ToOwned::to_owned))
        .unwrap_or_default()
}

/// The `origin` remote's FETCH url, or empty.
///
/// Fetch rather than push, matching `git remote get-url origin`'s default: a repository that pushes
/// somewhere else still IDENTIFIES as the place it fetches from, which is what this string is used
/// for.
fn remote_url(repository: &Repository) -> String {
    repository
        .find_remote("origin")
        .ok()
        .and_then(|remote| remote.url().ok().map(str::to_owned))
        .unwrap_or_default()
}

/// The stash depth.
///
/// A walk rather than a read, because there is no count to read: a stash is a reflog on
/// `refs/stash` and its depth is how many entries that log has. The walk is bounded by the depth
/// itself — tens of entries at the very worst — not by history, so it is a cheap walk rather than
/// an expensive one.
///
/// `stash_foreach` needs a MUTABLE repository handle, which is why this takes the handle apart
/// rather than borrowing it: opening the same path a second time costs one `.git` read and keeps
/// every other question on an immutable borrow that can be held across the whole answer.
fn stash_depth(repository: &Repository) -> i32 {
    let Ok(mut owned) = Repository::open(repository.path()) else {
        return 0;
    };
    let mut depth: i32 = 0;
    // The callback's `true` means "keep going". Saturating rather than wrapping: a stash nobody
    // could have made is still better reported as a very large number than as a negative one.
    let walked = owned.stash_foreach(|_, _, _| {
        depth = depth.saturating_add(1);
        true
    });
    if walked.is_err() { 0 } else { depth }
}

/// One entry per changed path, with its porcelain pair packed.
///
/// Renames are detected on BOTH axes because porcelain detects them on both, and the similarity
/// threshold is left at libgit2's default so it tracks `diff.renames` the way `git status` does.
/// Turning detection off would be the visible difference: a rename would arrive as a delete and an
/// add, which is two rows in the sidebar's count where a person sees one move.
fn changed_files(repository: &Repository) -> Vec<GitFileChange> {
    let conflicts = conflict_pairs(repository);
    let mut options = StatusOptions::new();
    options
        .show(StatusShow::IndexAndWorkdir)
        .include_untracked(true)
        // `git status --porcelain` lists an untracked DIRECTORY as one entry, not as its contents.
        .recurse_untracked_dirs(false)
        // Not `--ignored`, so these stay out — see this module's header.
        .include_ignored(false)
        .include_unmodified(false)
        .renames_head_to_index(true)
        .renames_index_to_workdir(true);
    let Ok(entries) = repository.statuses(Some(&mut options)) else {
        return Vec::new();
    };

    let mut files = Vec::new();
    for entry in entries.iter() {
        if files.len() >= MAX_FILES {
            break;
        }
        // The NEW path, for a rename as for anything else: `index_to_workdir` describes the
        // worktree's current name and is consulted first for exactly that reason.
        //
        // Bytes rather than `&str` on every rung, because a path is not required to be UTF-8 and a
        // file that cannot be spelled must still be COUNTED — the git line's number is the point.
        // Lossy is what the subprocess era produced too: `git` wrote raw bytes with
        // `core.quotepath=false` and the reader decoded them the same way.
        let path = entry
            .index_to_workdir()
            .and_then(|delta| delta.new_file().path_bytes())
            .or_else(|| {
                entry
                    .head_to_index()
                    .and_then(|delta| delta.new_file().path_bytes())
            })
            .map_or_else(
                || String::from_utf8_lossy(entry.path_bytes()).into_owned(),
                |bytes| String::from_utf8_lossy(bytes).into_owned(),
            );
        if path.is_empty() {
            continue;
        }
        let flags = entry.status();
        // A conflict is not a bitflag pair — the stages say which of the seven it is, and the flag
        // only says that it is one of them.
        let (x, y) = if flags.contains(git2::Status::CONFLICTED) {
            conflicts
                .iter()
                .find(|(name, _)| *name == path)
                .map_or(('U', 'U'), |(_, pair)| *pair)
        } else {
            porcelain::pair(flags)
        };
        files.push(GitFileChange {
            status_code: porcelain::pack(x, y),
            path,
        });
    }
    files
}

/// Every unmerged path's `XY` pair, read from which index stages it has.
///
/// Collected once per answer rather than per entry: the conflict iterator walks the index, and a
/// status list with a hundred conflicted paths would otherwise walk it a hundred times.
fn conflict_pairs(repository: &Repository) -> Vec<(String, (char, char))> {
    let Ok(index) = repository.index() else {
        return Vec::new();
    };
    let Ok(conflicts) = index.conflicts() else {
        return Vec::new();
    };
    conflicts
        .filter_map(Result::ok)
        .filter_map(|conflict| {
            // The path is on whichever stage exists; all present stages carry the same one.
            let path = conflict
                .our
                .as_ref()
                .or(conflict.their.as_ref())
                .or(conflict.ancestor.as_ref())
                .map(|entry| String::from_utf8_lossy(&entry.path).into_owned())?;
            Some((
                path,
                porcelain::unmerged(
                    conflict.ancestor.is_some(),
                    conflict.our.is_some(),
                    conflict.their.is_some(),
                ),
            ))
        })
        .collect()
}
