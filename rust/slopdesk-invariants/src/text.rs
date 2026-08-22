//! The four things `sed`, `awk` and `grep` were doing, as functions.
//!
//! Every extraction in the shell gate was one of these shapes, and each shape had a failure mode
//! the shell hid. `sed -n 's/…/\1/p'` exits 0 when it matches nothing, so a stale extraction reads
//! as an empty set rather than an error; `awk '/start/, /end/'` silently spans to end-of-file when
//! the closing pattern is gone. Here each returns a type that makes the empty case VISIBLE —
//! [`Option`] for a single capture, an empty [`Vec`] for a set — and the caller's rule says what
//! empty means, which is the one thing the shell never made anybody write down.

use std::collections::BTreeSet;
use std::sync::OnceLock;

use regex::Regex;

/// A compiled pattern, built once per process.
///
/// Rules run under rayon and most of them are the same handful of patterns applied to different
/// files, so compiling inside the rule would pay regex construction per call. `cached` keys on the
/// pattern text and is the only way this crate builds a [`Regex`].
///
/// # Panics
/// On an invalid pattern. Every pattern here is a literal in this crate's own source, so an invalid
/// one is a bug in a rule rather than anything about the tree being checked, and failing at the
/// first call is how it gets found.
#[must_use]
pub fn cached(pattern: &str) -> &'static Regex {
    use std::collections::HashMap;
    use std::sync::Mutex;

    static CACHE: OnceLock<Mutex<HashMap<String, &'static Regex>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = cache.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(compiled) = guard.get(pattern) {
        return compiled;
    }
    // MULTILINE, always. Every pattern here is a port of a `grep`, `sed` or `awk` expression, and
    // all three are line-oriented: `^` means start-of-line and `$` means end-of-line to every one of
    // them. Leaving Rust's default in place made `$` mean end-of-FILE, which is not a stricter
    // reading of the same rule — it is a different rule that happens to be satisfied by one line in
    // the file, so the extraction reads empty and `same` reports it as stale.
    let compiled: &'static Regex = Box::leak(Box::new(
        regex::RegexBuilder::new(pattern)
            .multi_line(true)
            .build()
            .unwrap_or_else(|err| panic!("invariant pattern {pattern:?}: {err}")),
    ));
    guard.insert(pattern.to_owned(), compiled);
    compiled
}

/// Whether `haystack` contains a match — `grep -q`.
#[must_use]
pub fn matches(haystack: &str, pattern: &str) -> bool {
    cached(pattern).is_match(haystack)
}

/// How many LINES match — `grep -c`, which counts lines and not matches.
#[must_use]
pub fn count_lines(haystack: &str, pattern: &str) -> usize {
    let regex = cached(pattern);
    haystack.lines().filter(|line| regex.is_match(line)).count()
}

/// The lines that match — `grep`.
#[must_use]
pub fn lines_matching<'a>(haystack: &'a str, pattern: &str) -> Vec<&'a str> {
    let regex = cached(pattern);
    haystack.lines().filter(|line| regex.is_match(line)).collect()
}

/// The first capture group of the first match — `sed -n 's/…/\1/p' | head -1`.
///
/// `None` when nothing matched, which is the case the shell spelled as the empty string and every
/// comparison then accepted as agreement.
#[must_use]
pub fn capture_first(haystack: &str, pattern: &str) -> Option<String> {
    cached(pattern)
        .captures(haystack)
        .and_then(|caps| caps.get(1))
        .map(|m| m.as_str().to_owned())
}

/// Every first-capture-group, in match order, duplicates kept — `sed -n 's/…/\1/p'`.
#[must_use]
pub fn capture_all(haystack: &str, pattern: &str) -> Vec<String> {
    cached(pattern)
        .captures_iter(haystack)
        .filter_map(|caps| caps.get(1).map(|m| m.as_str().to_owned()))
        .collect()
}

/// Every first-capture-group, sorted and deduplicated — `sed -n 's/…/\1/p' | sort -u`.
///
/// This is what a rule comparing two SETS across the language boundary wants: the shell reached for
/// `sort -u` because declaration order is not part of any contract, and a set that differs only in
/// order is not a drift anybody needs told about.
#[must_use]
pub fn capture_set(haystack: &str, pattern: &str) -> BTreeSet<String> {
    cached(pattern)
        .captures_iter(haystack)
        .filter_map(|caps| caps.get(1).map(|m| m.as_str().to_owned()))
        .collect()
}

