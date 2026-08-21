//! The one answer to "is this path confined to this root".
//!
//! This is the security core of the metadata RPC. A client sends a path — a folder to list, a file
//! to diff, a transcript to read — and the only thing standing between that string and an arbitrary
//! read of the host's filesystem is the rule in this file. It is the rule for `listDirectory`,
//! `gitDiff`, `listAgentSessions` and `readAgentSession`, and it is also the rule the embedded
//! editor's bridge routes an open by, so that a file never lands in another project's window.
//!
//! ## Why it is one function and not three
//!
//! It was three, in three languages' worth of disagreement, and every one of them believed it was
//! the same rule:
//!
//! - `MetadataResponseBuilder` split on `/` and refused any `..` component outright.
//! - `CodeBridgeServer.contains` was a string `hasPrefix` with a separator guard bolted on, and did
//!   no `..` handling at all — `contains(root: "/a", path: "/a/../../etc/passwd")` answered TRUE.
//! - `files::read_session` resolved `..` lexically and then re-checked the prefix, so
//!   `/root/a/../b` was ALLOWED where the builder REFUSED it, and the root itself was REFUSED where
//!   the builder ALLOWED it.
//!
//! Three algorithms cannot all be right about a security question, and the third of them carried a
//! comment asserting what the *other language* did — which is a contract held in place by prose.
//! The failure mode that shape produces is not a compile error and not a test failure: it is a
//! layer that was believed to be defence in depth turning out to answer a different question from
//! the layer in front of it, so that tightening one of them tightens nothing.
//!
//! ## The rules, each with the failure it prevents
//!
//! **A `..` component is REFUSED, never resolved.** Resolving is the tempting answer — it is more
//! permissive and `/repo/src/../lib` is a real directory — but lexical resolution is a LIE in the
//! presence of a symlink: if `/repo/link` points at `/etc`, then `/repo/link/../passwd` resolves
//! lexically to `/repo/passwd`, which is inside, while the kernel opens `/passwd`, which is not.
//! Refusing the component outright is a strict superset of what lexical resolution refuses, so it
//! cannot be wrong where resolution was right. What it costs is that a caller may not climb: a
//! client asking for `/repo/src/../lib` is refused and has to ask for `/repo/lib`. No surface in
//! this app builds a path by climbing — every one of them descends a listing it was handed — so the
//! cost is theoretical and the guarantee is not.
//!
//! **A `.` component and a repeated `/` are dropped, and a trailing `/` with them.** These cannot
//! climb, so refusing them would only make three spellings of one path behave differently, and a
//! rule with three spellings is a rule somebody will eventually test at only one of them.
//!
//! **The root itself is INSIDE.** `listDirectory` of the pane's own cwd is the ordinary case and
//! there is nothing to be gained by calling a directory outside itself. `read_session` needs the
//! opposite — a session ROOT is a directory and a directory is not a transcript — but that is a
//! question about being a FILE, not about confinement, so it is asked at that call site, off the
//! [`Confined::relative`] this returns.
//!
//! **An empty root, a relative root, and a root of `/` are all REFUSED.** The first two are caller
//! bugs, and a caller bug in a confinement base is how a bug becomes an escape. `/` is the
//! interesting one: it is a well-formed absolute path, and taking it would mean answering "yes,
//! inside" for every path on the machine — a predicate that has stopped being one. A pane whose cwd
//! could not be resolved, or a workbench window rooted at `/`, must not silently be granted the
//! filesystem, so a root with no components is not a confinement base.
//!
//! **An interior NUL is REFUSED.** A path is bytes to Rust and a C string to `execve`, and the two
//! disagree about where one ends. A NUL cannot lengthen a path, only truncate it, so this is not
//! closing a known escape — it is refusing to reason about a string whose meaning changes on the
//! way to the syscall.
//!
//! ## The residual, stated rather than hidden
//!
//! **This is a LEXICAL rule. A symlink inside the root that points outside it is followed.**
//! `list_directory` of `/repo/link-to-etc` lists `/etc`. That is deliberate, and `canonicalize` is
//! not the fix:
//!
//! 1. it requires the path to EXIST, so a confinement verdict would depend on filesystem state and
//!    a missing file would become a refusal rather than a clean "not found";
//! 2. it would refuse legitimate paths, because the ROOT arrives from `getcwd`/OSC-7 or from a
//!    workbench window and is not itself canonical — on macOS `/tmp` is a symlink, and a checkout
//!    under one would stop matching its own cwd;
//! 3. it does not actually close the hole, because the hole is a TOCTOU one: a canonical answer can
//!    be re-pointed by a symlink swap before the caller opens it. Closing it properly needs an
//!    `openat` walk with `O_NOFOLLOW`, or Linux's `RESOLVE_BENEATH`, which macOS does not have.
//!
//! The threat this confinement is against is a request that wanders out of its pane's project by
//! path ARITHMETIC. It is not against a hostile local filesystem: the symlink would have to be
//! placed by the same user whose files the request would reach, on a machine reachable only over
//! that user's own `WireGuard` mesh (`CLAUDE.md`: "No app-layer crypto or auth"). Widening the rule
//! to cover an attacker who can already write into the project root would cost every legitimate
//! symlinked checkout, and buy an attacker nothing they do not already have.

