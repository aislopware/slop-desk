//! Moving EVERY byte over a bare descriptor, and saying which of the three ways it ended.
//!
//! Ported from the deleted `SlopDeskTTY.FileDescriptorIO`, which was itself the
//! collapse of thirteen hand-written copies of these two loops. Each copy folded in the same two
//! facts, and each was a chance to get one of them wrong:
//!
//! - **`EINTR` is a retry, not a failure.** A signal delivered mid-syscall — `SIGWINCH` on a
//!   resize, the `SIGCHLD` of a reaped pane — makes `write(2)` return `-1` having moved nothing.
//!   Treating that as an error truncates a control reply for no reason at all.
//! - **A short write is normal.** `write(2)` is permitted to move fewer bytes than it was given,
//!   and on a socket whose peer is a beat behind it usually does.
//!
//! ## Why this is an admission, when `nix` wraps both calls
//! `nix::unistd::write` is safe, but it takes a `BorrowedFd`, and minting one from a `RawFd` is
//! `BorrowedFd::borrow_raw` — the same unsafe assertion, moved one call earlier and stated in a
//! less obvious place. The obligation does not disappear by being wrapped, so it is discharged
//! here, beside the loop it belongs to and in the same shape [`crate::sock`] and [`crate::pty`]
//! already use: a bare `RawFd` the caller holds open for the duration.
//!
//! ## What deliberately did NOT collapse
//! The REACTION. A control reply to a client that has gone away is dropped; a frame half-written is
//! a lost boundary and must be reported. Both are right, so the loop answers a [`Transfer`] and
//! each caller switches on it into its own vocabulary.

use std::os::fd::RawFd;

use nix::errno::Errno;

/// How a loop that must move every byte ended.
///
/// Named for neither `read` nor `write` because it is the same three answers for both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transfer {
    /// Every byte moved.
    Complete,
    /// The syscall returned 0 with bytes still owed — the peer is gone. An EOF mid-frame is a
    /// different fact from an idle descriptor, which is why it is not folded into `Failed`.
    PeerClosed {
        /// What moved before the peer went.
        transferred: usize,
    },
    /// The syscall failed.
    Failed {
        /// Why.
        errno: Errno,
        /// What moved before it did.
        transferred: usize,
    },
}

impl Transfer {
    /// The outcome as ONE integer, for a caller that cannot hold an enum.
    ///
    /// `0` complete, `-1` peer closed, and otherwise the positive errno. The byte count is dropped
    /// because no caller has ever read it: both live callers of the loop this replaced discarded
    /// the whole outcome, and a partial count is only actionable to a caller that could resume,
    /// which a dropped control reply and a closed socket both cannot.
    ///
    /// The flattening lives HERE rather than at the C boundary because choosing what a caller that
    /// cannot see the enum is told is a decision, and the boundary holds none.
    #[must_use]
    pub const fn code(self) -> i32 {
        match self {
            Self::Complete => 0,
            Self::PeerClosed { .. } => -1,
            Self::Failed { errno, .. } => errno as i32,
        }
    }
}

/// `write(2)` until the whole of `bytes` is out.
///
/// An empty slice is [`Transfer::Complete`] without a syscall — there is nothing to owe.
#[expect(
    unsafe_code,
    reason = "write(2)'s safe wrapper wants a BorrowedFd, which is the same assertion moved earlier"
)]
#[must_use]
pub fn write_all(fd: RawFd, bytes: &[u8]) -> Transfer {
    let mut rest = bytes;
    let mut transferred = 0_usize;
    while !rest.is_empty() {
        // SAFETY: `rest` is a live Rust slice for the duration and the length is exactly its own,
        // so the call reads only inside it. `fd` is the caller's obligation — a descriptor
        // this process holds open — and a closed or unwritable one is answered with an
        // errno.
        let moved = unsafe { libc::write(fd, rest.as_ptr().cast::<libc::c_void>(), rest.len()) };
        if moved > 0 {
            let done = usize::try_from(moved).unwrap_or(rest.len()).min(rest.len());
            transferred = transferred.saturating_add(done);
            rest = rest.get(done..).unwrap_or_default();
            continue;
        }
        if moved < 0 {
            let errno = Errno::last();
            if errno == Errno::EINTR {
                continue;
            }
            return Transfer::Failed { errno, transferred };
        }
        return Transfer::PeerClosed { transferred };
    }
    Transfer::Complete
}

