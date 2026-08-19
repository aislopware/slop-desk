//! The `gitDiff` verb — the diff base chosen, and the patch bytes returned.
//!
//! ## What used to be here
//! `gitStatus`, which forked `git` four times inside a fork of this program. It is now
//! `rust/slopdesk-git`, LINKED into hostd: five spawns per debounced `FSEvents` tick became none,
//! and the porcelain parser that stood here became libgit2 answering the questions directly. The
//! wire's `XY` packing went with it, to `slopdesk_git::porcelain`.
//!
//! The diff did not follow, and the difference is the answer's SHAPE rather than its cost. A patch
//! is up to 15 MiB of opaque bytes that hostd forwards without looking inside, produced once when a
//! person opens a file — a fork whose whole output is a blob nobody parses, on a path that rides a
//! click. `libgit2` would have to render the patch itself to answer it, which is a second diff
//! implementation to keep looking like `git`'s.

use crate::run;

/// Where the host's `git` is.
///
/// Absolute rather than `PATH`-resolved: this runs with whatever environment hostd inherited, and a
/// `git` earlier on someone's `PATH` is not the one the operator means when they ask what their
/// repo looks like.
pub const GIT: &str = "/usr/bin/git";

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
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

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
}
