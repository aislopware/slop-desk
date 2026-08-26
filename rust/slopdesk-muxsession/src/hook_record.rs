//! Which PANE a Claude Code hook record belongs to.
//!
//! An installed hook POSTs one record per connection to an `AF_UNIX` socket superd owns, and the
//! record is two things stuck together: a `pane=<id>` header line, then the raw hook JSON. The JSON
//! is `slopdesk-hookevent`'s to read. What is here is only the header — the routing key, and the
//! one part of the record hostd itself has to understand before it can hand the rest to the pane
//! that asked for it.
//!
//! ## This is the READING half of a grammar written elsewhere
//!
//! `slopdesk_hook::build_record` frames it: `pane=`, the id, `\n`, the body with its trailing
//! newlines collapsed, `\n`. The drain on this side strips exactly ONE of those trailing newlines
//! before the record gets here, so what [`split`] sees is `build_record`'s output minus its last
//! byte. The fixtures in the tests below are spelled that way on purpose — they are that crate's
//! own test vectors, put back through the reader.
//!
//! ## Validate-then-drop, and the four ways there is no pane
//!
//! The peer is a process nobody here launched, so every malformed shape has to have an answer and
//! none of them may be an error. There is no pane id when:
//!
//! * the record has NO newline at all — a single line, so there is no header to have,
//! * the first line does not start with `pane=` — someone else's framing, or none,
//! * the id is empty (`pane=` with nothing after it) — which `build_record` emits verbatim when the
//!   agent's environment carries no `SLOPDESK_PANE_ID`, rather than inventing one,
//! * the id is not UTF-8 — a pane id is a string on the near side and an unreadable one names no
//!   pane.
//!
//! The router drops a record with no pane, which is why each of those four has to answer `None`
//! rather than something a lookup would then miss on.
//!
//! ## The first two of those four keep the WHOLE record as the JSON; the last two do not
//!
//! That asymmetry is deliberate and it is the edge this module exists to keep. A record with no
//! recognisable header might still be a bare hook body — the framing predates the header — so the
//! whole of it is handed on as the JSON. But a record whose header WAS `pane=` and whose id was
//! merely empty or unreadable has a header, and it must not be fed to the JSON parser: the parse
//! would fail on `pane=` and the failure would be attributed to the agent's body rather than to the
//! id. So those two answer the remainder AFTER the newline.
//!
//! ## Nothing is copied
//!
//! Both halves come back as byte RANGES into the caller's own record. The near side already holds
//! those bytes in a `Data` it read off the socket, and a hook body carries the tool input — a large
//! `Write` puts hundreds of kilobytes through here, twice per tool call. Answering positions is the
//! same convention `detach_retention` uses for a different reason, and here it is the whole cost.

use core::ops::Range;

/// The `pane=` header's marker, spelled once. Case-SENSITIVE: the writer emits lower case and an
/// id-carrying record that spelled it otherwise is not one of ours.
const MARKER: &[u8] = b"pane=";

/// Where each half of a record is, as byte ranges into the record itself.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Split {
    /// The trimmed pane id, or `None` for each of the four ways there is not one.
    pub pane: Option<Range<usize>>,
    /// The hook JSON. Never empty-by-convention — an empty range means the record carried no body,
    /// which the parser drops on its own.
    pub json: Range<usize>,
}

/// Splits one received record into its routing key and its body.
#[must_use]
pub fn split(record: &[u8]) -> Split {
    let whole = Split {
        pane: None,
        json: 0..record.len(),
    };
    // No newline: one line, so there is no header line to be a header. The whole thing is the body.
    let Some(newline) = record.iter().position(|&byte| byte == b'\n') else {
        return whole;
    };
    let Some(first_line) = record.get(..newline) else {
        return whole;
    };
    // Not our framing. Keep the whole record — including this line — as the body.
    if !first_line.starts_with(MARKER) {
        return whole;
    }
    let body = newline.saturating_add(1)..record.len();
    let Some(id_bytes) = first_line.get(MARKER.len()..) else {
        return Split {
            pane: None,
            json: body,
        };
    };
    // An id that is not UTF-8 names no pane on the near side, where a pane id IS a string. The
    // header is still a header, so the body is what follows it.
    let Ok(id) = core::str::from_utf8(id_bytes) else {
        return Split {
            pane: None,
            json: body,
        };
    };
    // `char::is_whitespace` is Unicode `White_Space`, which is exactly the union Foundation's
    // `.whitespacesAndNewlines` names (general category Zs, plus U+0009, plus U+000A–U+000D, U+0085,
    // U+2028 and U+2029). Trimming ASCII by hand would keep a NBSP the near side dropped, and a pane
    // id that differs by one invisible byte routes nowhere with nothing to see in a log.
    let trimmed = id.trim_matches(char::is_whitespace);
    if trimmed.is_empty() {
        return Split {
            pane: None,
            json: body,
        };
    }
    let leading = id
        .len()
        .saturating_sub(id.trim_start_matches(char::is_whitespace).len());
    let start = MARKER.len().saturating_add(leading);
    Split {
        pane: Some(start..start.saturating_add(trimmed.len())),
        json: body,
    }
}

