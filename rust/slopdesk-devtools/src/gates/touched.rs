//! The fast INNER-LOOP test gate: incremental build, then ONLY the test targets the change set
//! can reach.
//!
//! The full `swift test --parallel` costs ~100 s of pure execution even with a warm build; a
//! typical single-module edit reaches one to three test targets and lands in ~10-50 s total.
//! [`super::prepush`] stays the FULL gate.
//!
//! ## The change set is measured from the last FULL green, not from HEAD
//! Edits made across several commits since the last full run all stay in scope. When there is no
//! known-green baseline — a fresh clone, a wiped `.build/` — a diff against bare HEAD would
//! silently absolve every commit since the last full run, so the gate fails toward FULL and one
//! full green on a clean tree ends the penalty.
//!
//! The FFI artifact is the second baseline for the reason [`super::prepush`] carries it in its key:
//! no pathspec can see it move — the artifact is gitignored, all of `ThirdParty/slopdesk-ffi/` —
//! and the dependency closure cannot help either, since every Swift target that links the
//! xcframework does so through the package graph rather than through a changed file. So the whole
//! suite is the selection.
//!
//! ## The other Rust the graph cannot see
//! `rust/` IS tracked, and the diff reads it. What the `SwiftPM` graph cannot do is own a path in
//! it: a crate belongs to no target, so attribution would answer "unattributable" and escalate
//! every crate edit to the full suite — including this gate's own, which no Swift test can reach.
//! The edge that does exist is a suite BOOTING a daemon, and it is derived from the fixtures rather
//! than listed, by the scan [`super::prepush`] already runs to refuse an unbuilt tree. Today that
//! is one edge: `DropdE2ETests` spells `rust/slopdesk-dropd/target`, so a dropd edit selects
//! `SlopDeskFileTransferTests` and nothing else. Before this the diff never looked at `rust/` at
//! all, and a dropd change selected NOTHING while the recipe rebuilt the very binary that suite
//! spawns — bounded, because a touched green never writes the pre-push marker, so the miss cost a
//! late signal rather than a green the push had not earned.
//!
//! ## A touched green is NOT a full green
//! Only a genuinely full run on a clean tree writes the pre-push markers, so a partial pass can
//! never make a push skip tests it never ran.

use std::fs;
use std::path::Path;

use super::prepush;
use super::swift_graph::{self, Graph, Selection};
use crate::proc;

/// The cached package description. `swift package describe` costs ~1 s+; `Package.swift` changes
/// rarely.
const GRAPH_CACHE: &str = ".build/pkg-describe.json";

/// The description, from cache when it is not older than `Package.swift`.
///
/// # Errors
/// When `swift package describe` fails or answers something that is not the expected document.
pub fn graph(root: &Path) -> Result<Graph, String> {
    let cache = root.join(GRAPH_CACHE);
    let manifest = root.join("Package.swift");
    let stale = !cache.is_file()
        || match (modified(&manifest), modified(&cache)) {
            (Some(source), Some(cached)) => source > cached,
            _ => true,
        };
    if stale {
        let build = root.join(".build");
        fs::create_dir_all(&build).map_err(|error| format!("{}: {error}", build.display()))?;
        let described = proc::capture("swift", &["package", "describe", "--type", "json"], root)?;
        fs::write(&cache, &described).map_err(|error| format!("{GRAPH_CACHE}: {error}"))?;
        return Graph::parse(&described);
    }
    let text = fs::read_to_string(&cache).map_err(|error| format!("{GRAPH_CACHE}: {error}"))?;
    Graph::parse(&text)
}

/// A file's modification time, or `None` when it does not exist.
fn modified(path: &Path) -> Option<std::time::SystemTime> {
    fs::metadata(path).and_then(|data| data.modified()).ok()
}

/// The crate tree, diffed on its own because no target in the package description owns a path in
/// it.
const RUST_TREE: &str = "rust";

