//! Ranking the folders a user actually visits: `frequency × recency`, in integers.
//!
//! The client learns working directories from OSC 7 and persists them beside the workspace
//! document. `slopdesk jump`, the open-quickly overlay and the folder rail all order that set the
//! same way, which is why the scorer is one function rather than three sorts.
//!
//! ## Integer and ordered math only
//! The recency term is a small set of INTEGER bucket weights keyed on an entry's age, and the score
//! is an integer multiply — no float accumulation, and no bare `<`/`>` on a `NaN`-capable float.
//! The single place a `f64` appears is the age in seconds; it is guarded for finiteness, clamped
//! with the IEEE-ordered [`f64::max`]/[`f64::min`], and reduced to whole seconds, after which every
//! comparison is `NaN`-free. A corrupt or absurd timestamp can therefore neither trap nor outrank a
//! real entry: it scores as ancient.

/// Seconds since the reference epoch — the same `f64` Foundation's `Date` encodes into the JSON
/// sidecar, so a persisted database round-trips through this crate without a conversion that could
/// lose a bit.
pub type ReferenceSeconds = f64;

/// One persisted folder record: a visited working directory, how often it has been visited, and
/// when it was last visited.
///
/// The store keys entries by [`path`](Self::path); [`access_count`](Self::access_count) is the
/// frequency term and [`last_access`](Self::last_access) the recency term.
#[derive(Debug, Clone, PartialEq)]
pub struct FolderEntry {
    /// The visited directory path — the frecency key, validated by the store before it lands here.
    pub path: String,
    /// How many times this folder has been visited. Never negative in a store-built entry;
    /// [`score`] defensively clamps a hand-edited negative to zero.
    pub access_count: i64,
    /// When the folder was last visited.
    pub last_access: ReferenceSeconds,
}

impl FolderEntry {
    /// A record for one visited path.
    #[must_use]
    pub const fn new(path: String, access_count: i64, last_access: ReferenceSeconds) -> Self {
        Self {
            path,
            access_count,
            last_access,
        }
    }
}

/// Visited within the last hour — the freshest, highest-weight bucket.
pub const WEIGHT_HOUR: i64 = 16;
/// Visited within the last day.
pub const WEIGHT_DAY: i64 = 8;
/// Visited within the last week.
pub const WEIGHT_WEEK: i64 = 4;
/// Visited within the last month (~30 days).
pub const WEIGHT_MONTH: i64 = 2;
/// Older than a month — the lowest weight, still above zero so a frequently-used old folder is
/// ranked down rather than erased.
pub const WEIGHT_STALE: i64 = 1;

/// Bucket thresholds, in whole seconds.
const HOUR_SECONDS: i64 = 3_600;
/// One day.
const DAY_SECONDS: i64 = 86_400;
/// One week.
const WEEK_SECONDS: i64 = 604_800;
/// Thirty days.
const MONTH_SECONDS: i64 = 2_592_000;

/// An upper clamp on the age before the float reduction, so an absurd far-future `last_access` or a
/// corrupt interval can never overflow the integer domain. Roughly 317 years of seconds.
const MAX_AGE_SECONDS: i64 = 10_000_000_000;

/// A clamp on the frequency term so `frequency × weight` cannot overflow for a hand-edited absurd
/// count. Bounded inputs keep the score a well-defined non-negative integer.
const MAX_SCORED_FREQUENCY: i64 = 1_000_000;

