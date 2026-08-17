//! The screend wire.
//!
//! One length-prefixed request, one length-prefixed reply, big-endian, over an `AF_UNIX`
//! `SOCK_STREAM` socket.
//!
//! Deliberately NOT the mux wire and NOT golden-pinned — this is a private host↔service link
//! between two binaries shipped together, so it carries no negotiation. It is also NOT the
//! supervisor protocol: superd passes file descriptors and owns processes, screend touches neither
//! and needs neither.
//!
//! ## "version-locked by the build" was half true, and the half that was false is why
//! [`hello_payload`] exists
//! Shipped together, yes. RUNNING together, no: `scripts/install-screend.sh` installs a
//! `LaunchAgent`, so a screend started at login outlives every hostd of the day and survives the
//! `brew upgrade` that replaces its binary. The pair are then two different builds talking to each
//! other, which this wire tolerates — it is stable enough that they interoperate — while nothing
//! could TELL that they were. [`HELLO_BANNER`] is unchanged and still the pinned protocol identity;
//! the running build's version rides after it, so hostd can compare what is answering against what
//! is on disk.
//!
//! ```text
//! request  u32 len | u8 verb | u8 flags | u16 rows | u16 cols | u16 pane_len | pane… | raw…
//! reply    u32 len | u8 status | payload…
//! ```
//!
//! `len` counts every byte AFTER itself. Untrusted-input discipline applies as everywhere else in
//! the tree: decode is validate-then-drop — a short, over-long or unrecognised frame yields an
//! error the server answers with a status byte, never a panic.

/// The PROTOCOL identity, not a negotiated version and not the build's version. A mismatch means
/// the two binaries were not shipped together, which is a packaging bug.
///
/// Ratcheted byte for byte against `SlopDeskScreen.ScreenProtocol.helloBanner` by
/// `scripts/check-supervisor.sh`, so it is a constant on both sides and stays one. The running
/// build's version is appended by [`hello_payload`] rather than folded in here, for exactly that
/// reason: a constant a script compares cannot also carry a value that changes every release.
pub const HELLO_BANNER: &[u8] = b"slopdesk-screend 1";

/// What [`Verb::Hello`] actually answers: `slopdesk-screend <protocol> <build version>`.
///
/// Two numbers because they answer two questions that a single one keeps confusing. The protocol
/// digit says what this screend will agree to speak, and changing it is a deliberate edit on both
/// ends. The build version says which screend is speaking — and it moves on any release that
/// touched this daemon's sources, wire or not.
///
/// hostd reads the second to decide whether the screend ANSWERING is the screend on disk. It can
/// afford to act on the answer here where it cannot for superd: screend holds no children and no
/// durable state, its per-pane grids are a cache the next repaint refills, and hostd starts one
/// itself if none is listening (`scripts/install-screend.sh` says the same in its header). A
/// restart costs a repaint. superd's costs every pane.
///
/// Space-separated and appended, never prefixed: `HELLO_BANNER` stays a prefix of this, so a
/// reader that only knows the old payload — the gate scripts, the test fixtures that wait for a
/// bind — keeps matching.
///
/// `build_version` is a PARAMETER rather than an `env!` here, and that is not ceremony: this crate
/// is `slopdesk-screenwire`, so its own `CARGO_PKG_VERSION` is the wire crate's and not the
/// daemon's. The number that ships, that `scripts/tool-stamps.pin` records and that hostd compares
/// against `slopdesk-screend --version`, belongs to `slopdesk-screend`. Reading it here would have
/// answered with a plausible, stable, wrong string.
#[must_use]
pub fn hello_payload(build_version: &str) -> Vec<u8> {
    let mut payload = HELLO_BANNER.to_vec();
    payload.push(b' ');
    payload.extend_from_slice(build_version.as_bytes());
    payload
}

/// The largest request screend will read.
///
/// A cold-reattach compose carries a whole retained ring; 64 MiB is far above the largest ring the
/// host will ever retain and far below anything that could exhaust the daemon.
pub const MAX_FRAME: usize = 64 * 1024 * 1024;

