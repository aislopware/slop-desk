//! The By-Project sidebar key (wire type 34): which repository a pane's directory belongs to.
//!
//! The nearest ancestor of the pane's cwd — the cwd itself included — that is a git worktree
//! TOPLEVEL, else the cwd verbatim.
//!
//! ## Why this one question does not go through `git2`
//!
//! Everything else in this crate opens the repository, because everything else needs what is
//! INSIDE it. This needs only its boundary, and the boundary is a `.git` entry: a handful of
//! `stat(2)` calls bounded by the path's depth, against `git2`'s repository discovery opening
//! objects, config and index for an answer already known by then. The pane census runs this per
//! pane per prompt edge.
//!
//! `.git` may be a DIRECTORY (an ordinary clone) or a FILE (a linked `git worktree`, a submodule),
//! and both count — a linked worktree is its own section, which is also what `git rev-parse
//! --show-toplevel` reports from inside one.
//!
//! ## The canonical form comes first
//!
//! A pane's cwd arrives from two sources that disagree: OSC 7 carries the shell's LOGICAL `$PWD`
//! with symlink components intact, and the prompt-edge `proc_pidinfo` probe reports the kernel's
//! PHYSICAL vnode path. The same directory would key two ways depending on which spoke last, and
//! the client — which cannot stat host paths — would render one repository as two sections, or walk
//! a symlinked ANCESTOR whose target has a `.git` of its own and mint a third. So [`key_of`]
//! resolves before it walks.
//!
//! ## Blocking, deliberately
//!
//! Every `stat(2)` here can park indefinitely on a hung network mount, so the caller keeps this off
//! any thread that must stay live — hostd runs it on its metadata queue, never on the PTY read
//! loop.

use std::fs;
use std::path::Path;

/// The By-Project key for `cwd`, resolved and walked.
///
/// A relative or otherwise unwalkable path is answered verbatim: the two producers are absolute in
/// practice, but OSC 7 is shell-controlled input, and a key that is honestly "whatever they said"
/// groups a pane consistently without ever leaving the caller without one.
#[must_use]
pub fn key_of(cwd: &str) -> String {
    key_walking(&canonical(cwd), |path| {
        fs::symlink_metadata(Path::new(path).join(".git")).is_ok()
    })
}

/// `realpath(3)` of `cwd`, or `cwd` unchanged when it cannot be resolved.
///
/// A directory that vanished between the sniff and the walk, or one on an erroring mount, keeps the
/// path the shell reported — the type-33 cwd the client renders is that path either way, and only
/// the KEY is canonicalised.
#[must_use]
pub fn canonical(cwd: &str) -> String {
    fs::canonicalize(cwd)
        .ok()
        .and_then(|resolved| resolved.into_os_string().into_string().ok())
        .unwrap_or_else(|| cwd.to_owned())
}

/// The walk alone, against a caller's answer to "is this a worktree toplevel".
///
/// Split out so the rule is testable without a filesystem, and so a caller with its own cheaper
/// oracle (a warm cache of roots) can reuse the ordering rather than re-deriving it.
#[must_use]
pub fn key_walking(cwd: &str, mut is_repo_root: impl FnMut(&str) -> bool) -> String {
    // "/repo/" and "/repo" must latch and emit as ONE key; a bare "/" keeps its slash.
    let path = {
        let trimmed = cwd.trim_end_matches('/');
        if trimmed.is_empty() {
            if cwd.is_empty() { "" } else { "/" }
        } else {
            trimmed
        }
    };
    if !path.starts_with('/') {
        return path.to_owned();
    }
    let mut probe = path;
    while probe.len() > 1 {
        if is_repo_root(probe) {
            return probe.to_owned();
        }
        probe = match probe.rfind('/') {
            // The top-level parent ("/x" → "") stays "/", so the walk ends at the root rather than
            // stepping off the front of the string.
            Some(0) => "/",
            Some(slash) => &probe[..slash],
            None => return path.to_owned(),
        };
    }
    // Reached "/" (or started there). "/" as a repository is nonsensical for grouping, so the
    // normalised cwd is the key.
    //
    // `$HOME` lands here unless the user versions their dotfiles — in which case it IS a toplevel
    // and grouping under it is simply right. A pane opened by the `home` working-directory policy
    // therefore gets a section named after the home folder rather than the "Other" bucket, which is
    // DELIBERATE: "Other" means "no key yet", and a pane parked there jumps out to its own section
    // the moment one resolves. That churn is worse than a section.
    path.to_owned()
}

#[cfg(test)]
mod tests {
    use super::{canonical, key_of, key_walking};

    #[test]
    fn the_nearest_toplevel_wins() {
        let key = key_walking("/Users/me/repo/Sources/Deep", |path| path == "/Users/me/repo");
        assert_eq!(key, "/Users/me/repo");
    }

    #[test]
    fn a_toplevel_is_its_own_key() {
        assert_eq!(
            key_walking("/Users/me/repo", |path| path == "/Users/me/repo"),
            "/Users/me/repo"
        );
    }

    #[test]
    fn a_directory_in_no_repository_keys_as_itself() {
        assert_eq!(key_walking("/Users/me/notes", |_| false), "/Users/me/notes");
    }

    #[test]
    fn a_nested_checkout_beats_its_host() {
        // A vendored clone inside another repository is its own project, not the outer one's.
        let roots = ["/outer", "/outer/vendor/inner"];
        assert_eq!(
            key_walking("/outer/vendor/inner/src", |path| roots.contains(&path)),
            "/outer/vendor/inner"
        );
    }

    #[test]
    fn trailing_slashes_do_not_make_a_second_key() {
        assert_eq!(
            key_walking("/Users/me/repo/", |path| path == "/Users/me/repo"),
            "/Users/me/repo"
        );
        assert_eq!(key_walking("/Users/me/notes///", |_| false), "/Users/me/notes");
    }

    #[test]
    fn the_walk_climbs_one_level_at_a_time() {
        let mut probed = Vec::new();
        let key = key_walking("/x/y", |path| {
            probed.push(path.to_owned());
            false
        });
        assert_eq!(probed, ["/x/y", "/x"]);
        assert_eq!(key, "/x/y");
    }

    #[test]
    fn the_root_and_a_relative_path_are_answered_without_walking() {
        let mut probes = 0_usize;
        assert_eq!(
            key_walking("/", |_| {
                probes += 1;
                true
            }),
            "/"
        );
        assert_eq!(
            key_walking("relative/path", |_| {
                probes += 1;
                true
            }),
            "relative/path"
        );
        assert_eq!(probes, 0, "neither shape is worth a stat");
    }

    #[test]
    fn an_unresolvable_path_keeps_what_the_shell_said() {
        assert_eq!(
            canonical("/no/such/directory/anywhere"),
            "/no/such/directory/anywhere"
        );
        assert_eq!(
            key_of("/no/such/directory/anywhere"),
            "/no/such/directory/anywhere"
        );
    }

    #[test]
    fn a_real_repository_keys_to_its_toplevel() {
        // This crate's own checkout: the walk starts deep inside it and must climb out to the root.
        let here = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
        let key = key_of(here);
        assert!(
            here.starts_with(&key) && key.len() < here.len(),
            "expected an ancestor toplevel of {here}, got {key}"
        );
    }
}
