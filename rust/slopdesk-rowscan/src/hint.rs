//! Hint Mode's target scan: every span in the visible viewport a two-letter label can pin to.
//!
//! Four kinds, in priority order per row: the `OSC 8` links the program DECLARED and the paths and
//! URLs [`slopdesk_terminal::link`] classifies, then the user's `hint-pattern` matches, then IPv4
//! addresses, then git commit hashes. Every span carries display-CELL columns, and every later
//! match that overlaps an already-accepted span on its row is dropped — a hex run inside a URL must
//! not also light as a hash, and an IP inside a path must not double-light.
//!
//! ## The authored links come in, they are not found here
//!
//! An `OSC 8` run's display text is whatever the program wrote — `gcc` wrapping `file:///…#L12`
//! around the words `src/main.c:12` is the ordinary case — so nothing in `rows` reveals it and no
//! scan could. The caller supplies [`Authored`] runs from the engine, they are accepted before
//! anything is detected, and the overlap rule that was already here does the rest: a detector
//! guessing a different span over a declared link is dropped, because the program said what it
//! meant (`docs/68` §5.5).
//!
//! ## Untrusted on both sides
//!
//! The rows are whatever a remote program printed and the patterns are whatever a human pasted into
//! Settings. That pairing is why the engine is `regex` and not a backtracking one: a match here is
//! linear in the row's length whatever the pattern says, so no `hint-pattern` can hang the overlay.
//! A pattern that does not compile is DROPPED — never a trap, never an error the user has to
//! dismiss — which is also how a pattern written for a backtracking dialect (a lookaround, a
//! backreference) degrades: it stops matching, and the other patterns keep working.
//!
//! ## The columns come from the link scan's clustering
//!
//! [`slopdesk_terminal::link::text_cells`], not a second width table. The hint badge is drawn at
//! `col_start` and the link underline at the link's own `col_start`; on a CJK row those have to be
//! the same number, and the only way to guarantee that is one clustering answering both.
//!
//! An [`Authored`] run is the one exception, and it is not a second table either: its columns are
//! the ENGINE's cells, which is where a wide character's two columns are decided in the first
//! place. `text_cells` exists to reconstruct that count from text; a run that arrives with the
//! engine's own answer must not be re-clustered, or a `～` before the link would move the badge.

use regex::Regex;
use slopdesk_terminal::link::{
    DetectedLink, LinkSchemePolicy, MAX_MATCHES_PER_ROW, authored, bounded_prefix, detect, text_cells,
};

/// One `OSC 8` run a program DECLARED, as the engine reports it.
///
/// The columns are the engine's cells and are used as given — never re-derived from the row's text.
/// An authored link's display text is whatever the program wrote (`click here` over a thirty-byte
/// URL is the ordinary case), so there is nothing in `rows` to cluster that would answer the same
/// question.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Authored {
    /// Index into the rows being scanned.
    pub row: usize,
    /// First display cell of the run.
    pub col_start: usize,
    /// One past the last display cell.
    pub col_end: usize,
    /// The URI every cell of the run carries.
    pub uri: String,
}

/// A user-defined hint pattern: a regex, and the shell-command template a resolved label runs.
///
/// `action`'s `{0}` is replaced with the matched text at the actuation site, which is the client's
/// job — nothing here runs anything. `None` means the pattern carries no action and the target
/// falls back to copy-on-resolve.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pattern {
    /// The regex defining a custom hintable span.
    pub regex: String,
    /// The `{0}` action template, when the pattern carried one.
    pub action: Option<String>,
}

/// What a target is — which decides how a resolved label actuates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TargetKind {
    /// A path, `path:line:col`, URL, `file://` or `mailto:` span the link scan classified.
    ///
    /// It carries the whole [`DetectedLink`] so the actuator routes through the SAME link policy
    /// the ⌘-click and Jump-To paths use. A parallel mapping is a second answer waiting to drift.
    Link(Box<DetectedLink>),
    /// A `[0-9a-f]{7,40}` commit-hash-shaped token carrying at least one hex LETTER.
    GitHash,
    /// A dotted-quad IPv4 address, each octet in `0..=255`.
    IpAddress,
    /// A user `hint-pattern` match, with that pattern's action template.
    Custom {
        /// The `{0}` template the matched text is substituted into, when there is one.
        action: Option<String>,
    },
}

/// One hintable target in the visible viewport.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    /// Index into the rows that were scanned — NOT a scrollback line number.
    pub row: usize,
    /// First display cell of the span.
    pub col_start: usize,
    /// One past the last display cell.
    pub col_end: usize,
    /// The exact matched text.
    pub raw: String,
    /// What it is, and what a resolved label does with it.
    pub kind: TargetKind,
}