/// Bytes of fixed header after the length prefix.
pub const HEADER_LEN: usize = 8;

/// What the caller is asking for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Verb {
    /// Liveness + identity. No payload; the reply is [`HELLO_BANNER`].
    Hello = 0,
    /// STATELESS: parse `raw` at `rows`×`cols` and return the resulting screen as JSON. Every call
    /// starts from a blank grid — this is the `screen` ctl verb and the detection scan.
    Snapshot = 1,
    /// STATEFUL: feed `raw` into the RESIDENT model for `pane` (created on first use, at
    /// `rows`×`cols`) and return the resulting screen as JSON. `flags & FLAG_RESET` rebuilds the
    /// model first — which is also how a resize is expressed, since a VT model cannot be reflowed.
    Feed = 2,
    /// Drops the resident model for `pane`. Empty payload both ways.
    Forget = 3,
    /// STATELESS: parse `raw` at `rows`×`cols` and return the RENDERED cold-reattach byte stream.
    /// `flags & FLAG_REASSERT_INPUT_MODES` appends the net input-mode state of `raw` after it.
    Compose = 4,
    /// STATELESS: parse `raw` at `rows`×`cols` and return the RENDERED plain transcript.
    Transcript = 5,
    /// STATELESS and GEOMETRY-FREE: return `raw` with every fully-superseded line revision dropped
    /// (the progress-bar churn pass of the replay transform). `rows`/`cols` are ignored — the pass
    /// deliberately has no grid width.
    Collapse = 6,
    // 7 is RETIRED and stays unallocated. It was `Sanitize`, the whole replay transform in one
    // round trip — and the round trip was the mistake: `sanitize` is a pure function, so it is
    // `rust/slopdesk-sanitize` linked into the app now, not a verb. A future verb takes 10.
    /// STATELESS and GEOMETRY-FREE: return `raw` with only the zsh `PROMPT_SP` pass applied
    /// (`slopdesk_sanitize::prompteol`, which screend runs). For the caller holding ONE captured
    /// command block rather than a replay
    /// stream — the whole transform would be wrong there, its other anchors already stripped.
    PromptEolMarks = 8,
    /// STATEFUL: feed a pane's new bytes and answer the DETECTION VERDICT
    /// (screend's `detect::Verdict`) as JSON — not the screen.
    ///
    /// `raw` is `u16 agent_len | agent… | bytes…`: the label of the pane's foreground agent (empty
    /// for none) followed by the PTY chunk. A verb-local framing rather than a wire-layout change,
    /// because the layout is shared with eight other verbs that need no such field.
    ///
    /// `flags & FLAG_RESET` rebuilds the grid; `FLAG_REBUILD_REPLAY` additionally resets the
    /// sync-frame parser (a rebuild replays a DIFFERENT stream, so the parser's position describes
    /// bytes the model no longer holds); `FLAG_AGENT_CHANGED` drops the retained OSC evidence
    /// FIRST, so a sequence spanning the change is attributed to the new agent.
    Detect = 9,
}

impl Verb {
    /// Decodes a verb byte, or `None` for one this build does not serve.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            0 => Self::Hello,
            1 => Self::Snapshot,
            2 => Self::Feed,
            3 => Self::Forget,
            4 => Self::Compose,
            5 => Self::Transcript,
            6 => Self::Collapse,
            8 => Self::PromptEolMarks,
            9 => Self::Detect,
            _ => return None,
        })
    }
}

/// [`Verb::Feed`]: rebuild the resident model before feeding (a reset, or a resize).
pub const FLAG_RESET: u8 = 0x01;

/// [`Verb::Compose`]: append the stream's NET input-mode state to the reply, so a session still
/// inside a TUI keeps that TUI's modes across a cold reattach.
pub const FLAG_REASSERT_INPUT_MODES: u8 = 0x02;

