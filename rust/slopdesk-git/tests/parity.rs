//! Differential parity: every answer, against the `git` binary that used to give it.
//!
//! This crate replaced four subprocess invocations, and the byte those invocations produced is
//! pinned in `golden/golden_vectors.json`. So the test is not "does libgit2 work" — it is "does
//! libgit2, driven this way, say what `git` says", asked once per repository shape the sidebar can
//! actually meet.
//!
//! ## The oracle is the BINARY, not a second parser
//!
//! What this file spells is porcelain's GRAMMAR — an `XY` pair, one space, a path; a `## ` header
//! with the counts in a bracket — and nothing about how the old probe used to read it. Copying that
//! probe's parser in here would leave a mirror of a deleted implementation behind forever, which is
//! exactly what the one-implementation rule is against. Where the two disagree deliberately, the
//! disagreement is asserted rather than smoothed over; see [`an_unborn_head_reads_as_its_branch`].
//!
//! ## Why these fixtures
//!
//! Each is a shape that produces a status a DIFFERENT way, not a different amount of the same one:
//! a rename is detected rather than listed, a conflict comes off index stages rather than bitflags,
//! a stash is a reflog, divergence is a graph walk, an unborn head is the case where `head()`
//! itself fails. Adding a second modified file to any of them would test nothing the first one did
//! not.

#![expect(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::path::{Path, PathBuf};
use std::process::Command;

use slopdesk_git::{of_path, porcelain};
use slopdesk_wire::metadata::GitStatusPayload;

/// Where `git` is, matching the absolute path the probe used: a `git` earlier on someone's `PATH`
/// is not the one an operator means when they ask what their repository looks like.
const GIT: &str = "/usr/bin/git";

// ---------------------------------------------------------------------------------------------
// The scratch repository

/// A repository under the system temp directory, removed on drop.
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    /// Creates an initialised repository with one commit and a deterministic identity.
    ///
    /// `name` makes the directory unique WITHIN a run — the process id makes it unique between
    /// runs, and together they let the whole suite run concurrently without a shared counter.
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("slopdesk-git-parity-{}-{name}", std::process::id()));
        drop(std::fs::remove_dir_all(&root));
        std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
        let fixture = Self { root };
        fixture.git(&["init", "--initial-branch=main"]);
        fixture.git(&["config", "user.name", "Parity"]);
        fixture.git(&["config", "user.email", "parity@example.invalid"]);
        fixture
    }

    /// An initialised repository with NO commit — the unborn head.
    fn unborn(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("slopdesk-git-parity-{}-{name}", std::process::id()));
        drop(std::fs::remove_dir_all(&root));
        std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
        let fixture = Self { root };
        fixture.git(&["init", "--initial-branch=main"]);
        fixture.git(&["config", "user.name", "Parity"]);
        fixture.git(&["config", "user.email", "parity@example.invalid"]);
        fixture
    }

    fn path(&self) -> &str {
        self.root.to_str().expect("the temp path is UTF-8")
    }

    /// A `git` aimed at the FIXTURE and at nothing else.
    ///
    /// ⚠️ THE ENVIRONMENT IS PART OF THE FIXTURE. `current_dir` is not enough to say which
    /// repository a `git` means: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and friends all
    /// outrank it, and git exports exactly those to every hook it runs. So this whole suite
    /// passed from a shell and failed all twelve at once from `pre-commit` — the temp repo's
    /// `git init` and `git add` were being aimed at the real repository's index, which is both
    /// a wrong result and a genuinely dangerous one. Clearing them is the same defence the two
    /// `GIT_CONFIG_*` lines below already make against the developer's own config; it was
    /// simply never extended to the vars that say WHERE rather than HOW.
    ///
    /// Cleared rather than overridden: `env_remove` cannot be wrong about a value, and the list
    /// only has to name what git might inherit, not what it should be.
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(GIT);
        command
            .args(args)
            .current_dir(&self.root)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null");
        for inherited in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_PREFIX",
            "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CEILING_DIRECTORIES",
            "GIT_NAMESPACE",
        ] {
            command.env_remove(inherited);
        }
        command
    }

    /// Runs `git` in the fixture, asserting it succeeded — a fixture that failed to be built is a
    /// broken test rather than a failing assertion about the code.
    fn git(&self, args: &[&str]) -> String {
        let output = self.command(args).output().expect("git runs");
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    /// Runs `git` WITHOUT asserting success — for the merge that is supposed to conflict.
    fn git_may_fail(&self, args: &[&str]) -> String {
        let output = self.command(args).output().expect("git runs");
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn write(&self, name: &str, contents: &str) {
        let file = self.root.join(name);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent).expect("the parent directory is creatable");
        }
        std::fs::write(file, contents).expect("the file is writable");
    }

    fn remove(&self, name: &str) {
        std::fs::remove_file(self.root.join(name)).expect("the file is removable");
    }

    fn commit(&self, message: &str) {
        self.git(&["add", "-A"]);
        self.git(&["commit", "-m", message]);
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        drop(std::fs::remove_dir_all(&self.root));
    }
}

