//! `slopdesk jump [query]` — resolving a target directory over the frecency database.
//!
//! A pure fold: the caller feeds the visited folders, the focused pane's cached OSC-7 cwd, `$HOME`
//! and the persisted last-jump source, and gets back a path to `cd` into. No store, no socket, no
//! clock of its own — which is what lets the running app and the CLI reach the same answer without
//! agreeing on anything but this function.
//!
//! ## Semantics
//! - **With a query** — the most-frecent visited folder whose path CONTAINS the query, matched
//!   case-insensitively. No match answers `None`, and the caller reports the error. A query jump
//!   does NOT touch the `$HOME` toggle.
//! - **No query** — a toggle between `$HOME` and the *last jump source*. Away from home: jump home
//!   and remember the cwd being left as the new source. At home: jump back to that source, keeping
//!   it, so the toggle alternates. With no source recorded yet, fall back to the single
//!   most-frecent folder, and failing that stay at `$HOME`.
//! - **`--no-cd`** is a non-committing PREVIEW: it resolves the same path but must not advance the
//!   toggle, because no jump happened.

use crate::frecency::{FolderEntry, ReferenceSeconds, ranked};

/// The outcome of a resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JumpResolution {
    /// The directory to `cd` into, or to print under `--no-cd`.
    pub path: String,
    /// The home-toggle source the caller should persist. On a committed jump this is the advanced
    /// source; on a preview it is the caller's existing source UNCHANGED, so the caller can assign
    /// it unconditionally rather than branching.
    pub last_jump_source: Option<String>,
}

/// Resolves a jump target.
///
/// `query` of `None` — or blank — selects the `$HOME` toggle. `change_directory` is `false` for a
/// `--no-cd` preview. Answers `None` only when a query matched no visited folder.
#[must_use]
pub fn resolve(
    query: Option<&str>,
    entries: &[FolderEntry],
    now: ReferenceSeconds,
    home_path: &str,
    current_cwd: Option<&str>,
    last_jump_source: Option<&str>,
    change_directory: bool,
) -> Option<JumpResolution> {
    // Validate-then-default: an all-whitespace query, cwd or source is treated as absent.
    let trimmed_query = non_empty(query);
    let cwd = non_empty(current_cwd);
    let source = non_empty(last_jump_source);

    let mut next_source = source.map(str::to_owned);
    let path = if let Some(needle) = trimmed_query {
        // Query jump — frecency-ranked substring match; leaves the home toggle untouched.
        let lowered = needle.to_lowercase();
        ranked(entries, now, None)
            .into_iter()
            .find(|entry| entry.path.to_lowercase().contains(&lowered))?
            .path
            .clone()
    } else if let Some(cwd) = cwd.filter(|cwd| *cwd != home_path) {
        // Away from home → go home, remembering where we left as the new source.
        next_source = Some(cwd.to_owned());
        home_path.to_owned()
    } else if let Some(source) = source {
        // At home, or cwd unknown → return to the recorded source, KEEPING it so it alternates.
        source.to_owned()
    } else if let Some(top) = ranked(entries, now, Some(1)).first() {
        // No recorded source yet → the single most-frecent folder.
        top.path.clone()
    } else {
        // Nothing learned at all → stay at home.
        home_path.to_owned()
    };

    Some(JumpResolution {
        path,
        // A preview resolves and prints, but does not advance the toggle: no jump happened.
        last_jump_source: if change_directory {
            next_source
        } else {
            source.map(str::to_owned)
        },
    })
}

