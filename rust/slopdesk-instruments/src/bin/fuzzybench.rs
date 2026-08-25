//! `slopdesk-fuzzybench` — the palette's ranking, against the REAL `fzf`.
//!
//! `rust/slopdesk-fuzzy` is a port of fzf's `FuzzyMatchV2`, not a dependency on an fzf-LIKE crate,
//! and what the palette promises is that it ranks the way fzf ranks. That crate's own tests pin OUR
//! reading of `algo.go`; only this harness can catch the oracle itself moving, because only this
//! harness runs the canonical Go binary on the same corpus and diffs the answers.
//!
//! Two questions, the same two the Swift instrument asked:
//!
//! 1. **Parity** — does the port rank like `fzf --filter`? The match SET (every fuzzy subsequence
//!    hit, which must be identical on ASCII), the top-K ORDER, and score monotonicity over fzf's
//!    own order (a STRICT inversion is a real scoring divergence; an equal-score reorder is a
//!    tiebreak).
//! 2. **Speed** — how fast is it, against fzf's wall clock and against a Bitap (Fuse-style)
//!    baseline on the same corpus.
//!
//! ## The numbers are not the ones in `docs/55` §"The scorer"
//! That table timed the FFI DOOR — `slopdesk_fuzzy_score` as Swift calls it, marshalling included —
//! against the Swift matcher it replaced. This times the crate directly, so it is the algorithm's
//! number with no boundary in it. Both are true; they answer different questions, and quoting one
//! into the other's table would be wrong.
//!
//! `fzf` is optional: without it the parity columns are skipped and the throughput columns still
//! print. Never part of a test suite — it spawns a foreign binary and scales its corpus.
//!
//! ```text
//! slopdesk-fuzzybench [scaleN]     # repeat the corpus up to ~N entries for throughput
//! ```

use std::collections::{HashMap, HashSet};
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The queries every run asks. Short prefixes, camelCase humps and whole words, because those are
/// the three shapes a palette actually receives.
const QUERIES: [&str; 16] = [
    "fz",
    "gc",
    "ff",
    "plt",
    "src",
    "cfg",
    "tcp",
    "fec",
    "mixer",
    "store",
    "palette",
    "fuzzymatch",
    "wsstore",
    "vidproto",
    "readme",
    "pkg",
];

/// The corpus when the program is run outside the package root and `Sources/` cannot be walked.
const FALLBACK: [&str; 15] = [
    "getConfig",
    "git commit",
    "background",
    "fuzzy-finder",
    "fuzzyfinder",
    "PaletteDataSource.swift",
    "SearchMixer",
    "WorkspaceStore",
    "FuzzyMatcher.swift",
    "src/algo/algo.go",
    "README.md",
    "Package.swift",
    "foobar",
    "foo-bar",
    "out-of-bound",
];

/// How many of the top results the ranking-agreement column compares.
const TOP_K: usize = 10;

/// Every Swift path under `dir`, plus each one's basename so boundary cases are exercised.
fn collect_swift(dir: &Path, into: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_swift(&path, into);
            continue;
        }
        if path.extension().and_then(|extension| extension.to_str()) != Some("swift") {
            continue;
        }
        if let Some(text) = path.to_str() {
            into.push(text.to_owned());
        }
        if let Some(base) = path.file_name().and_then(|name| name.to_str()) {
            into.push(base.to_owned());
        }
    }
}

/// Real, representative fuzzy targets, de-duplicated in a deterministic order.
fn load_corpus() -> Vec<String> {
    let mut found = Vec::new();
    collect_swift(Path::new("Sources"), &mut found);
    if found.is_empty() {
        found = FALLBACK.iter().map(|entry| (*entry).to_owned()).collect();
    }
    let mut seen = HashSet::new();
    found
        .into_iter()
        .filter(|entry| !entry.is_empty() && seen.insert(entry.clone()))
        .collect()
}

/// The corpus repeated, with a numeric suffix so entries stay distinct, up to about `target`.
fn scaled(base: &[String], target: usize) -> Vec<String> {
    if target <= base.len() || base.is_empty() {
        return base.to_vec();
    }
    let mut out = base.to_vec();
    let mut round = 0_usize;
    while out.len() < target {
        for entry in base {
            if out.len() >= target {
                break;
            }
            out.push(format!("{entry}#{round}"));
        }
        round = round.saturating_add(1);
    }
    out
}

