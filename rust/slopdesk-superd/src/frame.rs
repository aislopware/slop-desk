//! The framing for the `slopdesk-superd` ↔ `slopdesk-hostd` control socket.
//!
//! ```text
//! <1 byte tag> <4 bytes big-endian length> <length bytes body>
//! ```
//!
//! The LAYOUT is `slopdesk_superwire` — which tag, how long, and what the packed bodies mean. It
//! was written out twice, here and in `Sources/SlopDeskSupervisor/SupervisorFrame.swift`, each
//! module's own doc describing the other as a mirror. What is left in this file is superd's SEND
//! side: `sendmsg` with `SCM_RIGHTS`, the write-until-gone loop, and the read-exactly loop. The
//! reading end keeps its own, because the two lanes genuinely differ — this one hands away a
//! descriptor it owns through `nix`, and hostd receives one through its own passing code.
//!
//! ## Two body kinds, and why the second one is not JSON
//! Control traffic is JSON ([`TAG_PLAIN`], [`TAG_WITH_DESCRIPTOR`]). A pane's OUTPUT is not
//! ([`TAG_OUTPUT`]): it is arbitrary bytes at up to a megabyte a second per pane, and base64 in a
//! JSON string would cost a third more wire and two more copies for nothing. It gets a packed
//! binary body instead — see [`write_output`].
//!
//! Adding a tag looks like it breaks the append-only rule (`protocol`, rule 1), because a peer that
//! does not know it answers [`FrameError::UnknownTag`] and drops the connection. It does not, and
//! the reason is worth stating: superd sends an output frame only to a client that asked for one
//! with `subscribe`, and an older hostd has no such verb. The capability is gated by the request,
//! so a tag never reaches a peer that cannot read it.
//!
//! ## Why the tag byte exists
//! `SCM_RIGHTS` ancillary data is delivered to the **first `recvmsg` that reads any byte of the
//! matching `sendmsg`**. On a `SOCK_STREAM` socket a multi-byte header can come up short, which
//! would leave the fd already installed in this process while the header is still half-read — a
//! state with no correct recovery. A one-byte read cannot be short, so the fd rides the tag and
//! the rest of the frame is plain stream bytes. This is the whole reason the header is not simply
//! a length.
//!
//! ## Why `nix` and not hand-rolled `cmsghdr` arithmetic
//! The Swift side has to compute `CMSG_SPACE`/`CMSG_LEN` by hand, because those are C macros and
//! Swift cannot see them — and it has to know that Darwin aligns cmsg to `uint32_t`, not to the
//! platform word. `nix::sys::socket` wraps all of that in a safe API. Getting to delete that
//! arithmetic is a large part of why this half is Rust.

use std::io::IoSlice;
use std::os::fd::{AsRawFd as _, BorrowedFd, OwnedFd};

use nix::errno::Errno;
use nix::sys::socket::{ControlMessage, MsgFlags, sendmsg};
// The tags, the cap and the payload room are `slopdesk_superwire`'s — one spelling for the daemon
// that writes them and the host that reads them. Re-exported rather than re-declared so a call site
// here reads the way it always did.
pub use slopdesk_superwire::{
    MAX_BODY_BYTES, TAG_BLOCKS, TAG_OUTPUT, TAG_PLAIN, TAG_SNIFF, TAG_WITH_DESCRIPTOR, max_output_payload,
};

/// What can go wrong reading or writing a frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// The body exceeds [`MAX_BODY_BYTES`], in either direction.
    BodyTooLarge(usize),
    /// The leading byte was neither tag. The stream is desynchronised; drop the connection.
    UnknownTag(u8),
    /// Orderly shutdown, or a half-frame followed by one.
    PeerClosed,
    /// A syscall failed.
    Io(Errno),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BodyTooLarge(size) => write!(formatter, "frame body of {size} bytes is too large"),
            Self::UnknownTag(tag) => write!(formatter, "unknown frame tag {tag:#04x}"),
            Self::PeerClosed => write!(formatter, "peer closed the connection"),
            Self::Io(errno) => write!(formatter, "frame i/o failed: {errno}"),
        }
    }
}

impl std::error::Error for FrameError {}

impl From<Errno> for FrameError {
    fn from(errno: Errno) -> Self {
        Self::Io(errno)
    }
}

