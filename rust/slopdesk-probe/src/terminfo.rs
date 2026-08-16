//! The `terminfo` question: which `TERM` this host can actually honour.
//!
//! ## The problem it answers
//! The client renders with libghostty, so the host's first instinct is to advertise
//! `TERM=xterm-ghostty` — that is what unlocks the kitty keyboard protocol and DEC 2026
//! synchronized output. But the `xterm-ghostty` entry ships with Ghostty, not with the base OS, so
//! a fresh host usually does not have it. On such a host every curses app — `vim`, `htop`, `less`,
//! `tmux`, `top` — calls `setupterm("xterm-ghostty")`, finds nothing, and either refuses to start
//! ("terminal is not fully functional") or degrades to a dumb fallback with the wrong key
//! sequences.
//!
//! What the canonical tools do: `ssh` forwards `TERM` verbatim and RELIES on the remote having the
//! entry, which is exactly the failure above; `mosh` forces a `TERM` it ships terminfo for; kitty's
//! `ssh` kitten PUSHES its compiled terminfo and `tic`-installs it under `~/.terminfo` before
//! launching the shell — the best fidelity, and the only one that mutates somebody else's machine.
//!
//! This is the third option Ghostty itself documents (#54700): keep `xterm-ghostty` when the host
//! resolves it, and fall back to `xterm-256color` — present on effectively every Unix host, and
//! correct enough for all of the above — when it does not. Pushing terminfo stays out of scope; a
//! probe that writes to the host is a different kind of program.
//!
//! ## Why the fallback is a PARAMETER
//! Nothing here knows the two names. The caller asks "resolve `requested`, and if you cannot, say
//! `fallback`", so the decision table is about two strings rather than about an enum this side
//! would have to keep in step with the one hostd carries.

use std::collections::BTreeMap;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

/// Where `infocmp` is. Absolute for [`crate::git::GIT`]'s reason: the answer must be the one the
/// spawned TUI apps will get, not whatever a `PATH` earlier in someone's profile points at.
pub const INFOCMP: &str = "/usr/bin/infocmp";

/// The conventional system terminfo locations, present on macOS and most Linux.
pub const SYSTEM_DIRECTORIES: &[&str] = &[
    "/usr/share/terminfo",
    "/usr/lib/terminfo",
    "/etc/terminfo",
    "/usr/share/misc/terminfo",
];

/// The environment a resolution reads. A map rather than the process's own so the search order is
/// testable without `set_var`.
pub type Environment = BTreeMap<String, String>;

/// This process's environment.
#[must_use]
pub fn process_environment() -> Environment {
    std::env::vars().collect()
}

/// The ordered terminfo search directories, mirroring ncurses' own lookup: `$TERMINFO`, then
/// `~/.terminfo`, then each `:`-separated element of `$TERMINFO_DIRS`, then the system directories.
///
/// An EMPTY element of `$TERMINFO_DIRS` means "the compiled-in default location" to ncurses. It is
/// skipped here and approximated by [`SYSTEM_DIRECTORIES`], which are appended regardless — the
/// alternative is guessing at a path baked into somebody else's build.
#[must_use]
pub fn search_directories(environment: &Environment) -> Vec<String> {
    let mut dirs: Vec<String> = Vec::new();
    if let Some(terminfo) = environment.get("TERMINFO").filter(|value| !value.is_empty()) {
        dirs.push(terminfo.clone());
    }
    if let Some(home) = environment.get("HOME").filter(|value| !value.is_empty()) {
        dirs.push(if home.ends_with('/') {
            format!("{home}.terminfo")
        } else {
            format!("{home}/.terminfo")
        });
    }
    if let Some(list) = environment.get("TERMINFO_DIRS").filter(|value| !value.is_empty()) {
        dirs.extend(
            list.split(':')
                .filter(|element| !element.is_empty())
                .map(ToOwned::to_owned),
        );
    }
    dirs.extend(SYSTEM_DIRECTORIES.iter().map(|dir| (*dir).to_owned()));
    dirs
}

