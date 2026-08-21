//! The framing for the `slopdesk-superd` ↔ `slopdesk-hostd` control socket.
//!
//! ```text
//! <1 byte tag> <4 bytes big-endian length> <length bytes body>
//! ```
//!
//! superd writes these and hostd reads them. Both ends were written out — superd's `frame.rs` in
//! Rust and `SupervisorFrame.swift` in Swift, each describing the other as a mirror — so this crate
//! is the one spelling of the layout, and each side keeps only its own syscalls.
//!
//! # Why the tag byte exists
//!
//! `SCM_RIGHTS` ancillary data is delivered to the FIRST `recvmsg` that reads any byte of the
//! matching `sendmsg`. On a `SOCK_STREAM` socket a multi-byte header can come up short, which would
//! leave the descriptor already installed in the reading process while the header is still
//! half-read — a state with no correct recovery. A one-byte read cannot be short, so the descriptor
//! rides the tag and the rest of the frame is plain stream bytes. This is the whole reason the
//! header is not simply a length.
//!
//! # Two body kinds, and why the second one is not JSON
//!
//! Control traffic is JSON ([`TAG_PLAIN`], [`TAG_WITH_DESCRIPTOR`]). A pane's OUTPUT is not
//! ([`TAG_OUTPUT`]): it is arbitrary bytes at up to a megabyte a second per pane, and base64 in a
//! JSON string would cost a third more wire and two more copies for nothing. It gets a packed
//! binary body instead — see [`pack_output`].
//!
//! # Adding a tag, and why it does not break the append-only rule
//!
//! A peer that does not know a tag answers "unknown" and drops the connection. That is safe here
//! because superd sends an output frame only to a client that asked for one with `subscribe`, and
//! an older hostd has no such verb. The capability is gated by the REQUEST, so a tag never reaches
//! a peer that cannot read it — which holds only while each tag has exactly one thing to ask for.
//!
//! # Validate-then-drop
//!
//! Every parser here answers `None` rather than a partial value, and none of them can panic on any
//! byte string: the peer may be an older or corrupt build, and a desynchronised socket is the
//! expensive failure this crate exists to make impossible to reach two different ways.

/// The control socket's name inside whichever directory resolves.
pub const CONTROL_SOCKET_NAME: &str = "slopdesk-superd.sock";

/// Overrides the whole socket directory. Test-only in practice: the gate script needs two superds
/// that cannot see each other.
pub const DIRECTORY_ENV_KEY: &str = "SLOPDESK_SUPERD_DIR";

/// Overrides the control socket path outright.
pub const SOCKET_ENV_KEY: &str = "SLOPDESK_SUPERD_SOCKET";

/// Where superd listens, decided from the three environment values that decide it.
///
/// `$SLOPDESK_SUPERD_SOCKET`, else `$SLOPDESK_SUPERD_DIR/slopdesk-superd.sock`, else
/// `$TMPDIR/slopdesk-superd.sock`, else `/tmp/slopdesk-superd.sock`. `$TMPDIR` on macOS is already
/// a per-user, `0700` directory, which is what makes the un-suffixed name safe. `/tmp` is not, and
/// the last resort exists only so a hand-run superd in a stripped environment fails somewhere
/// legible — `slopdesk_screenwire::socket_path` records the same ruling for the same ladder.
///
/// ## Why an address is in the FRAMING crate
///
/// For the reason every other layout here is: it is the one thing both ends must agree on before a
/// single frame can flow, and it cannot be negotiated. hostd has to FIND the control socket before
/// it can say `hello`, so there is no message in which superd could tell it — `superd/src/paths.rs`
/// says exactly that, and calls a divergence in this one name "not a protocol error, it is
/// silence". superd's other three paths stay superd's, because hostd is TOLD them in the `hello`
/// reply and a Swift constant for any of them would be a second answer.
///
/// ## The silence, which had already happened, twice
///
/// `SupervisorPaths.controlSocket` resolved this itself and the two rules were not the same rule.
/// It read `NSTemporaryDirectory()`, which on Darwin does not consult `$TMPDIR` at all — it answers
/// `confstr(_CS_DARWIN_USER_TEMP_DIR)` whatever the environment says — so any process with a
/// `TMPDIR` of its own had superd binding one path and hostd dialling another. And it knew nothing
/// of `SLOPDESK_SUPERD_DIR`, so the gate script's private daemon was reachable by nothing. The pair
/// agreed in the one case anyone exercises only because launchd sets `TMPDIR` to the very directory
/// that call returns.
///
/// ## Empty is unset
///
/// Every value is filtered for emptiness. An exported-but-blank variable is a shell accident, not a
/// request to bind nothing.
#[must_use]
pub fn control_socket_path(
    socket_override: Option<&str>,
    directory: Option<&str>,
    tmpdir: Option<&str>,
) -> String {
    fn set(value: Option<&str>) -> Option<&str> {
        value.filter(|text| !text.is_empty())
    }
    if let Some(path) = set(socket_override) {
        return path.to_owned();
    }
    let base = set(directory).or_else(|| set(tmpdir)).unwrap_or("/tmp");
    let separator = if base.ends_with('/') { "" } else { "/" };
    format!("{base}{separator}{CONTROL_SOCKET_NAME}")
}