// ---------------------------------------------------------------------------------------------
// The oracle

/// What `git` itself says, read off porcelain v1.
#[derive(Debug, Default, PartialEq, Eq)]
struct Oracle {
    branch: String,
    ahead: i32,
    behind: i32,
    files: Vec<(u8, String)>,
}

/// Asks the binary, and reads its grammar: `## ` header first, then one `XY path` line per change.
fn oracle(fixture: &Fixture) -> Oracle {
    let text = fixture.git(&[
        "--no-optional-locks",
        "-c",
        "core.quotepath=false",
        "status",
        "--porcelain",
        "-b",
    ]);
    let mut answer = Oracle::default();
    for line in text.lines().filter(|line| !line.is_empty()) {
        if let Some(header) = line.strip_prefix("## ") {
            read_header(header, &mut answer);
        } else if let Some(change) = read_change(line) {
            answer.files.push(change);
        }
    }
    answer.files.sort();
    answer
}

/// `main...origin/main [ahead 2, behind 1]` — the name in front of the bracket, the counts inside.
fn read_header(header: &str, answer: &mut Oracle) {
    let head = match (header.find('['), header.find(']')) {
        (Some(open), Some(close)) if open < close => {
            for token in header.get(open + 1..close).unwrap_or_default().split(',') {
                let token = token.trim();
                if let Some(count) = token.strip_prefix("ahead ") {
                    answer.ahead = count.parse().unwrap_or(0);
                } else if let Some(count) = token.strip_prefix("behind ") {
                    answer.behind = count.parse().unwrap_or(0);
                }
            }
            header.get(..open).unwrap_or_default()
        },
        _ => header,
    };
    let name = head.split("...").next().unwrap_or_default().trim();
    // `HEAD (no branch)` is detached, and a detached head has no name to show.
    answer.branch = if name.starts_with("HEAD") {
        String::new()
    } else {
        name.to_owned()
    };
}

/// `XY path`, and for a rename `XY old -> new` — the NEW path is the one the worktree holds.
fn read_change(line: &str) -> Option<(u8, String)> {
    let mut characters = line.chars();
    let x = characters.next()?;
    let y = characters.next()?;
    let rest = line.get(3..)?;
    let path = rest.rsplit(" -> ").next().unwrap_or(rest);
    if path.is_empty() {
        return None;
    }
    Some((porcelain::pack(x, y), path.to_owned()))
}

/// Our own answer in the oracle's shape, so the two can be compared as one value.
fn ours(status: &GitStatusPayload) -> Oracle {
    let mut files: Vec<(u8, String)> = status
        .files
        .iter()
        .map(|change| (change.status_code, change.path.clone()))
        .collect();
    files.sort();
    Oracle {
        branch: status.branch.clone(),
        ahead: status.ahead,
        behind: status.behind,
        files,
    }
}

/// The whole comparison, run once per fixture.
fn assert_parity(fixture: &Fixture) -> GitStatusPayload {
    let status = of_path(fixture.path());
    assert!(status.has_repo, "the fixture is a repository");
    assert_eq!(ours(&status), oracle(fixture));

    let toplevel = fixture.git(&["rev-parse", "--show-toplevel"]);
    assert_eq!(
        std::fs::canonicalize(&status.repo_root).expect("the root exists"),
        std::fs::canonicalize(toplevel.trim()).expect("the toplevel exists"),
        "the By-Project grouping key"
    );

    let stashes = fixture.git(&["stash", "list"]).lines().count();
    assert_eq!(
        usize::try_from(status.stash_count).unwrap(),
        stashes,
        "the stash depth"
    );
    status
}

// ---------------------------------------------------------------------------------------------
// The shapes

#[test]
fn a_clean_repository_has_a_branch_and_no_changes() {
    let fixture = Fixture::new("clean");
    fixture.write("kept.txt", "one\n");
    fixture.commit("first");
    let status = assert_parity(&fixture);
    assert_eq!(status.branch, "main");
    assert!(status.files.is_empty());
}

