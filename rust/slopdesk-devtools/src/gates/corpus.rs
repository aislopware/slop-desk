//! No committed terminal recording carries the machine it was recorded on.
//!
//! ## The failure this exists to make loud
//! `rust/slopdesk-vterm/corpus/*.sdrec` holds, byte for byte, everything a real program painted on
//! a real terminal on someone's real Mac. That is the whole value of the corpus — and it is also
//! the whole hazard, because a program that prints machine STATE prints it into a file that is then
//! committed to a public repository.
//!
//! It happened. `top` held this slot for one afternoon on 2026-09-02: its frames were the recording
//! machine's process list, its load averages, its PIDs and UIDs, and its operator's user name 435
//! times. It was caught by hand before the first commit and replaced with `less` paging a file from
//! this repository, so nothing reached git — but nothing except that hand would have caught it, and
//! the next recording is written by whoever needs one next.
//!
//! `corpus/README.md` states the rule in prose ("never record a program that prints machine
//! state"). This is the half that enforces it.
//!
//! ## Why it reads GIT and not the working tree
//! The leak that matters is the committed one, and the two sets genuinely differ: a recording made
//! and then rejected sits in the corpus directory as an untracked file, which is exactly what the
//! `top` incident left behind. A working-tree scan would red on a file the repository does not have
//! and cannot be fixed by any change to the repository — so the question is asked of `git
//! ls-files`, which is also the set a clone of this repo would receive.
//!
//! That is what makes this a GATE rather than a `slopdesk-invariants` rule: the answer comes from
//! git, not from the tree. It rides on `lint-reach`, with the other questions the tree cannot
//! answer about itself.
//!
//! ## Why the needles are bytes and not a decode
//! A `.sdrec` is a container of raw pty output. Decoding it would mean depending on
//! `slopdesk-vterm` — an engine build on the critical path of a gate that must stay cheap — and it
//! would look at less: a fingerprint can sit in a title, in a script, in a paste, or in the middle
//! of a frame nobody renders. A byte scan sees all of them.
//!
//! ## What a failure prints, and what it deliberately does not
//! The file and the KIND of fingerprint. Never the surrounding bytes and never the value itself:
//! a gate that answered "found `/Users/someone/…`" would copy the leak into every CI log that ran
//! it.
//!
//! ## The second pass, and why it is narrower
//! A recording is not the only file in this repository written by a machine. The same sweep that
//! wrote this gate found `docs/research/readonly-inspector-corpus.json` quoting the operator's own
//! `~/.claude/projects/-Users-<user>/` path — committed, in a public repo, from a research note
//! nobody thought of as machine output. So EVERY tracked file is scanned too, and with the
//! run-time needles only: an absolute `/Users/me/…` inside a Swift test fixture is a synthetic
//! path and firing on it would make the gate unusable, while a literal match of the machine's own
//! user or host name never is.
//!
//! That asymmetry is the whole design. The recordings get the full needle set because a `.sdrec`
//! is verbatim machine output and nothing in one is written by hand; every other file gets the two
//! needles that cannot be a coincidence.

use std::path::Path;

use crate::proc;

/// Where the recordings live, and the glob git is asked for.
const RECORDINGS: &str = "*.sdrec";

/// How few tracked recordings mean the question stopped being asked.
///
/// The corpus is committed and `slopdesk-vterm`'s own replay floors at four recordings, so a scan
/// that found fewer than that is not a clean corpus — it is a scan looking in the wrong place, or a
/// glob that stopped matching. A vacuous pass is the one answer this gate must never give.
const FLOOR: usize = 4;

/// A byte sequence that must not appear in a recording, and the name a failure reports it by.
///
/// Every one is a SHAPE rather than a value: an absolute home path, a private key header, a
/// credential-shaped environment assignment. They are static because they are true on any machine —
/// a recording made on someone else's laptop leaks the same way — and they are matched
/// case-sensitively, because the lowercase spellings are what these actually look like and a
/// case-insensitive `/users/` would fire on ordinary prose.
const NEEDLES: &[(&str, &str)] = &[
    ("/Users/", "an absolute macOS home path"),
    ("/home/", "an absolute Linux home path"),
    ("/Volumes/", "an absolute path into a mounted volume"),
    ("/private/var/folders/", "a per-user temporary directory"),
    ("ssh-rsa ", "an SSH public key"),
    ("PRIVATE KEY-----", "a private key body"),
    ("AKIA", "an AWS access key id"),
    ("_TOKEN=", "a token-shaped environment assignment"),
    ("_SECRET=", "a secret-shaped environment assignment"),
    ("API_KEY=", "an API-key-shaped environment assignment"),
];

/// The shortest a run-time value may be before it is used as a needle.
///
/// A two-character user name or a host called `mac` would match inside ordinary output and the gate
/// would be unusable on that machine. Skipping such a value costs one of several needles rather
/// than the scan, and the static ones above do not depend on it.
const SHORTEST_RUNTIME_NEEDLE: usize = 4;