/// Frame carries no file descriptor.
pub const TAG_PLAIN: u8 = 0x01;
/// Frame carries exactly one `SCM_RIGHTS` file descriptor.
pub const TAG_WITH_DESCRIPTOR: u8 = 0x02;
/// Frame carries a pane's raw output bytes rather than JSON. See [`pack_output`].
pub const TAG_OUTPUT: u8 = 0x03;
/// Frame carries what the shell said OUT OF BAND in the chunk about to be sent.
///
/// Always precedes the [`TAG_OUTPUT`] frame carrying those bytes, under the same hold of the wire
/// lock, so the receiver can pair the two: one is sent only when there was something to say, which
/// means a receiver can never wait to find out whether one is coming.
///
/// Gated as [`TAG_OUTPUT`] is: superd sniffs a pane only when the spawn asked for shell
/// integration, and an older hostd does not know that field — so it never asks, is never sniffed,
/// and never sees this tag.
pub const TAG_SNIFF: u8 = 0x04;
/// Frame carries the command-block changes the chunk about to be sent produced.
///
/// Same placement and reason as [`TAG_SNIFF`], and a gate of its own: superd segments a pane only
/// when the spawn asked for blocks. A tag rather than another kind inside the `0x04` batch, because
/// the two answer to DIFFERENT gates — folding them would make one frame's contents depend on two
/// independent flags, and the property that keeps a new tag safe only holds while each tag has
/// exactly one thing to ask for.
pub const TAG_BLOCKS: u8 = 0x05;

/// The largest body either side will send or accept.
///
/// A `spawn` carries a full child environment, bounded by `ARG_MAX` (1 MiB on macOS); the cap sits
/// above that and below anything that would let a corrupt or skewed peer make either side allocate
/// wildly. Over-long is refused, never truncated.
pub const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;

/// The frame header: a big-endian body length. The tag is written separately, on its own.
pub const HEADER_LEN: usize = 4;

/// Whether `tag` is one this protocol defines. A leading byte that is not leaves the stream
/// desynchronised, with no marker to resynchronise on — the connection is dropped.
#[must_use]
pub const fn is_known_tag(tag: u8) -> bool {
    matches!(
        tag,
        TAG_PLAIN | TAG_WITH_DESCRIPTOR | TAG_OUTPUT | TAG_SNIFF | TAG_BLOCKS
    )
}

/// How many payload bytes one [`pack_output`] frame can carry for `pane_id`.
///
/// [`MAX_BODY_BYTES`] less the output header — a 2-byte id length, the id, and the 8-byte offset.
///
/// Not a theoretical bound: a pane's ring defaults to exactly [`MAX_BODY_BYTES`], so a hostd
/// resuming a pane that filled its ring during a restart asks for a backlog that provably does not
/// fit in one frame. Splitting is the answer rather than a smaller ring, because the offset is
/// per-frame and absolute: N frames say the same thing as one, and the receiver splices them by the
/// numbers it is given. Failing instead would lose the whole backlog in exactly the case superd
/// exists for.
#[must_use]
pub const fn max_output_payload(pane_id: &str) -> usize {
    MAX_BODY_BYTES.saturating_sub(2 + pane_id.len() + 8)
}