/// One decoded frame.
#[derive(Debug)]
pub struct Frame {
    /// Which body kind this is — one of [`TAG_PLAIN`], [`TAG_WITH_DESCRIPTOR`], [`TAG_OUTPUT`],
    /// [`TAG_SNIFF`], [`TAG_BLOCKS`].
    pub tag: u8,
    /// The body, JSON or packed output depending on `tag`.
    pub body: Vec<u8>,
    /// The descriptor the sender attached, now owned by this process.
    pub descriptor: Option<OwnedFd>,
}

/// Writes one frame, attaching `descriptor` when present.
///
/// The descriptor is BORROWED, and the borrow is the point: `SCM_RIGHTS` copies the open file into
/// the receiver at `sendmsg` time, so the sender's own descriptor must still be open then. Taking a
/// [`BorrowedFd`] rather than a bare number makes that a compile-time fact — a raw fd whose owner
/// had already been dropped would name whatever the kernel handed out next, and the receiver would
/// silently adopt a different file.
///
/// Not internally synchronised — a socket shared by several senders needs a lock around this call,
/// or two frames interleave and the stream never resynchronises. `Connection` owns that lock.
///
/// # Errors
/// [`FrameError::BodyTooLarge`] before any bytes go out, or [`FrameError::Io`] mid-write. A failure
/// after the tag has gone leaves the stream desynchronised, so the caller must drop the connection
/// rather than retry.
pub fn write(
    socket: BorrowedFd<'_>,
    body: &[u8],
    descriptor: Option<BorrowedFd<'_>>,
) -> Result<(), FrameError> {
    if body.len() > MAX_BODY_BYTES {
        return Err(FrameError::BodyTooLarge(body.len()));
    }
    let tag = [if descriptor.is_some() {
        TAG_WITH_DESCRIPTOR
    } else {
        TAG_PLAIN
    }];

    let iov = [IoSlice::new(&tag)];
    // The fd must ride the tag, not the body: see the module header.
    match descriptor {
        Some(borrowed) => {
            let fds = [borrowed.as_raw_fd()];
            let cmsgs = [ControlMessage::ScmRights(&fds)];
            send_all_of_first_byte(socket, &iov, &cmsgs)?;
        },
        None => send_all_of_first_byte(socket, &iov, &[])?,
    }

    // `body.len()` is bounded by MAX_BODY_BYTES above, so the cast cannot wrap.
    let length = u32::try_from(body.len()).map_err(|_ignored| FrameError::BodyTooLarge(body.len()))?;
    write_all(socket, &length.to_be_bytes())?;
    write_all(socket, body)
}

/// Writes one pane-output frame.
///
/// ```text
/// <0x03> <4B be length> | <2B be pane-id length> <pane id> <8B be offset> <payload>
/// ```
///
/// The offset is the absolute position of the FIRST payload byte in the pane's output since it was
/// born ([`crate::ring`]). Carrying it per frame rather than making the receiver count is what lets
/// a subscriber notice a gap: if this offset is not where its own cursor sat, bytes were lost, and
/// a terminal that silently concatenates across a hole renders a screen that is wrong rather than
/// merely short.
///
/// Same locking rule as [`write`]: the caller holds the connection's write lock, or two frames
/// interleave and the stream never resynchronises.
///
/// # Errors
/// [`FrameError::BodyTooLarge`] before any bytes go out, or [`FrameError::Io`] mid-write.
pub fn write_output(
    socket: BorrowedFd<'_>,
    pane_id: &str,
    offset: u64,
    payload: &[u8],
) -> Result<(), FrameError> {
    let length = 2 + pane_id.len() + 8 + payload.len();
    let body =
        slopdesk_superwire::pack_output(pane_id, offset, payload).ok_or(FrameError::BodyTooLarge(length))?;
    send_body(socket, TAG_OUTPUT, &body)
}

/// Writes one sniffed-events frame: `<0x04> <4B be length> | <2B be pane-id length> <pane id>
/// <JSON>`.
///
/// It PRECEDES the [`write_output`] frame carrying the bytes these events were found in, on the
/// same connection under the same write lock, so the receiver can hand the events on with their own
/// chunk. Ordering is the entire reason this is a frame rather than a channel.
///
/// # Errors
/// [`FrameError::BodyTooLarge`] before any bytes go out, or [`FrameError::Io`] mid-write.
pub fn write_sniff(socket: BorrowedFd<'_>, pane_id: &str, json: &[u8]) -> Result<(), FrameError> {
    write_pane_json(socket, TAG_SNIFF, pane_id, json)
}

