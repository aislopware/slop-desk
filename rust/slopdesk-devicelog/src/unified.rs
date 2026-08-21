//! `log stream --style compact`, one line.
//!
//! ```text
//! 2026-08-04 13:50:19.565 Df Unity2025Poster[76037:219b94d] [com.acme:ui] laid out
//! ```
//!
//! Simpler than `logcat`'s: the header is four whole tokens and the message is everything after
//! them, because the unified log puts no padding inside a token the way a right-aligned pid does.
//! What it does share is the failure mode — a line split at the wrong token still renders, is still
//! the right length, and is simply attributed to the wrong process at the wrong severity.

use crate::lexer::{Cursor, is_date, is_time};
use crate::{Line, Severity};

/// The date the unified log prints, which carries a year.
const DATE_LENGTH: usize = 10;

/// One line. Never fails: an unrecognised line becomes a [`Severity::Plain`] row carrying the whole
/// text as its message.
#[must_use]
pub fn parse(line: &[u8]) -> Line {
    let mut cursor = Cursor::new(line);
    let Some(date) = cursor.token() else {
        return Line::verbatim(line.len());
    };
    if !is_date(cursor.bytes(&date), DATE_LENGTH) {
        return Line::verbatim(line.len());
    }
    let Some(time) = cursor.token() else {
        return Line::verbatim(line.len());
    };
    if !is_time(cursor.bytes(&time)) {
        return Line::verbatim(line.len());
    }
    let Some(kind) = cursor.token() else {
        return Line::verbatim(line.len());
    };
    let kind = cursor.bytes(&kind);
    if !is_severity_token(kind) {
        return Line::verbatim(line.len());
    }
    let Some(source) = cursor.token() else {
        return Line::verbatim(line.len());
    };
    Line {
        time,
        name: process_name(&cursor, source),
        message: cursor.rest(),
        severity: severity(kind),
    }
}

/// One or two letters, capital first — `E`, `Df`, `Db`. Checked so a line whose third token happens
/// to be a word does not become a severity nobody sent.
fn is_severity_token(token: &[u8]) -> bool {
    matches!(token.len(), 1 | 2)
        && token.first().is_some_and(u8::is_ascii_uppercase)
        && token.iter().all(u8::is_ascii_alphabetic)
}

/// The alphabet, counted off ten thousand real lines (2026-08-04): `Db` debug, `Df` default, `E`
/// error, `I` info, `A` activity, `F` fault.
///
/// Unlike `logcat`'s, a token this build has not seen inks as [`Severity::Plain`] rather than
/// declining the line: the SHAPE check above already did the work of keeping prose out of this
/// slot, and the unified log's type alphabet is a moving target where `logcat`'s eight letters are
/// not.
const fn severity(token: &[u8]) -> Severity {
    match token {
        b"F" => Severity::Fatal,
        b"E" => Severity::Error,
        b"I" => Severity::Info,
        b"Db" | b"A" => Severity::Debug,
        // `Df` is default, the ordinary case and by far the largest share after debug. Inking it
        // would light most of the console and leave the errors no louder than everything else.
        _ => Severity::Plain,
    }
}

/// `Unity2025Poster[76037:219b94d]` → `Unity2025Poster`. The pid/tid pair is noise at a sidebar's
/// width and the name is what anyone scans for. An emitter with no bracket — some kernel-side ones
/// arrive that way — keeps its whole token rather than becoming empty.
fn process_name(cursor: &Cursor<'_>, source: core::ops::Range<usize>) -> core::ops::Range<usize> {
    let bytes = cursor.bytes(&source);
    match bytes.iter().position(|byte| *byte == b'[') {
        Some(at) => source.start..source.start + at,
        None => source,
    }
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a fixture that is not valid UTF-8 has already failed"
)]
mod tests {
    use super::parse;
    use crate::Severity;

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
    fn a_well_formed_line_splits_into_time_severity_process_and_message() {
        let (time, process, message, severity) =
            split("2026-08-04 13:50:19.565 Df Unity2025Poster[76037:219b94d] [com.acme:ui] laid out");
        // The DATE is dropped and the time kept: every row in a console opened now carries the same
        // date, so printing it spends a third of a sidebar's width saying nothing.
        assert_eq!(time, "13:50:19.565");
        assert_eq!(process, "Unity2025Poster");
        assert_eq!(message, "[com.acme:ui] laid out");
        assert_eq!(severity, Severity::Plain);
    }