/// [`Verb::Detect`]: these bytes are a scrollback REBUILD replay.
///
/// Resets the sync-frame parser along with the grid. Distinct from [`FLAG_RESET`], which a
/// geometry drift also sets while the stream itself continues uninterrupted.
pub const FLAG_REBUILD_REPLAY: u8 = 0x08;

/// [`Verb::Detect`]: a different agent now holds the pane's foreground.
///
/// Drops the retained OSC title/progress BEFORE folding these bytes, so the previous process's
/// evidence cannot be read as the new one's.
pub const FLAG_AGENT_CHANGED: u8 = 0x10;

/// How a reply's payload should be read.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Status {
    /// Success — the payload is the verb's result.
    Ok = 0,
    /// The frame did not decode, or its parameters were out of range. The payload is a UTF-8
    /// message; the connection stays open (one bad request does not cost the caller its socket).
    BadRequest = 1,
    /// The daemon could not serve a well-formed request. Payload is a UTF-8 message.
    Internal = 2,
}

impl Status {
    /// The status a reply byte names, or `None` for one this build does not know.
    ///
    /// Strict rather than forward-tolerant, unlike the wire's metadata enums: a status the client
    /// cannot interpret means it does not know whether the request SUCCEEDED, and guessing "ok"
    /// would hand a caller a payload it should not trust.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Ok),
            1 => Some(Self::BadRequest),
            2 => Some(Self::Internal),
            _ => None,
        }
    }
}

/// A decoded request, borrowing the frame body.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Request<'a> {
    /// What to do.
    pub verb: Verb,
    /// Verb-specific bits (today only [`FLAG_RESET`]).
    pub flags: u8,
    /// Grid height the bytes are parsed at.
    pub rows: usize,
    /// Grid width the bytes are parsed at.
    pub cols: usize,
    /// The resident-model key ([`Verb::Feed`]/[`Verb::Forget`]); empty for the stateless verbs.
    pub pane: &'a str,
    /// The PTY bytes.
    pub raw: &'a [u8],
}

/// Why a frame body did not decode.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DecodeError {
    /// The body is shorter than the fixed header, or than its own declared pane length.
    Truncated,
    /// The verb byte is not one this build serves.
    UnknownVerb(u8),
    /// The pane id is not UTF-8.
    PaneNotUtf8,
    /// A reply's status byte is not one this build knows.
    UnknownStatus(u8),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Truncated => f.write_str("frame truncated"),
            Self::UnknownVerb(byte) => write!(f, "unknown verb {byte}"),
            Self::PaneNotUtf8 => f.write_str("pane id is not utf-8"),
            Self::UnknownStatus(byte) => write!(f, "unknown reply status {byte}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// Decodes a request body (the bytes AFTER the length prefix).
///
/// # Errors
/// [`DecodeError`] for a short body, an unknown verb or a non-UTF-8 pane id.
pub fn decode_request(body: &[u8]) -> Result<Request<'_>, DecodeError> {
    // Split-then-destructure rather than index. screend could index its way through this because
    // its whole crate allows it — a terminal GRID is an indexed structure whose coordinates are
    // clamped on the way in. There is no grid here: every byte below arrived over a socket, so the
    // length check IS the proof and the pattern is what makes the compiler hold it.
    let (header, rest) = body.split_at_checked(HEADER_LEN).ok_or(DecodeError::Truncated)?;
    let &[
        verb_byte,
        flags,
        rows_hi,
        rows_lo,
        cols_hi,
        cols_lo,
        pane_hi,
        pane_lo,
    ] = header
    else {
        return Err(DecodeError::Truncated);
    };
    let verb = Verb::from_byte(verb_byte).ok_or(DecodeError::UnknownVerb(verb_byte))?;
    let rows = usize::from(u16::from_be_bytes([rows_hi, rows_lo]));
    let cols = usize::from(u16::from_be_bytes([cols_hi, cols_lo]));
    let pane_len = usize::from(u16::from_be_bytes([pane_hi, pane_lo]));
    let (pane_bytes, raw) = rest.split_at_checked(pane_len).ok_or(DecodeError::Truncated)?;
    let pane = std::str::from_utf8(pane_bytes).map_err(|_| DecodeError::PaneNotUtf8)?;
    Ok(Request {
        verb,
        flags,
        rows,
        cols,
        pane,
        raw,
    })
}