/// One recording's fingerprints: what was found, by the name it is reported under.
///
/// Pure, so the break-test can seed a leak without writing a file into the corpus.
#[must_use]
pub fn fingerprints(bytes: &[u8], runtime: &[(String, String)]) -> Vec<String> {
    let mut found = runtime_fingerprints(bytes, runtime);
    for (needle, what) in NEEDLES {
        if contains(bytes, needle.as_bytes()) {
            found.push((*what).to_owned());
        }
    }
    found
}

/// What a file carries of THIS machine, and nothing else.
///
/// The second pass's needle set. A hand-written source is full of paths that look like a home
/// directory and are not one — a test fixture asserting on `/Users/me/Projects` is the normal case,
/// not a leak — so the static needles are not asked there. A literal match of the machine's own
/// user or host name has no innocent reading.
#[must_use]
pub fn runtime_fingerprints(bytes: &[u8], runtime: &[(String, String)]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for (value, what) in runtime {
        if value.len() >= SHORTEST_RUNTIME_NEEDLE && contains(bytes, value.as_bytes()) {
            found.push(what.clone());
        }
    }
    found
}

/// Whether `haystack` holds `needle` anywhere.
fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || needle.len() > haystack.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|window| window == needle)
}

/// The values only THIS machine can supply, paired with what a hit would mean.
///
/// Best-effort by construction: a recording made on another machine cannot be checked against that
/// machine's user name, and the static needles above are what cover it. What these add is the case
/// the static ones cannot see — a program printing the operator's own name or host with no path
/// around it, which is precisely how `top` leaked.
fn runtime_needles(root: &Path) -> Vec<(String, String)> {
    let mut needles: Vec<(String, String)> = Vec::new();
    if let Ok(user) = std::env::var("USER") {
        needles.push((user, "this machine's user name".to_owned()));
    }
    if let Some(host) = proc::ask("hostname", &["-s"], root) {
        let host = host.trim().to_owned();
        if !host.is_empty() {
            needles.push((host, "this machine's host name".to_owned()));
        }
    }
    needles
}

/// Every tracked file matching `pathspec`, as repo-relative paths.
///
/// # Errors
/// When git cannot be asked at all, which is reported rather than read as "no files".
fn tracked(root: &Path, pathspec: &[&str]) -> Result<Vec<String>, String> {
    let mut arguments = vec!["ls-files", "--"];
    arguments.extend_from_slice(pathspec);
    let listing = proc::capture("git", &arguments, root).map_err(|why| {
        format!(
            "check-corpus: FAIL — `git ls-files` could not be run, so this gate cannot tell a clean tree \
             from an unread one: {why}"
        )
    })?;
    Ok(listing
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect())
}

/// The largest tracked file the second pass reads.
///
/// The pass is over EVERY tracked file, and the handful above this are fonts and one vendored
/// server binary — none of them written by a machine that knows the operator's name. Reading them
/// would cost more than the question is worth, and the recordings the first pass reads have no cap
/// at all.
const LARGEST_SCANNED: u64 = 8 * 1024 * 1024;