/// Writes one command-blocks frame: `<0x05> <4B be length> | <2B be pane-id length> <pane id>
/// <JSON>`.
///
/// Precedes the [`write_output`] frame carrying the bytes that produced these changes, for the same
/// reason [`write_sniff`] does: a receiver that has been handed a batch knows the chunk is next,
/// where one that has been handed a chunk can never know whether a batch was coming.
///
/// # Errors
/// [`FrameError::BodyTooLarge`] before any bytes go out, or [`FrameError::Io`] mid-write.
pub fn write_blocks(socket: BorrowedFd<'_>, pane_id: &str, json: &[u8]) -> Result<(), FrameError> {
    write_pane_json(socket, TAG_BLOCKS, pane_id, json)
}

/// The body both out-of-band frames share: a pane id and a JSON batch about it.
///
/// One function rather than two near-copies, because the two tags differ ONLY in what the JSON
/// means. A divergence in the framing would be a bug that shows up as a desynchronised socket
/// rather than as a wrong value, which is the expensive kind.
fn write_pane_json(socket: BorrowedFd<'_>, tag: u8, pane_id: &str, json: &[u8]) -> Result<(), FrameError> {
    let length = 2 + pane_id.len() + json.len();
    let body = slopdesk_superwire::pack_pane_json(pane_id, json).ok_or(FrameError::BodyTooLarge(length))?;
    send_body(socket, tag, &body)
}

/// The tag, the header and the body, in that order, for a frame carrying no descriptor.
///
/// One function rather than the same three writes at each packed-body call site — the ORDER is the
/// frame, and a caller that got it wrong would desynchronise the socket rather than send a bad
/// value.
fn send_body(socket: BorrowedFd<'_>, tag: u8, body: &[u8]) -> Result<(), FrameError> {
    let header = slopdesk_superwire::header(body.len()).ok_or(FrameError::BodyTooLarge(body.len()))?;
    let tag = [tag];
    let iov = [IoSlice::new(&tag)];
    send_all_of_first_byte(socket, &iov, &[])?;
    write_all(socket, &header)?;
    write_all(socket, body)
}

/// Reads one frame. Blocks until a whole frame arrives, the peer closes, or the socket errors.
///
/// # Errors
/// [`FrameError::PeerClosed`] on orderly shutdown; [`FrameError::UnknownTag`] or
/// [`FrameError::BodyTooLarge`] when the peer is corrupt or skewed past recognition. In every
/// error case an already-adopted descriptor is dropped here, so a bad frame cannot leak an fd —
/// and a leaked master fd is a pane that can never be hung up.
pub fn read(socket: BorrowedFd<'_>) -> Result<Frame, FrameError> {
    let (tag, descriptor) = read_tag(socket)?;
    if !slopdesk_superwire::is_known_tag(tag) {
        // The kernel may already have installed a descriptor before we decided the tag was
        // nonsense. `descriptor` is an OwnedFd, so dropping it here closes it.
        drop(descriptor);
        return Err(FrameError::UnknownTag(tag));
    }

    let mut header = [0_u8; slopdesk_superwire::HEADER_LEN];
    read_exactly(socket, &mut header)?;
    let Some(length) = slopdesk_superwire::body_length(header) else {
        drop(descriptor);
        return Err(FrameError::BodyTooLarge(u32::from_be_bytes(header) as usize));
    };
    let mut body = vec![0_u8; length];
    read_exactly(socket, &mut body)?;
    Ok(Frame {
        tag,
        body,
        descriptor,
    })
}

/// The one-byte `recvmsg` that also collects the ancillary descriptor.
///
/// The syscall and the adoption both live in [`slopdesk_posix::fdpass`], because the proof that the
/// descriptor is unowned exists only in the instruction after `recvmsg` returns and cannot be
/// carried out of it. What is left here is the framing meaning: a peer that closed is
/// [`FrameError::PeerClosed`], not an errno.
fn read_tag(socket: BorrowedFd<'_>) -> Result<(u8, Option<OwnedFd>), FrameError> {
    match slopdesk_posix::fdpass::recv_tagged(socket.as_raw_fd())? {
        Some(tagged) => Ok((tagged.byte, tagged.descriptor)),
        None => Err(FrameError::PeerClosed),
    }
}

