//! The `gitStatus` and `gitDiff` verbs — porcelain v1 parsed, and the diff base chosen.
//!
//! ## Why this moved out of the host
//! `gitStatus` forks `git` FOUR times: `status --porcelain -b`, `remote get-url origin`, `rev-parse
//! --show-toplevel`, `stash list`. Doing that from hostd meant four spawns on hostd's own metadata
//! queue per request; doing it from here means ONE spawn from hostd and four inside a program that
//! exists to make them. The parsing that used to be untestable — the Swift probe is documented as
//! compiled-and-reviewed only, because a unit test that spawns a real `git` is the hang-safety
//! rule's whole subject — is now ordinary functions over strings, with the process boundary at the
//! edge.

use serde_json::{Value, json};

use crate::run;

/// Where the host's `git` is.
///
/// Absolute rather than `PATH`-resolved: this runs with whatever environment hostd inherited, and a
/// `git` earlier on someone's `PATH` is not the one the operator means when they ask what their
/// repo looks like.
pub const GIT: &str = "/usr/bin/git";

/// The changed-file cap. A second backstop under the builder's own — a repo mid-rebase with a
/// hundred thousand touched paths must not be able to build a frame nobody can send.
pub const MAX_GIT_FILES: usize = 4096;

/// One entry of the status list: the porcelain `XY` pair packed into a byte, plus the path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileChange {
    /// High nibble = `X` (index), low nibble = `Y` (worktree) — the host-defined packing the client
    /// unpacks to render a change category.
    pub status_code: u8,
    /// The repo-relative path.
    pub path: String,
}

/// What `git-status` answers. `has_repo == false` is the whole answer; every other field is then
/// empty by construction.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Status {
    /// Whether the cwd is inside a repository at all.
    pub has_repo: bool,
    /// The branch name; empty when detached.
    pub branch: String,
    /// The `origin` URL; empty when there is no remote.
    pub remote_url: String,
    /// The absolute toplevel — the By-Project grouping key. Empty when it could not be resolved,
    /// which the client answers by falling back to the pane cwd.
    pub repo_root: String,
    /// Commits ahead of the upstream.
    pub ahead: i32,
    /// Commits behind the upstream.
    pub behind: i32,
    /// The stash depth.
    pub stash_count: i32,
    /// The changed files, capped at [`MAX_GIT_FILES`].
    pub files: Vec<FileChange>,
}

impl Status {
    /// The JSON the Swift side decodes. A no-repo answer still carries every key: a decoder that
    /// has to branch on which fields are present is a decoder with two shapes to get right.
    #[must_use]
    pub fn to_json(&self) -> Value {
        json!({
            "hasRepo": self.has_repo,
            "branch": self.branch,
            "remoteURL": self.remote_url,
            "repoRoot": self.repo_root,
            "ahead": self.ahead,
            "behind": self.behind,
            "stashCount": self.stash_count,
            "files": self.files.iter().map(|change| json!({
                "statusCode": change.status_code,
                "path": change.path,
            })).collect::<Vec<_>>(),
        })
    }
}

/// The full status of `cwd`.
///
/// `--no-optional-locks` keeps this read-only probe from taking `index.lock` for git's
/// opportunistic untracked-cache refresh: the scheduler probes on a cadence, and a probe racing the
/// user's own `git commit` in the pane must never make THAT fail on a held lock. `-c
/// core.quotepath=false` disables git's octal-escaping of non-ASCII paths, so an accented or CJK
/// filename flows through verbatim — both for display and as the `git-diff` pathspec, which would
/// otherwise match nothing against the quoted literal.
#[must_use]
pub fn status(cwd: &str) -> Status {
    let Some(output) = run::capture_text(GIT, &[
        "--no-optional-locks",
        "-c",
        "core.quotepath=false",
        "-C",
        cwd,
        "status",
        "--porcelain",
        "-b",
    ]) else {
        return Status::default();
    };
    let mut status = parse_status(&output);
    if !status.has_repo {
        return Status::default();
    }
    let remote = run::capture_text(GIT, &["-C", cwd, "remote", "get-url", "origin"]).unwrap_or_default();
    remote.trim().clone_into(&mut status.remote_url);
    status.repo_root = toplevel(cwd).unwrap_or_default();
    status.stash_count = stash_count(cwd);
    status
}

