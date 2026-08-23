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
//! no pathspec can see it move (`rust/` is untracked, so the diff against the baseline TREE is
//! empty however many crates changed) and the dependency closure cannot help either, since every
//! Swift target that links the xcframework does so through the package graph rather than through a
//! changed file. So the whole suite is the selection.
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

/// The paths the tests CONSUME, which is what the diff is scoped to.
///
/// Wider than what compiles: `scripts/` is read at run time by the gate-contract suites, `golden/`
/// by the sniffer guard, and `Package.resolved` decides external dependency versions.
const PATHSPEC: &[&str] = &[
    "Package.swift",
    "Package.resolved",
    "Sources",
    "Tests",
    "golden",
    "scripts",
];

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

    let mut changed: Vec<String> = Vec::new();
    let mut arguments: Vec<String> = vec!["diff".to_owned(), "--name-only".to_owned(), base, "--".to_owned()];
    arguments.extend(PATHSPEC.iter().map(|path| (*path).to_owned()));
    changed.extend(lines(&proc::capture("git", &arguments, root)?));

    let mut untracked: Vec<String> = vec![
        "ls-files".to_owned(),
        "--others".to_owned(),
        "--exclude-standard".to_owned(),
        "--".to_owned(),
    ];
    untracked.extend(PATHSPEC.iter().map(|path| (*path).to_owned()));
    changed.extend(lines(&proc::capture("git", &untracked, root)?));

    changed.sort_unstable();
    changed.dedup();
    Ok((swift_graph::attribute(&graph(root)?, &changed), None))
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
    use super::{PATHSPEC, lines};

    /// The diff must see every path the tests consume, not only what compiles.
    #[test]
    fn the_pathspec_covers_what_is_only_read() {
        assert!(PATHSPEC.contains(&"scripts"));
        assert!(PATHSPEC.contains(&"golden"));
        assert!(PATHSPEC.contains(&"Package.resolved"));
    }

    #[test]
    fn blank_lines_are_not_paths() {
        assert_eq!(lines("a\n\n  \nb\n"), vec!["a".to_owned(), "b".to_owned()]);
        assert!(lines("").is_empty());
    }
}
