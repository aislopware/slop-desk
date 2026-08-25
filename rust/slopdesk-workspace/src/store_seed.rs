//! What a pane born beside another one inherits, and which readings the store keeps at all.
//!
//! Two facts follow a pane everywhere it is drawn: where its shell is (`pane/cwd`) and which
//! project section it belongs to (`pane/projectKey`). A split, a new tab and a new window all mint
//! a pane that has neither yet, and the surfaces that name it draw on the FIRST frame — long before
//! the host's own answer for the child's PTY round-trips. So the store seeds both from the pane the
//! gesture was made on.
//!
//! The seeds and the write gates are one module because they are one guard read from two ends. A
//! plugin manager that steps into its cache directory to source a plugin makes the kernel's answer
//! to "where is this shell" briefly TRUE and completely useless, and the two sides of that are:
//! never inherit such a reading ([`inheritable_cwd`]), and never store one
//! ([`accepts_cwd`]). Three transcriptions of the same guard is how one of them ends up missing.
//!
//! ## The subtree rule is what keeps a child in its parent's section
//!
//! A parent's project key is the host's word about a REPOSITORY, and the child's inherited
//! directory is where its shell will start. Seeding the key is right exactly when the second is
//! inside the first ([`covers`]). Without the guard, a parent whose key went stale across an
//! un-re-pushed `cd`, or a working-directory policy that resolves a fixed directory, files the
//! child under a project it is not in — and the host's later push corrects it, visibly, a beat
//! after the user has already read the wrong section header.
//!
//! Without the SEED, the child sections by its raw inherited directory instead, so a pane split
//! from one sitting in a repository subdirectory tears off into its own subdirectory-named section
//! until the round trip lands. Both failures are the same length; only one of them is wrong.

use slopdesk_tree::session::PaneSpec;

/// Whether `path` is inside section `key`'s subtree, INCLUDING the key itself.
///
/// A key written with a trailing slash names the same directory as one without, so the separator is
/// added only when it is not already there — otherwise a key of `/work/alpha/` would demand
/// `/work/alpha//src` to match and cover nothing at all.
///
/// The strict half of this rule lives at
/// [`store_git_cadence::aliases_under`](crate::store_git_cadence::aliases_under), which answers a
/// different question — whether a reply may be filed under a SECOND key — and answers it about keys
/// that have already been normalized. Kept apart rather than shared because the two disagree at the
/// filesystem root, and merging them would silently pick one side of that disagreement.
#[must_use]
pub fn covers(key: &str, path: &str) -> bool {
    if path == key {
        return true;
    }
    let mut prefix = key.to_owned();
    if !prefix.ends_with('/') {
        prefix.push('/');
    }
    path.starts_with(&prefix)
}

/// A pane's working directory sanitized as an INHERIT SOURCE, or `None` when there is nothing worth
/// inheriting.
///
/// A transient plugin-cache directory is dropped. Without this, a directory probe that caught the
/// shell mid plugin-manager `cd` seeds the NEW pane's directory — and then its spawn directory, its
/// folder-name title and its project section are all that plugin's, which is the whole of the
/// "the new pane opened in `zsh-users---zsh-autosuggestions`" symptom.
///
/// `None` in, `None` out: a pane with no directory yet has nothing to hand down, and the caller's
/// own policy resolves the host default from there.
#[must_use]
pub fn inheritable_cwd(cwd: Option<&str>) -> Option<&str> {
    cwd.filter(|path| !PaneSpec::looks_like_transient_plugin_cwd(path))
}

/// The parent's project key, seeded onto the child, or `None` to seed nothing.
///
/// Guarded three ways, and each one is a different way of being wrong:
///
/// - A blank or plugin-cache key is not a project.
/// - A parent that has no host key of its own — still on its directory fallback — seeds NOTHING.
///   The child's identical directory fallback already sections it beside the parent, so a seed here
///   would only be the same answer arrived at less honestly.
/// - A key that does not [`cover`](covers) the inherited directory is not this child's project.
///
/// The host's own push for the child's PTY confirms or corrects the seed either way; what the seed
/// buys is the first frame.
#[must_use]
pub fn inheritable_project_key<'a>(key: Option<&'a str>, inherited_cwd: Option<&str>) -> Option<&'a str> {
    let key = key.filter(|key| !key.is_empty() && !PaneSpec::looks_like_transient_plugin_cwd(key))?;
    let cwd = inherited_cwd?;
    covers(key, cwd).then_some(key)
}