/// What this change set selects, and the one line explaining an escalation.
///
/// # Errors
/// When git or `swift package describe` cannot answer.
pub fn selection(root: &Path, explicit: &[String]) -> Result<(Selection, Option<String>), String> {
    if !explicit.is_empty() {
        return Ok((Selection::Targets(explicit.to_vec()), None));
    }

    let base = prepush::recorded(root, prepush::TREE_MARKER);
    if base.is_empty() || proc::ask("git", &["cat-file", "-e", &base], root).is_none() {
        return Ok((
            Selection::Full,
            Some("test-touched: no full-green baseline — running the FULL suite to establish one".to_owned()),
        ));
    }
    if prepush::ffi_stamp(root) != prepush::recorded(root, prepush::FFI_MARKER) {
        return Ok((
            Selection::Full,
            Some("test-touched: the FFI artifact changed — running the FULL suite".to_owned()),
        ));
    }

    // The tested inputs and the crate tree are ONE diff: two `git diff` calls against the same base
    // would answer about two moments, and an edit landing between them would be attributed by
    // neither. What separates them afterwards is the path, not the question.
    let mut scope: Vec<String> = prepush::TESTED_INPUTS
        .iter()
        .map(|path| (*path).to_owned())
        .collect();
    scope.push(RUST_TREE.to_owned());

    let mut changed: Vec<String> = Vec::new();
    let mut arguments: Vec<String> = vec!["diff".to_owned(), "--name-only".to_owned(), base, "--".to_owned()];
    arguments.extend(scope.iter().cloned());
    changed.extend(lines(&proc::capture("git", &arguments, root)?));

    let mut untracked: Vec<String> = vec![
        "ls-files".to_owned(),
        "--others".to_owned(),
        "--exclude-standard".to_owned(),
        "--".to_owned(),
    ];
    untracked.extend(scope);
    changed.extend(lines(&proc::capture("git", &untracked, root)?));

    changed.sort_unstable();
    changed.dedup();

    let (crates, swift): (Vec<String>, Vec<String>) =
        changed.into_iter().partition(|path| path.starts_with("rust/"));
    let booted = booted_suites(&prepush::daemon_consumers(root)?, &crates);
    Ok((
        swift_graph::attribute(&graph(root)?, &swift).widened(booted),
        None,
    ))
}

/// The test targets that boot a daemon whose crate is among `crates`.
///
/// A pure function of the derived edges and the change set, so the mapping is testable without a
/// git tree: `rust/slopdesk-dropd/src/protocol.rs` names the crate in its SECOND component, and a
/// crate nothing boots contributes nothing rather than escalating — the whole reason `rust/` can be
/// in the diff at all. This gate's own crate is the everyday instance of that.
fn booted_suites(
    consumers: &std::collections::BTreeMap<String, std::collections::BTreeSet<String>>,
    crates: &[String],
) -> std::collections::BTreeSet<String> {
    let mut picked = std::collections::BTreeSet::new();
    for path in crates {
        let Some(name) = path.split('/').nth(1) else {
            continue;
        };
        if let Some(suites) = consumers.get(name) {
            picked.extend(suites.iter().cloned());
        }
    }
    picked
}

/// Non-empty lines, trimmed.
fn lines(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Build incrementally, then run what the selection names.
///
/// # Errors
/// When the build or the selected tests fail.
pub fn run(root: &Path, dry_run: bool, explicit: &[String]) -> Result<(), String> {
    let (selection, note) = selection(root, explicit)?;
    if let Some(line) = &note {
        println!("{line}");
    }
    if dry_run {
        println!("test-touched (dry-run): {}", selection.printed());
        return Ok(());
    }

    proc::run("swift", &["build", "--build-tests"], root)?;
    match selection {
        Selection::Full => {
            if note.is_none() {
                println!("test-touched: change set escalates to the FULL suite");
            }
            proc::run("swift", &["test", "--parallel", "--skip-build"], root)?;
            // Mirror the pre-push gate: a full green on a clean tree warms its cache, BOTH halves.
            prepush::record_green(root)
        },
        Selection::None => {
            println!("test-touched: no SwiftPM test target reaches the change set — build was the gate");
            Ok(())
        },
        Selection::Targets(names) => {
            println!("test-touched: running {}", names.join(" "));
            let filter = format!("^({})\\.", names.join("|"));
            proc::run(
                "swift",
                &["test", "--parallel", "--skip-build", "--filter", &filter],
                root,
            )
        },
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use super::{booted_suites, lines, prepush};

    /// The diff must see every path the tests consume, not only what compiles — and it must reach
    /// that list rather than re-spell it, which is what this file did until the two disagreed.
    #[test]
    fn the_scope_is_the_pre_push_list() {
        assert!(prepush::TESTED_INPUTS.contains(&"scripts"));
        assert!(prepush::TESTED_INPUTS.contains(&"golden"));
        assert!(prepush::TESTED_INPUTS.contains(&"Package.resolved"));
    }

    /// A crate a suite boots selects that suite; a crate nothing boots selects nothing, which is
    /// the property that lets `rust/` be in the diff without escalating every gate edit to the
    /// full run.
    #[test]
    fn only_a_booted_crate_selects_a_suite() {
        let mut consumers: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        consumers.insert(
            "slopdesk-dropd".to_owned(),
            BTreeSet::from(["SlopDeskFileTransferTests".to_owned()]),
        );
        assert_eq!(
            booted_suites(&consumers, &["rust/slopdesk-dropd/src/protocol.rs".to_owned()]),
            BTreeSet::from(["SlopDeskFileTransferTests".to_owned()])
        );
        assert!(
            booted_suites(&consumers, &[
                "rust/slopdesk-devtools/src/gates/touched.rs".to_owned(),
                "rust".to_owned(),
            ])
            .is_empty()
        );
    }

    #[test]
    fn blank_lines_are_not_paths() {
        assert_eq!(lines("a\n\n  \nb\n"), vec!["a".to_owned(), "b".to_owned()]);
        assert!(lines("").is_empty());
    }
}