/// Check that no committed recording carries a machine fingerprint.
///
/// # Errors
/// One message naming every offending file and what was found in it — never the value, which would
/// put the leak in the log that reports it.
#[expect(clippy::print_stdout, reason = "the fingerprint census is this gate's report")]
pub fn run(root: &Path) -> Result<(), String> {
    let files = tracked(root, &[RECORDINGS])?;
    if files.len() < FLOOR {
        return Err(format!(
            "check-corpus: FAIL — git tracks {} file(s) matching {RECORDINGS} and the committed corpus has \
             at least {FLOOR}. A scan over nothing passes vacuously, so this is reported rather than \
             accepted: either the recordings were deleted, or this gate is looking in the wrong place",
            files.len()
        ));
    }

    let runtime = runtime_needles(root);
    let mut failures: Vec<String> = Vec::new();
    for file in &files {
        let bytes = std::fs::read(root.join(file))
            .map_err(|error| format!("check-corpus: FAIL — {file} is tracked and unreadable: {error}"))?;
        let found = fingerprints(&bytes, &runtime);
        if !found.is_empty() {
            failures.push(format!("  {file}: {}", found.join(", ")));
        }
    }

    // The second pass: every other tracked file, with the run-time needles only. See the module
    // note for why the needle sets differ.
    let everything = tracked(root, &[])?;
    if everything.len() < files.len() {
        return Err(format!(
            "check-corpus: FAIL — `git ls-files` listed {} file(s) in the whole tree and {} recordings in \
             it, which cannot both be true. The second pass would be reading a set smaller than the first",
            everything.len(),
            files.len()
        ));
    }
    for file in everything.iter().filter(|file| !files.contains(file)) {
        let path = root.join(file);
        if std::fs::metadata(&path).is_ok_and(|meta| meta.len() > LARGEST_SCANNED) {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else {
            // A tracked path with no readable file is a checkout state (a sparse checkout, an
            // LFS pointer), not a leak. The first pass reports its own unreadable files, because
            // there the file is the subject.
            continue;
        };
        let found = runtime_fingerprints(&bytes, &runtime);
        if !found.is_empty() {
            failures.push(format!("  {file}: {}", found.join(", ")));
        }
    }

    if failures.is_empty() {
        println!(
            "check-corpus: {} committed recording(s) and {} tracked file(s) carry no machine fingerprint",
            files.len(),
            everything.len()
        );
        return Ok(());
    }

    Err(format!(
        "check-corpus: FAIL — a committed file carries the machine it was made on:\n{}\nThis repository is \
         public and its history is permanent. A `.sdrec` holds every byte a program painted, so re-record \
         it under the minimal environment the recorder now gives its child \
         (rust/slopdesk-vterm/corpus/README.md) and never record a program that prints machine state — that \
         rule exists because `top` held a corpus slot for one afternoon with this machine's process list in \
         it. Any other file: redact the value, and check whether what wrote it was a machine",
        failures.join("\n")
    ))
}

#[cfg(test)]
mod tests {
    use super::{FLOOR, fingerprints, runtime_fingerprints};

    fn no_runtime() -> Vec<(String, String)> {
        Vec::new()
    }

    /// The break-test: the exact shape `top` left behind — a home path in the middle of a frame.
    #[test]
    fn an_absolute_home_path_inside_a_frame_is_caught() {
        let mut recording = b"SDREC2\n".to_vec();
        recording.extend_from_slice(b"\x1b[2J\x1b[H  501 /Users/someone/Library/Caches  \x1b[0m");
        assert_eq!(fingerprints(&recording, &no_runtime()), vec![
            "an absolute macOS home path".to_owned()
        ]);
    }

    /// The corpus as it ships: repo-relative paths, escape sequences and prose, and nothing else.
    #[test]
    fn a_recording_of_repository_content_is_clean() {
        let recording = b"SDREC2\n\x1b[2J\x1b[Hdocs/68-terminal-surface-in-rust.md \
                          rust/slopdesk-vterm/corpus/README.md\x1b[0m";
        assert!(fingerprints(recording, &no_runtime()).is_empty());
    }

    /// A user name with no path around it is the case only a run-time needle can see — and it is
    /// how `top` leaked, since a process list prints the owner bare.
    #[test]
    fn a_bare_user_name_is_caught_by_the_run_time_needle() {
        let runtime = vec![("someone".to_owned(), "this machine's user name".to_owned())];
        let recording = b"  1234 someone   0.0  0.1 top\r\n";
        assert_eq!(fingerprints(recording, &runtime), vec![
            "this machine's user name".to_owned()
        ]);
    }

    /// A run-time value too short to be distinctive is dropped rather than making the gate unusable
    /// on that machine — a user called `bo` appears inside `bootstrap`.
    #[test]
    fn a_short_run_time_value_is_not_used_as_a_needle() {
        let runtime = vec![("bo".to_owned(), "this machine's user name".to_owned())];
        assert!(fingerprints(b"bootstrap complete\r\n", &runtime).is_empty());
    }

    /// Several kinds in one file are all reported, because a re-record has to fix all of them.
    #[test]
    fn every_kind_found_is_named() {
        let recording = b"/Users/x\r\nssh-rsa AAAAB3\r\nGITHUB_TOKEN=abc\r\n";
        let found = fingerprints(recording, &no_runtime());
        assert_eq!(found.len(), 3, "{found:?}");
    }

    /// The floor is what stops a scan over nothing from reporting green, and it is the same four
    /// `slopdesk-termrender`'s own loader floors at — a corpus below it is a deletion, not a tree.
    #[test]
    fn the_floor_is_the_replays_own_minimum() {
        assert_eq!(FLOOR, 4);
    }

    /// The second pass asks LESS of an ordinary file: a synthetic home path in a test fixture is
    /// the normal case, and a gate that fired on it would be turned off within a day.
    #[test]
    fn an_ordinary_source_file_is_not_judged_by_the_static_needles() {
        let fixture = b"XCTAssertEqual(resolved, \"/Users/me/Projects/demo\")\n";
        assert!(runtime_fingerprints(fixture, &no_runtime()).is_empty());
        assert!(
            !fingerprints(fixture, &no_runtime()).is_empty(),
            "the recordings' pass must still catch it"
        );
    }

    /// The break-test for the file this pass was written for: a research note quoting the
    /// operator's own home directory, committed to a public repository.
    #[test]
    fn a_committed_note_quoting_this_machines_home_is_caught() {
        let runtime = vec![("someone".to_owned(), "this machine's user name".to_owned())];
        let note = b"On this machine (`~/.claude/projects/-Users-someone/`), two directories\n";
        assert_eq!(runtime_fingerprints(note, &runtime), vec![
            "this machine's user name".to_owned()
        ]);
    }
}
