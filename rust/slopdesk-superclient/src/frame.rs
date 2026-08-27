//! hostd's half of the control-socket framing: read a frame, write a body.
//!
//! ```text
//! <1 byte tag> <4 bytes big-endian length> <length bytes body>
//! ```
//!
//! The LAYOUT is [`slopdesk_superwire`]'s — which tag, how long, and what the packed bodies mean.
//! Only the syscalls are here, and only hostd's: the port of
//! hostd's Swift frame reader and its descriptor-passing half, both of
//! which the same change deletes.
//!
//! ## Why the tag byte exists
//! `SCM_RIGHTS` ancillary data is delivered to the FIRST `recvmsg` that reads any byte of the
//! matching `sendmsg`. On a `SOCK_STREAM` socket a multi-byte header can come up short, which would
//! leave the descriptor already installed in this process while the header is still half-read — a
//! state with no correct recovery. A one-byte read cannot be short, so the descriptor rides the tag
//! and the rest of the frame is ordinary stream bytes.
//!
//! ## Why this is not superd's `frame.rs`
//! It is the same layout and the opposite lane. superd SENDS descriptors, so its writer carries
//! `ControlMessage::ScmRights`, a `BorrowedFd` parameter and the argument for why the borrow has to
//! outlive the `sendmsg`. hostd sends none — it has nothing superd wants — so [`write`] takes a
//! body and nothing else, and the whole ancillary-send path is absent rather than unused. Sharing
//! one module would mean carrying superd's half into hostd and hostd's `recv_tagged` into superd,
//! and `slopdesk-superwire`'s manifest already records the ruling: the layout is shared, the lanes
//! are not.

use std::os::fd::{AsRawFd as _, BorrowedFd, OwnedFd};

use nix::errno::Errno;

