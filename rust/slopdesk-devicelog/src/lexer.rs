//! The three reads both grammars start with: take a whitespace-delimited token, and decide whether
//! it LOOKS like a date or a time.
//!
//! The grammars themselves stay apart, and should — `logcat -v time` puts a priority letter and a
//! `Tag( pid):` header where `log stream --style compact` puts a severity token and a
//! `Process[pid:tid]`, and a console that guessed between them would mis-colour every row of one
//! device. What was never different is the lexing: both consume the remainder the same way, and
//! both check SHAPE rather than value, for the same reason — validating the calendar or the clock
//! here would reject a log written across a timezone change, and the value is never read anyway.
//!
//! The date's LENGTH is the one parameter, because it is the one real difference: `logcat` prints
//! no year (`08-04`) and the unified log does (`2026-08-04`). A parameter rather than a second
//! function so that the "digits and dashes, exactly this long" rule has one spelling.

use core::ops::Range;

/// A byte walk over one line, handing out whitespace-delimited tokens.
///
/// It yields RANGES rather than slices so a caller can hand them straight to a span record without
/// re-deriving where in the line a token sat.
#[derive(Debug, Clone)]
pub struct Cursor<'a> {
    line: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    /// A cursor at the head of `line`.
    #[must_use]
    pub const fn new(line: &'a [u8]) -> Self {
        Self { line, at: 0 }
    }

    /// Where the cursor is, which is the head of everything not yet taken.
    #[must_use]
    pub const fn offset(&self) -> usize {
        self.at
    }

    /// The rest of the line with its leading gap trimmed, as a range.
    #[must_use]
    pub fn rest(&self) -> Range<usize> {
        let mut at = self.at;
        while self.line.get(at).is_some_and(u8::is_ascii_whitespace) {
            at += 1;
        }
        at..self.line.len()
    }

    /// The next whitespace-delimited run, consumed. `None` at end of input.
    pub fn token(&mut self) -> Option<Range<usize>> {
        while self.line.get(self.at).is_some_and(u8::is_ascii_whitespace) {
            self.at += 1;
        }
        let start = self.at;
        while self
            .line
            .get(self.at)
            .is_some_and(|byte| !byte.is_ascii_whitespace())
        {
            self.at += 1;
        }
        if start == self.at {
            None
        } else {
            Some(start..self.at)
        }
    }

    /// The bytes a range names. Empty for a range this cursor's line does not cover, which cannot
    /// happen for a range this cursor produced.
    #[must_use]
    pub fn bytes(&self, span: &Range<usize>) -> &'a [u8] {
        self.line.get(span.clone()).unwrap_or_default()
    }

    /// The line itself, for the fallback that keeps an unrecognised row whole.
    #[must_use]
    pub const fn line(&self) -> &'a [u8] {
        self.line
    }
}

/// `08-04` (`length: 5`) or `2026-08-04` (`length: 10`). Shape only; the value is never read.
#[must_use]
pub fn is_date(token: &[u8], length: usize) -> bool {
    token.len() == length && token.iter().all(|byte| byte.is_ascii_digit() || *byte == b'-')
}

/// `13:50:19.565`. Shape, not value — same reasoning as [`is_date`].
#[must_use]
pub fn is_time(token: &[u8]) -> bool {
    token.len() >= 8
        && token.first().is_some_and(u8::is_ascii_digit)
        && token
            .iter()
            .all(|byte| byte.is_ascii_digit() || *byte == b':' || *byte == b'.')
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a test that cannot take a token has already failed"
)]
mod tests {
    use super::{Cursor, is_date, is_time};

    #[test]
    fn a_token_is_the_run_between_gaps_and_the_range_names_where_it_sat() {
        let line = b"  one   two ";
        let mut cursor = Cursor::new(line);
        assert_eq!(cursor.token().unwrap(), 2..5);
        assert_eq!(cursor.token().unwrap(), 8..11);
        assert_eq!(cursor.token(), None);
    }

    #[test]
    fn an_empty_line_has_no_tokens_rather_than_one_empty_one() {
        assert_eq!(Cursor::new(b"").token(), None);
        assert_eq!(Cursor::new(b"   ").token(), None);
    }

    #[test]
    fn the_rest_keeps_its_own_spacing_once_the_leading_gap_is_off() {
        // A padded table in someone's log output is information, and only the gap the header left
        // behind is this parse's to remove.
        let line = b"head   a    b";
        let mut cursor = Cursor::new(line);
        cursor.token().unwrap();
        assert_eq!(cursor.bytes(&cursor.rest()), b"a    b");
    }

    #[test]
    fn a_date_is_digits_and_dashes_of_exactly_its_length() {
        assert!(is_date(b"08-04", 5));
        assert!(is_date(b"2026-08-04", 10));
        assert!(
            !is_date(b"2026-08-04", 5),
            "the year is the two grammars' one real difference"
        );
        assert!(!is_date(b"08x04", 5));
    }

    #[test]
    fn a_unicode_digit_is_not_a_date_digit() {
        // The Swift this replaces asked `Character.isNumber`, which accepts every Unicode digit. A
        // line whose first token is Arabic-Indic numerals is not a timestamp either source wrote,
        // and narrowing to ASCII only ever moves such a line towards the verbatim fallback.
        assert!(!is_date("٠٨-٠٤".as_bytes(), 5));
    }

    #[test]
    fn a_time_is_shape_and_not_a_clock() {
        assert!(is_time(b"13:50:19.565"));
        assert!(
            is_time(b"99:99:99"),
            "validating the clock would reject a timezone change"
        );
        assert!(!is_time(b"13:50"), "too short to be a stamp either source prints");
        assert!(!is_time(b"a3:50:19.565"));
    }
}