/// Parses the porcelain v1 `-b` body: the `## ` header plus one line per changed path.
///
/// Split out from [`status`] because it is the whole reason this is testable at all — the four
/// spawns are one line each, and everything that can be WRONG is in here.
#[must_use]
pub fn parse_status(output: &str) -> Status {
    let mut status = Status::default();
    for line in output.split('\n').filter(|line| !line.is_empty()) {
        status.has_repo = true;
        if let Some(header) = line.strip_prefix("## ") {
            parse_branch_header(header, &mut status);
        } else if line.len() >= 3
            && status.files.len() < MAX_GIT_FILES
            && let Some(change) = parse_status_line(line)
        {
            status.files.push(change);
        }
    }
    status
}

/// Parses `<branch>...<upstream> [ahead N, behind M]`, a bare `<branch>`, or `HEAD (no branch)`.
///
/// Defensive throughout: a missing or unparseable field keeps its default rather than discarding
/// the line, because the branch name is the part a person reads and the counts are the part they
/// can do without.
fn parse_branch_header(header: &str, status: &mut Status) {
    // The counts live in the bracket, the name in front of it — so parsing the bracket is also what
    // decides where the name ends. A header with no bracket, or with a `]` before its `[`, is all
    // name.
    let head = match (header.find('['), header.find(']')) {
        (Some(open), Some(close)) if open < close => {
            let inside = header.get(open + 1..close).unwrap_or_default();
            for token in inside.split(',') {
                let token = token.trim();
                if let Some(count) = token.strip_prefix("ahead ") {
                    status.ahead = count.parse().unwrap_or(0);
                } else if let Some(count) = token.strip_prefix("behind ") {
                    status.behind = count.parse().unwrap_or(0);
                }
            }
            header.get(..open).unwrap_or_default()
        },
        _ => header,
    };
    let name = head.split("...").next().unwrap_or_default().trim();
    // `HEAD (no branch)` is detached, and a detached head has no name to show.
    status.branch = if name.starts_with("HEAD") {
        String::new()
    } else {
        name.to_owned()
    };
}

/// Parses one porcelain v1 line, `XY <path>`. A rename (`XY old -> new`) keeps the NEW path — what
/// the worktree now holds is what a person can open.
#[must_use]
pub fn parse_status_line(line: &str) -> Option<FileChange> {
    let mut chars = line.chars();
    let x = chars.next()?;
    let y = chars.next()?;
    // The path starts after the `XY` pair and its one separating space. Byte offsets are safe here:
    // porcelain's first three columns are always ASCII.
    let rest = line.get(3..)?;
    let path = rest.rsplit(" -> ").next().unwrap_or(rest);
    if path.is_empty() {
        return None;
    }
    Some(FileChange {
        status_code: pack_status(x, y),
        path: path.to_owned(),
    })
}

/// Maps a porcelain status char to a 4-bit code. **The client mirrors this inverse** to name the
/// change category, so the table is a wire contract and not an internal choice.
#[must_use]
pub const fn status_nibble(char: char) -> u8 {
    match char {
        ' ' => 0,
        'M' => 1,
        'A' => 2,
        'D' => 3,
        'R' => 4,
        'C' => 5,
        'U' => 6,
        '?' => 7,
        '!' => 8,
        'T' => 9,
        _ => 15,
    }
}

/// Packs `X` (index) and `Y` (worktree) into one byte: high nibble `X`, low nibble `Y`.
#[must_use]
pub const fn pack_status(x: char, y: char) -> u8 {
    (status_nibble(x) << 4) | status_nibble(y)
}

