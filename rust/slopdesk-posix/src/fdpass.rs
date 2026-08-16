//! The receiving half of `SCM_RIGHTS`: one byte, and at most one descriptor riding with it.
//!
//! ## Why the receive and the adoption are one function
//! `OwnedFd::from_raw_fd` is unsafe because an `i32` carries no proof that nobody else owns the
//! descriptor it names. That proof exists in exactly one place — the instruction after `recvmsg`
//! returns, where the kernel has just installed the descriptor in this process and handed it back
//! once. A crate that exported `adopt(RawFd) -> OwnedFd` would be exporting a safe signature it
//! cannot honour; a crate that exported it as `unsafe fn` would push the obligation back out to the
//! caller this crate exists to keep clean. So the receive comes with it, and the raw integer never
//! becomes visible to anyone.
//!
//! ## Why one byte
//! An fd is attached to a `sendmsg`, not to a stream position, so the receiver has to be at a
//! `recvmsg` boundary to collect it. `slopdesk-superd`'s framing puts the tag byte in its own
//! `sendmsg` for exactly that reason; the length and body that follow are ordinary stream reads.
//! Anything larger here would let a body byte be consumed by a call that is about the descriptor.

use std::io::IoSliceMut;
use std::os::fd::{FromRawFd as _, OwnedFd, RawFd};

use nix::errno::Errno;
use nix::sys::socket::{ControlMessageOwned, MsgFlags, recvmsg};

/// One byte off the socket, plus the descriptor the sender attached to it.
#[derive(Debug)]
pub struct Tagged {
    /// The byte itself.
    pub byte: u8,
    /// The attached descriptor, already owned by this process — dropping it closes it.
    pub descriptor: Option<OwnedFd>,
}

/// Reads one byte and any `SCM_RIGHTS` descriptor sent with it, retrying `EINTR`.
///
/// `Ok(None)` is an orderly shutdown by the peer (a zero-byte `recvmsg`), which is not an error and
/// must not be reported as one — it is how a hostd that has exited is told apart from a hostd that
/// has broken.
///
/// A peer attaching more than one descriptor is malformed. The first is kept and the rest are
/// closed here rather than leaked: a leaked PTY master is a pane that can never be hung up, which
/// outlives the connection that caused it.
///
/// # Errors
/// The `recvmsg` errno, or the errno from walking the control messages.
pub fn recv_tagged(socket: RawFd) -> Result<Option<Tagged>, Errno> {
    let mut byte = [0_u8; 1];
    loop {
        let mut iov = [IoSliceMut::new(&mut byte)];
        // Space for exactly one fd; see the doc comment for what happens to a second.
        let mut space = nix::cmsg_space!([RawFd; 1]);
        let message = match recvmsg::<()>(socket, &mut iov, Some(&mut space), MsgFlags::empty()) {
            Ok(message) => message,
            Err(Errno::EINTR) => continue,
            Err(errno) => return Err(errno),
        };
        if message.bytes == 0 {
            return Ok(None);
        }

        let mut adopted: Option<OwnedFd> = None;
        for control in message.cmsgs()? {
            if let ControlMessageOwned::ScmRights(fds) = control {
                for raw in fds {
                    let owned = adopt(raw);
                    if adopted.is_none() {
                        adopted = Some(owned);
                    } else {
                        drop(owned);
                    }
                }
            }
        }
        // A `recvmsg` that reported bytes filled the one-byte iovec, so the index is inhabited;
        // `EBADMSG` stands in for the impossible case rather than an unwrap.
        let Some(&first) = byte.first() else {
            return Err(Errno::EBADMSG);
        };
        return Ok(Some(Tagged {
            byte: first,
            descriptor: adopted,
        }));
    }
}

/// Takes ownership of a descriptor `recvmsg` has just installed.
///
/// Private, and it must stay private: the caller above is the only context in which the safety
/// argument holds, and making this reachable from anywhere else would turn a proof into a hope.
#[expect(
    unsafe_code,
    reason = "the kernel hands back a raw fd; taking ownership of it needs from_raw_fd"
)]
fn adopt(raw: RawFd) -> OwnedFd {
    // SAFETY: `recvmsg` installed this descriptor in this process microseconds ago and reported it
    // to this loop exactly once. No other owner exists, so this is the first and only adoption.
    unsafe { OwnedFd::from_raw_fd(raw) }
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::io::{IoSlice, Read as _, Write as _};
    use std::os::fd::{AsRawFd as _, OwnedFd};
    use std::os::unix::net::UnixStream;

    use nix::sys::socket::{ControlMessage, MsgFlags, sendmsg};

    use super::recv_tagged;

    /// A plain byte with no ancillary data arrives as itself.
    #[test]
    fn a_bare_byte_arrives_with_no_descriptor() {
        let (left, right) = UnixStream::pair().unwrap();
        let payload = [0x42_u8];
        let iov = [IoSlice::new(&payload)];
        sendmsg::<()>(left.as_raw_fd(), &iov, &[], MsgFlags::empty(), None).unwrap();

        let got = recv_tagged(right.as_raw_fd()).unwrap().unwrap();
        assert_eq!(got.byte, 0x42);
        assert!(got.descriptor.is_none());
    }

    /// The whole point: a descriptor attached to the byte comes back OWNED, usable after the
    /// sender's own copy is gone.
    #[test]
    fn an_attached_descriptor_arrives_owned() {
        let (left, right) = UnixStream::pair().unwrap();
        let (payload_end, mut probe_end) = UnixStream::pair().unwrap();

        let byte = [0x01_u8];
        let iov = [IoSlice::new(&byte)];
        let fds = [payload_end.as_raw_fd()];
        let cmsgs = [ControlMessage::ScmRights(&fds)];
        sendmsg::<()>(left.as_raw_fd(), &iov, &cmsgs, MsgFlags::empty(), None).unwrap();
        drop(payload_end); // the receiver's copy must stand on its own

        let got = recv_tagged(right.as_raw_fd()).unwrap().unwrap();
        assert_eq!(got.byte, 0x01);
        let received: OwnedFd = got.descriptor.unwrap();

        // It is a live socket, not a number: write through the received end and read the probe.
        let mut carried = UnixStream::from(received);
        carried.write_all(b"through").unwrap();
        let mut buffer = [0_u8; 7];
        probe_end.read_exact(&mut buffer).unwrap();
        assert_eq!(&buffer, b"through");
    }

    /// An orderly close is `Ok(None)`, not an error — that distinction is what tells a hostd that
    /// exited apart from a hostd that broke.
    #[test]
    fn a_closed_peer_is_none_rather_than_an_error() {
        let (left, right) = UnixStream::pair().unwrap();
        drop(left);
        assert!(recv_tagged(right.as_raw_fd()).unwrap().is_none());
    }
}