/// What can go wrong reading or writing a frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// The body exceeds [`slopdesk_superwire::MAX_BODY_BYTES`], in either direction.
    BodyTooLarge(usize),
    /// The leading byte was not a tag this build knows. The stream is desynchronised past recovery;
    /// drop the connection rather than hunt for the next plausible byte.
    UnknownTag(u8),
    /// Orderly shutdown, or a half-frame followed by one.
    PeerClosed,
    /// A syscall failed.
    Io(Errno),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match *self {
            Self::BodyTooLarge(size) => write!(formatter, "frame body of {size} bytes is too large"),
            Self::UnknownTag(tag) => write!(formatter, "unknown frame tag {tag:#04x}"),
            Self::PeerClosed => write!(formatter, "superd closed the connection"),
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

/// One decoded frame, with whatever superd attached to it.
#[derive(Debug)]
pub struct Frame {
    /// Which body kind this is — one of `slopdesk_superwire`'s five tags.
    pub tag: u8,
    /// The body: JSON for the two control tags, a packed layout for the three pane tags.
    pub body: Vec<u8>,
    /// The descriptor superd sent, already owned by this process. Dropping it closes it.
    pub descriptor: Option<OwnedFd>,
}

/// Writes one request body.
///
/// No descriptor parameter, and that is the whole difference from superd's writer: hostd has
/// nothing to hand over. Every frame it sends is [`slopdesk_superwire::TAG_PLAIN`].
///
/// Not internally synchronised. A socket shared by several senders needs a lock around this call,
/// or two frames interleave and the stream never resynchronises — [`crate::connection::Connection`]
/// owns that lock.
///
/// # Errors
/// [`FrameError::BodyTooLarge`] before any bytes go out, or [`FrameError::Io`] mid-write. A failure
/// after the tag has gone leaves the stream desynchronised, so the caller must drop the connection
/// rather than retry.
pub fn write(socket: BorrowedFd<'_>, body: &[u8]) -> Result<(), FrameError> {
    let header = slopdesk_superwire::header(body.len()).ok_or(FrameError::BodyTooLarge(body.len()))?;
    write_all(socket, &[slopdesk_superwire::TAG_PLAIN])?;
    write_all(socket, &header)?;
    write_all(socket, body)
}

/// Reads one frame. Blocks until a whole frame arrives, superd closes, or the socket errors.
///
/// # Errors
/// [`FrameError::PeerClosed`] on orderly shutdown; [`FrameError::UnknownTag`] or
/// [`FrameError::BodyTooLarge`] when the peer is corrupt or skewed past recognition. In every error
/// case a descriptor the kernel already installed is dropped here rather than leaked — a leaked PTY
/// master is a pane that can never be hung up, and it outlives the connection that caused it.
pub fn read(socket: BorrowedFd<'_>) -> Result<Frame, FrameError> {
    let (tag, descriptor) = read_tag(socket)?;
    if !slopdesk_superwire::is_known_tag(tag) {
        drop(descriptor);
        return Err(FrameError::UnknownTag(tag));
    }

    let mut header = [0_u8; slopdesk_superwire::HEADER_LEN];
    if let Err(error) = read_exactly(socket, &mut header) {
        drop(descriptor);
        return Err(error);
    }
    let Some(length) = slopdesk_superwire::body_length(header) else {
        drop(descriptor);
        return Err(FrameError::BodyTooLarge(u32::from_be_bytes(header) as usize));
    };
    let mut body = vec![0_u8; length];
    if let Err(error) = read_exactly(socket, &mut body) {
        drop(descriptor);
        return Err(error);
    }
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
    use std::io::IoSlice;
    use std::os::fd::{AsFd as _, AsRawFd as _, OwnedFd};

    use nix::sys::socket::{
        AddressFamily, ControlMessage, MsgFlags, SockFlag, SockType, sendmsg, socketpair,
    };

    use super::{FrameError, read, write};

    fn pair() -> (OwnedFd, OwnedFd) {
        socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty()).unwrap()
    }

    /// The superd side of a frame, written the way superd writes it — the tag in its own `sendmsg`
    /// so a descriptor can ride it.
    fn superd_writes(socket: &OwnedFd, tag: u8, body: &[u8], descriptor: Option<&OwnedFd>) {
        let tag = [tag];
        let iov = [IoSlice::new(&tag)];
        match descriptor {
            Some(carried) => {
                let fds = [carried.as_raw_fd()];
                let cmsgs = [ControlMessage::ScmRights(&fds)];
                sendmsg::<()>(socket.as_raw_fd(), &iov, &cmsgs, MsgFlags::empty(), None).unwrap();
            },
            None => {
                sendmsg::<()>(socket.as_raw_fd(), &iov, &[], MsgFlags::empty(), None).unwrap();
            },
        }
        let header = slopdesk_superwire::header(body.len()).unwrap();
        nix::unistd::write(socket, &header).unwrap();
        let mut rest = body;
        while !rest.is_empty() {
            let written = nix::unistd::write(socket, rest).unwrap();
            rest = rest.get(written..).unwrap();
        }
    }

    #[test]
    fn a_body_round_trips() {
        let (ours, theirs) = pair();
        write(ours.as_fd(), br#"{"id":7}"#).unwrap();
        let frame = read(theirs.as_fd()).unwrap();
        assert_eq!(frame.tag, slopdesk_superwire::TAG_PLAIN);
        assert_eq!(frame.body, br#"{"id":7}"#);
        assert!(frame.descriptor.is_none());
    }

    /// Two frames back to back must not bleed into each other — the tag/length split is the only
    /// thing separating them on a `SOCK_STREAM`.
    #[test]
    fn back_to_back_frames_stay_distinct() {
        let (ours, theirs) = pair();
        write(ours.as_fd(), b"first").unwrap();
        write(ours.as_fd(), b"second").unwrap();
        assert_eq!(read(theirs.as_fd()).unwrap().body, b"first");
        assert_eq!(read(theirs.as_fd()).unwrap().body, b"second");
    }

    /// The property the whole tag-byte design rests on: the descriptor arrives, and the body that
    /// follows it is still whole.
    #[test]
    fn a_descriptor_arrives_owned_and_the_body_survives_it() {
        let (superd, hostd) = pair();
        let (carried, other) = pair();
        superd_writes(
            &superd,
            slopdesk_superwire::TAG_WITH_DESCRIPTOR,
            br#"{"id":1,"status":"ok"}"#,
            Some(&carried),
        );

        let frame = read(hostd.as_fd()).unwrap();
        assert_eq!(frame.body, br#"{"id":1,"status":"ok"}"#);
        let adopted = frame.descriptor.unwrap();
        assert_ne!(
            adopted.as_raw_fd(),
            carried.as_raw_fd(),
            "a real dup, not the same number"
        );
        // It is the same open file, not just a number: a byte written on the far end arrives on it.
        nix::unistd::write(&other, b"z").unwrap();
        let mut byte = [0_u8; 1];
        nix::unistd::read(&adopted, &mut byte).unwrap();
        assert_eq!(byte, *b"z");
    }

    /// A pane-output frame carries no descriptor and is not JSON. The tag is the whole
    /// discriminator, and it must survive the read unchanged.
    #[test]
    fn an_output_frame_keeps_its_tag_and_packed_body() {
        let (superd, hostd) = pair();
        let packed = slopdesk_superwire::pack_output("pane-7", 4096, b"hello").unwrap();
        superd_writes(&superd, slopdesk_superwire::TAG_OUTPUT, &packed, None);

        let frame = read(hostd.as_fd()).unwrap();
        assert_eq!(frame.tag, slopdesk_superwire::TAG_OUTPUT);
        let (pane_id, offset, payload) = slopdesk_superwire::parse_output(&frame.body).unwrap();
        assert_eq!((pane_id, offset, payload), ("pane-7", 4096, b"hello".as_slice()));
    }

    /// A tag this build has no name for desynchronises the stream, so it is reported rather than
    /// skipped — and the descriptor the kernel may already have installed with it is closed.
    #[test]
    fn an_unknown_tag_is_refused() {
        let (superd, hostd) = pair();
        nix::unistd::write(&superd, &[0x7F]).unwrap();
        assert!(matches!(read(hostd.as_fd()), Err(FrameError::UnknownTag(0x7F))));
    }

    /// An empty body is legal and must not read as a closed peer — the two differ by one syscall's
    /// return value and by everything else.
    #[test]
    fn an_empty_body_is_not_a_closed_peer() {
        let (superd, hostd) = pair();
        write(superd.as_fd(), b"").unwrap();
        assert!(read(hostd.as_fd()).unwrap().body.is_empty());
        drop(superd);
        assert!(matches!(read(hostd.as_fd()), Err(FrameError::PeerClosed)));
    }

    /// A half-written frame must not be reported as a short body: the reader blocks for the rest,
    /// and only a close ends it.
    #[test]
    fn a_truncated_header_reports_a_closed_peer_rather_than_a_short_frame() {
        let (superd, hostd) = pair();
        nix::unistd::write(&superd, &[slopdesk_superwire::TAG_PLAIN, 0, 0]).unwrap();
        drop(superd);
        assert!(matches!(read(hostd.as_fd()), Err(FrameError::PeerClosed)));
    }

    /// A body past the cap is refused before a single byte goes out, so the socket is still
    /// synchronised afterwards and the next frame reads cleanly.
    #[test]
    fn an_oversized_body_is_refused_before_the_tag_goes_out() {
        let (ours, theirs) = pair();
        let body = vec![0_u8; slopdesk_superwire::MAX_BODY_BYTES + 1];
        assert!(matches!(
            write(ours.as_fd(), &body),
            Err(FrameError::BodyTooLarge(_))
        ));
        write(ours.as_fd(), b"after").unwrap();
        assert_eq!(read(theirs.as_fd()).unwrap().body, b"after");
    }
}