/// The repo's absolute toplevel for `cwd`; `None` outside a repo or when `git` is missing.
#[must_use]
pub fn toplevel(cwd: &str) -> Option<String> {
    let top = run::capture_text(GIT, &["-C", cwd, "rev-parse", "--show-toplevel"])?
        .trim()
        .to_owned();
    (!top.is_empty()).then_some(top)
}

/// The stash depth (`git stash list` line count), clamped.
///
/// Best-effort like everything here: a missing binary, a non-repo and an empty stash are all `0`,
/// and none of them is worth telling apart in a badge that shows a number.
#[must_use]
pub fn stash_count(cwd: &str) -> i32 {
    run::capture_text(GIT, &["-C", cwd, "stash", "list"]).map_or(0, |out| {
        i32::try_from(out.split('\n').filter(|line| !line.is_empty()).count()).unwrap_or(i32::MAX)
    })
}

/// Resolves the diff for a repo-root-relative `file` whose pane cwd is `cwd`.
///
/// The answer is the FIRST non-empty result across three bases, all rooted at the repo TOPLEVEL —
/// never the pane cwd, because porcelain paths are repo-root-relative and a subdir cwd would match
/// nothing.
///
/// The bases, in order:
/// 1. `diff HEAD` — the combined change vs the last commit, so a STAGED change shows just like an
///    unstaged one (`git diff` alone is empty for a staged file).
/// 2. `diff` — the plain unstaged worktree diff, for a repo with no commits where `diff HEAD`
///    errors but a tracked file is modified.
/// 3. `diff --cached` — the staged index-vs-HEAD diff, for the no-HEAD repo where a freshly-staged
///    add lives ONLY in the index and neither of the above shows it.
///
/// `run` is injected so the base ordering and the subdir-relativity fix are pinned without a real
/// `git`. An all-empty chain returns the last result, which is the same mapping the single-command
/// path produced for an unchanged or untracked file: empty bytes → `.ok` empty, `None` →
/// `.notFound`.
pub fn resolve_diff(
    cwd: &str,
    file: &str,
    mut run: impl FnMut(&[&str]) -> Option<Vec<u8>>,
) -> Option<Vec<u8>> {
    let top = run(&["-C", cwd, "rev-parse", "--show-toplevel"])
        .map(|bytes| String::from_utf8_lossy(&bytes).trim().to_owned())
        .unwrap_or_default();
    let root = if top.is_empty() { cwd } else { top.as_str() };
    let mut last = None;
    for base in [
        vec!["-C", root, "diff", "HEAD", "--", file],
        vec!["-C", root, "diff", "--", file],
        vec!["-C", root, "diff", "--cached", "--", file],
    ] {
        let result = run(&base);
        if let Some(bytes) = &result
            && !bytes.is_empty()
        {
            return result;
        }
        last = result.or(last);
    }
    last
}