/// Every hintable target in `rows`, row-major and left-to-right — the order labels are assigned in.
///
/// `cwd` resolves relative paths and is ignored unless it is itself absolute; `schemes` governs
/// which `scheme://…` URLs count; `declared` carries the `OSC 8` runs the engine reports and is
/// neither scanned nor bounded by `max_scan_columns`, because a program's own link is not a guess
/// this scan is rationing. `max_scan_columns` of `0` scans nothing rather than everything, which is
/// the same bound and the same reading [`detect`] applies.
#[must_use]
pub fn targets(
    rows: &[&str],
    cwd: Option<&str>,
    schemes: &LinkSchemePolicy,
    patterns: &[Pattern],
    declared: &[Authored],
    max_scan_columns: usize,
) -> Vec<Target> {
    if max_scan_columns == 0 {
        return Vec::new();
    }
    // Per-row accepted spans, so an extra match that overlaps a link — or a higher-priority extra
    // match — can be dropped before it is built.
    let mut per_row: Vec<Vec<Target>> = vec![Vec::new(); rows.len()];

    // The authored runs go in FIRST, which is the whole of their priority: every later match is
    // already checked against what is accepted, so a detector guessing a different span over a link
    // the program declared is dropped by the rule that was there all along.
    for run in declared {
        let Some(accepted) = per_row.get_mut(run.row) else {
            continue;
        };
        if accepted.len() >= MAX_MATCHES_PER_ROW {
            continue;
        }
        accepted.push(Target {
            row: run.row,
            col_start: run.col_start,
            col_end: run.col_end,
            raw: run.uri.clone(),
            kind: TargetKind::Link(Box::new(authored(&run.uri, run.row, run.col_start, run.col_end))),
        });
    }

    for link in detect(rows, cwd, schemes, max_scan_columns) {
        let Some(accepted) = per_row.get_mut(link.row) else {
            continue;
        };
        if overlaps(accepted, link.col_start, link.col_end) {
            continue;
        }
        accepted.push(Target {
            row: link.row,
            col_start: link.col_start,
            col_end: link.col_end,
            raw: link.raw.clone(),
            kind: TargetKind::Link(Box::new(link)),
        });
    }

    // Compiled once for the whole scan rather than once per row: a viewport is dozens of rows, and
    // an invalid pattern is dropped here instead of failing quietly forty times.
    let compiled: Vec<(Regex, Option<&str>)> = patterns
        .iter()
        .filter_map(|pattern| {
            Regex::new(&pattern.regex)
                .ok()
                .map(|regex| (regex, pattern.action.as_deref()))
        })
        .collect();
    let git_hash = git_hash_regex();
    let ipv4 = ipv4_regex();

    for (row, line) in rows.iter().enumerate() {
        let bounded = bounded_prefix(line, max_scan_columns);
        if bounded.is_empty() {
            continue;
        }
        let Some(accepted) = per_row.get_mut(row) else {
            continue;
        };
        for (regex, action) in &compiled {
            add_matches(regex, bounded, row, accepted, &mut |_| {
                Some(TargetKind::Custom {
                    action: action.map(str::to_owned),
                })
            });
        }
        if let Some(regex) = ipv4.as_ref() {
            add_matches(regex, bounded, row, accepted, &mut |matched| {
                bounded_by(bounded, matched, is_ip_boundary).then_some(TargetKind::IpAddress)
            });
        }
        if let Some(regex) = git_hash.as_ref() {
            add_matches(regex, bounded, row, accepted, &mut |matched| {
                // A long DECIMAL run is not a commit hash: require at least one hex letter, and a
                // token boundary on both sides so a hash inside a longer word never lights.
                (matched
                    .as_str()
                    .bytes()
                    .any(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_digit())
                    && bounded_by(bounded, matched, is_word_boundary))
                .then_some(TargetKind::GitHash)
            });
        }
    }

    let mut out: Vec<Target> = per_row.into_iter().flatten().collect();
    out.sort_by_key(|target| (target.row, target.col_start));
    out
}

/// Whether `col_start..col_end` touches any span already accepted on the row.
///
/// One predicate for all four kinds, because "a higher-priority span already claimed these cells"
/// is one rule: an authored link outranks a detected one, a detected one outranks a custom pattern,
/// and a hex run inside either must not also light as a hash.
fn overlaps(accepted: &[Target], col_start: usize, col_end: usize) -> bool {
    accepted
        .iter()
        .any(|other| col_start < other.col_end && other.col_start < col_end)
}