/// The four header bytes for a body of `length`, or `None` when it exceeds [`MAX_BODY_BYTES`].
///
/// The refusal is the point: a truncated length desynchronises the socket, where a refusal costs
/// one message.
#[must_use]
pub fn header(length: usize) -> Option<[u8; HEADER_LEN]> {
    if length > MAX_BODY_BYTES {
        return None;
    }
    u32::try_from(length).ok().map(u32::to_be_bytes)
}

/// The body length a header names, or `None` when it exceeds [`MAX_BODY_BYTES`].
#[must_use]
pub fn body_length(header: [u8; HEADER_LEN]) -> Option<usize> {
    let length = u32::from_be_bytes(header) as usize;
    (length <= MAX_BODY_BYTES).then_some(length)
}

/// One pane-output body:
///
/// ```text
/// <2B be pane-id length> <pane id> <8B be offset> <payload>
/// ```
///
/// The offset is the absolute position of the FIRST payload byte in that pane's output since it was
/// born. It rides every frame rather than being counted by the receiver so that a gap is
/// DETECTABLE: a stream spliced across an unannounced hole renders a terminal that is wrong, not
/// merely short.
///
/// `None` when the id does not fit its 2-byte length, or the whole body would exceed
/// [`MAX_BODY_BYTES`].
#[must_use]
pub fn pack_output(pane_id: &str, offset: u64, payload: &[u8]) -> Option<Vec<u8>> {
    let name = pane_id.as_bytes();
    let name_length = u16::try_from(name.len()).ok()?;
    let length = 2_usize
        .checked_add(name.len())?
        .checked_add(8)?
        .checked_add(payload.len())?;
    if length > MAX_BODY_BYTES {
        return None;
    }
    let mut body = Vec::with_capacity(length);
    body.extend_from_slice(&name_length.to_be_bytes());
    body.extend_from_slice(name);
    body.extend_from_slice(&offset.to_be_bytes());
    body.extend_from_slice(payload);
    Some(body)
}

/// The body both out-of-band frames share:
///
/// ```text
/// <2B be pane-id length> <pane id> <JSON>
/// ```
///
/// One function rather than two near-copies for [`TAG_SNIFF`] and [`TAG_BLOCKS`], because the two
/// differ ONLY in what the JSON means. A divergence in the framing would be a bug that shows up as
/// a desynchronised socket rather than as a wrong value, which is the expensive kind.
#[must_use]
pub fn pack_pane_json(pane_id: &str, json: &[u8]) -> Option<Vec<u8>> {
    let name = pane_id.as_bytes();
    let name_length = u16::try_from(name.len()).ok()?;
    let length = 2_usize.checked_add(name.len())?.checked_add(json.len())?;
    if length > MAX_BODY_BYTES {
        return None;
    }
    let mut body = Vec::with_capacity(length);
    body.extend_from_slice(&name_length.to_be_bytes());
    body.extend_from_slice(name);
    body.extend_from_slice(json);
    Some(body)
}

/// The pane id, offset and payload [`pack_output`] wrote. Borrows the body; nothing is copied.
///
/// `None` for a body too short to hold its own header, or one whose id is not UTF-8.
#[must_use]
pub fn parse_output(body: &[u8]) -> Option<(&str, u64, &[u8])> {
    let (pane_id, rest) = split_name(body)?;
    let offset: [u8; 8] = rest.get(..8)?.try_into().ok()?;
    Some((pane_id, u64::from_be_bytes(offset), rest.get(8..)?))
}

/// The pane id and JSON [`pack_pane_json`] wrote — [`TAG_SNIFF`] and [`TAG_BLOCKS`] share a body
/// shape, so they share a parse.
///
/// `None` for a body too short to hold its own header, or one whose id is not UTF-8.
#[must_use]
pub fn parse_pane_json(body: &[u8]) -> Option<(&str, &[u8])> {
    split_name(body)
}

