//! The Outline tab's two readings: how long ago a row ran, and how it ended.
//!
//! Kept free of any palette so the only theme-coupled part is the view's gutter → colour map. The
//! classification itself is headless.
//!
//! Follows the codebase's coarse-duration convention: a SINGLE coarse unit, integer arithmetic
//! only. The delta is truncated to whole seconds once and every bucket after that is integer
//! division and an ordered integer comparison — no float compare, which is the repo's standing
//! float rule and the reason this is not a `Duration` formatter.

/// Relative time from an instant `seconds_ago` in the past: sub-second is `now`, then `34s ago` /
/// `4m ago` / `2h ago` / `3d ago`.
///
/// It carries the `ago` suffix that a bare duration render — an uptime, an elapsed count — does
/// NOT: the suffix is read only by the Outline, so it lives with the Outline.
///
/// The caller subtracts the two instants, because only the caller has a clock. A NEGATIVE delta is
/// clock skew and clamps to `now` rather than emitting a string with a minus in it, which is why
/// this takes a signed count and not an unsigned one: refusing the negative at the type level would
/// only move the clamp to every call site.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "the truncation IS the coarse unit — a float here would round 59s up to a minute"
)]
pub fn relative_time(seconds_ago: i64) -> String {
    let seconds = seconds_ago.max(0);
    if seconds == 0 {
        return "now".to_owned();
    }
    if seconds < 60 {
        return format!("{seconds}s ago");
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{minutes}m ago");
    }
    let hours = minutes / 60;
    if hours < 24 {
        return format!("{hours}h ago");
    }
    format!("{} ago", DayCount(hours / 24))
}

/// A day count, written as `Nd` — a private wrapper so the format above reads as one unit rather
/// than as an arithmetic expression spliced into a string.
struct DayCount(i64);

impl core::fmt::Display for DayCount {
    fn fmt(&self, out: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(out, "{}d", self.0)
    }
}

/// The Outline row's exit-status gutter bucket.
///
/// Grey while running, green on success, red on a non-zero exit. The view maps this to its own
/// three tokens, so this is the testable classification and the colour map is the only
/// theme-coupled part.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gutter {
    /// Still executing — no `OSC 133 D` yet.
    Running,
    /// Finished with exit 0, or no reported code.
    Succeeded,
    /// Finished with a non-zero exit code.
    Failed,
}

impl Gutter {
    /// The bucket a block status code names.
    ///
    /// The codes are the near side's own `running` / `succeeded` / `failed` order, so the host
    /// status and the Outline cannot disagree about what counts as success. An unrecognised code
    /// reads as [`Gutter::Running`] — the neutral dot — because claiming an outcome for a block
    /// whose status did not survive the crossing is the one wrong answer here.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Succeeded,
            2 => Self::Failed,
            _ => Self::Running,
        }
    }

    /// This bucket's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Running => 0,
            Self::Succeeded => 1,
            Self::Failed => 2,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Gutter, relative_time};

    #[test]
    fn each_bucket_prints_one_coarse_unit() {
        assert_eq!(relative_time(0), "now");
        assert_eq!(relative_time(1), "1s ago");
        assert_eq!(relative_time(59), "59s ago");
        assert_eq!(relative_time(60), "1m ago");
        assert_eq!(relative_time(3599), "59m ago");
        assert_eq!(relative_time(3600), "1h ago");
        assert_eq!(relative_time(86_399), "23h ago");
        assert_eq!(relative_time(86_400), "1d ago");
        assert_eq!(relative_time(86_400 * 3), "3d ago");
    }

    /// Clock skew is the one input that would otherwise print a minus sign at a user.
    #[test]
    fn a_future_instant_clamps_to_now() {
        assert_eq!(relative_time(-1), "now");
        assert_eq!(relative_time(i64::MIN), "now");
    }

    /// A single coarse unit — never `1h 4m ago`.
    #[test]
    fn nothing_prints_two_units() {
        for seconds in [61, 3661, 90_061, 1_000_000] {
            let text = relative_time(seconds);
            assert_eq!(text.split(' ').count(), 2, "{seconds} -> {text:?}");
        }
    }

    #[test]
    fn every_bucket_round_trips_and_an_unknown_code_stays_neutral() {
        for gutter in [Gutter::Running, Gutter::Succeeded, Gutter::Failed] {
            assert_eq!(Gutter::from_code(gutter.code()), gutter);
        }
        assert_eq!(
            Gutter::from_code(200),
            Gutter::Running,
            "an unreadable status must not claim an outcome",
        );
    }
}