/// `sendmsg` for the single tag byte, retrying `EINTR`.
///
/// A one-byte send either transfers its byte or fails; there is no short case to loop over, which
/// is the property the whole tag-byte design rests on.
fn send_all_of_first_byte(
    socket: BorrowedFd<'_>,
    iov: &[IoSlice<'_>],
    cmsgs: &[ControlMessage<'_>],
) -> Result<(), FrameError> {
    loop {
        match sendmsg::<()>(socket.as_raw_fd(), iov, cmsgs, MsgFlags::empty(), None) {
            Ok(0) => return Err(FrameError::PeerClosed),
            Ok(_) => return Ok(()),
            Err(Errno::EINTR) => (),
            Err(errno) => return Err(FrameError::Io(errno)),
        }
    }
}

/// `write(2)` until every byte is gone, retrying `EINTR` and short writes.
fn write_all(socket: BorrowedFd<'_>, mut bytes: &[u8]) -> Result<(), FrameError> {
    while !bytes.is_empty() {
        match nix::unistd::write(socket, bytes) {
            Ok(0) => return Err(FrameError::PeerClosed),
            Ok(written) => bytes = bytes.get(written..).ok_or(FrameError::PeerClosed)?,
            Err(Errno::EINTR) => (),
            Err(errno) => return Err(FrameError::Io(errno)),
        }
    }
    Ok(())
}

/// `read(2)` until the buffer is exactly full.
fn read_exactly(socket: BorrowedFd<'_>, mut buffer: &mut [u8]) -> Result<(), FrameError> {
    while !buffer.is_empty() {
        match nix::unistd::read(socket, buffer) {
            Ok(0) => return Err(FrameError::PeerClosed),
            Ok(got) => buffer = buffer.get_mut(got..).ok_or(FrameError::PeerClosed)?,
            Err(Errno::EINTR) => (),
            Err(errno) => return Err(FrameError::Io(errno)),
        }
    }
    Ok(())
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::os::fd::{AsFd as _, AsRawFd as _};

    use nix::sys::socket::{AddressFamily, SockFlag, SockType, socketpair};

    /// The output frame's header must survive a round trip exactly, because a subscriber that
    /// mis-parses the offset splices its terminal stream at the wrong place and cannot tell.
    #[test]
    fn an_output_frame_round_trips_its_pane_offset_and_payload() {
        let encoded = {
            let mut body = Vec::new();
            body.extend_from_slice(&3_u16.to_be_bytes());
            body.extend_from_slice(b"abc");
            body.extend_from_slice(&0x0102_0304_0506_0708_u64.to_be_bytes());
            body.extend_from_slice(b"hello");
            body
        };
        let (pane_id, offset, payload) = parse_output(&encoded).unwrap();
        assert_eq!(pane_id, "abc");
        assert_eq!(offset, 0x0102_0304_0506_0708);
        assert_eq!(payload, b"hello");
    }

    /// An empty payload is legal — a subscriber resuming exactly at the head gets one — and must
    /// not be mistaken for a truncated frame.
    #[test]
    fn an_output_frame_with_no_payload_parses() {
        let mut body = Vec::new();
        body.extend_from_slice(&1_u16.to_be_bytes());
        body.extend_from_slice(b"p");
        body.extend_from_slice(&42_u64.to_be_bytes());
        let (pane_id, offset, payload) = parse_output(&body).unwrap();
        assert_eq!((pane_id, offset), ("p", 42));
        assert!(payload.is_empty());
    }

    /// Validate-then-drop: a body too short for its own header yields `None` rather than panicking
    /// on a slice, and a truncated one is not silently read as a shorter valid frame.
    #[test]
    fn a_truncated_output_body_is_refused_rather_than_guessed() {
        assert!(parse_output(&[]).is_none());
        assert!(parse_output(&[0x00]).is_none());
        // Claims a 9-byte pane id and supplies 1.
        assert!(parse_output(&[0x00, 0x09, b'p']).is_none());
        // A full pane id but only 7 of the 8 offset bytes.
        let mut short = vec![0x00, 0x01, b'p'];
        short.extend_from_slice(&[0; 7]);
        assert!(parse_output(&short).is_none());
    }

    /// The tag must round-trip on the read side, or a receiver cannot tell JSON from bytes.
    #[test]
    fn output_and_plain_tags_are_distinct() {
        assert_ne!(TAG_OUTPUT, TAG_PLAIN);
        assert_ne!(TAG_OUTPUT, TAG_WITH_DESCRIPTOR);
        assert_ne!(TAG_SNIFF, TAG_OUTPUT);
        assert_ne!(TAG_SNIFF, TAG_PLAIN);
        assert_ne!(TAG_SNIFF, TAG_WITH_DESCRIPTOR);
    }

    /// A sniff frame must arrive whole and taggged as itself: the receiver routes on the tag alone,
    /// and a body decoded as a reply would be a guaranteed failure on the hottest socket here.
    #[test]
    fn a_sniff_frame_round_trips_through_a_real_socket() {
        let (ours, theirs) = pair();
        write_sniff(ours.as_fd(), "pane-7", br#"{"events":[{"kind":"bell"}]}"#).unwrap();
        let frame = read(theirs.as_fd()).unwrap();
        assert_eq!(frame.tag, TAG_SNIFF);
        assert!(frame.descriptor.is_none());
        let (pane_id, json) = parse_pane_json(&frame.body).unwrap();
        assert_eq!(pane_id, "pane-7");
        assert_eq!(json, br#"{"events":[{"kind":"bell"}]}"#);
    }

    /// Validate-then-drop, same as [`parse_output`]: a body too short for its own header yields
    /// `None` rather than panicking on a slice.
    #[test]
    fn a_truncated_sniff_body_is_refused_rather_than_guessed() {
        assert!(parse_pane_json(&[]).is_none());
        assert!(parse_pane_json(&[0x00]).is_none());
        // Claims a 9-byte pane id and supplies 1.
        assert!(parse_pane_json(&[0x00, 0x09, b'p']).is_none());
        // A well-formed id with an EMPTY payload parses — superd never sends one, but a receiver
        // that treated it as truncation would drop the connection over a harmless frame.
        assert_eq!(parse_pane_json(&[0x00, 0x01, b'p']), Some(("p", [].as_slice())));
    }

    use slopdesk_superwire::{parse_output, parse_pane_json};

    use super::{
        FrameError, MAX_BODY_BYTES, TAG_OUTPUT, TAG_PLAIN, TAG_SNIFF, TAG_WITH_DESCRIPTOR,
        max_output_payload, read, write, write_output, write_sniff,
    };

    fn pair() -> (std::os::fd::OwnedFd, std::os::fd::OwnedFd) {
        socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty()).unwrap()
    }

    #[test]
    fn frame_round_trips_a_body() {
        let (a, b) = pair();
        write(a.as_fd(), br#"{"id":7}"#, None).unwrap();
        let frame = read(b.as_fd()).unwrap();
        assert_eq!(frame.body, br#"{"id":7}"#);
        assert!(frame.descriptor.is_none());
    }

    /// Two frames back to back must not bleed into each other — the tag/length split is the only
    /// thing separating them on a `SOCK_STREAM`.
    #[test]
    fn back_to_back_frames_stay_distinct() {
        let (a, b) = pair();
        write(a.as_fd(), b"first", None).unwrap();
        write(a.as_fd(), b"second", None).unwrap();
        assert_eq!(read(b.as_fd()).unwrap().body, b"first");
        assert_eq!(read(b.as_fd()).unwrap().body, b"second");
    }

    /// The fd arrives with the tag and the body that follows is still whole. This is the property
    /// the tag byte was introduced for.
    #[test]
    fn descriptor_crosses_alongside_the_body() {
        let (a, b) = pair();
        let (carried, other) = pair();
        write(a.as_fd(), b"payload", Some(carried.as_fd())).unwrap();

        let frame = read(b.as_fd()).unwrap();
        assert_eq!(frame.body, b"payload");
        let adopted = frame.descriptor.unwrap();
        assert_ne!(
            adopted.as_raw_fd(),
            carried.as_raw_fd(),
            "a real dup, not the same number"
        );

        // The adopted fd is the same socket: a byte written on `other` arrives on it.
        nix::unistd::write(&other, b"z").unwrap();
        let mut byte = [0_u8; 1];
        nix::unistd::read(&adopted, &mut byte).unwrap();
        assert_eq!(byte, *b"z");
    }

    /// The sender keeps its own descriptor. This is the fact the entire daemon rests on: superd
    /// hands hostd a duplicate and stays the last holder, so hostd dying never sends `SIGHUP`.
    #[test]
    fn sender_retains_its_own_descriptor() {
        let (a, b) = pair();
        let (carried, other) = pair();
        write(a.as_fd(), b"x", Some(carried.as_fd())).unwrap();
        drop(read(b.as_fd()).unwrap());

        // `carried` still works after the receiver's copy has been dropped.
        nix::unistd::write(&other, b"y").unwrap();
        let mut byte = [0_u8; 1];
        nix::unistd::read(&carried, &mut byte).unwrap();
        assert_eq!(byte, *b"y");
    }

    /// The header eats into the frame, and a backlog writer has to know by exactly how much.
    #[test]
    fn an_output_frames_payload_room_is_the_cap_less_its_own_header() {
        assert_eq!(max_output_payload("pane"), MAX_BODY_BYTES - (2 + 4 + 8));
        // A pane id can be long; the answer stays a floor rather than an underflow.
        assert_eq!(max_output_payload(&"x".repeat(MAX_BODY_BYTES)), 0);
    }

    /// The reason [`super::max_output_payload`] exists, stated as an assertion: a pane that fills
    /// its ring while hostd is away has a backlog that CANNOT go out in one frame. Anyone tempted
    /// to send `resumed.bytes` whole — the code did, until review caught it — loses the whole
    /// backlog exactly when it matters most.
    #[test]
    fn a_full_rings_backlog_does_not_fit_in_one_output_frame() {
        assert!(
            crate::ring::DEFAULT_CAPACITY_BYTES > max_output_payload("some-pane-id"),
            "the default ring must still be the case that forces the split",
        );
    }

    /// Exactly the advertised room goes out; one byte more is refused before anything is written,
    /// which is what makes a chunking caller safe.
    #[test]
    fn an_output_frame_takes_exactly_its_advertised_payload_and_not_one_byte_more() {
        let (a, b) = pair();
        let limit = max_output_payload("p");
        let reader = std::thread::spawn(move || read(b.as_fd()).map(|frame| frame.body.len()));
        write_output(a.as_fd(), "p", 0, &vec![0_u8; limit]).unwrap();
        assert_eq!(reader.join().unwrap().unwrap(), MAX_BODY_BYTES);

        assert!(matches!(
            write_output(a.as_fd(), "p", 0, &vec![0_u8; limit + 1]),
            Err(FrameError::BodyTooLarge(_))
        ));
    }

    #[test]
    fn oversized_body_is_refused_not_truncated() {
        let (a, _b) = pair();
        let body = vec![0_u8; MAX_BODY_BYTES + 1];
        assert!(matches!(
            write(a.as_fd(), &body, None),
            Err(FrameError::BodyTooLarge(_))
        ));
    }

    #[test]
    fn unknown_tag_is_rejected() {
        let (a, b) = pair();
        nix::unistd::write(&a, &[0x7F]).unwrap();
        assert!(matches!(read(b.as_fd()), Err(FrameError::UnknownTag(0x7F))));
    }

    #[test]
    fn peer_close_is_distinguishable_from_a_zero_length_body() {
        let (a, b) = pair();
        write(a.as_fd(), b"", None).unwrap();
        assert!(read(b.as_fd()).unwrap().body.is_empty());
        drop(a);
        assert!(matches!(read(b.as_fd()), Err(FrameError::PeerClosed)));
    }

    /// A half-written frame must not be reported as a short body — the reader blocks for the rest
    /// and only `PeerClosed` ends it.
    #[test]
    fn truncated_header_reports_peer_closed_not_a_short_frame() {
        let (a, b) = pair();
        nix::unistd::write(&a, &[TAG_PLAIN, 0, 0]).unwrap();
        drop(a);
        assert!(matches!(read(b.as_fd()), Err(FrameError::PeerClosed)));
    }
}