    #[test]
    fn the_process_loses_its_pid_and_thread_but_keeps_its_name() {
        let (_, process, ..) = split("2026-08-04 13:50:19.565 I SpringBoard[112:5f] up");
        assert_eq!(process, "SpringBoard");
    }

    #[test]
    fn an_emitter_with_no_bracket_keeps_its_whole_token() {
        let (_, process, message, _) = split("2026-08-04 13:50:19.565 E kernel something failed");
        assert_eq!(process, "kernel");
        assert_eq!(message, "something failed");
    }

    #[test]
    fn the_severity_alphabet_collapses_to_what_a_console_can_ink() {
        let ink = |token: &str| split(&format!("2026-08-04 13:50:19.565 {token} proc[1:2] m")).3;
        assert_eq!(ink("F"), Severity::Fatal);
        assert_eq!(ink("E"), Severity::Error);
        assert_eq!(ink("I"), Severity::Info);
        assert_eq!(ink("Db"), Severity::Debug);
        assert_eq!(ink("A"), Severity::Debug);
        assert_eq!(ink("Df"), Severity::Plain);
        // A token the shape accepts but this build has not seen inks as plain rather than guessing.
        assert_eq!(ink("Z"), Severity::Plain);
    }

    #[test]
    fn a_server_banner_is_kept_verbatim_rather_than_dropped() {
        // `log stream` prefaces its output with its own notices. Swallowing them makes a console
        // look like it silently lost the first second, which is the failure hardest to diagnose.
        let text = "getpwuid_r did not find a match for uid 501";
        let (time, process, message, severity) = split(text);
        assert_eq!(message, text);
        assert!(time.is_empty());
        assert!(process.is_empty());
        assert_eq!(severity, Severity::Plain);
    }

    #[test]
    fn a_line_that_only_looks_like_the_grammar_is_not_split_into_one() {
        // Three tokens in the right places, none of them the right shape. Splitting this would
        // attribute a plain sentence to a process called "at".
        let text = "Filtering the log data using \"level\" and more words";
        assert_eq!(split(text).2, text);
        // A date-shaped first token is not enough on its own either.
        let almost = "2026-08-04 not-a-time Df proc[1:2] m";
        assert_eq!(split(almost).2, almost);
        // Nor is a severity slot holding a word.
        let word = "2026-08-04 13:50:19.565 Filtering proc[1:2] m";
        assert_eq!(split(word).2, word);
    }

    #[test]
    fn a_non_ascii_capital_leaves_the_line_whole() {
        // The Swift this replaces asked `Character.isUppercase`, so a Cyrillic capital in the
        // severity slot split the line into a severity nobody sent.
        let text = "2026-08-04 13:50:19.565 Д proc[1:2] m";
        assert_eq!(split(text).2, text);
    }

    #[test]
    fn an_empty_line_survives_as_an_empty_row_rather_than_a_panic() {
        assert_eq!(split("").2, "");
        assert_eq!(split("2026-08-04").2, "2026-08-04");
        assert_eq!(split("2026-08-04 13:50:19.565 I").2, "2026-08-04 13:50:19.565 I");
    }

    #[test]
    fn a_message_keeps_its_internal_spacing_once_the_header_is_off() {
        // Only the leading gap after the process token is trimmed. A log line's own alignment is
        // information — a padded table in someone's output must survive the parse.
        let (_, _, message, _) = split("2026-08-04 13:50:19.565 I p[1:2]   a    b");
        assert_eq!(message, "a    b");
    }

    #[test]
    fn a_line_that_ends_at_the_process_has_an_empty_message() {
        let (_, process, message, _) = split("2026-08-04 13:50:19.565 I p[1:2]");
        assert_eq!(process, "p");
        assert_eq!(message, "");
    }

    #[test]
    fn every_span_stays_inside_the_line_for_any_input() {
        for text in [
            "",
            " ",
            "2026-08-04 13:50:19.565 I [",
            "2026-08-04 13:50:19.565 I [1:2] m",
            "2026-08-04 13:50:19.565 Df p[1:2]",
            "\u{a0}2026-08-04 13:50:19.565 I p[1:2] m",
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