/// A minimal Bitap — the family Fuse-style matchers use.
///
/// Does the pattern appear as an ordered subsequence, and a crude score of `-(span)` so tighter
/// matches rank higher. It is here to show the "different feel" a matcher with no word-boundary,
/// camelCase or consecutive-run structure has, and as a speed reference point.
fn bitap_score(query: &str, candidate: &str) -> Option<i64> {
    let pattern: Vec<char> = query.to_lowercase().chars().collect();
    if pattern.is_empty() {
        return Some(0);
    }
    let mut matched = 0_usize;
    let mut first: Option<usize> = None;
    let mut last = 0_usize;
    for (position, character) in candidate.to_lowercase().chars().enumerate() {
        let Some(wanted) = pattern.get(matched) else {
            break;
        };
        if character != *wanted {
            continue;
        }
        if first.is_none() {
            first = Some(position);
        }
        last = position;
        matched = matched.saturating_add(1);
    }
    if matched != pattern.len() {
        return None;
    }
    let span = last.saturating_sub(first?);
    Some(-i64::try_from(span).unwrap_or(0))
}

/// Where `fzf` is, or `None` when it is not installed.
fn which_fzf() -> Option<String> {
    let output = Command::new("/usr/bin/env")
        .args(["which", "fzf"])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if path.is_empty() { None } else { Some(path) }
}

