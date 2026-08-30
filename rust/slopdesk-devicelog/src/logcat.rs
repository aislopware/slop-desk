//! `logcat -v time`, one line.
//!
//! ```text
//! 08-04 13:50:19.565 D/ActivityManager( 1234): started up
//! ```
//!
//! The case this module exists for is the PID WIDTH. `logcat`'s own format string is
//! `%c/%-8s(%5d): `, so the pid is right-aligned into a fixed-width field: `( 1234):` carries a
//! leading space and splits the header across two whitespace-delimited tokens, while `(12345):`
//! closes inside the first one. Both shapes occur on the same device within one session, and a
//! parser that handles only the narrow one silently drops the entire message of every wide-pid line
//! — a console that looks like it is printing empty rows.

use crate::lexer::{Cursor, is_date, is_time};
use crate::{Line, Severity};

/// The date `logcat` prints, which carries no year.
const DATE_LENGTH: usize = 5;

/// One line. Never fails: an unrecognised line becomes a [`Severity::Plain`] row carrying the whole
/// text as its message.
#[must_use]
pub fn parse(line: &[u8]) -> Line {
    let mut cursor = Cursor::new(line);
    let Some(head) = header(&mut cursor) else {
        return Line::verbatim(line.len());
    };
    Line {
        time: head.time,
        name: tag_name(&cursor, head.tag_start),
        message: body(&cursor, head.tag_start),
        severity: head.severity,
    }
}

/// What the three leading tokens yield when all three are the right shape.
struct Header {
    time: core::ops::Range<usize>,
    severity: Severity,
    /// Where the tag starts — just past the `X/`. The rest of the header is found from here.
    tag_start: usize,
}

/// The three-token preamble, or `None` for a line that is not one.
///
/// The slash is REQUIRED, not decoration: `logcat`'s format string puts one after the priority
/// letter, so without that check any prose whose third word begins with a capital in `VDIWEFAS` —
/// "Everything is fine" — parses as an error row with a tag cut out of the middle of the word.
fn header(cursor: &mut Cursor<'_>) -> Option<Header> {
    let date = cursor.token()?;
    if !is_date(cursor.bytes(&date), DATE_LENGTH) {
        return None;
    }
    let time = cursor.token()?;
    if !is_time(cursor.bytes(&time)) {
        return None;
    }
    let head = cursor.token()?;
    let bytes = cursor.bytes(&head);
    let priority = *bytes.first()?;
    if bytes.get(1) != Some(&b'/') {
        return None;
    }
    Some(Header {
        time,
        severity: severity(priority)?,
        tag_start: head.start + 2,
    })
}

/// `logcat`'s priority letters, mapped onto what a console can ink. `None` for a letter `logcat`
/// does not print, which is what keeps a capitalised word out of the severity slot.
const fn severity(priority: u8) -> Option<Severity> {
    Some(match priority {
        b'F' | b'A' => Severity::Fatal,
        b'E' => Severity::Error,
        b'W' => Severity::Warning,
        b'I' => Severity::Info,
        // `V` is verbose and `D` is debug: both real priorities, both uninked. `S` is `logcat`'s
        // SILENT, which is a filter level rather than something it ever prints, and it is accepted
        // here only so the priority check and the filter alphabet do not disagree.
        b'V' | b'D' | b'S' => Severity::Plain,
        _ => return None,
    })
}

/// `ActivityManager( 1234)` → `ActivityManager`. A tag with no bracket runs to the end of its
/// token; an empty tag (`logcat` allows one) yields an empty range rather than a placeholder.
fn tag_name(cursor: &Cursor<'_>, tag_start: usize) -> core::ops::Range<usize> {
    let mut at = tag_start;
    let line = cursor.line();
    while line
        .get(at)
        .is_some_and(|byte| !byte.is_ascii_whitespace() && *byte != b'(')
    {
        at += 1;
    }
    tag_start..at
}

/// The message, which starts after the `):` that closes the pid.
///
/// The colon is searched for AFTER the bracket, never before it: a tag is allowed to contain one
/// (`Choreographer:x`), and the first colon in the header would then cut the tag short.
///
/// A header with no bracket at all — which `logcat` does not write, but a line that got this far
/// could still hold — falls back to the first colon anywhere after the tag, and to the whole
/// remainder if there is none. Either way a row renders with its text rather than empty.
fn body(cursor: &Cursor<'_>, tag_start: usize) -> core::ops::Range<usize> {
    let line = cursor.line();
    let from = line.get(tag_start..).map_or(tag_start, |tail| {
        tail.iter()
            .position(|byte| *byte == b'(')
            .map_or(tag_start, |at| tag_start + at)
    });
    let colon = line
        .get(from..)
        .and_then(|tail| tail.iter().position(|byte| *byte == b':'));
    let Some(colon) = colon else {
        return trimmed(line, tag_start);
    };
    trimmed(line, from + colon + 1)
}

/// From `at` to the end, with the leading gap dropped.
fn trimmed(line: &[u8], at: usize) -> core::ops::Range<usize> {
    let mut at = at.min(line.len());
    while line.get(at).is_some_and(u8::is_ascii_whitespace) {
        at += 1;
    }
    at..line.len()
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a fixture that is not valid UTF-8 has already failed"
)]
mod tests {
    use super::parse;
    use crate::Severity;

    /// The three text fields, as strings, for a line given as a string.
    fn split(text: &str) -> (String, String, String, Severity) {
        let line = parse(text.as_bytes());
        let cut = |span: core::ops::Range<usize>| {
            core::str::from_utf8(text.as_bytes().get(span).unwrap())
                .unwrap()
                .to_owned()
        };
        (cut(line.time), cut(line.name), cut(line.message), line.severity)
    }

