//! The PANEL's end of the Android bridge's one-line request protocol.
//!
//! `slopdesk_androidd::protocol` is the other end of the same grammar: it decodes the request line
//! this module writes and encodes the reply line this module reads. They were a Rust decoder and a
//! Swift encoder facing each other across a socket — the op names, the field names and the
//! `{"ok":…}` envelope all spelled twice, in two languages, with nothing that could fail if one
//! side gained a field the other did not.
//!
//! ## What crosses, and what does not
//!
//! One connection, one request: a single JSON object followed by `\n`. What happens after the
//! reply line depends on the op — `screenshot` names a byte count and sends a PNG, `logcat` prints
//! until the client hangs up, `open` becomes raw scrcpy bytes — and none of that is here. The
//! SOCKET stays on the near side, along with the ack/stream split that has to happen inside the
//! receive handler. What moved is the part that is a grammar: which fields an op carries, what a
//! refusal says, and how a byte stream of console output becomes lines.
//!
//! ## The one rule that is not the daemon's
//!
//! [`REFUSED`] and [`UNREADABLE_REPLY`] are the panel's own sentences, for the two refusals the
//! host does not word itself: a reply that is not an object at all, and one that says `ok: false`
//! with no `error`. Every other failure sentence on this path is the HOST's, forwarded verbatim,
//! because the host already decided which of its failures are worth telling apart.

use serde_json::{Map, Value};

/// What the panel asks the bridge for. The byte is the door's; the verb is the wire's.
///
/// Seven rather than the four the client class advertises: `screenshot`, `logcat` and `open` are
/// requests like the others and differ only in what they do with the socket afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum BridgeOp {
    /// Every device the host can see, running or merely defined.
    List = 0,
    /// Start an AVD by name. The one op that names no serial — there is not one yet.
    Boot = 1,
    /// Stop a running device by serial.
    Shutdown = 2,
    /// One emulator-console command, answered in the reply's `output`.
    Console = 3,
    /// One PNG capture: the reply names a byte count and the bytes follow it.
    Screenshot = 4,
    /// `logcat` at a priority, streamed until the client hangs up.
    Logcat = 5,
    /// The scrcpy mirror: video down, control up, verbatim after the ack.
    Open = 6,
}

impl BridgeOp {
    /// The byte the C door takes.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The op for `byte`, or `None` for a value no build of this crate wrote.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::List),
            1 => Some(Self::Boot),
            2 => Some(Self::Shutdown),
            3 => Some(Self::Console),
            4 => Some(Self::Screenshot),
            5 => Some(Self::Logcat),
            6 => Some(Self::Open),
            _ => None,
        }
    }

    /// The word the daemon reads out of `op`.
    #[must_use]
    pub const fn verb(self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Boot => "boot",
            Self::Shutdown => "shutdown",
            Self::Console => "console",
            Self::Screenshot => "screenshot",
            Self::Logcat => "logcat",
            Self::Open => "open",
        }
    }
}

/// One request line, newline included — or `None` for an op whose required field is empty.
///
/// `serial` and `argument` are EMPTY for absent, which is the same non-answer a null pointer is at
/// the door. `argument` is the op's second field: the AVD name for [`BridgeOp::Boot`], the command
/// for [`BridgeOp::Console`], the priority letter for [`BridgeOp::Logcat`], and nothing at all for
/// the rest.
///
/// **The refusal is the daemon's own rule, moved forward one hop.** `Request::string` treats an
/// empty field as absent precisely because it reaches an argument vector — `adb -s "" shell` is a
/// different command from the one that was meant — so a request the daemon would refuse is one this
/// side should never have sent. Refusing here costs a round trip nobody wanted and lets the near
/// side keep exactly one "the request could not be built" arm, where it used to have one per
/// operation guarding against a JSON encoder that raised rather than threw.
///
/// `max_size` is read for [`BridgeOp::Open`] alone and is NOT validated: the daemon clamps it to
/// the range its encoder accepts and falls back to its own default outside that, so refusing here
/// would turn a mirror that opens at the default size into one that does not open.
#[must_use]
pub fn request_line(op: BridgeOp, serial: &str, argument: &str, max_size: i64) -> Option<String> {
    let mut fields = Map::new();
    fields.insert("op".to_owned(), Value::String(op.verb().to_owned()));

    let mut named = |key: &str, value: &str| -> Option<()> {
        if value.is_empty() {
            return None;
        }
        fields.insert(key.to_owned(), Value::String(value.to_owned()));
        Some(())
    };

    match op {
        BridgeOp::List => {},
        BridgeOp::Boot => named("avd", argument)?,
        BridgeOp::Shutdown | BridgeOp::Screenshot => named("serial", serial)?,
        BridgeOp::Console => {
            named("serial", serial)?;
            named("command", argument)?;
        },
        BridgeOp::Logcat => {
            named("serial", serial)?;
            named("level", argument)?;
        },
        BridgeOp::Open => {
            named("serial", serial)?;
            fields.insert("maxSize".to_owned(), Value::from(max_size));
        },
    }

    Some(format!("{}\n", Value::Object(fields)))
}