/// [`resolve_diff`] against the real `git`.
#[must_use]
pub fn diff(cwd: &str, file: &str) -> Option<Vec<u8>> {
    resolve_diff(cwd, file, |arguments| run::capture(GIT, arguments))
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    // MARK: The branch header

    #[test]
    fn a_tracking_branch_yields_its_name_and_both_counts() {
        let parsed = parse_status("## main...origin/main [ahead 2, behind 3]\n");
        assert_eq!(parsed.branch, "main");
        assert_eq!(parsed.ahead, 2);
        assert_eq!(parsed.behind, 3);
        assert!(parsed.has_repo);
    }

    #[test]
    fn one_sided_and_absent_counts_default_to_zero() {
        assert_eq!(parse_status("## main...origin/main [ahead 7]\n").ahead, 7);
        assert_eq!(parse_status("## main...origin/main [ahead 7]\n").behind, 0);
        let bare = parse_status("## main\n");
        assert_eq!((bare.branch.as_str(), bare.ahead, bare.behind), ("main", 0, 0));
    }

    #[test]
    fn a_detached_head_has_no_branch_name_to_show() {
        assert_eq!(parse_status("## HEAD (no branch)\n").branch, "");
    }

    #[test]
    fn a_branch_with_slashes_survives_intact() {
        assert_eq!(
            parse_status("## feature/a/b...origin/feature/a/b\n").branch,
            "feature/a/b",
        );
    }

    // MARK: The file lines

    #[test]
    fn the_status_pair_packs_high_index_low_worktree() {
        assert_eq!(pack_status(' ', 'M'), 0x01);
        assert_eq!(pack_status('M', ' '), 0x10);
        assert_eq!(pack_status('?', '?'), 0x77);
        assert_eq!(pack_status('R', 'D'), 0x43);
        // Anything the table does not name is 15, never a silent 0 that would read as "unchanged".
        assert_eq!(pack_status('Z', 'z'), 0xFF);
    }

    /// The documented convention, as INDEPENDENT literals of the spec rather than anything read
    /// back from the table under test.
    const CONVENTION: [(char, u8); 10] = [
        (' ', 0),
        ('M', 1),
        ('A', 2),
        ('D', 3),
        ('R', 4),
        ('C', 5),
        ('U', 6),
        ('?', 7),
        ('!', 8),
        ('T', 9),
    ];

    #[test]
    fn every_porcelain_char_maps_to_its_documented_nibble() {
        for (char, nibble) in CONVENTION {
            assert_eq!(status_nibble(char), nibble, "status_nibble({char})");
        }
        assert_eq!(
            status_nibble('Z'),
            15,
            "an unnamed char is the 15 sentinel, never a silent 0"
        );
    }

    #[test]
    fn the_packing_is_the_inverse_of_the_client_unpacking() {
        // The inverse table any CLIENT-side unpacking follows. Written out here rather than derived,
        // because the two tables drifting apart is exactly the failure this pins — and the client is
        // a different program that cannot be imported.
        const fn client_char(nibble: u8) -> char {
            match nibble {
                1 => 'M',
                2 => 'A',
                3 => 'D',
                4 => 'R',
                5 => 'C',
                6 => 'U',
                7 => '?',
                8 => '!',
                9 => 'T',
                _ => ' ',
            }
        }
        for (x, _) in CONVENTION {
            for (y, _) in CONVENTION {
                let packed = pack_status(x, y);
                assert_eq!(
                    client_char(packed >> 4),
                    x,
                    "the high nibble must unpack to X={x}"
                );
                assert_eq!(
                    client_char(packed & 0x0F),
                    y,
                    "the low nibble must unpack to Y={y}"
                );
            }
        }
    }

    #[test]
    fn a_rename_keeps_the_path_the_worktree_now_holds() {
        let change = parse_status_line("R  old/name.txt -> new/name.txt").unwrap();
        assert_eq!(change.path, "new/name.txt");
        assert_eq!(change.status_code, pack_status('R', ' '));
    }

    #[test]
    fn a_path_containing_an_arrow_is_not_mistaken_for_a_rename() {
        // ` -> ` inside a filename is legal. Splitting from the RIGHT keeps the last occurrence as
        // the separator, which is the one a rename actually uses.
        let change = parse_status_line(" M a -> b -> c.txt").unwrap();
        assert_eq!(change.path, "c.txt");
    }

    #[test]
    fn a_non_ascii_path_survives_because_quotepath_is_off() {
        let change = parse_status_line(" M báo cáo/tệp.txt").unwrap();
        assert_eq!(change.path, "báo cáo/tệp.txt");
    }

    #[test]
    fn a_short_or_empty_line_is_dropped_rather_than_guessed_at() {
        assert!(parse_status_line("").is_none());
        assert!(parse_status_line("M").is_none());
        assert!(parse_status_line(" M ").is_none());
    }

    #[test]
    fn the_file_list_is_capped() {
        let mut body = String::from("## main\n");
        for index in 0..(MAX_GIT_FILES + 50) {
            body.push_str(" M file");
            body.push_str(&index.to_string());
            body.push('\n');
        }
        assert_eq!(parse_status(&body).files.len(), MAX_GIT_FILES);
    }

    #[test]
    fn empty_output_is_not_a_repo() {
        let parsed = parse_status("");
        assert!(!parsed.has_repo);
        assert_eq!(parsed, Status::default());
    }

    // MARK: The diff bases

    #[test]
    fn the_first_non_empty_base_wins_and_the_diff_is_rooted_at_the_toplevel() {
        let mut seen: Vec<Vec<String>> = Vec::new();
        let found = resolve_diff("/repo/sub", "src/a.rs", |arguments| {
            seen.push(arguments.iter().map(|a| (*a).to_owned()).collect());
            if arguments.contains(&"--show-toplevel") {
                return Some(b"/repo\n".to_vec());
            }
            // `diff HEAD` is empty, the plain worktree diff has the change.
            if arguments.contains(&"HEAD") {
                return Some(Vec::new());
            }
            Some(b"@@ patch @@".to_vec())
        });
        assert_eq!(found.as_deref(), Some(b"@@ patch @@".as_slice()));
        // Every diff invocation ran at the TOPLEVEL, not the subdir cwd — the whole point.
        for arguments in seen.iter().filter(|a| a.contains(&"diff".to_owned())) {
            assert_eq!(arguments[1], "/repo", "{arguments:?}");
        }
        // …and `--cached` was never reached, because an earlier base answered.
        assert!(!seen.iter().any(|a| a.contains(&"--cached".to_owned())));
    }

    #[test]
    fn an_unresolvable_toplevel_falls_back_to_the_pane_cwd() {
        let mut roots = Vec::new();
        let _unused = resolve_diff("/some/where", "a.rs", |arguments| {
            if arguments.contains(&"--show-toplevel") {
                return None;
            }
            roots.push(arguments[1].to_owned());
            Some(Vec::new())
        });
        assert!(roots.iter().all(|root| root == "/some/where"));
    }

    #[test]
    fn an_all_empty_chain_answers_empty_rather_than_missing() {
        let found = resolve_diff("/repo", "a.rs", |arguments| {
            if arguments.contains(&"--show-toplevel") {
                return Some(b"/repo\n".to_vec());
            }
            Some(Vec::new())
        });
        // Empty bytes, NOT `None`: the file exists and simply has no diff, which the builder maps to
        // an ok-with-nothing rather than a not-found.
        assert_eq!(found.as_deref(), Some(b"".as_slice()));
    }

    #[test]
    fn a_git_that_cannot_run_at_all_answers_missing() {
        let found = resolve_diff("/repo", "a.rs", |_| None);
        assert!(found.is_none());
    }

    #[test]
    fn the_staged_only_case_reaches_the_cached_base() {
        let found = resolve_diff("/repo", "a.rs", |arguments| {
            if arguments.contains(&"--show-toplevel") {
                return Some(b"/repo\n".to_vec());
            }
            if arguments.contains(&"--cached") {
                return Some(b"staged".to_vec());
            }
            Some(Vec::new())
        });
        assert_eq!(found.as_deref(), Some(b"staged".as_slice()));
    }

    // MARK: The JSON shape

    #[test]
    fn a_no_repo_answer_still_carries_every_key() {
        let object = Status::default().to_json();
        for key in [
            "hasRepo",
            "branch",
            "remoteURL",
            "repoRoot",
            "ahead",
            "behind",
            "stashCount",
            "files",
        ] {
            assert!(object.get(key).is_some(), "{key}");
        }
        assert_eq!(object["hasRepo"], false);
        assert_eq!(object["files"], json!([]));
    }

    #[test]
    fn the_status_code_crosses_as_a_number_the_client_unpacks() {
        let status = Status {
            has_repo: true,
            files: vec![FileChange {
                status_code: pack_status('M', 'M'),
                path: "a.rs".to_owned(),
            }],
            ..Status::default()
        };
        assert_eq!(status.to_json()["files"][0]["statusCode"], 0x11);
    }
}