    #[test]
    fn the_ordinary_line_splits_into_time_tag_and_message() {
        let (time, tag, message, severity) = split("08-04 13:50:19.565 D/ActivityManager( 1234): started up");
        assert_eq!(time, "13:50:19.565");
        assert_eq!(tag, "ActivityManager");
        assert_eq!(message, "started up");
        assert_eq!(severity, Severity::Plain);
    }

    #[test]
    fn a_wide_pid_keeps_its_message() {
        // The regression this module exists for: with five pid digits the `):` closes the first
        // token and the message lives in the remainder.
        let (_, tag, message, severity) = split("08-04 13:50:19.565 E/Zygote(12345): boom");
        assert_eq!(tag, "Zygote");
        assert_eq!(message, "boom");
        assert_eq!(severity, Severity::Error);
    }

    #[test]
    fn a_tag_containing_a_colon_is_not_cut_short() {
        let (_, tag, message, _) = split("08-04 13:50:19.565 I/Choreographer:x(12345): skipped 30");
        assert_eq!(tag, "Choreographer:x");
        assert_eq!(message, "skipped 30");
    }

    #[test]
    fn the_message_keeps_its_own_colons() {
        let (_, _, message, severity) = split("08-04 13:50:19.565 W/Net( 999): GET https://x/y: 404");
        assert_eq!(message, "GET https://x/y: 404");
        assert_eq!(severity, Severity::Warning);
    }

    #[test]
    fn the_date_is_dropped_and_the_time_is_kept() {
        let (time, ..) = split("08-04 13:50:19.565 I/X( 1): hi");
        assert_eq!(time, "13:50:19.565");
    }

    #[test]
    fn each_priority_letter_lands_in_its_bucket() {
        for (letter, expected) in [
            ('F', Severity::Fatal),
            // `A` is logcat's ASSERT, which is what a native abort prints: same bucket, because
            // both mean the process is going away.
            ('A', Severity::Fatal),
            ('E', Severity::Error),
            ('W', Severity::Warning),
            ('I', Severity::Info),
            ('V', Severity::Plain),
            // Debug is the largest share of a busy device's output by a wide margin, so tinting it
            // would light up most of the console and leave the errors no louder than anything else.
            ('D', Severity::Plain),
        ] {
            let (_, tag, _, severity) = split(&format!("08-04 13:50:19.565 {letter}/Tag( 1): x"));
            assert_eq!(severity, expected, "priority {letter}");
            assert_eq!(tag, "Tag", "priority {letter}");
        }
    }

    #[test]
    fn a_logcat_banner_survives_verbatim() {
        // A swallowed banner is a console that looks like it lost the boundary between two runs —
        // precisely the line someone reading a crash is looking for.
        let banner = "--------- beginning of crash";
        let (time, tag, message, severity) = split(banner);
        assert_eq!(message, banner);
        assert_eq!(severity, Severity::Plain);
        assert!(tag.is_empty());
        assert!(time.is_empty());
    }

    #[test]
    fn a_line_whose_third_token_merely_starts_with_a_capital_is_not_a_severity() {
        // Without the slash check, any prose beginning with `E` would become an error row.
        let text = "08-04 13:50:19.565 Everything is fine";
        let (_, _, message, severity) = split(text);
        assert_eq!(severity, Severity::Plain);
        assert_eq!(message, text);
    }

    #[test]
    fn a_priority_letter_logcat_never_prints_leaves_the_line_whole() {
        let text = "08-04 13:50:19.565 Z/Tag( 1): x";
        assert_eq!(split(text).2, text);
    }

    #[test]
    fn an_empty_line_is_an_empty_row_rather_than_a_panic() {
        assert_eq!(split("").2, "");
        assert_eq!(split("08-04").2, "08-04");
        assert_eq!(split("08-04 13:50:19.565").2, "08-04 13:50:19.565");
    }

    #[test]
    fn a_message_that_is_empty_does_not_borrow_the_next_field() {
        let (_, tag, message, _) = split("08-04 13:50:19.565 I/Tag(12345): ");
        assert_eq!(tag, "Tag");
        assert_eq!(message, "");
    }

    #[test]
    fn a_header_with_no_bracket_still_renders_its_text() {
        // `logcat` does not write this, but a row that reached here holds text either way, and an
        // empty row is the one outcome worth ruling out.
        let (_, tag, message, _) = split("08-04 13:50:19.565 I/Tag: hi");
        assert_eq!(tag, "Tag:");
        assert_eq!(message, "hi");
    }

    #[test]
    fn every_span_stays_inside_the_line_for_any_input() {
        // The spans cross a C ABI and are used to slice the caller's own buffer, so a range past
        // the end is a crash on the far side rather than a wrong row here.
        for text in [
            "",
            " ",
            "08-04 13:50:19.565 I/",
            "08-04 13:50:19.565 I/(",
            "08-04 13:50:19.565 I/(:",
            "08-04 13:50:19.565 I/Tag(",
            "08-04 13:50:19.565 /Tag( 1): x",
            "\u{a0}08-04 13:50:19.565 I/Tag( 1): x",
        ] {
            let line = parse(text.as_bytes());
            let len = text.len();
            for span in [line.time, line.name, line.message] {
                assert!(
                    span.start <= span.end && span.end <= len,
                    "{text:?} left {span:?}"
                );
            }
        }
    }
}