/// The panel's word for a host that said `ok: false` and named no reason.
pub const REFUSED: &str = "The host refused.";

/// The panel's word for a reply line that is not a JSON object at all.
pub const UNREADABLE_REPLY: &str = "The host's reply made no sense.";

/// Why the host refused, or `None` for a reply that acked.
///
/// The three arms the near side used to spell for itself: not an object → [`UNREADABLE_REPLY`];
/// `ok` anything but `true` → the host's own `error`, or [`REFUSED`] when it named none; otherwise
/// the reply stands and the caller reads its fields.
///
/// **An `error` that is present but EMPTY reads as [`REFUSED`] rather than as an empty sentence.**
/// The near side shows this string to a person, so a blank one is a dialog with no text in it — and
/// it is what makes the door's `0` sentinel sound, since every answer this function gives is a
/// non-empty sentence by construction.
#[must_use]
pub fn reply_failure(line: &[u8]) -> Option<String> {
    let Some(fields) = object(line) else {
        return Some(UNREADABLE_REPLY.to_owned());
    };
    if fields.get("ok").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let named = fields
        .get("error")
        .and_then(Value::as_str)
        .filter(|message| !message.is_empty());
    Some(named.map_or_else(|| REFUSED.to_owned(), ToOwned::to_owned))
}

/// What one console command printed. An absent `output` and an empty one are the same answer —
/// the console prints nothing either way, and a flag would name a distinction the surface cannot
/// act on.
#[must_use]
pub fn console_output(line: &[u8]) -> String {
    object(line)
        .and_then(|fields| {
            fields
                .get("output")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .unwrap_or_default()
}

/// The largest capture the panel will collect.
///
/// A 4K tablet's PNG is a few megabytes; sixteen is well past any real screen and short of a number
/// that could be an allocation attack. The ceiling belongs on this side because the count is the
/// HOST's claim about what is coming, and a claim is exactly the kind of number a client checks.
pub const SCREENSHOT_LIMIT: usize = 16 << 20;

/// How many PNG bytes follow the ack, or `None` for a count this panel will not collect.
///
/// `None` covers all three refusals at once — no `bytes` field, a count of zero or less, and a
/// count past [`SCREENSHOT_LIMIT`] — because the near side does the same thing with each: it stops,
/// with the one sentence that says the capture made no sense.
///
/// Both JSON spellings of an integer are accepted, for `Request::int`'s reason at the other end of
/// this wire: a decoder decides between integer and float from the literal's own syntax, and a
/// count written `5.0` is still five. The float arm is range-checked before it converts, so a
/// `NaN` or a `1e300` is a refused field rather than an arbitrary number.
#[must_use]
pub fn screenshot_bytes(line: &[u8]) -> Option<usize> {
    let count = object(line).and_then(|fields| integer(fields.get("bytes")?))?;
    let count = usize::try_from(count).ok()?;
    (count > 0 && count <= SCREENSHOT_LIMIT).then_some(count)
}

/// One reply line as its object, or `None` for anything that is not one.
fn object(line: &[u8]) -> Option<Map<String, Value>> {
    let value: Value = serde_json::from_slice(line).ok()?;
    match value {
        Value::Object(fields) => Some(fields),
        _ => None,
    }
}

/// A JSON number as an integer, accepting the float spelling of a whole one.
#[expect(
    clippy::cast_possible_truncation,
    reason = "the range and fract guards above are what make the conversion exact; `as` on an out-of-range \
              float saturates silently, which is what they refuse"
)]
fn integer(value: &Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return Some(number);
    }
    let number = value.as_f64()?;
    (number.is_finite() && number.fract() == 0.0 && number >= -(2_f64.powi(53)) && number <= 2_f64.powi(53))
        .then_some(number as i64)
}