/// The recency weight for an entry last visited at `last_access`, observed at `now`.
///
/// A non-finite age is treated as ancient ([`WEIGHT_STALE`]); a future-dated `last_access` — clock
/// skew, a negative age — counts as "just now".
#[must_use]
pub fn recency_weight(now: ReferenceSeconds, last_access: ReferenceSeconds) -> i64 {
    let age_seconds = now - last_access;
    // Validate-then-default: a NaN or infinite interval from a corrupt timestamp reads as ancient.
    // After this guard the ordered comparisons below are well-defined.
    if !age_seconds.is_finite() {
        return WEIGHT_STALE;
    }
    // Ordered min/max rather than `<`/`>` ternaries, per the float convention. NaN is already gone.
    #[expect(
        clippy::cast_precision_loss,
        reason = "MAX_AGE_SECONDS is 1e10, far inside f64's exactly-representable integer range"
    )]
    let bounded = age_seconds.max(0.0).min(MAX_AGE_SECONDS as f64);
    #[expect(
        clippy::cast_possible_truncation,
        reason = "guarded: finite and clamped into [0, MAX_AGE_SECONDS]"
    )]
    let age = bounded as i64;
    if age < HOUR_SECONDS {
        WEIGHT_HOUR
    } else if age < DAY_SECONDS {
        WEIGHT_DAY
    } else if age < WEEK_SECONDS {
        WEIGHT_WEEK
    } else if age < MONTH_SECONDS {
        WEIGHT_MONTH
    } else {
        WEIGHT_STALE
    }
}

/// The frecency score: `frequency × recency_weight`.
///
/// A negative or absurd frequency clamps into `0..=MAX_SCORED_FREQUENCY`, so the score is always a
/// well-defined non-negative integer and the ordering can never invert.
#[must_use]
pub fn score(entry: &FolderEntry, now: ReferenceSeconds) -> i64 {
    let frequency = entry.access_count.clamp(0, MAX_SCORED_FREQUENCY);
    frequency * recency_weight(now, entry.last_access)
}

/// Entries ordered by descending frecency.
///
/// Ties break NEWER-first, so a `limit` keeps the freshest, then by `path` ascending for a fully
/// deterministic order. `limit` of `None` returns every entry.
///
/// The comparison borrows rather than materialising `(entry, score)` pairs the way the Swift did,
/// and the returned `Vec` holds references — the callers all read a path out and drop the rest, so
/// there is no reason for the ranking to clone a database it does not own.
#[must_use]
pub fn ranked(entries: &[FolderEntry], now: ReferenceSeconds, limit: Option<usize>) -> Vec<&FolderEntry> {
    let mut sorted: Vec<&FolderEntry> = entries.iter().collect();
    sorted.sort_by(|left, right| {
        score(right, now)
            .cmp(&score(left, now))
            // `total_cmp` is the ordered float comparison: a corrupt NaN timestamp sorts to one end
            // deterministically instead of making the sort's contract undefined.
            .then_with(|| right.last_access.total_cmp(&left.last_access))
            .then_with(|| left.path.cmp(&right.path))
    });
    if let Some(limit) = limit {
        sorted.truncate(limit);
    }
    sorted
}

#[cfg(test)]
mod tests {
    use super::{
        FolderEntry, WEIGHT_DAY, WEIGHT_HOUR, WEIGHT_MONTH, WEIGHT_STALE, WEIGHT_WEEK, ranked,
        recency_weight, score,
    };

    /// An arbitrary "now" far enough from the epoch that every bucket has room beneath it.
    const NOW: f64 = 1_000_000_000.0;

    fn entry(path: &str, count: i64, age_seconds: f64) -> FolderEntry {
        FolderEntry::new(path.to_owned(), count, NOW - age_seconds)
    }

    #[test]
    fn each_bucket_boundary_falls_on_the_documented_side() {
        assert_eq!(recency_weight(NOW, NOW), WEIGHT_HOUR);
        assert_eq!(recency_weight(NOW, NOW - 3_599.0), WEIGHT_HOUR);
        assert_eq!(recency_weight(NOW, NOW - 3_600.0), WEIGHT_DAY);
        assert_eq!(recency_weight(NOW, NOW - 86_399.0), WEIGHT_DAY);
        assert_eq!(recency_weight(NOW, NOW - 86_400.0), WEIGHT_WEEK);
        assert_eq!(recency_weight(NOW, NOW - 604_799.0), WEIGHT_WEEK);
        assert_eq!(recency_weight(NOW, NOW - 604_800.0), WEIGHT_MONTH);
        assert_eq!(recency_weight(NOW, NOW - 2_591_999.0), WEIGHT_MONTH);
        assert_eq!(recency_weight(NOW, NOW - 2_592_000.0), WEIGHT_STALE);
    }