/// Encodes a request frame (length prefix included) — the shape the Swift client writes, kept here
/// so the encoder and the decoder cannot drift apart within this build.
#[must_use]
pub fn encode_request(request: &Request<'_>) -> Vec<u8> {
    let pane = request.pane.as_bytes();
    let body_len = HEADER_LEN + pane.len() + request.raw.len();
    let mut out = Vec::with_capacity(4 + body_len);
    out.extend_from_slice(&u32::try_from(body_len).unwrap_or(u32::MAX).to_be_bytes());
    out.push(request.verb as u8);
    out.push(request.flags);
    out.extend_from_slice(&u16::try_from(request.rows).unwrap_or(u16::MAX).to_be_bytes());
    out.extend_from_slice(&u16::try_from(request.cols).unwrap_or(u16::MAX).to_be_bytes());
    out.extend_from_slice(&u16::try_from(pane.len()).unwrap_or(u16::MAX).to_be_bytes());
    out.extend_from_slice(pane);
    out.extend_from_slice(request.raw);
    out
}

/// [`Verb::Detect`]'s verb-local payload: `u16 agent_len | agent… | bytes…`.
///
/// The label is length-prefixed rather than delimited because a manifest label is a foreign string
/// in the general case, and a delimiter is a rule about its contents. A label longer than the
/// prefix can hold is truncated to its capacity — no manifest label is within three orders of
/// magnitude of that, and a truncation is a wrong answer where a panic is no answer at all.
#[must_use]
pub fn encode_detect_payload(agent: &str, raw: &[u8]) -> Vec<u8> {
    let label = agent.as_bytes();
    let length = u16::try_from(label.len()).unwrap_or(u16::MAX);
    let mut out = Vec::with_capacity(2 + usize::from(length) + raw.len());
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(label.get(..usize::from(length)).unwrap_or(label));
    out.extend_from_slice(raw);
    out
}

/// Splits [`Verb::Detect`]'s verb-local payload back apart.
///
/// `None` when the payload is truncated or the label is not UTF-8 — the caller answers
/// [`Status::BadRequest`] rather than guessing at a boundary.
#[must_use]
pub fn decode_detect_payload(raw: &[u8]) -> Option<(&str, &[u8])> {
    let (length, rest) = raw.split_at_checked(2)?;
    let declared = usize::from(u16::from_be_bytes([*length.first()?, *length.get(1)?]));
    let (label, bytes) = rest.split_at_checked(declared)?;
    Some((std::str::from_utf8(label).ok()?, bytes))
}

/// Splits a reply body into its status and payload — the CLIENT's end, the mirror of
/// [`encode_reply`]. The caller has already read the `len` bytes off the socket.
///
/// # Errors
/// [`DecodeError::Truncated`] for an empty body, [`DecodeError::UnknownVerb`] carrying the status
/// byte when it names no status this build knows.
pub fn decode_reply(body: &[u8]) -> Result<(Status, &[u8]), DecodeError> {
    let (first, payload) = body.split_first().ok_or(DecodeError::Truncated)?;
    let status = Status::from_byte(*first).ok_or(DecodeError::UnknownStatus(*first))?;
    Ok((status, payload))
}