/// The lines from the first match of `start` through the first following match of `end`, inclusive
/// — `awk '/start/, /end/'`.
///
/// Returns the empty string when `start` never matches. When `start` matches and `end` does not,
/// this returns the REST OF THE FILE, exactly as awk does: the range stays open. That is worth
/// keeping rather than fixing, because it is what the ported rules were written against, and a rule
/// whose range ran away answers with far too much rather than too little — a loud wrong verdict,
/// which is the failure direction this crate chooses everywhere.
#[must_use]
pub fn range(haystack: &str, start: &str, end: &str) -> String {
    let (start_re, end_re) = (cached(start), cached(end));
    let mut out = String::new();
    let mut open = false;
    for line in haystack.lines() {
        if !open {
            if !start_re.is_match(line) {
                continue;
            }
            open = true;
        }
        out.push_str(line);
        out.push('\n');
        // awk tests the end pattern on the START line too only when it is a different line, so the
        // opening line closing its own range needs the guard the `open` flag above already gives:
        // the end test runs on every line INCLUDING the first, which is awk's behaviour for
        // `/a/, /b/` when a line matches both.
        if end_re.is_match(line) && out.lines().count() > 1 {
            break;
        }
    }
    out
}

/// The lines BEFORE the first match of `pattern` — `awk '/pattern/ { exit } { print }'`.
///
/// The shell used this to read a Rust file's code while leaving its `#[cfg(test)]` module out: a
/// test that asserts an absence has to SPELL the banned thing, so a ban that read the whole file
/// would fail on its own proof.
#[must_use]
pub fn before(haystack: &str, pattern: &str) -> String {
    let regex = cached(pattern);
    let mut out = String::new();
    for line in haystack.lines() {
        if regex.is_match(line) {
            break;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// A set rendered the way a diagnostic should read it: space separated, sorted.
#[must_use]
pub fn join(set: &BTreeSet<String>) -> String {
    set.iter().cloned().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::{before, capture_all, capture_first, capture_set, count_lines, range};

    /// The reason `cached` forces multi-line. Every pattern here ports a line-oriented tool, and
    /// `$` meaning end-of-FILE turns a live extraction into a stale-looking empty one.
    #[test]
    fn a_dollar_anchors_a_line_the_way_sed_reads_it() {
        let text = "let a = 1\nstatic let readChunkSize = 32 * 1024\nlet b = 2\n";
        assert_eq!(
            capture_first(text, r"readChunkSize = (.*)$").as_deref(),
            Some("32 * 1024"),
        );
    }

    #[test]
    fn a_capture_that_matches_nothing_answers_none_rather_than_empty() {
        assert_eq!(capture_first("let x = 1", r"VERSION_MAJOR: i32 = (\d+)"), None);
    }

    #[test]
    fn the_first_capture_wins_the_way_head_1_did() {
        let text = "VERSION_MAJOR: i32 = 3;\nVERSION_MAJOR: i32 = 9;\n";
        assert_eq!(
            capture_first(text, r"VERSION_MAJOR: i32 = (\d+)").as_deref(),
            Some("3"),
        );
    }

    #[test]
    fn a_set_sorts_and_deduplicates_while_the_list_keeps_order() {
        let text = "\"resize\"\n\"attach\"\n\"resize\"\n";
        let pattern = "\"([a-z]+)\"";
        assert_eq!(capture_set(text, pattern).into_iter().collect::<Vec<_>>(), vec![
            "attach".to_owned(),
            "resize".to_owned()
        ],);
        assert_eq!(capture_all(text, pattern), vec!["resize", "attach", "resize"]);
    }

    /// grep -c counts LINES, so two matches on one line are one hit. Several ported rules assert an
    /// exact count and would read differently if this counted matches.
    #[test]
    fn a_count_is_of_lines_and_not_of_matches() {
        assert_eq!(count_lines("a a a\nb\na\n", "a"), 2);
    }

    #[test]
    fn a_range_is_inclusive_of_both_ends_and_stops_at_the_first_close() {
        let text = "before\nenum Kind {\n  case a\n}\nafter\nenum Kind {\n}\n";
        assert_eq!(range(text, r"enum Kind \{", r"^\}"), "enum Kind {\n  case a\n}\n");
    }

    /// A range whose closing pattern never matches runs to end-of-file rather than answering
    /// nothing — awk's behaviour, and the one a rule should notice by over-matching.
    #[test]
    fn an_unclosed_range_runs_to_the_end_the_way_awk_does() {
        let text = "before\nenum Kind {\n  case a\n";
        assert_eq!(range(text, r"enum Kind \{", r"^\}"), "enum Kind {\n  case a\n");
    }

    #[test]
    fn before_stops_at_the_first_match_and_excludes_it() {
        assert_eq!(
            before("code\n#[cfg(test)]\nmod tests\n", r"#\[cfg\(test\)\]"),
            "code\n"
        );
    }
}