/// The `<2B be length> <utf-8 id>` prefix both packed bodies start with, and what follows it.
fn split_name(body: &[u8]) -> Option<(&str, &[u8])> {
    let name_length = usize::from(u16::from_be_bytes([*body.first()?, *body.get(1)?]));
    let after_name = 2_usize.checked_add(name_length)?;
    let name = core::str::from_utf8(body.get(2..after_name)?).ok()?;
    Some((name, body.get(after_name..)?))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a fault — and a fixed offset into a body \
                  this test just packed is the assertion, where `get` would soften it"
    )]

    use super::{
        CONTROL_SOCKET_NAME, MAX_BODY_BYTES, TAG_BLOCKS, TAG_OUTPUT, TAG_PLAIN, TAG_SNIFF,
        TAG_WITH_DESCRIPTOR, body_length, control_socket_path, header, is_known_tag, max_output_payload,
        pack_output, pack_pane_json, parse_output, parse_pane_json,
    };

    /// The whole ladder, in the order it is tried. Each rung is a case that had a wrong answer on
    /// one side or the other before this became one function.
    #[test]
    fn the_control_address_falls_through_its_ladder_in_order() {
        assert_eq!(
            control_socket_path(Some("/run/explicit.sock"), Some("/dir"), Some("/tmpdir")),
            "/run/explicit.sock",
            "an outright override beats everything under it",
        );
        assert_eq!(
            control_socket_path(None, Some("/dir"), Some("/tmpdir")),
            format!("/dir/{CONTROL_SOCKET_NAME}"),
            "the gate script's private directory — the rung Swift had never heard of",
        );
        assert_eq!(
            control_socket_path(None, None, Some("/tmpdir")),
            format!("/tmpdir/{CONTROL_SOCKET_NAME}"),
            "the ordinary case, and the one NSTemporaryDirectory() answered differently",
        );
        assert_eq!(
            control_socket_path(None, None, None),
            format!("/tmp/{CONTROL_SOCKET_NAME}"),
            "the stripped environment, which should fail somewhere legible",
        );
    }

    /// An exported-but-blank variable is a shell accident. Reading it as a request would have meant
    /// binding the empty path, or binding directly inside `/`.
    #[test]
    fn an_empty_environment_value_is_unset_at_every_rung() {
        assert_eq!(
            control_socket_path(Some(""), Some(""), Some("/tmpdir")),
            format!("/tmpdir/{CONTROL_SOCKET_NAME}"),
        );
        assert_eq!(
            control_socket_path(Some(""), Some(""), Some("")),
            format!("/tmp/{CONTROL_SOCKET_NAME}")
        );
    }

    /// A directory that already ends in a slash must not produce a doubled one: `//` is a legal but
    /// DIFFERENT path string, and the two ends compare these as strings before they ever connect.
    #[test]
    fn a_trailing_slash_does_not_double() {
        assert_eq!(
            control_socket_path(None, None, Some("/tmpdir/")),
            format!("/tmpdir/{CONTROL_SOCKET_NAME}"),
        );
    }

    #[test]
    fn the_tags_are_the_five_this_protocol_defines_and_no_others() {
        // The numbering is the wire. A shifted constant desynchronises every peer at once.
        assert_eq!(
            [TAG_PLAIN, TAG_WITH_DESCRIPTOR, TAG_OUTPUT, TAG_SNIFF, TAG_BLOCKS],
            [1, 2, 3, 4, 5]
        );
        for tag in 1..=5 {
            assert!(is_known_tag(tag), "tag {tag}");
        }
        assert!(!is_known_tag(0));
        assert!(!is_known_tag(6));
        assert!(!is_known_tag(0xFF));
    }

    #[test]
    fn a_header_round_trips_and_refuses_what_would_desynchronise_the_socket() {
        assert_eq!(header(0), Some([0, 0, 0, 0]));
        assert_eq!(header(1), Some([0, 0, 0, 1]));
        assert_eq!(header(MAX_BODY_BYTES), Some([0, 0x40, 0, 0]));
        assert_eq!(
            header(MAX_BODY_BYTES + 1),
            None,
            "truncating here loses the boundary"
        );
        for length in [0, 1, 255, 256, 65_535, MAX_BODY_BYTES] {
            assert_eq!(header(length).and_then(body_length), Some(length));
        }
        // A peer may claim more than the cap; the reader refuses rather than allocating it.
        assert_eq!(body_length([0xFF, 0xFF, 0xFF, 0xFF]), None);
    }

    #[test]
    fn an_output_body_round_trips_with_its_offset_and_payload_intact() {
        let body = pack_output("pane-7", 0x0102_0304_0506_0708, b"hello").expect("packs");
        assert_eq!(&body[..2], &[0, 6], "the id length is big-endian and two bytes");
        let (pane, offset, payload) = parse_output(&body).expect("parses");
        assert_eq!(pane, "pane-7");
        assert_eq!(offset, 0x0102_0304_0506_0708);
        assert_eq!(payload, b"hello");
    }

    #[test]
    fn an_empty_payload_is_a_frame_and_not_a_refusal() {
        // A pane can be subscribed to before it has said anything; a zero-length chunk still
        // carries an OFFSET, which is what the receiver splices by.
        let body = pack_output("p", 42, b"").expect("packs");
        assert_eq!(parse_output(&body), Some(("p", 42, [].as_slice())));
    }

    #[test]
    fn a_pane_json_body_round_trips_and_both_tags_read_it_the_same_way() {
        let body = pack_pane_json("pane-7", br#"{"events":[]}"#).expect("packs");
        assert_eq!(
            parse_pane_json(&body),
            Some(("pane-7", br#"{"events":[]}"#.as_slice()))
        );
        // The two out-of-band tags differ only in what the JSON means, so one parse serves both.
        assert_eq!(parse_pane_json(&body).map(|(_, json)| json.len()), Some(13));
    }

    #[test]
    fn a_payload_that_would_overflow_the_frame_is_refused_rather_than_split_here() {
        // Splitting is the CALLER's decision, because the offset is per-frame and absolute — the
        // packer refusing is what makes a caller that forgot notice.
        let too_big = vec![0_u8; MAX_BODY_BYTES];
        assert_eq!(pack_output("p", 0, &too_big), None);
        assert_eq!(pack_pane_json("p", &too_big), None);
        // And the limit says exactly how much does fit.
        let fits = vec![0_u8; max_output_payload("p")];
        assert!(pack_output("p", 0, &fits).is_some());
        assert!(pack_output("p", 0, &vec![0_u8; max_output_payload("p") + 1]).is_none());
    }

    #[test]
    fn a_body_too_short_to_hold_its_own_header_is_dropped_rather_than_guessed() {
        for body in [[].as_slice(), &[0], &[0, 6], &[0, 6, b'p'], &[0, 1, b'p']] {
            assert_eq!(parse_output(body), None, "{body:?}");
        }
        // The pane-json parse needs less, so it accepts what the output parse cannot.
        assert_eq!(parse_pane_json(&[0, 1, b'p']), Some(("p", [].as_slice())));
        assert_eq!(parse_pane_json(&[0, 6, b'p']), None);
    }

    #[test]
    fn a_pane_id_that_is_not_utf8_is_dropped_rather_than_lossily_decoded() {
        // The id names a pane the receiver will look up; a replacement character would name a
        // different one, or none, and the frame would be attributed to the wrong terminal.
        let body = [0, 1, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(parse_output(&body), None);
        assert_eq!(parse_pane_json(&body), None);
    }

    #[test]
    fn a_length_that_overruns_the_body_is_dropped_rather_than_read_past() {
        // The claimed id length is 0xFFFF but there are three bytes. A parser that trusted it would
        // read past the buffer; this one answers None.
        let body = [0xFF, 0xFF, b'p'];
        assert_eq!(parse_output(&body), None);
        assert_eq!(parse_pane_json(&body), None);
    }

    #[test]
    fn no_byte_string_can_make_a_parser_panic() {
        // Both parsers read a body a peer wrote, and that peer may be an older or corrupt build.
        for first in [0_u8, 1, 2, 0x7F, 0xFF] {
            for second in [0_u8, 1, 8, 0xFF] {
                for tail in 0..12_usize {
                    let mut body = vec![first, second];
                    body.extend(std::iter::repeat_n(0xAB, tail));
                    let _ignored = parse_output(&body);
                    let _ignored = parse_pane_json(&body);
                }
            }
        }
    }
}