/// Encodes a reply frame (length prefix included).
#[must_use]
pub fn encode_reply(status: Status, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.extend_from_slice(&u32::try_from(1 + payload.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.push(status as u8);
    out.extend_from_slice(payload);
    out
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a fault — and a fixed offset into a frame \
                  this test just built is the assertion, where `get` would soften it"
    )]

    use super::{
        DecodeError, FLAG_RESET, Request, Status, Verb, decode_detect_payload, decode_reply, decode_request,
        encode_detect_payload, encode_reply, encode_request,
    };

    #[test]
    fn a_request_survives_the_round_trip() {
        let request = Request {
            verb: Verb::Feed,
            flags: FLAG_RESET,
            rows: 24,
            cols: 80,
            pane: "pane-7",
            raw: b"hello\x1b[31m",
        };
        let frame = encode_request(&request);
        let decoded = decode_request(&frame[4..]).expect("round trip");
        assert_eq!(decoded, request);
    }

    #[test]
    fn a_short_body_and_an_unknown_verb_are_errors_not_panics() {
        assert_eq!(decode_request(&[0u8; 3]), Err(DecodeError::Truncated));
        assert_eq!(
            decode_request(&[200, 0, 0, 24, 0, 80, 0, 0]),
            Err(DecodeError::UnknownVerb(200))
        );
        // A pane length that outruns the body.
        assert_eq!(
            decode_request(&[2, 0, 0, 24, 0, 80, 0, 9]),
            Err(DecodeError::Truncated)
        );
    }

    #[test]
    fn a_reply_carries_its_status_ahead_of_the_payload() {
        let frame = encode_reply(Status::BadRequest, b"nope");
        assert_eq!(&frame[..4], &5u32.to_be_bytes());
        assert_eq!(frame[4], Status::BadRequest as u8);
        assert_eq!(&frame[5..], b"nope");
    }

    #[test]
    fn a_detect_payload_survives_the_round_trip() {
        let payload = encode_detect_payload("claude", b"\x1b[2J screen bytes");
        assert_eq!(
            decode_detect_payload(&payload),
            Some(("claude", &b"\x1b[2J screen bytes"[..]))
        );
    }

    #[test]
    fn an_empty_label_and_empty_bytes_still_round_trip() {
        let payload = encode_detect_payload("", b"");
        assert_eq!(payload, [0, 0]);
        assert_eq!(decode_detect_payload(&payload), Some(("", &b""[..])));
    }

    #[test]
    fn a_label_that_is_not_ascii_keeps_its_byte_length_not_its_char_count() {
        let payload = encode_detect_payload("réponse", b"x");
        assert_eq!(decode_detect_payload(&payload), Some(("réponse", &b"x"[..])));
        // Eight UTF-8 bytes for seven characters — the prefix counts bytes.
        assert_eq!(payload.get(..2), Some(&[0, 8][..]));
    }

    #[test]
    fn a_truncated_detect_payload_is_none_rather_than_a_guess() {
        assert_eq!(decode_detect_payload(&[]), None);
        assert_eq!(decode_detect_payload(&[0]), None);
        // A label length that outruns the body.
        assert_eq!(decode_detect_payload(&[0, 40, b'c']), None);
        // A label that is not UTF-8.
        assert_eq!(decode_detect_payload(&[0, 1, 0xFF]), None);
    }

    #[test]
    fn a_reply_survives_the_round_trip_through_both_ends() {
        for status in [Status::Ok, Status::BadRequest, Status::Internal] {
            let frame = encode_reply(status, b"payload");
            let body = frame.get(4..).expect("a body after the length prefix");
            assert_eq!(decode_reply(body), Ok((status, &b"payload"[..])));
        }
    }

    #[test]
    fn a_reply_with_no_payload_decodes_to_an_empty_one() {
        let frame = encode_reply(Status::Ok, b"");
        let body = frame.get(4..).expect("a body");
        assert_eq!(decode_reply(body), Ok((Status::Ok, &b""[..])));
    }

    #[test]
    fn an_empty_or_unknown_status_reply_is_refused_rather_than_read_as_success() {
        assert_eq!(decode_reply(&[]), Err(DecodeError::Truncated));
        for byte in 3..=u8::MAX {
            assert_eq!(
                decode_reply(&[byte, 0]),
                Err(DecodeError::UnknownStatus(byte)),
                "{byte}"
            );
        }
    }
}
