//! One timestamp, in the one format the record uses.
//!
//! `YYYY-MM-DDTHH:MM:SSZ` — ISO-8601, UTC, second resolution. A string in the record rather than a
//! number so the file reads the same to a person and to `jq`, and so no decoding strategy has to be
//! agreed with whatever reads it next.
//!
//! ## Why this is hand-rolled and not a date crate
//! It is one direction of one format at one resolution, with no locale, no zone database and no
//! parsing. `chrono` and `time` are both fine crates and both bring a calendar engine, a parser and
//! a zone abstraction to render twenty characters. The conversion below is Howard Hinnant's
//! `civil_from_days`, which is the algorithm those crates use too — it is exact for every day in
//! the proleptic Gregorian calendar and it is short enough to read in a sitting, which is the bar
//! `CLAUDE.md` sets for taking a dependency versus not.
//!
//! Leap SECONDS are not modelled, deliberately: Unix time does not have them either, so a stamp
//! here means "this many seconds since the epoch, rendered", which is the same thing every other
//! reader of this file will believe.

// `integer_division` is a restriction lint about losing precision to truncation. Here the
// truncation IS the calendar: `day_seconds / 3600` is the hour, and every term of Hinnant's
// conversion is a floor division by construction — the leap-day corrections are exactly what
// `/ 4`, `/ 100` and `/ 400` count. A float anywhere in it would be the bug.
#![expect(
    clippy::integer_division,
    reason = "floor division is the calendar conversion, not a rounding accident"
)]

use std::time::{SystemTime, UNIX_EPOCH};

/// Now, as the record spells it.
///
/// A clock before the epoch renders as the epoch rather than failing: this stamp is a REPORT field,
/// and refusing to write a launch record because the machine's clock is wrong would cost the
/// restart path for a line nothing branches on.
#[must_use]
pub fn now_iso8601() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| i64::try_from(since.as_secs()).unwrap_or(0));
    iso8601(seconds)
}

/// A Unix second count as `YYYY-MM-DDTHH:MM:SSZ`.
///
/// Split from [`now_iso8601`] so the calendar arithmetic is testable against known instants without
/// a clock — the half that can be wrong is the half with no I/O in it.
#[must_use]
pub fn iso8601(unix_seconds: i64) -> String {
    // `rem_euclid` rather than `%`: a negative instant must borrow a day rather than produce a
    // negative hour, which is what a plain remainder would give for anything before 1970.
    let day_seconds = unix_seconds.rem_euclid(86_400);
    let days = unix_seconds.div_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let (hour, minute, second) = (day_seconds / 3600, day_seconds % 3600 / 60, day_seconds % 60);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Days since 1970-01-01 as a proleptic Gregorian date.
///
/// Hinnant's `civil_from_days`, unchanged. It shifts the epoch to 0000-03-01 so that the leap day
/// lands at the END of a year and the 400-year cycle becomes plain division — which is what lets
/// the whole conversion be six statements with no table and no loop.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    // 719_468 = days from 0000-03-01 to 1970-01-01. From here on a "year" starts in March.
    let shifted = days + 719_468;
    // Which 400-year era, and where inside it. 146_097 days is exactly 400 Gregorian years.
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    // The three subtractions remove the leap days a naive /365 would over-count: one per 4 years,
    // back one per 100, forward one per 400.
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    // March-based month, 0..=11, then rotated back so January is 1.
    let march_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * march_month + 2) / 5 + 1;
    let month = if march_month < 10 {
        march_month + 3
    } else {
        march_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
#[expect(
    clippy::indexing_slicing,
    reason = "a fixed offset into a stamp whose length was just asserted is the assertion"
)]
mod tests {
    use super::{iso8601, now_iso8601};

    /// Known instants, each chosen for something the arithmetic could get wrong.
    #[test]
    fn known_instants_render_exactly() {
        // The epoch itself: every term is zero, and the March shift has to undo cleanly.
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        // The last second of a day, so hour/minute/second do not borrow into the next one.
        assert_eq!(iso8601(86_399), "1970-01-01T23:59:59Z");
        // The first second of the next day.
        assert_eq!(iso8601(86_400), "1970-01-02T00:00:00Z");
        // 2000-02-29 — a leap day in a century year, which the /100 and /400 terms disagree about.
        assert_eq!(iso8601(951_782_400), "2000-02-29T00:00:00Z");
        // 2024-02-29 — an ordinary leap day, where only the /4 term matters.
        assert_eq!(iso8601(1_709_164_800), "2024-02-29T00:00:00Z");
        // 2100-03-01 — the day AFTER a leap day that does not exist, the case /4 alone gets wrong.
        assert_eq!(iso8601(4_107_542_400), "2100-03-01T00:00:00Z");
        // A time with all three fields distinct, so none of them is reading another's remainder.
        assert_eq!(iso8601(1_735_689_723), "2025-01-01T00:02:03Z");
    }

    /// Before the epoch the day borrows rather than going negative — the `rem_euclid` this exists
    /// for. A plain `%` would render `1969-12-31T-1:00:00Z`.
    #[test]
    fn an_instant_before_the_epoch_borrows_a_day() {
        assert_eq!(iso8601(-1), "1969-12-31T23:59:59Z");
        assert_eq!(iso8601(-86_400), "1969-12-31T00:00:00Z");
    }

    /// The shape, from the real clock: twenty characters, the separators where a reader expects
    /// them, and a trailing `Z` so nothing has to guess the zone.
    #[test]
    fn the_live_stamp_has_the_shape_the_record_documents() {
        let stamp = now_iso8601();
        assert_eq!(stamp.len(), 20, "{stamp}");
        assert!(stamp.ends_with('Z'), "{stamp}");
        assert_eq!(stamp.as_bytes()[4], b'-', "{stamp}");
        assert_eq!(stamp.as_bytes()[7], b'-', "{stamp}");
        assert_eq!(stamp.as_bytes()[10], b'T', "{stamp}");
        assert_eq!(stamp.as_bytes()[13], b':', "{stamp}");
        assert_eq!(stamp.as_bytes()[16], b':', "{stamp}");
        // A clock this far off is a broken machine, not a formatting bug — but a stamp that renders
        // in the wrong millennium would sail past every assertion above.
        assert!(stamp.starts_with("20"), "{stamp}");
    }
}