/// `read(2)` until `into` is exactly full.
///
/// The mirror of [`write_all`], and the reason it takes a caller's buffer rather than answering
/// one: a partial fill is still worth looking at, and the caller already knows how many bytes it
/// wanted.
#[expect(
    unsafe_code,
    reason = "read(2)'s safe wrapper wants a BorrowedFd, which is the same assertion moved earlier"
)]
#[must_use]
pub fn read_exactly(fd: RawFd, into: &mut [u8]) -> Transfer {
    let mut rest = into;
    let mut transferred = 0_usize;
    while !rest.is_empty() {
        // SAFETY: `rest` is a live, uniquely-borrowed Rust slice for the duration and the length is
        // exactly its own, so the call writes only inside it. `fd` is the caller's obligation, and
        // a closed or unreadable one is answered with an errno.
        let moved = unsafe { libc::read(fd, rest.as_mut_ptr().cast::<libc::c_void>(), rest.len()) };
        if moved > 0 {
            let done = usize::try_from(moved).unwrap_or(rest.len()).min(rest.len());
            transferred = transferred.saturating_add(done);
            // The slice has to be handed over rather than re-borrowed: a `&mut` cannot be sliced
            // out of itself while the original is still in scope.
            rest = std::mem::take(&mut rest).get_mut(done..).unwrap_or_default();
            continue;
        }
        if moved < 0 {
            let errno = Errno::last();
            if errno == Errno::EINTR {
                continue;
            }
            return Transfer::Failed { errno, transferred };
        }
        return Transfer::PeerClosed { transferred };
    }
    Transfer::Complete
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::io::Read as _;
    use std::os::fd::{AsRawFd as _, RawFd};
    use std::os::unix::net::UnixStream;

    use nix::errno::Errno;

    use super::{Transfer, read_exactly, write_all};

    /// A pipe, for the cases that need one end genuinely closed.
    #[expect(unsafe_code, reason = "pipe(2) is the fixture")]
    fn open_pipe() -> (RawFd, RawFd) {
        let mut ends: [RawFd; 2] = [-1, -1];
        // SAFETY: `ends` is a live local array of exactly the two ints `pipe` fills.
        let result = unsafe { libc::pipe(ends.as_mut_ptr()) };
        assert_eq!(result, 0, "pipe: {}", Errno::last());
        (ends.first().copied().unwrap(), ends.get(1).copied().unwrap())
    }

    /// Closes a descriptor the fixture opened.
    #[expect(unsafe_code, reason = "the fixture's own descriptors")]
    fn close(fd: RawFd) {
        // SAFETY: `fd` came from a fixture in this module and is closed exactly once.
        let _ignored = unsafe { libc::close(fd) };
    }

    /// Every byte arrives, in order, on the other end. The whole point.
    #[test]
    fn a_write_moves_the_whole_buffer() {
        let (mut left, right) = UnixStream::pair().unwrap();
        let payload = b"{\"id\":\"1\",\"ok\":true}\n";
        assert_eq!(write_all(right.as_raw_fd(), payload), Transfer::Complete);
        drop(right);

        let mut received = Vec::new();
        left.read_to_end(&mut received).unwrap();
        assert_eq!(received, payload);
    }

    /// A buffer bigger than any socket send buffer still lands whole — the short-write half of the
    /// loop, which a single `write(2)` would silently truncate.
    #[test]
    fn a_write_larger_than_the_send_buffer_still_lands_whole() {
        let (mut left, right) = UnixStream::pair().unwrap();
        let payload: Vec<u8> = (0..1_000_000_u32)
            .map(|index| u8::try_from(index % 256).unwrap_or(0))
            .collect();
        let expected = payload.clone();

        // The reader has to drain concurrently or the writer parks forever once the buffer fills —
        // which is the POSIX contract this loop is written against, not a test artefact.
        let reader = std::thread::spawn(move || {
            let mut received = Vec::new();
            left.read_to_end(&mut received).unwrap();
            received
        });
        assert_eq!(write_all(right.as_raw_fd(), &payload), Transfer::Complete);
        drop(right);

        assert_eq!(reader.join().unwrap(), expected);
    }

    /// Nothing to write is complete, and does not reach a syscall — so it is complete even on a
    /// descriptor that could not have taken a byte.
    #[test]
    fn an_empty_write_is_complete_without_a_syscall() {
        assert_eq!(write_all(-1, &[]), Transfer::Complete);
    }

    /// A descriptor that cannot be written to reports the errno rather than looping.
    #[test]
    fn a_bad_descriptor_reports_its_errno() {
        assert_eq!(write_all(-1, b"x"), Transfer::Failed {
            errno: Errno::EBADF,
            transferred: 0,
        });
    }

    /// Reading exactly what was written is complete and byte-exact.
    #[test]
    fn a_read_fills_the_whole_buffer() {
        let (read_end, write_end) = open_pipe();
        assert_eq!(write_all(write_end, b"0123456789"), Transfer::Complete);

        let mut buffer = [0_u8; 10];
        assert_eq!(read_exactly(read_end, &mut buffer), Transfer::Complete);
        assert_eq!(&buffer, b"0123456789");

        close(read_end);
        close(write_end);
    }

    /// A peer that closes still owing bytes is `PeerClosed` WITH the count, not a generic failure:
    /// the caller that cares is one that half-read a frame, and "how far did it get" is the only
    /// thing distinguishing that from an idle descriptor.
    #[test]
    fn a_peer_that_closes_mid_buffer_says_how_far_it_got() {
        let (read_end, write_end) = open_pipe();
        assert_eq!(write_all(write_end, b"abc"), Transfer::Complete);
        close(write_end);

        let mut buffer = [0_u8; 8];
        assert_eq!(read_exactly(read_end, &mut buffer), Transfer::PeerClosed {
            transferred: 3
        });
        assert_eq!(buffer.first().copied(), Some(b'a'));

        close(read_end);
    }

    /// Asking for nothing is complete, mirroring the write side.
    #[test]
    fn an_empty_read_is_complete() {
        assert_eq!(read_exactly(-1, &mut []), Transfer::Complete);
    }

    /// A read from a descriptor that is not open reports its errno.
    #[test]
    fn a_bad_descriptor_reports_its_errno_on_the_read_side_too() {
        let mut buffer = [0_u8; 4];
        assert_eq!(read_exactly(-1, &mut buffer), Transfer::Failed {
            errno: Errno::EBADF,
            transferred: 0,
        });
    }

    /// The three outcomes flatten to three distinguishable integers, and the errno survives — a
    /// caller across the C boundary has to be able to tell "gone" from "broke, and here is why".
    #[test]
    fn the_flattened_code_keeps_the_three_answers_apart() {
        assert_eq!(Transfer::Complete.code(), 0);
        assert_eq!(Transfer::PeerClosed { transferred: 7 }.code(), -1);
        assert_eq!(
            Transfer::Failed {
                errno: Errno::EPIPE,
                transferred: 2,
            }
            .code(),
            Errno::EPIPE as i32
        );
        assert!(
            Transfer::Failed {
                errno: Errno::EPIPE,
                transferred: 0,
            }
            .code()
                > 0,
            "an errno must not collide with either sentinel"
        );
    }
}