/// The candidate paths a compiled `term` entry could sit at, in search order.
///
/// terminfo files as one-character subdirectories: `x/xterm-ghostty`. Some `tic` builds — notably
/// ncurses configured with `--enable-term-driver`, which is what macOS ships — write the first
/// character's HEX instead, so `78/xterm-ghostty` is checked too. Missing the second layout means
/// reporting "unresolvable" on a machine that resolves it perfectly well.
#[must_use]
pub fn candidate_paths(term: &str, directories: &[String]) -> Vec<String> {
    let Some(first) = term.chars().next() else {
        return Vec::new();
    };
    let hex = format!("{:02x}", if first.is_ascii() { first as u32 } else { 0 });
    let mut candidates = Vec::with_capacity(directories.len() * 2);
    for base in directories {
        for sub in [first.to_string(), hex.clone()] {
            // Join without doubling a slash, and never absolutise: an environment directory may
            // legitimately be relative, and rewriting it would look somewhere the shell would not.
            let base = base.strip_suffix('/').unwrap_or(base);
            candidates.push(format!("{base}/{sub}/{term}"));
        }
    }
    candidates
}

/// Whether any candidate path for `term` exists, using an injected `exists` so the layout rules are
/// pinned without a filesystem carrying either one.
pub fn entry_exists(term: &str, directories: &[String], exists: impl Fn(&str) -> bool) -> bool {
    candidate_paths(term, directories).iter().any(|path| exists(path))
}

/// Whether `infocmp` says `term` resolves. `None` when it could not be run at all, which is not the
/// same answer as "no" — the caller falls back for both, but only one of them is about the
/// terminal.
#[must_use]
pub fn infocmp_resolves(term: &str) -> Option<bool> {
    // Both streams to /dev/null: only the exit status is wanted, and a dumped capability list on
    // hostd's stdout would land in the middle of somebody's log.
    let status = Command::new(INFOCMP)
        .arg(term)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()?;
    Some(status.success())
}

/// Whether this host can resolve `term`: the directory search first (a `stat`, no subprocess), then
/// `infocmp` as the authority, since it consults the same database ncurses will.
///
/// Neither answering is "no". A host with no `infocmp` and no entry on disk is a host where
/// advertising the entry helps nobody.
#[must_use]
pub fn resolvable(term: &str, environment: &Environment) -> bool {
    if entry_exists(term, &search_directories(environment), |path| {
        std::path::Path::new(path).exists()
    }) {
        return true;
    }
    infocmp_resolves(term).unwrap_or(false)
}

/// The decision, as a pure function of the two names and one boolean.
///
/// | requested    | resolvable | → term       | fell back |
/// |--------------|------------|--------------|-----------|
/// | == fallback  | (any)      | fallback     | false     |
/// | != fallback  | true       | requested    | false     |
/// | != fallback  | false      | fallback     | true      |
///
/// A request that IS the fallback is authoritative and never probed — there is nothing to fall back
/// from, and re-deriving an operator's deliberate `--xterm256` into something else is not a
/// resolution, it is an override of one.
#[must_use]
pub fn decide(requested: &str, fallback: &str, resolvable: bool) -> (String, bool) {
    if requested == fallback {
        return (fallback.to_owned(), false);
    }
    if resolvable {
        return (requested.to_owned(), false);
    }
    (fallback.to_owned(), true)
}

/// [`decide`] against the real host, skipping the probe entirely when there is nothing to decide.
#[must_use]
pub fn resolve(requested: &str, fallback: &str, environment: &Environment) -> (String, bool) {
    if requested == fallback {
        return (fallback.to_owned(), false);
    }
    decide(requested, fallback, resolvable(requested, environment))
}

/// The answer hostd decodes.
#[must_use]
pub fn to_json(term: &str, fell_back: bool) -> Value {
    json!({ "term": term, "fellBack": fell_back })
}