/// What shape the candidate argument is allowed to arrive in.
///
/// This rides with the containment question rather than sitting in front of it because both are
/// "may this argument be acted on", and splitting them put half the judgement in the calling
/// language — which is how the three implementations this file replaced came to disagree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    /// Absolute, or relative and joined to the root. The `listDirectory` / `listAgentSessions`
    /// argument, where a client may name a folder either way.
    Either,
    /// Relative only — an absolute candidate is REFUSED rather than confined. `gitDiff`'s argument
    /// is a repo-relative pathspec by wire contract, and an absolute one naming the same file would
    /// be a second accepted spelling of an argument with exactly one.
    RelativeOnly,
    /// Absolute only — a relative candidate is REFUSED rather than joined. An agent session id and
    /// an editor open target are both absolute host paths by construction; a relative one is a
    /// malformed request, and joining it to a root would invent a file the caller never named.
    AbsoluteOnly,
}

/// A candidate that survived the rule, in the two forms callers need.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Confined {
    /// The normalised absolute path — always beginning with `/`, never ending with one, with no
    /// empty, `.` or `..` component in it.
    absolute: String,
    /// Where in `absolute` the part BELOW the root begins. Equal to `absolute.len()` exactly when
    /// the candidate names the root itself.
    relative_offset: usize,
}

impl Confined {
    /// The normalised absolute path.
    #[must_use]
    pub fn absolute(&self) -> &str {
        &self.absolute
    }

    /// The part of the path below the root, with no leading `/`. Empty exactly when the candidate
    /// names the root itself — which is what a caller checks when it needs a FILE rather than a
    /// containment answer.
    #[must_use]
    pub fn relative(&self) -> &str {
        self.absolute.get(self.relative_offset..).unwrap_or_default()
    }

    /// The byte offset [`Confined::relative`] starts at, for a caller reading the answer out of a
    /// buffer rather than out of this type — which is what the FFI door does.
    #[must_use]
    pub const fn relative_offset(&self) -> usize {
        self.relative_offset
    }
}

/// The non-empty, non-`.`, non-`..` components of `path`, or `None` when the path may not be acted
/// on at all.
///
/// `None` is the whole point: a `..` anywhere, or a NUL anywhere, means this function has no answer
/// rather than a normalised one, so no caller can accidentally proceed with a "best effort"
/// reading of a path that was trying to climb.
fn components(path: &str) -> Option<Vec<&str>> {
    if path.as_bytes().contains(&0) {
        return None;
    }
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {},
            ".." => return None,
            other => parts.push(other),
        }
    }
    Some(parts)
}