/// `fzf --filter=<query>` over the corpus — fzf's own ranked matches, best first.
///
/// The corpus is fed from a SEPARATE thread on purpose. `fzf` writes its answer while it is still
/// reading, so a writer that is also the reader deadlocks the moment the corpus outgrows the pipe
/// buffer — which a `scaleN` run does immediately.
fn run_fzf(query: &str, corpus: &[String]) -> Option<Vec<String>> {
    let mut child = Command::new("fzf")
        .arg(format!("--filter={query}"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut sink = child.stdin.take()?;
    let mut corpus_text = corpus.join("\n");
    corpus_text.push('\n');
    let feeder = std::thread::spawn(move || {
        // A short read on fzf's side is a closed pipe, which is the same nothing as no matches.
        let _written = sink.write_all(corpus_text.as_bytes());
    });
    // Exit status 1 means "no matches", which is a valid empty answer rather than a failure.
    let output = child.wait_with_output().ok()?;
    let _joined = feeder.join();
    let text = String::from_utf8_lossy(&output.stdout);
    Some(
        text.lines()
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect(),
    )
}

/// One fixed-width column, padded left or right.
fn column(text: &str, width: usize, right: bool) -> String {
    let length = text.chars().count();
    if length >= width {
        return text.to_owned();
    }
    let padding = " ".repeat(width - length);
    if right {
        format!("{padding}{text}")
    } else {
        format!("{text}{padding}")
    }
}

/// Everything the run folds across all sixteen queries.
#[derive(Debug, Default)]
struct Totals {
    /// Time in the scoring door, which also returns positions.
    ours_time: Duration,
    /// Time in the score-only door.
    rank_time: Duration,
    /// Candidates scored, summed over queries.
    comparisons: usize,
    /// Queries whose match set was identical to fzf's.
    set_matches: usize,
    /// Queries where the set could be compared at all.
    set_checks: usize,
    /// Summed top-K agreement fractions.
    top_k_sum: f64,
    /// Queries the top-K fraction could be taken over.
    top_k_count: usize,
    /// Queries whose best result was fzf's best result.
    top1_agree: usize,
    /// Queries where a best result existed on both sides.
    top1_count: usize,
    /// Adjacent pairs in fzf's order where our score CONTRADICTS it.
    score_inversions: usize,
    /// Adjacent pairs compared.
    score_pairs: usize,
    /// Candidates where the two doors disagreed about the score.
    rank_disagreements: usize,
}

/// The four parity columns, when fzf answered.
#[derive(Debug)]
struct Parity {
    /// How many candidates fzf matched.
    count: String,
    /// Whether the two match SETS were identical, or by how much they differed.
    set_equal: String,
    /// What fraction of fzf's top-K we also put in our top-K.
    top_k: String,
    /// Whether the single best result agreed.
    top1: String,
}

/// Runs fzf over the same corpus and folds every parity measure into `totals`.
///
/// `ours` is our ranking, best first; `score_of` is our score for each candidate we matched.
fn compare_with_fzf(
    query: &str,
    corpus: &[String],
    ours: &[&str],
    score_of: &HashMap<&str, i32>,
    totals: &mut Totals,
) -> Option<Parity> {
    let theirs = run_fzf(query, corpus)?;

    let ours_set: HashSet<&str> = ours.iter().copied().collect();
    let their_set: HashSet<&str> = theirs.iter().map(String::as_str).collect();
    let identical = ours_set == their_set;
    let set_equal = if identical {
        "yes".to_owned()
    } else {
        format!("Δ{}", ours_set.symmetric_difference(&their_set).count())
    };
    if identical {
        totals.set_matches = totals.set_matches.saturating_add(1);
    }
    totals.set_checks = totals.set_checks.saturating_add(1);

    // Top-K as a SET, which is robust to equal-score ties ordering differently.
    let mut top_k = "—".to_owned();
    let ours_top: HashSet<&str> = ours.iter().copied().take(TOP_K).collect();
    let their_top: HashSet<&str> = theirs.iter().map(String::as_str).take(TOP_K).collect();
    if !their_top.is_empty() {
        let shared = ours_top.intersection(&their_top).count();
        let agreement = shared as f64 / their_top.len().min(TOP_K).max(1) as f64;
        top_k = format!("{:.0}%", agreement * 100.0);
        totals.top_k_sum += agreement;
        totals.top_k_count = totals.top_k_count.saturating_add(1);
    }

    let mut top1 = "—".to_owned();
    if let (Some(theirs_best), Some(ours_best)) = (theirs.first(), ours.first()) {
        let agreed = theirs_best.as_str() == *ours_best;
        top1 = if agreed { "OK" } else { "no" }.to_owned();
        if agreed {
            totals.top1_agree = totals.top1_agree.saturating_add(1);
        }
        totals.top1_count = totals.top1_count.saturating_add(1);
    }

    // Score monotonicity over fzf's order: if fzf puts A before B, our score for A must be at least
    // our score for B. A STRICT violation is a scoring divergence; equality is only a tiebreak.
    for pair in theirs.windows(2) {
        let (Some(before), Some(after)) = (pair.first(), pair.get(1)) else {
            continue;
        };
        let (Some(earlier), Some(later)) =
            (score_of.get(before.as_str()), score_of.get(after.as_str()))
        else {
            continue;
        };
        totals.score_pairs = totals.score_pairs.saturating_add(1);
        if earlier < later {
            totals.score_inversions = totals.score_inversions.saturating_add(1);
        }
    }

    Some(Parity {
        count: theirs.len().to_string(),
        set_equal,
        top_k,
        top1,
    })
}

/// Scores one query over the corpus, folds it into `totals`, and answers the row to print.
fn run_query(query: &str, corpus: &[String], have_fzf: bool, totals: &mut Totals) -> String {
    let started = Instant::now();
    let matched: Vec<(usize, i32)> = corpus
        .iter()
        .enumerate()
        .filter_map(|(index, candidate)| {
            slopdesk_fuzzy::score(query, candidate).map(|found| (index, found.score))
        })
        .collect();
    let elapsed = started.elapsed();
    totals.ours_time += elapsed;
    totals.comparisons = totals.comparisons.saturating_add(corpus.len());

    let started = Instant::now();
    let ranked: Vec<Option<i32>> = corpus
        .iter()
        .map(|candidate| slopdesk_fuzzy::rank(query, candidate))
        .collect();
    totals.rank_time += started.elapsed();
    for (index, candidate) in corpus.iter().enumerate() {
        let scored = slopdesk_fuzzy::score(query, candidate).map(|found| found.score);
        if ranked.get(index).copied().flatten() != scored {
            totals.rank_disagreements = totals.rank_disagreements.saturating_add(1);
        }
    }

    // fzf's DEFAULT tiebreak, so the comparison is apples to apples: score desc, then length asc,
    // then input index asc.
    let mut ordered = matched.clone();
    ordered.sort_by(|left, right| {
        right
            .1
            .cmp(&left.1)
            .then_with(|| {
                let left_length = corpus.get(left.0).map_or(0, |entry| entry.chars().count());
                let right_length = corpus.get(right.0).map_or(0, |entry| entry.chars().count());
                left_length.cmp(&right_length)
            })
            .then_with(|| left.0.cmp(&right.0))
    });
    let ours: Vec<&str> = ordered
        .iter()
        .filter_map(|(index, _)| corpus.get(*index).map(String::as_str))
        .collect();
    let score_of: HashMap<&str, i32> = matched
        .iter()
        .filter_map(|(index, score)| corpus.get(*index).map(|entry| (entry.as_str(), *score)))
        .collect();

    let nanos_each = elapsed.as_secs_f64() * 1e9 / corpus.len().max(1) as f64;
    let parity = if have_fzf {
        compare_with_fzf(query, corpus, &ours, &score_of, totals)
    } else {
        None
    };
    let missing = "—".to_owned();

    format!(
        "{}{}{}{}{}{}{}",
        column(query, 13, false),
        column(&ours.len().to_string(), 7, true),
        column(parity.as_ref().map_or(&missing, |found| &found.count), 8, true),
        column(
            parity.as_ref().map_or(&missing, |found| &found.set_equal),
            10,
            true
        ),
        column(parity.as_ref().map_or(&missing, |found| &found.top_k), 10, true),
        column(&format!("{nanos_each:.1}"), 12, true),
        column(parity.as_ref().map_or(&missing, |found| &found.top1), 8, true)
    )
}

/// Millions of comparisons a second, and nanoseconds each, for one folded duration.
fn throughput(comparisons: usize, spent: Duration) -> (f64, f64) {
    let seconds = spent.as_secs_f64();
    if seconds <= 0.0 || comparisons == 0 {
        return (0.0, 0.0);
    }
    let count = comparisons as f64;
    (count / seconds / 1e6, spent.as_secs_f64() * 1e9 / count)
}

/// Build the corpus, ask every query, then print the folded verdict.
fn main() {
    let scale: usize = std::env::args()
        .nth(1)
        .and_then(|argument| argument.parse().ok())
        .unwrap_or(0);
    let base = load_corpus();
    let corpus = if scale > 0 {
        scaled(&base, scale)
    } else {
        base.clone()
    };
    let fzf = which_fzf();
    let have_fzf = fzf.is_some();

    println!("slopdesk-fuzzybench — rust/slopdesk-fuzzy (fzf V2 port) vs real fzf + Bitap baseline");
    println!("{}", "=".repeat(92));
    println!(
        "corpus: {} entries (base {})  •  queries: {}  •  fzf: {}",
        corpus.len(),
        base.len(),
        QUERIES.len(),
        fzf.unwrap_or_else(|| "NOT FOUND — parity columns skipped".to_owned())
    );
    println!("{}", "-".repeat(92));
    println!(
        "{}{}{}{}{}{}{}",
        column("query", 13, false),
        column("ours", 7, true),
        column("fzf", 8, true),
        column("setEq", 10, true),
        column("top10", 10, true),
        column("ours ns/c", 12, true),
        column("top1=", 8, true)
    );
    println!("{}", "-".repeat(92));

    let mut totals = Totals::default();
    for query in QUERIES {
        println!("{}", run_query(query, &corpus, have_fzf, &mut totals));
    }
    println!("{}", "-".repeat(92));

    let (ours_rate, ours_each) = throughput(totals.comparisons, totals.ours_time);
    println!("ours throughput: {ours_rate:.2} M comparisons/sec  ({ours_each:.1} ns/comparison avg)");
    let (rank_rate, rank_each) = throughput(totals.comparisons, totals.rank_time);
    println!(
        "score-only door: {rank_rate:.2} M comparisons/sec  ({rank_each:.1} ns/comparison avg)  •  {} disagreements with the scoring door",
        totals.rank_disagreements
    );
    if totals.set_checks > 0 {
        println!(
            "match-set parity vs fzf: {}/{} queries identical",
            totals.set_matches, totals.set_checks
        );
    }
    if totals.top_k_count > 0 {
        let average = totals.top_k_sum / totals.top_k_count as f64;
        println!(
            "top-{TOP_K} ranking agreement vs fzf: {:.0}% avg  •  top-1 exact: {}/{}",
            average * 100.0,
            totals.top1_agree,
            totals.top1_count
        );
    }
    if totals.score_pairs > 0 {
        println!(
            "score monotonicity over fzf's order: {}/{} strict inversions (0 ⇒ our scores never \
             contradict fzf's ranking; differences are tiebreaks only)",
            totals.score_inversions, totals.score_pairs
        );
    }

    let mut bitap_time = Duration::ZERO;
    let mut bitap_comparisons = 0_usize;
    for query in QUERIES {
        let started = Instant::now();
        for candidate in &corpus {
            let _scored = bitap_score(query, candidate);
        }
        bitap_time += started.elapsed();
        bitap_comparisons = bitap_comparisons.saturating_add(corpus.len());
    }
    let (bitap_rate, bitap_each) = throughput(bitap_comparisons, bitap_time);
    println!(
        "Bitap baseline throughput: {bitap_rate:.2} M comparisons/sec  ({bitap_each:.1} ns/comparison avg)"
    );
    println!("{}", "=".repeat(92));
}