#[cfg(test)]
#[expect(
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    fn environment(pairs: &[(&str, &str)]) -> Environment {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn the_search_order_is_ncurses_own() {
        let dirs = search_directories(&environment(&[
            ("TERMINFO", "/custom/ti"),
            ("HOME", "/home/me"),
            ("TERMINFO_DIRS", "/a::/b"),
        ]));
        assert_eq!(dirs[0], "/custom/ti");
        assert_eq!(dirs[1], "/home/me/.terminfo");
        // The empty element is skipped, not turned into "" — a bare join on it would search `/`.
        assert_eq!(dirs[2], "/a");
        assert_eq!(dirs[3], "/b");
        assert_eq!(dirs[4], SYSTEM_DIRECTORIES[0]);
        assert_eq!(dirs.len(), 4 + SYSTEM_DIRECTORIES.len());
    }

    #[test]
    fn an_empty_or_absent_variable_contributes_nothing() {
        let dirs = search_directories(&environment(&[
            ("TERMINFO", ""),
            ("HOME", ""),
            ("TERMINFO_DIRS", ""),
        ]));
        assert_eq!(dirs.len(), SYSTEM_DIRECTORIES.len());
    }

    #[test]
    fn a_home_with_a_trailing_slash_does_not_double_it() {
        let dirs = search_directories(&environment(&[("HOME", "/home/me/")]));
        assert_eq!(dirs[0], "/home/me/.terminfo");
    }

    #[test]
    fn both_the_letter_and_the_hex_layout_are_searched() {
        let dirs = vec!["/usr/share/terminfo".to_owned()];
        let candidates = candidate_paths("xterm-ghostty", &dirs);
        assert_eq!(candidates, [
            "/usr/share/terminfo/x/xterm-ghostty",
            // 0x78 is 'x'. macOS's ncurses writes this layout, and only checking the letter one
            // reports "unresolvable" on a machine that resolves it.
            "/usr/share/terminfo/78/xterm-ghostty",
        ]);
    }

    #[test]
    fn a_directory_that_already_ends_in_a_slash_joins_cleanly() {
        let dirs = vec!["/ti/".to_owned()];
        assert_eq!(candidate_paths("a", &dirs)[0], "/ti/a/a");
    }

    #[test]
    fn a_relative_directory_stays_relative() {
        // An environment may legitimately name one, and rewriting it would search a path the shell
        // would not.
        let dirs = vec!["ti".to_owned()];
        assert_eq!(candidate_paths("a", &dirs)[0], "ti/a/a");
    }

    #[test]
    fn an_empty_term_has_no_candidates() {
        assert!(candidate_paths("", &["/ti".to_owned()]).is_empty());
    }

    #[test]
    fn the_hex_layout_is_found_when_the_letter_one_is_not() {
        let dirs = vec!["/ti".to_owned()];
        assert!(entry_exists("xterm-ghostty", &dirs, |path| {
            path == "/ti/78/xterm-ghostty"
        }));
        assert!(!entry_exists("xterm-ghostty", &dirs, |_| false));
    }

    #[test]
    fn a_request_that_is_already_the_fallback_is_authoritative() {
        // Both resolvable answers, because neither is consulted: the caller said what it wanted.
        assert_eq!(
            decide("xterm-256color", "xterm-256color", false),
            ("xterm-256color".to_owned(), false,)
        );
        assert_eq!(
            decide("xterm-256color", "xterm-256color", true),
            ("xterm-256color".to_owned(), false,)
        );
    }

    #[test]
    fn a_resolvable_request_is_kept_and_is_not_a_fallback() {
        assert_eq!(
            decide("xterm-ghostty", "xterm-256color", true),
            ("xterm-ghostty".to_owned(), false,)
        );
    }

    #[test]
    fn an_unresolvable_request_falls_back_and_says_so() {
        // The `true` is what hostd logs on — once, at session start.
        assert_eq!(
            decide("xterm-ghostty", "xterm-256color", false),
            ("xterm-256color".to_owned(), true,)
        );
    }

    #[test]
    fn resolving_a_request_that_is_the_fallback_probes_nothing() {
        // No filesystem and no `infocmp` can change this answer, which is why `resolve` returns
        // before either. An environment naming a directory that does not exist proves it went
        // nowhere near one.
        let env = environment(&[("TERMINFO", "/definitely/not/here")]);
        assert_eq!(
            resolve("xterm-256color", "xterm-256color", &env),
            ("xterm-256color".to_owned(), false,)
        );
    }

    #[test]
    fn the_answer_carries_both_fields() {
        assert_eq!(
            to_json("xterm-256color", true).to_string(),
            r#"{"fellBack":true,"term":"xterm-256color"}"#,
        );
    }

    #[test]
    fn a_term_nothing_could_ever_have_is_unresolvable() {
        // Runs the real `infocmp` on this machine. Safe to assert either way round only for a name
        // no database can hold: the point is that an unresolvable entry answers false rather than
        // erroring, and that the whole path runs.
        assert!(!resolvable("slopdesk-no-such-terminal-entry", &environment(&[])));
    }
}