/// Both axes at once, which is the pair that would collapse if either column were dropped.
#[test]
fn staged_and_unstaged_changes_keep_their_own_columns() {
    let fixture = Fixture::new("both-axes");
    fixture.write("kept.txt", "one\n");
    fixture.write("gone.txt", "two\n");
    fixture.commit("first");

    fixture.write("kept.txt", "staged\n");
    fixture.git(&["add", "kept.txt"]);
    fixture.write("kept.txt", "and then modified again\n");
    fixture.write("added.txt", "new and staged\n");
    fixture.git(&["add", "added.txt"]);
    fixture.remove("gone.txt");
    fixture.write("untracked.txt", "never seen\n");

    let status = assert_parity(&fixture);
    let byte = |name: &str| {
        status
            .files
            .iter()
            .find(|change| change.path == name)
            .map(|change| change.status_code)
    };
    assert_eq!(byte("kept.txt"), Some(porcelain::pack('M', 'M')));
    assert_eq!(byte("added.txt"), Some(porcelain::pack('A', ' ')));
    assert_eq!(byte("gone.txt"), Some(porcelain::pack(' ', 'D')));
    assert_eq!(byte("untracked.txt"), Some(porcelain::pack('?', '?')));
}

/// An untracked DIRECTORY is one entry, not one per file inside it — the setting that decides this
/// is `recurse_untracked_dirs(false)`, and getting it backwards would inflate every count.
#[test]
fn an_untracked_directory_is_one_entry() {
    let fixture = Fixture::new("untracked-dir");
    fixture.write("kept.txt", "one\n");
    fixture.commit("first");
    fixture.write("fresh/a.txt", "a\n");
    fixture.write("fresh/b.txt", "b\n");

    let status = assert_parity(&fixture);
    assert_eq!(status.files.len(), 1, "one entry for the directory");
}

/// Detection, not enumeration: a rename must arrive as ONE entry carrying the new path.
#[test]
fn a_rename_is_one_entry_at_its_new_path() {
    let fixture = Fixture::new("rename");
    fixture.write(
        "before.txt",
        "a body long enough to be recognisably the same file\n",
    );
    fixture.commit("first");
    fixture.git(&["mv", "before.txt", "after.txt"]);

    let status = assert_parity(&fixture);
    assert_eq!(status.files.len(), 1);
    assert_eq!(
        status.files.first().map(|change| change.path.as_str()),
        Some("after.txt")
    );
}

/// The conflict pair comes off INDEX STAGES, because `git2` reports one `CONFLICTED` bit for all
/// seven of porcelain's unmerged pairs.
#[test]
fn a_conflict_carries_the_pair_its_stages_say() {
    let fixture = Fixture::new("conflict");
    fixture.write("shared.txt", "base\n");
    fixture.commit("first");
    fixture.git(&["checkout", "-b", "theirs"]);
    fixture.write("shared.txt", "theirs\n");
    fixture.commit("theirs");
    fixture.git(&["checkout", "main"]);
    fixture.write("shared.txt", "ours\n");
    fixture.commit("ours");
    fixture.git_may_fail(&["merge", "theirs"]);

    let status = assert_parity(&fixture);
    let conflicted = status
        .files
        .iter()
        .find(|change| change.path == "shared.txt")
        .expect("the conflicted file is listed");
    assert_eq!(conflicted.status_code, porcelain::pack('U', 'U'));
}

/// One side deleted, which is the pair that reads backwards if ours and theirs are swapped.
#[test]
fn a_delete_conflict_reads_from_our_side_first() {
    let fixture = Fixture::new("conflict-delete");
    fixture.write("shared.txt", "base\n");
    fixture.commit("first");
    fixture.git(&["checkout", "-b", "theirs"]);
    fixture.remove("shared.txt");
    fixture.commit("they removed it");
    fixture.git(&["checkout", "main"]);
    fixture.write("shared.txt", "we changed it\n");
    fixture.commit("we kept it");
    fixture.git_may_fail(&["merge", "theirs"]);

    let status = assert_parity(&fixture);
    let conflicted = status
        .files
        .iter()
        .find(|change| change.path == "shared.txt")
        .expect("the conflicted file is listed");
    assert_eq!(conflicted.status_code, porcelain::pack('U', 'D'));
}

/// A reflog walk, not a count that can be read — and the sigil it feeds is one gitoxide cannot
/// answer at all, which is why this crate is on `git2`.
#[test]
fn the_stash_depth_is_every_entry() {
    let fixture = Fixture::new("stash");
    fixture.write("kept.txt", "one\n");
    fixture.commit("first");
    fixture.write("kept.txt", "two\n");
    fixture.git(&["stash", "push", "-m", "first stash"]);
    fixture.write("kept.txt", "three\n");
    fixture.git(&["stash", "push", "-m", "second stash"]);

    let status = assert_parity(&fixture);
    assert_eq!(status.stash_count, 2);
    assert!(status.files.is_empty(), "stashing left the worktree clean");
}