/// Runs `regex` over `bounded`, and keeps each match that `build` accepts, does not overlap an
/// already-accepted span, and fits under the per-row cap.
fn add_matches(
    regex: &Regex,
    bounded: &str,
    row: usize,
    accepted: &mut Vec<Target>,
    build: &mut dyn FnMut(&regex::Match<'_>) -> Option<TargetKind>,
) {
    for matched in regex.find_iter(bounded) {
        if accepted.len() >= MAX_MATCHES_PER_ROW {
            break;
        }
        if matched.is_empty() {
            continue;
        }
        let col_start = text_cells(bounded.get(..matched.start()).unwrap_or(""));
        let col_end = col_start.saturating_add(text_cells(matched.as_str()));
        if overlaps(accepted, col_start, col_end) {
            continue;
        }
        let Some(kind) = build(&matched) else { continue };
        accepted.push(Target {
            row,
            col_start,
            col_end,
            raw: matched.as_str().to_owned(),
            kind,
        });
    }
}

/// Whether the scalars either side of `matched` both satisfy `boundary`.
///
/// The two built-in shapes need a boundary the `regex` crate deliberately has no syntax for — it is
/// an automaton, and a lookaround is not one. Spelling the boundary as a predicate over the two
/// neighbouring scalars is the same rule, checked where it can be read.
fn bounded_by(line: &str, matched: &regex::Match<'_>, boundary: fn(char) -> bool) -> bool {
    let before = line
        .get(..matched.start())
        .and_then(|head| head.chars().next_back());
    let after = line.get(matched.end()..).and_then(|tail| tail.chars().next());
    before.is_none_or(boundary) && after.is_none_or(boundary)
}

/// A hash ends where an alphanumeric stops — `deadbeef` inside `xdeadbeefy` is not one.
const fn is_word_boundary(scalar: char) -> bool {
    !scalar.is_ascii_alphanumeric()
}

/// An address ends where a digit or a dot stops, so a five-part run never partially matches.
const fn is_ip_boundary(scalar: char) -> bool {
    !scalar.is_ascii_digit() && scalar != '.'
}

/// Commit-hash shape: a 7–40 character lowercase hex run. The boundary and the "at least one
/// letter" rule are checked by the caller, where they can be read as the rules they are.
fn git_hash_regex() -> Option<Regex> {
    Regex::new("[0-9a-f]{7,40}").ok()
}

/// IPv4 dotted-quad with each octet validated `0..=255` IN the pattern. The boundary is the
/// caller's.
fn ipv4_regex() -> Option<Regex> {
    Regex::new(
        r"(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}",
    )
    .ok()
}

#[cfg(test)]
mod tests {
    use slopdesk_terminal::link::{LinkSchemePolicy, MAX_SCAN_COLUMNS};

    use super::{Authored, Pattern, Target, TargetKind, targets};

    fn scan(rows: &[&str], patterns: &[Pattern]) -> Vec<Target> {
        targets(
            rows,
            None,
            &LinkSchemePolicy::All,
            patterns,
            &[],
            MAX_SCAN_COLUMNS,
        )
    }

    /// One scan with authored runs alongside the rows the program printed.
    fn declared(rows: &[&str], runs: &[Authored]) -> Vec<Target> {
        targets(rows, None, &LinkSchemePolicy::All, &[], runs, MAX_SCAN_COLUMNS)
    }

    fn kinds(rows: &[&str]) -> Vec<TargetKind> {
        scan(rows, &[]).into_iter().map(|target| target.kind).collect()
    }

    #[test]
    fn a_commit_hash_needs_a_letter_and_a_boundary() {
        let found = scan(&["fix in deadbeef1 today"], &[]);
        assert_eq!(found.len(), 1);
        assert_eq!(found.first().map(|target| target.raw.as_str()), Some("deadbeef1"));
        assert_eq!(kinds(&["12345678901234"]), vec![], "a long decimal is not a hash");
        assert_eq!(kinds(&["xdeadbeefy"]), vec![], "inside a word is not a hash");
        assert_eq!(kinds(&["abc123"]), vec![], "six characters is under the floor");
    }

    #[test]
    fn an_address_is_a_quad_and_the_boundary_stops_a_fifth_octet() {
        let found = scan(&["ping 192.168.1.42 ok"], &[]);
        assert_eq!(found.len(), 1);
        assert_eq!(
            found.first().map(|target| target.raw.as_str()),
            Some("192.168.1.42")
        );
        assert_eq!(kinds(&["1.2.3.4.5"]), vec![], "five parts is not a quad");
        assert_eq!(kinds(&["999.1.1.1"]), vec![], "an octet past 255 is not one");
    }

    #[test]
    fn an_extra_match_inside_a_link_is_dropped_rather_than_double_lit() {
        let found = scan(&["see https://example.com/deadbeef1/x"], &[]);
        assert_eq!(found.len(), 1, "the hex inside the URL must not also light");
        assert!(matches!(
            found.first().map(|target| &target.kind),
            Some(&TargetKind::Link(_))
        ));
        let found = scan(&["/var/log/192.168.1.42/app.log"], &[]);
        assert_eq!(found.len(), 1, "the address inside the path must not also light");
    }

    #[test]
    fn a_user_pattern_carries_its_action_and_outranks_the_builtins() {
        let pattern = Pattern {
            regex: "TICKET-[0-9]+".to_owned(),
            action: Some("open {0}".to_owned()),
        };
        let found = scan(&["see TICKET-4242"], &[pattern]);
        assert_eq!(found.len(), 1);
        assert_eq!(
            found.first().map(|target| &target.kind),
            Some(&TargetKind::Custom {
                action: Some("open {0}".to_owned())
            })
        );
    }

    #[test]
    fn a_pattern_that_does_not_compile_is_dropped_and_the_others_still_run() {
        let broken = Pattern {
            regex: "([unclosed".to_owned(),
            action: None,
        };
        let good = Pattern {
            regex: "OK-[0-9]+".to_owned(),
            action: None,
        };
        let found = scan(&["OK-7 here"], &[broken, good]);
        assert_eq!(found.len(), 1, "the broken pattern is a no-op, not a failure");
        assert_eq!(found.first().map(|target| target.raw.as_str()), Some("OK-7"));
    }

    #[test]
    fn a_lookaround_pattern_degrades_to_no_matches_rather_than_a_trap() {
        // The Swift this replaced ran ICU, which has lookaround; the linear-time engine does not.
        // The contract is that such a pattern simply stops matching — the overlay still opens.
        let icu_only = Pattern {
            regex: "(?<![a-z])WORD".to_owned(),
            action: None,
        };
        assert_eq!(scan(&["a WORD here"], &[icu_only]).len(), 0);
    }

    #[test]
    fn the_columns_are_display_cells_and_the_order_is_row_major() {
        let found = scan(&["中文 deadbeef1", "192.168.1.42"], &[]);
        assert_eq!(found.len(), 2);
        let first = found.first().map(|target| (target.row, target.col_start));
        assert_eq!(first, Some((0, 5)), "two wide glyphs and a space are five cells");
        assert_eq!(found.get(1).map(|target| target.row), Some(1));
    }

    #[test]
    fn a_zero_column_bound_scans_nothing() {
        assert!(targets(&["deadbeef1"], None, &LinkSchemePolicy::All, &[], &[], 0).is_empty());
    }

    /// The gap this input closes: the display text is a word, so no scan of the row could find it.
    #[test]
    fn a_declared_link_over_plain_words_is_hintable_at_all() {
        let found = declared(&["see the docs for more"], &[Authored {
            row: 0,
            col_start: 8,
            col_end: 12,
            uri: "https://example.com/manual".to_owned(),
        }]);
        assert_eq!(found.len(), 1);
        // The span is the ENGINE's four cells, not the twenty-six the URI would cluster to.
        assert_eq!(
            found
                .first()
                .map(|target| (target.col_start, target.col_end, target.raw.as_str())),
            Some((8, 12, "https://example.com/manual"))
        );
        assert!(
            found
                .first()
                .is_some_and(|target| matches!(target.kind, TargetKind::Link(_)))
        );
    }

    /// `gcc` wrapping `file://…#L12` around the words it printed — the case `docs/68` §5.5 names.
    #[test]
    fn a_detected_span_under_a_declared_one_is_dropped() {
        let runs = [Authored {
            row: 0,
            col_start: 0,
            col_end: 12,
            uri: "file:///build/src/main.c".to_owned(),
        }];
        let found = declared(&["src/main.c:12: warning"], &runs);
        assert_eq!(found.len(), 1, "the detector's guess lost to the declaration");
        assert_eq!(
            found.first().map(|target| target.raw.as_str()),
            Some("file:///build/src/main.c")
        );
    }

    #[test]
    fn a_detected_span_beside_a_declared_one_survives() {
        let runs = [Authored {
            row: 0,
            col_start: 0,
            col_end: 4,
            uri: "https://example.com/a".to_owned(),
        }];
        let found = declared(&["docs /etc/hosts"], &runs);
        assert_eq!(found.len(), 2);
        assert_eq!(found.get(1).map(|target| target.raw.as_str()), Some("/etc/hosts"));
    }

    /// A hash inside a declared link must not double-light, exactly as one inside a detected link
    /// does not — the priority rule is one rule, not one per kind.
    #[test]
    fn a_hash_inside_a_declared_link_does_not_also_light() {
        let runs = [Authored {
            row: 0,
            col_start: 0,
            col_end: 16,
            uri: "https://git.example/commit/deadbeef1".to_owned(),
        }];
        let found = declared(&["commit deadbeef1"], &runs);
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn a_declared_run_on_a_row_that_does_not_exist_is_ignored() {
        let found = declared(&["one row"], &[Authored {
            row: 9,
            col_start: 0,
            col_end: 3,
            uri: "https://example.com".to_owned(),
        }]);
        assert!(found.is_empty());
    }
}