/// A single console line's ceiling.
///
/// A device can print a stack trace as one line, but a line that never ENDS is a stream that has
/// gone wrong, and holding it costs memory the panel will never show.
pub const LOG_LINE_LIMIT: usize = 1 << 16;

/// The console's byte stream, split into the lines a console row is made of.
///
/// This is the one part of the log lane that has to be right. A chunk boundary lands mid-line
/// constantly on a busy device, so a naive per-chunk split turns one line into two half-rows
/// several times a second — which is why the incomplete tail is held here and not re-derived by
/// whoever reads the next chunk.
#[derive(Debug, Default)]
pub struct LogLineSplitter {
    /// The tail of the last chunk, up to the point where a line was still incomplete.
    partial: Vec<u8>,
}

impl LogLineSplitter {
    /// A splitter at the head of a fresh subscription.
    #[must_use]
    pub const fn new() -> Self {
        Self { partial: Vec::new() }
    }

    /// Folds one freshly received chunk in and answers every line it completed.
    ///
    /// **The flood guard fires only on a buffer that is BOTH over the ceiling and newline-free**,
    /// and it drops the whole buffer rather than a prefix of it. Those are two deliberate halves of
    /// one rule: a 90 KiB line is a legal stack trace as long as something terminated it, and half
    /// of an unterminated one is a row nobody can read attached to a boundary nobody can see.
    ///
    /// A `\r` immediately before the newline is stripped, once. Decoding is LOSSY rather than
    /// refusing: `logcat` passes through whatever bytes an app logged, including invalid UTF-8, and
    /// a dropped line is a hole in a console nobody can explain.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<String> {
        self.partial.extend_from_slice(chunk);
        if self.partial.len() > LOG_LINE_LIMIT && !self.partial.contains(&b'\n') {
            self.partial.clear();
            return Vec::new();
        }
        let mut lines = Vec::new();
        while let Some(newline) = self.partial.iter().position(|byte| *byte == b'\n') {
            let mut line: Vec<u8> = self.partial.drain(..=newline).collect();
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            lines.push(String::from_utf8_lossy(&line).into_owned());
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::{
        BridgeOp, LOG_LINE_LIMIT, LogLineSplitter, REFUSED, SCREENSHOT_LIMIT, UNREADABLE_REPLY,
        console_output, reply_failure, request_line, screenshot_bytes,
    };

    fn decoded(line: &str) -> Value {
        assert!(line.ends_with('\n'), "every request line is terminated");
        serde_json::from_str(line.trim_end_matches('\n')).unwrap_or(Value::Null)
    }

    fn field(line: &str, key: &str) -> Option<String> {
        decoded(line)
            .get(key)
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    }

    #[test]
    fn every_op_survives_the_byte_it_crosses_as() {
        for op in [
            BridgeOp::List,
            BridgeOp::Boot,
            BridgeOp::Shutdown,
            BridgeOp::Console,
            BridgeOp::Screenshot,
            BridgeOp::Logcat,
            BridgeOp::Open,
        ] {
            assert_eq!(BridgeOp::from_byte(op.as_byte()), Some(op));
        }
        assert_eq!(BridgeOp::from_byte(7), None);
        assert_eq!(BridgeOp::from_byte(u8::MAX), None);
    }

    #[test]
    fn the_listing_request_carries_nothing_but_its_verb() {
        let line = request_line(BridgeOp::List, "", "", 0).unwrap_or_default();
        assert_eq!(field(&line, "op").as_deref(), Some("list"));
        assert_eq!(decoded(&line).as_object().map(serde_json::Map::len), Some(1));
    }

    #[test]
    fn each_op_names_the_fields_the_daemon_reads() {
        let boot = request_line(BridgeOp::Boot, "", "Pixel_8", 0).unwrap_or_default();
        assert_eq!(field(&boot, "avd").as_deref(), Some("Pixel_8"));
        // A boot names no serial: there is not one yet.
        assert_eq!(field(&boot, "serial"), None);

        let shutdown = request_line(BridgeOp::Shutdown, "emulator-5554", "", 0).unwrap_or_default();
        assert_eq!(field(&shutdown, "serial").as_deref(), Some("emulator-5554"));

        let console = request_line(BridgeOp::Console, "emulator-5554", "rotate", 0).unwrap_or_default();
        assert_eq!(field(&console, "command").as_deref(), Some("rotate"));
        assert_eq!(field(&console, "serial").as_deref(), Some("emulator-5554"));

        let logcat = request_line(BridgeOp::Logcat, "emulator-5554", "W", 0).unwrap_or_default();
        assert_eq!(field(&logcat, "level").as_deref(), Some("W"));

        let shot = request_line(BridgeOp::Screenshot, "emulator-5554", "", 0).unwrap_or_default();
        assert_eq!(field(&shot, "serial").as_deref(), Some("emulator-5554"));
    }

    #[test]
    fn the_mirror_carries_its_size_as_a_number_the_daemon_can_clamp() {
        let line = request_line(BridgeOp::Open, "emulator-5554", "", 1024).unwrap_or_default();
        assert_eq!(decoded(&line).get("maxSize").and_then(Value::as_i64), Some(1024));
        // Out of the daemon's own 320…4096 range, and still SENT: it falls back to its default
        // rather than refusing, so a refusal here would lose a mirror that would have opened.
        let wild = request_line(BridgeOp::Open, "emulator-5554", "", 16384).unwrap_or_default();
        assert_eq!(decoded(&wild).get("maxSize").and_then(Value::as_i64), Some(16384));
    }

    #[test]
    fn an_op_missing_its_required_field_is_refused_rather_than_sent_empty() {
        assert_eq!(request_line(BridgeOp::Boot, "", "", 0), None);
        assert_eq!(request_line(BridgeOp::Shutdown, "", "", 0), None);
        assert_eq!(request_line(BridgeOp::Screenshot, "", "", 0), None);
        assert_eq!(request_line(BridgeOp::Console, "serial", "", 0), None);
        assert_eq!(request_line(BridgeOp::Console, "", "rotate", 0), None);
        assert_eq!(request_line(BridgeOp::Logcat, "serial", "", 0), None);
        assert_eq!(request_line(BridgeOp::Open, "", "", 1024), None);
    }

    #[test]
    fn a_quote_in_what_the_user_typed_cannot_end_the_object_early() {
        let line = request_line(BridgeOp::Console, "s", "geo fix \"1\" \\ \n", 0).unwrap_or_default();
        assert_eq!(field(&line, "command").as_deref(), Some("geo fix \"1\" \\ \n"));
        // Exactly one newline in the line, and it is the terminator.
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn an_acked_reply_has_no_failure() {
        assert_eq!(reply_failure(br#"{"ok":true,"devices":[]}"#), None);
    }

    #[test]
    fn the_hosts_own_complaint_is_forwarded_verbatim() {
        assert_eq!(
            reply_failure(br#"{"ok":false,"error":"no such avd"}"#).as_deref(),
            Some("no such avd")
        );
    }

    #[test]
    fn a_refusal_with_no_readable_reason_still_reads_as_a_sentence() {
        assert_eq!(reply_failure(br#"{"ok":false}"#).as_deref(), Some(REFUSED));
        // Present but empty, and present but not a string: both are a blank dialog otherwise.
        assert_eq!(
            reply_failure(br#"{"ok":false,"error":""}"#).as_deref(),
            Some(REFUSED)
        );
        assert_eq!(
            reply_failure(br#"{"ok":false,"error":7}"#).as_deref(),
            Some(REFUSED)
        );
        // A missing `ok` is a refusal too — the field is the ack.
        assert_eq!(reply_failure(br#"{"devices":[]}"#).as_deref(), Some(REFUSED));
        assert_eq!(reply_failure(br#"{"ok":"true"}"#).as_deref(), Some(REFUSED));
    }

    #[test]
    fn a_reply_that_is_not_an_object_says_so_in_its_own_words() {
        for line in [
            &b"this is not json"[..],
            b"[1,2,3]",
            b"\"ok\"",
            b"",
            &[0xFF, 0xFE][..],
        ] {
            assert_eq!(reply_failure(line).as_deref(), Some(UNREADABLE_REPLY));
        }
    }

    #[test]
    fn console_output_reads_the_field_and_folds_every_absence_to_nothing() {
        assert_eq!(console_output(br#"{"ok":true,"output":"OK\n"}"#), "OK\n");
        assert_eq!(console_output(br#"{"ok":true}"#), "");
        assert_eq!(console_output(br#"{"ok":true,"output":42}"#), "");
        assert_eq!(console_output(b"not json"), "");
    }

    #[test]
    fn a_screenshot_count_is_taken_only_inside_the_ceiling() {
        assert_eq!(screenshot_bytes(br#"{"ok":true,"bytes":2048}"#), Some(2048));
        assert_eq!(
            screenshot_bytes(format!(r#"{{"bytes":{SCREENSHOT_LIMIT}}}"#).as_bytes()),
            Some(SCREENSHOT_LIMIT)
        );
        assert_eq!(
            screenshot_bytes(format!(r#"{{"bytes":{}}}"#, SCREENSHOT_LIMIT + 1).as_bytes()),
            None
        );
        assert_eq!(screenshot_bytes(br#"{"bytes":0}"#), None);
        assert_eq!(screenshot_bytes(br#"{"bytes":-1}"#), None);
        assert_eq!(screenshot_bytes(br#"{"ok":true}"#), None);
        assert_eq!(screenshot_bytes(br#"{"bytes":"2048"}"#), None);
        assert_eq!(screenshot_bytes(b"not json"), None);
    }

    #[test]
    fn a_count_written_as_a_whole_float_is_still_a_count() {
        assert_eq!(screenshot_bytes(br#"{"bytes":2048.0}"#), Some(2048));
        assert_eq!(screenshot_bytes(br#"{"bytes":2048.5}"#), None);
        assert_eq!(screenshot_bytes(br#"{"bytes":1e300}"#), None);
    }

    #[test]
    fn a_chunk_boundary_mid_line_does_not_make_two_rows_of_one() {
        let mut splitter = LogLineSplitter::new();
        assert!(splitter.push(b"first half").is_empty());
        assert_eq!(splitter.push(b" second half\n"), ["first half second half"]);
    }

    #[test]
    fn a_boundary_between_the_carriage_return_and_its_newline_still_strips_one() {
        let mut splitter = LogLineSplitter::new();
        assert!(splitter.push(b"row\r").is_empty());
        assert_eq!(splitter.push(b"\nnext\r\n"), ["row", "next"]);
    }

    #[test]
    fn a_chunk_of_many_lines_answers_all_of_them_at_once() {
        let mut splitter = LogLineSplitter::new();
        assert_eq!(splitter.push(b"a\nb\nc\n"), ["a", "b", "c"]);
        // The empty lines a `logcat` banner leaves behind are rows too.
        assert_eq!(splitter.push(b"\n\n"), ["", ""]);
    }

    #[test]
    fn a_flood_with_no_newline_in_it_is_dropped_whole() {
        let mut splitter = LogLineSplitter::new();
        assert!(splitter.push(&vec![b'x'; LOG_LINE_LIMIT + 1]).is_empty());
        // Nothing survived, so the next terminated line stands alone.
        assert_eq!(splitter.push(b"after\n"), ["after"]);
    }

    #[test]
    fn an_oversized_line_that_a_newline_terminates_survives() {
        let mut splitter = LogLineSplitter::new();
        let mut chunk = vec![b'x'; LOG_LINE_LIMIT + 1];
        chunk.push(b'\n');
        let lines = splitter.push(&chunk);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines.first().map(String::len), Some(LOG_LINE_LIMIT + 1));
    }

    #[test]
    fn a_tail_left_over_the_ceiling_is_still_dropped_on_the_next_chunk() {
        let mut splitter = LogLineSplitter::new();
        let mut chunk = vec![b'a'; 8];
        chunk.push(b'\n');
        chunk.extend(core::iter::repeat_n(b'b', LOG_LINE_LIMIT + 1));
        assert_eq!(splitter.push(&chunk).len(), 1);
        // The tail is over the ceiling with no newline of its own: the next chunk drops it.
        assert!(splitter.push(b"c").is_empty());
        assert_eq!(splitter.push(b"done\n"), ["done"]);
    }

    #[test]
    fn bytes_an_app_logged_that_are_not_utf8_keep_their_row() {
        let mut splitter = LogLineSplitter::new();
        let lines = splitter.push(&[b'o', 0xFF, b'k', b'\n']);
        assert_eq!(lines, ["o\u{FFFD}k"]);
    }

    #[test]
    fn a_lone_carriage_return_row_is_an_empty_row_rather_than_a_lost_one() {
        let mut splitter = LogLineSplitter::new();
        assert_eq!(splitter.push(b"\r\n"), [""]);
        // A `\r` that is not at the end of a line is the app's own byte and stays.
        assert_eq!(splitter.push(b"a\rb\n"), ["a\rb"]);
    }
}