/// Divergence is a graph walk against the tracking branch, and both directions count at once.
#[test]
fn ahead_and_behind_are_counted_against_the_upstream() {
    let upstream = Fixture::new("upstream");
    upstream.write("kept.txt", "one\n");
    upstream.commit("first");
    upstream.write("kept.txt", "two\n");
    upstream.commit("second");

    let clone = Fixture::new("clone");
    // A clone into an already-initialised directory: fetch and track, which is the same end state
    // and does not need the directory to be empty.
    clone.git(&["remote", "add", "origin", upstream.path()]);
    clone.git(&["fetch", "origin"]);
    clone.git(&["reset", "--hard", "origin/main"]);
    clone.git(&["branch", "--set-upstream-to=origin/main", "main"]);
    // One commit behind: rewind the local branch by one.
    clone.git(&["reset", "--hard", "HEAD~1"]);
    // Two commits ahead of THAT point.
    clone.write("mine.txt", "a\n");
    clone.commit("mine one");
    clone.write("mine.txt", "b\n");
    clone.commit("mine two");

    let status = assert_parity(&clone);
    assert_eq!((status.ahead, status.behind), (2, 1));
    assert_eq!(status.remote_url, upstream.path(), "the origin fetch url");
}

/// A detached head has no name to show — the sidebar's detached sigil is what says where it is.
#[test]
fn a_detached_head_has_no_branch_name() {
    let fixture = Fixture::new("detached");
    fixture.write("kept.txt", "one\n");
    fixture.commit("first");
    fixture.write("kept.txt", "two\n");
    fixture.commit("second");
    fixture.git(&["checkout", "--detach", "HEAD~1"]);

    let status = assert_parity(&fixture);
    assert!(status.branch.is_empty());
}

/// **A deliberate divergence from the subprocess era.**
///
/// Porcelain prints `## No commits yet on main` for an unborn head, and the old parser took the
/// whole sentence as the branch name — the sidebar showed `No commits yet on main` where a person
/// expects `main`. This crate reads the name off the symbolic reference instead, so the oracle's
/// raw header is NOT the expected answer here and this is the one shape `assert_parity` cannot be
/// asked about.
#[test]
fn an_unborn_head_reads_as_its_branch() {
    let fixture = Fixture::unborn("unborn");
    fixture.write("fresh.txt", "never committed\n");

    let status = of_path(fixture.path());
    assert!(status.has_repo);
    assert_eq!(status.branch, "main");
    assert_eq!(oracle(&fixture).branch, "No commits yet on main");
    // Everything else still agrees, including the untracked file the header sits above.
    assert_eq!(
        status
            .files
            .iter()
            .map(|change| (change.status_code, change.path.clone()))
            .collect::<Vec<_>>(),
        oracle(&fixture).files
    );
}

/// A directory that is not in a repository answers the empty struct, which is the same answer a
/// missing `git` binary used to give and means the same thing.
#[test]
fn a_directory_outside_any_repository_answers_nothing() {
    let root = std::env::temp_dir().join(format!("slopdesk-git-parity-{}-bare", std::process::id()));
    drop(std::fs::remove_dir_all(&root));
    std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
    let status = of_path(root.to_str().expect("the temp path is UTF-8"));
    drop(std::fs::remove_dir_all(&root));
    assert_eq!(status, GitStatusPayload::no_repo());
    assert!(!status.has_repo);
}

/// Discovery walks UP the way `git` does: a pane sitting three directories inside a repository is
/// still inside it, and answers about the repository rather than about the directory.
#[test]
fn discovery_walks_up_from_a_subdirectory() {
    let fixture = Fixture::new("subdirectory");
    fixture.write("deep/inside/here/kept.txt", "one\n");
    fixture.commit("first");
    fixture.write("deep/inside/here/kept.txt", "two\n");

    let deep = fixture.root.join("deep/inside/here");
    let status = of_path(deep.to_str().expect("the temp path is UTF-8"));
    assert!(status.has_repo);
    assert_eq!(status.branch, "main");
    // The path is repository-relative, not relative to the directory that was asked about.
    assert_eq!(
        status.files.first().map(|change| change.path.as_str()),
        Some("deep/inside/here/kept.txt")
    );
    assert_eq!(
        Path::new(&status.repo_root),
        std::fs::canonicalize(&fixture.root).expect("the root exists")
    );
}