    #[test]
    fn a_future_timestamp_counts_as_just_now_rather_than_inverting_the_age() {
        assert_eq!(recency_weight(NOW, NOW + 10_000.0), WEIGHT_HOUR);
    }

    #[test]
    fn a_corrupt_timestamp_scores_as_ancient_and_never_traps() {
        assert_eq!(recency_weight(NOW, f64::NAN), WEIGHT_STALE);
        assert_eq!(recency_weight(NOW, f64::INFINITY), WEIGHT_STALE);
        assert_eq!(recency_weight(f64::NAN, NOW), WEIGHT_STALE);
        // Absurdly ancient, past the clamp: still the stale bucket, still no trap.
        assert_eq!(recency_weight(NOW, -1e300), WEIGHT_STALE);
    }

    #[test]
    fn the_score_is_frequency_times_the_bucket_weight() {
        assert_eq!(score(&entry("/a", 3, 0.0), NOW), 3 * WEIGHT_HOUR);
        assert_eq!(score(&entry("/a", 3, 100_000.0), NOW), 3 * WEIGHT_WEEK);
    }

    #[test]
    fn a_hand_edited_negative_count_clamps_to_zero_instead_of_going_negative() {
        assert_eq!(score(&entry("/a", -50, 0.0), NOW), 0);
    }

    #[test]
    fn an_absurd_count_clamps_rather_than_overflowing() {
        let clamped = score(&entry("/a", i64::MAX, 0.0), NOW);
        assert_eq!(clamped, 1_000_000 * WEIGHT_HOUR);
    }

    #[test]
    fn ranking_is_by_descending_score() {
        // Fresh-but-rare vs stale-but-frequent: 1×16 = 16 loses to 20×1 = 20.
        let entries = vec![entry("/fresh", 1, 0.0), entry("/frequent", 20, 5_000_000.0)];
        let order: Vec<&str> = ranked(&entries, NOW, None)
            .iter()
            .map(|folder| folder.path.as_str())
            .collect();
        assert_eq!(order, ["/frequent", "/fresh"]);
    }

    #[test]
    fn ties_break_newer_first_then_by_path() {
        let entries = vec![
            entry("/b", 1, 100.0),
            entry("/a", 1, 100.0),
            entry("/newer", 1, 50.0),
        ];
        let order: Vec<&str> = ranked(&entries, NOW, None)
            .iter()
            .map(|folder| folder.path.as_str())
            .collect();
        assert_eq!(order, ["/newer", "/a", "/b"]);
    }

    #[test]
    fn a_limit_keeps_the_top_n_and_a_limit_past_the_end_is_harmless() {
        let entries = vec![entry("/a", 5, 0.0), entry("/b", 3, 0.0), entry("/c", 1, 0.0)];
        assert_eq!(ranked(&entries, NOW, Some(0)).len(), 0);
        assert_eq!(ranked(&entries, NOW, Some(2)).len(), 2);
        assert_eq!(ranked(&entries, NOW, Some(99)).len(), 3);
        assert_eq!(ranked(&[], NOW, Some(5)).len(), 0);
    }

    #[test]
    fn a_corrupt_entry_never_outranks_a_real_one() {
        let entries = vec![
            FolderEntry::new("/corrupt".to_owned(), 100, f64::NAN),
            entry("/real", 1, 0.0),
        ];
        let order: Vec<&str> = ranked(&entries, NOW, None)
            .iter()
            .map(|folder| folder.path.as_str())
            .collect();
        // 100 × WEIGHT_STALE = 100 still beats 1 × 16, which is the honest arithmetic — what the
        // test pins is that the NaN neither traps nor produces a nondeterministic order.
        assert_eq!(order, ["/corrupt", "/real"]);
        assert_eq!(
            ranked(&entries, NOW, None)
                .iter()
                .map(|folder| folder.path.as_str())
                .collect::<Vec<_>>(),
            order
        );
    }
}