/// [`split`] with the ranges already resolved — the shape a Rust caller wants and the tests read.
#[must_use]
pub fn parts(record: &[u8]) -> (Option<&str>, &[u8]) {
    let found = split(record);
    let pane = found
        .pane
        .and_then(|range| record.get(range))
        .and_then(|bytes| core::str::from_utf8(bytes).ok());
    (pane, record.get(found.json).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::{parts, split};

    /// A record as it reaches the router: `slopdesk_hook::build_record`'s bytes with the single
    /// trailing newline the drain strips already gone.
    fn framed(pane_id: &str, body: &str) -> Vec<u8> {
        format!("pane={pane_id}\n{body}").into_bytes()
    }

    #[test]
    fn a_framed_record_splits_into_its_pane_and_its_json() {
        let record = framed("conn-1:3", r#"{"hook_event_name":"Stop"}"#);
        assert_eq!(
            parts(&record),
            (Some("conn-1:3"), br#"{"hook_event_name":"Stop"}"#.as_slice())
        );
    }

    /// `build_record("", …)` — the relay frames an empty id rather than inventing one, and the
    /// router is where that record stops.
    #[test]
    fn an_empty_pane_id_routes_nowhere() {
        let record = framed("", r#"{"hook_event_name":"Stop"}"#);
        let (pane, json) = parts(&record);
        assert_eq!(pane, None);
        assert_eq!(
            json,
            br#"{"hook_event_name":"Stop"}"#.as_slice(),
            "the header was still a header — feeding `pane=` to the JSON parser would blame the body",
        );
    }

    #[test]
    fn a_record_with_no_header_is_all_json() {
        let record = br#"{"hook_event_name":"Stop"}"#;
        assert_eq!(parts(record), (None, record.as_slice()));
    }

    /// Someone else's first line, or a body that happens to start on one: the whole record —
    /// INCLUDING that line and its newline — is the body, because a bare hook body is a shape this
    /// framing has to keep accepting.
    #[test]
    fn a_first_line_that_is_not_our_header_is_kept_whole() {
        let record = b"{\n\"hook_event_name\":\"Stop\"}";
        assert_eq!(parts(record), (None, record.as_slice()));
        let capitalised = b"PANE=p1\n{}";
        assert_eq!(
            parts(capitalised),
            (None, capitalised.as_slice()),
            "the marker is the writer's, spelled the writer's way",
        );
    }

    /// The id is trimmed with Foundation's `.whitespacesAndNewlines`, which is Unicode
    /// `White_Space` — so a stray carriage return from a shell that framed the record by hand, and
    /// a non-breaking space nobody can see, both come off.
    #[test]
    fn surrounding_whitespace_comes_off_the_id() {
        assert_eq!(parts(b"pane=  p1  \n{}").0, Some("p1"));
        assert_eq!(parts(b"pane=p1\r\n{}").0, Some("p1"), "a CRLF-framed record");
        assert_eq!(parts("pane=\u{00A0}p1\u{00A0}\n{}".as_bytes()).0, Some("p1"));
        assert_eq!(
            parts(b"pane=   \n{}").0,
            None,
            "an id that is nothing but whitespace is an empty id",
        );
    }

    /// A pane id is a `String` on the near side, so bytes that are not UTF-8 name no pane. The body
    /// still follows the header rather than swallowing it.
    #[test]
    fn a_pane_id_that_is_not_utf8_names_no_pane() {
        let mut record = b"pane=".to_vec();
        record.extend_from_slice(&[0xFF, 0xFE]);
        record.extend_from_slice(b"\n{}");
        let (pane, json) = parts(&record);
        assert_eq!(pane, None);
        assert_eq!(json, b"{}");
    }

    /// An id may hold anything but a newline — the header line ends at the first one, and pane ids
    /// are `connectionID:channelID` or `service:<name>`, both of which carry a colon.
    #[test]
    fn the_id_runs_to_the_first_newline_and_no_further() {
        let record = framed("service:code-server", "{}\n{}");
        let (pane, json) = parts(&record);
        assert_eq!(pane, Some("service:code-server"));
        assert_eq!(json, b"{}\n{}", "an embedded newline belongs to the body");
    }

    /// `build_record("P", b"")` frames a body-less record; the drain strips its one trailing
    /// newline, so what arrives is a header and nothing else. The pane is still resolved — dropping
    /// it here would lose the id before the parser got a chance to say the body was empty.
    #[test]
    fn a_header_with_no_body_still_names_its_pane() {
        assert_eq!(parts(b"pane=P\n"), (Some("P"), b"".as_slice()));
    }

    #[test]
    fn an_empty_record_is_empty_rather_than_an_error() {
        assert_eq!(parts(b""), (None, b"".as_slice()));
    }

    /// The ranges are into the caller's own record — nothing is copied, and the positions are the
    /// answer the FFI door hands over. Asserted directly so a refactor that starts allocating is
    /// visible here rather than in a profile.
    #[test]
    fn the_answer_is_positions_into_the_record_the_caller_still_holds() {
        let record = b"pane=  p1 \n{\"a\":1}";
        let found = split(record);
        assert_eq!(found.pane, Some(7..9));
        assert_eq!(found.json, 11..record.len());
        assert_eq!(record.get(7..9), Some(b"p1".as_slice()));
    }
}