/// Whether a freshly-observed working directory is worth writing.
///
/// The same plugin-cache guard as [`inheritable_cwd`], read from the WRITE end — the live sources
/// are kernel probes fired on command completion and by the palette's resolver, and both race a
/// plugin manager's `cd`. Plus the dirty guard: an unchanged value is not a visit, and writing it
/// would spend a document save and a frecency record on a re-focus that moved nothing.
#[must_use]
pub fn accepts_cwd(candidate: &str, current: Option<&str>) -> bool {
    !PaneSpec::looks_like_transient_plugin_cwd(candidate) && current != Some(candidate)
}

/// Whether a host-pushed project key is worth writing.
///
/// The mirror of [`accepts_cwd`] with one guard more: a blank key is not an answer. The host's own
/// resolver can race a plugin manager's `cd` exactly as a client-side probe can, so the same
/// reading is dropped from this end too, and a reattach that re-asserts the value the store already
/// holds spends nothing.
#[must_use]
pub fn accepts_project_key(candidate: &str, current: Option<&str>) -> bool {
    !candidate.is_empty()
        && !PaneSpec::looks_like_transient_plugin_cwd(candidate)
        && current != Some(candidate)
}

#[cfg(test)]
mod tests {
    use super::{accepts_cwd, accepts_project_key, covers, inheritable_cwd, inheritable_project_key};

    /// Coverage admits the key itself, its subdirectories, and nothing that merely starts the same.
    #[test]
    fn coverage_is_a_subtree_and_not_a_prefix() {
        assert!(covers("/work/alpha", "/work/alpha"));
        assert!(covers("/work/alpha", "/work/alpha/src/deep"));
        assert!(!covers("/work/alpha", "/work/alphabet"));
        assert!(!covers("/work/alpha", "/work"));
    }

    /// A key written with a trailing slash names the same subtree as one without.
    #[test]
    fn a_trailing_slash_key_still_covers_its_subtree() {
        assert!(covers("/work/alpha/", "/work/alpha/src"));
        assert!(covers("/work/alpha/", "/work/alpha/"));
        assert!(!covers("/work/alpha/", "/work/alphabet"));
        assert!(covers("/", "/work/alpha"), "the root covers everything, once");
    }

    /// A plugin-cache directory is never handed down.
    #[test]
    fn a_plugin_cache_directory_is_not_inherited() {
        assert_eq!(inheritable_cwd(Some("/work/alpha")), Some("/work/alpha"));
        assert_eq!(
            inheritable_cwd(Some("/cache/zsh-users---zsh-autosuggestions")),
            None
        );
        assert_eq!(inheritable_cwd(None), None);
    }

    /// The key is seeded only when it genuinely covers where the child's shell will start.
    #[test]
    fn the_key_is_seeded_only_over_its_own_subtree() {
        assert_eq!(
            inheritable_project_key(Some("/work/alpha"), Some("/work/alpha/src")),
            Some("/work/alpha"),
        );
        assert_eq!(
            inheritable_project_key(Some("/work/alpha"), Some("/work/beta")),
            None,
            "a stale key across an un-re-pushed cd files the child nowhere rather than wrongly",
        );
        assert_eq!(inheritable_project_key(Some("/work/alpha"), None), None);
    }

    /// A parent still on its directory fallback seeds nothing.
    #[test]
    fn a_keyless_parent_seeds_nothing() {
        assert_eq!(inheritable_project_key(None, Some("/work/alpha")), None);
        assert_eq!(inheritable_project_key(Some(""), Some("/work/alpha")), None);
        assert_eq!(
            inheritable_project_key(Some("/cache/owner---repo"), Some("/cache/owner---repo/x")),
            None,
        );
    }

    /// The two write gates: the plugin guard, the dirty guard, and — for the key — blankness.
    #[test]
    fn the_write_gates_drop_the_transient_and_the_unchanged() {
        assert!(accepts_cwd("/work/alpha", None));
        assert!(accepts_cwd("/work/alpha", Some("/work/beta")));
        assert!(!accepts_cwd("/work/alpha", Some("/work/alpha")));
        assert!(!accepts_cwd("/cache/owner---repo", None));
        assert!(
            accepts_cwd("", None),
            "a blank directory is a directory the caller may store"
        );

        assert!(accepts_project_key("/work/alpha", None));
        assert!(!accepts_project_key("/work/alpha", Some("/work/alpha")));
        assert!(!accepts_project_key("/cache/owner---repo", None));
        assert!(!accepts_project_key("", None), "a blank key is not an answer");
    }
}