/// `text` trimmed of surrounding whitespace, or `None` when it is empty or all whitespace.
fn non_empty(text: Option<&str>) -> Option<&str> {
    text.map(str::trim).filter(|trimmed| !trimmed.is_empty())
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::resolve;
    use crate::frecency::FolderEntry;

    const NOW: f64 = 1_000_000_000.0;
    const HOME: &str = "/Users/me";

    fn entry(path: &str, count: i64, age_seconds: f64) -> FolderEntry {
        FolderEntry::new(path.to_owned(), count, NOW - age_seconds)
    }

    fn db() -> Vec<FolderEntry> {
        vec![
            entry("/Users/me/work/slopdesk", 10, 60.0),
            entry("/Users/me/work/other", 2, 100_000.0),
            entry("/tmp/scratch", 1, 5_000_000.0),
        ]
    }

    #[test]
    fn a_query_picks_the_most_frecent_containing_folder() {
        let resolved = resolve(Some("work"), &db(), NOW, HOME, None, None, true).expect("a match");
        assert_eq!(resolved.path, "/Users/me/work/slopdesk");
    }

    #[test]
    fn a_query_matches_case_insensitively() {
        let resolved = resolve(Some("SLOPdesk"), &db(), NOW, HOME, None, None, true).expect("a match");
        assert_eq!(resolved.path, "/Users/me/work/slopdesk");
    }

    #[test]
    fn a_query_that_matches_nothing_resolves_to_nothing() {
        assert_eq!(resolve(Some("nowhere"), &db(), NOW, HOME, None, None, true), None);
    }

    #[test]
    fn a_query_jump_leaves_the_home_toggle_source_alone() {
        let resolved = resolve(
            Some("scratch"),
            &db(),
            NOW,
            HOME,
            Some("/somewhere/else"),
            Some("/previous"),
            true,
        )
        .expect("a match");
        assert_eq!(resolved.path, "/tmp/scratch");
        assert_eq!(resolved.last_jump_source.as_deref(), Some("/previous"));
    }

    #[test]
    fn away_from_home_the_toggle_goes_home_and_remembers_where_it_left() {
        let resolved = resolve(
            None,
            &db(),
            NOW,
            HOME,
            Some("/Users/me/work/slopdesk"),
            None,
            true,
        )
        .expect("the toggle always resolves");
        assert_eq!(resolved.path, HOME);
        assert_eq!(
            resolved.last_jump_source.as_deref(),
            Some("/Users/me/work/slopdesk")
        );
    }

    #[test]
    fn at_home_the_toggle_returns_to_the_source_and_keeps_it_so_it_alternates() {
        let resolved = resolve(
            None,
            &db(),
            NOW,
            HOME,
            Some(HOME),
            Some("/Users/me/work/slopdesk"),
            true,
        )
        .expect("the toggle always resolves");
        assert_eq!(resolved.path, "/Users/me/work/slopdesk");
        // Kept, not cleared — the next bare jump goes home again.
        assert_eq!(
            resolved.last_jump_source.as_deref(),
            Some("/Users/me/work/slopdesk")
        );
    }

    #[test]
    fn with_no_source_yet_the_toggle_falls_back_to_the_most_frecent_folder() {
        let resolved =
            resolve(None, &db(), NOW, HOME, Some(HOME), None, true).expect("the toggle always resolves");
        assert_eq!(resolved.path, "/Users/me/work/slopdesk");
    }

    #[test]
    fn with_nothing_learned_at_all_the_toggle_stays_at_home() {
        let resolved = resolve(None, &[], NOW, HOME, Some(HOME), None, true).expect("home is the floor");
        assert_eq!(resolved.path, HOME);
        assert_eq!(resolved.last_jump_source, None);
    }

    #[test]
    fn a_preview_resolves_the_same_path_without_advancing_the_toggle() {
        let away = Some("/Users/me/work/slopdesk");
        let committed = resolve(None, &db(), NOW, HOME, away, Some("/previous"), true).expect("resolves");
        let preview = resolve(None, &db(), NOW, HOME, away, Some("/previous"), false).expect("resolves");
        assert_eq!(committed.path, preview.path);
        assert_eq!(
            committed.last_jump_source.as_deref(),
            Some("/Users/me/work/slopdesk")
        );
        assert_eq!(preview.last_jump_source.as_deref(), Some("/previous"));
    }

    #[test]
    fn a_blank_query_cwd_or_source_reads_as_absent() {
        // A whitespace-only query is the toggle, not a query that matches nothing.
        let resolved = resolve(Some("   "), &db(), NOW, HOME, Some("  \n "), Some("\t"), true)
            .expect("the toggle always resolves");
        assert_eq!(resolved.path, "/Users/me/work/slopdesk", "the frecency fallback");
        assert_eq!(resolved.last_jump_source, None);
    }

    #[test]
    fn a_query_is_trimmed_before_it_is_matched() {
        let resolved = resolve(Some("  scratch  "), &db(), NOW, HOME, None, None, true).expect("a match");
        assert_eq!(resolved.path, "/tmp/scratch");
    }

    #[test]
    fn an_unknown_cwd_behaves_like_being_at_home() {
        let resolved = resolve(None, &db(), NOW, HOME, None, Some("/previous"), true).expect("resolves");
        assert_eq!(resolved.path, "/previous");
        assert_eq!(resolved.last_jump_source.as_deref(), Some("/previous"));
    }
}