/// Whether `candidate` is a path this module could ever confine — absolute, naming at least one
/// component, free of `..` and of an interior NUL.
///
/// The question a caller asks when it has no root in hand. The metadata builder is the one that
/// does: a `readAgentSession` id is confined against the agent-session roots, which live under the
/// host's `$HOME` and are the forked probe's business, not the pure reducer's. What the reducer can
/// still do — and must, so that a hostile id never reaches a fork at all — is refuse an argument
/// that is not a well-formed absolute path in the first place.
///
/// It is the same parser as [`confine`], deliberately. Two questions over one implementation is not
/// two implementations; two spellings of "does this contain `..`" is exactly what this file exists
/// to end.
#[must_use]
pub fn is_confinable_absolute(candidate: &str) -> bool {
    candidate.starts_with('/') && components(candidate).is_some_and(|parts| !parts.is_empty())
}

/// Confines `candidate` to `root`, answering `None` for everything the rule refuses.
///
/// The module documentation above is the argument for each refusal; what follows is only the order
/// they are applied in, which matters for one reason: the ROOT is judged before the candidate is
/// looked at, so a caller that passed an unusable root gets a refusal rather than an answer that
/// happened to be safe for the path it asked about.
#[must_use]
pub fn confine(root: &str, candidate: &str, shape: Shape) -> Option<Confined> {
    if !root.starts_with('/') {
        return None;
    }
    let root_parts = components(root)?;
    if root_parts.is_empty() {
        return None;
    }

    // An empty candidate is not "the root". A caller whose argument went missing must see a
    // refusal, not the root's own contents — the wire's "no argument means the pane cwd" default is
    // a decision the request decoder makes explicitly, not one this rule makes by accident.
    if candidate.is_empty() {
        return None;
    }
    let candidate_is_absolute = candidate.starts_with('/');
    let wrong_shape = match shape {
        Shape::Either => false,
        Shape::RelativeOnly => candidate_is_absolute,
        Shape::AbsoluteOnly => !candidate_is_absolute,
    };
    if wrong_shape {
        return None;
    }
    let candidate_parts = components(candidate)?;

    // A relative candidate is joined to the root; an absolute one stands alone and has to prove it
    // starts with the root's components. The comparison is COMPONENT-wise, never a string prefix:
    // `/a/repo-evil` shares eight characters with `/a/repo` and none of its components.
    let full: Vec<&str> = if candidate_is_absolute {
        candidate_parts
    } else {
        let mut joined = root_parts.clone();
        joined.extend(candidate_parts);
        joined
    };
    if !full.starts_with(&root_parts) {
        return None;
    }

    let mut absolute = String::with_capacity(full.iter().map(|part| part.len() + 1).sum());
    for part in &full {
        absolute.push('/');
        absolute.push_str(part);
    }
    let root_len: usize = root_parts.iter().map(|part| part.len() + 1).sum();
    // The `+ 1` steps over the separator between the root and what is below it. When there is
    // nothing below it there is no separator to step over, and the offset is the whole length.
    let relative_offset = if full.len() == root_parts.len() {
        absolute.len()
    } else {
        root_len + 1
    };
    Some(Confined {
        absolute,
        relative_offset,
    })
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{Shape, confine, is_confinable_absolute};

    /// The confined absolute path, or `None`.
    fn absolute(root: &str, candidate: &str, shape: Shape) -> Option<String> {
        confine(root, candidate, shape).map(|found| found.absolute().to_owned())
    }

    /// The confined path below the root, or `None`.
    fn relative(root: &str, candidate: &str, shape: Shape) -> Option<String> {
        confine(root, candidate, shape).map(|found| found.relative().to_owned())
    }

    /// The containment answer alone — what the editor bridge's routing asks.
    fn within(root: &str, candidate: &str) -> bool {
        confine(root, candidate, Shape::AbsoluteOnly).is_some()
    }

    // MARK: The ordinary answers

    #[test]
    fn a_child_of_the_root_is_confined_either_way_it_is_spelled() {
        assert_eq!(
            absolute("/repo", "src/main.rs", Shape::Either).as_deref(),
            Some("/repo/src/main.rs"),
        );
        assert_eq!(
            absolute("/repo", "/repo/src/main.rs", Shape::Either).as_deref(),
            Some("/repo/src/main.rs"),
        );
        assert_eq!(
            relative("/repo", "src/main.rs", Shape::Either).as_deref(),
            Some("src/main.rs"),
        );
    }

    #[test]
    fn the_root_itself_is_inside_and_its_relative_half_is_empty() {
        let found = confine("/repo", "/repo", Shape::AbsoluteOnly).unwrap();
        assert_eq!(found.absolute(), "/repo");
        assert_eq!(found.relative(), "");
        assert_eq!(found.relative_offset(), found.absolute().len());
        // Which is the ONE thing a caller needing a file rather than a directory checks.
        assert_eq!(
            relative("/repo", "/repo/a", Shape::AbsoluteOnly).as_deref(),
            Some("a")
        );
    }

    #[test]
    fn a_trailing_slash_and_a_doubled_slash_name_the_same_path() {
        assert_eq!(
            absolute("/repo/", "/repo//src///main.rs", Shape::Either).as_deref(),
            Some("/repo/src/main.rs"),
        );
        assert_eq!(
            absolute("/repo/", "/repo/", Shape::Either).as_deref(),
            Some("/repo")
        );
        assert_eq!(
            absolute("/repo", "./src/./main.rs", Shape::Either).as_deref(),
            Some("/repo/src/main.rs"),
            "a `.` cannot climb, so it is dropped rather than refused",
        );
    }

    // MARK: Traversal, in every position

    #[test]
    fn a_parent_component_is_refused_wherever_it_appears() {
        for candidate in [
            "..",
            "../escape",
            "src/../../escape",
            "src/..",
            "src/../lib",
            "/repo/../etc/passwd",
            "/repo/src/../../etc/passwd",
            "/..",
            "/repo/..",
            "/repo/./../etc",
            "/repo//../etc",
        ] {
            assert_eq!(
                absolute("/repo", candidate, Shape::Either),
                None,
                "refused outright: {candidate}",
            );
        }
    }

    #[test]
    fn a_traversal_that_would_have_landed_back_inside_is_still_refused() {
        // This is the one case where refusing is STRICTER than resolving, and it is the case that
        // decided the rule: resolving it lexically is only correct if no component on the way is a
        // symlink, and nothing in a string can say whether one is.
        assert_eq!(absolute("/repo", "/repo/a/../b", Shape::Either), None);
        assert_eq!(absolute("/repo", "a/../b", Shape::Either), None);
        assert_eq!(absolute("/repo", "/repo/../repo/b", Shape::Either), None);
    }

    #[test]
    fn a_root_carrying_a_traversal_is_refused_rather_than_resolved() {
        // A root with a `..` in it is a caller bug, and resolving one here would be the same
        // lexical guess the candidate rule refuses to make.
        assert_eq!(absolute("/repo/..", "/etc", Shape::Either), None);
        assert_eq!(absolute("/repo/../repo", "/repo/a", Shape::Either), None);
    }

    // MARK: The prefix that is not a component

    #[test]
    fn a_sibling_whose_name_merely_starts_with_the_roots_is_outside() {
        assert!(!within("/a/repo", "/a/repo-evil/x"));
        assert!(!within("/a/repo", "/a/repository"));
        assert!(within("/a/repo", "/a/repo/x"));
        assert_eq!(absolute("/a/repo", "/a/repo-evil", Shape::Either), None);
    }

    #[test]
    fn a_path_above_the_root_is_outside() {
        assert!(!within("/a/b", "/a"));
        assert!(!within("/a/b", "/"));
    }

    // MARK: Roots that are not confinement bases

    #[test]
    fn an_empty_or_relative_root_confines_nothing() {
        assert!(!within("", "/a/b"));
        assert!(!within("relative", "/a/b"));
        assert!(!within("relative", "relative/b"));
    }

    #[test]
    fn the_filesystem_root_is_not_a_confinement_base() {
        // A predicate that answers "inside" for every path on the machine has stopped being one.
        // A pane whose cwd could not be resolved must be refused, not granted everything.
        assert!(!within("/", "/etc/passwd"));
        assert!(!within("/", "/"));
        assert_eq!(absolute("/", "anything", Shape::Either), None);
    }

    // MARK: The candidate's shape

    #[test]
    fn each_shape_refuses_the_spelling_it_does_not_accept() {
        assert_eq!(
            absolute("/repo", "/repo/src", Shape::RelativeOnly),
            None,
            "an absolute pathspec is not a repo-relative one",
        );
        assert_eq!(
            absolute("/repo", "src", Shape::AbsoluteOnly),
            None,
            "a relative id is a malformed request, not a path to join",
        );
        assert!(absolute("/repo", "src", Shape::RelativeOnly).is_some());
        assert!(absolute("/repo", "/repo/src", Shape::AbsoluteOnly).is_some());
    }

    #[test]
    fn an_empty_candidate_is_refused_rather_than_read_as_the_root() {
        for shape in [Shape::Either, Shape::RelativeOnly, Shape::AbsoluteOnly] {
            assert_eq!(absolute("/repo", "", shape), None);
        }
        // `/` as a candidate names no component at all, which is the same missing argument wearing
        // a leading slash.
        assert_eq!(absolute("/repo", "/", Shape::Either), None);
        assert_eq!(absolute("/repo", "//", Shape::Either), None);
    }

    #[test]
    fn a_candidate_of_only_dots_resolves_to_the_root_it_was_measured_against() {
        // `.` cannot climb, so `/repo/.` IS `/repo` — the one spelling of "the root" that is not an
        // empty argument.
        let found = confine("/repo", ".", Shape::Either).unwrap();
        assert_eq!(found.absolute(), "/repo");
        assert_eq!(found.relative(), "");
    }

    // MARK: The byte-level refusals

    #[test]
    fn an_interior_nul_is_refused_on_either_side() {
        assert_eq!(absolute("/repo", "src/a\u{0}/b", Shape::Either), None);
        assert_eq!(absolute("/repo\u{0}", "/repo/a", Shape::Either), None);
        assert!(!is_confinable_absolute("/repo/a\u{0}b"));
    }

    // MARK: The shape question asked alone

    #[test]
    fn the_rootless_question_accepts_exactly_what_the_rule_could_confine() {
        assert!(is_confinable_absolute("/home/me/.claude/projects/-p/s.jsonl"));
        assert!(is_confinable_absolute("/a"));
        assert!(!is_confinable_absolute(""));
        assert!(!is_confinable_absolute("/"));
        assert!(!is_confinable_absolute("//"));
        assert!(!is_confinable_absolute("relative.jsonl"));
        assert!(!is_confinable_absolute("/a/../../secrets"));
        assert!(!is_confinable_absolute("../secrets"));
    }

    // MARK: The escape the deleted implementations disagreed about

    #[test]
    fn the_string_prefix_escape_the_bridge_used_to_answer_true_for_is_refused() {
        // `CodeBridgeServer.contains` was a `hasPrefix` with a separator guard and no `..` handling
        // at all: it answered TRUE for every one of these. It was reachable only behind a
        // `standardizingPath` two files away, which is not a guarantee — it is a coincidence.
        assert!(!within("/a", "/a/../../etc/passwd"));
        assert!(!within("/a", "/a/../b"));
        assert!(!within("/a/b", "/a/b/../../../etc/passwd"));
        assert!(!within("/a/b", "/a/b//../../etc"));
    }
}
