//! One connected control socket: the descriptor, the write lock, and the hang-up.
//!
//! The port of `Sources/SlopDeskSupervisor/SupervisorConnection.swift`, minus the parts that were
//! only there because Swift could not see C macros.
//!
//! ## Why `close` shuts down rather than closes
//! The reader thread borrows this socket for the whole life of the connection. Closing the
//! descriptor out from under it would free a number the kernel is free to hand to the next `open`,
//! and the reader would go on reading somebody else's file. `shutdown(Both)` ends the connection
//! without freeing the number: the parked `recvmsg` returns zero, the reader unwinds, and the
//! descriptor is closed exactly once when the last [`Connection`] reference is dropped.

use std::os::fd::{AsFd as _, AsRawFd as _, BorrowedFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::Mutex;

use nix::errno::Errno;
use nix::sys::socket::Shutdown;

use crate::frame::{self, Frame, FrameError};

/// A connected control socket.
///
/// Shared between whoever owns the client and the client's own reader thread, so every method takes
/// `&self`. Writes are serialised by [`Connection::send`]'s own lock; reads are not, because there
/// is exactly one reader by construction.
#[derive(Debug)]
pub struct Connection {
    socket: OwnedFd,
    /// Held across a whole frame. Two interleaved frames desynchronise the stream permanently, and
    /// there is no resynchronisation point in a tag/length framing to recover at.
    writing: Mutex<()>,
}

impl Connection {
    /// Dials superd at `path`.
    ///
    /// # Errors
    /// The `connect(2)` errno. `ENOENT` is the ordinary one and means superd is not running — which
    /// is fatal to panes rather than degradable, because nothing else in this process can fork a
    /// shell.
    pub fn dial(path: &str) -> Result<Self, Errno> {
        let stream = UnixStream::connect(path)
            .map_err(|error| error.raw_os_error().map_or(Errno::ECONNREFUSED, Errno::from_raw))?;
        Ok(Self {
            socket: OwnedFd::from(stream),
            writing: Mutex::new(()),
        })
    }

    /// Adopts an already-connected socket. The test seam, and the shape a socket handed over by
    /// something else would use.
    #[must_use]
    pub const fn adopt(socket: OwnedFd) -> Self {
        Self {
            socket,
            writing: Mutex::new(()),
        }
    }

    /// Writes one request body, whole, with no other frame interleaved into it.
    ///
    /// # Errors
    /// [`FrameError`] from the framing, or [`FrameError::PeerClosed`] when another thread poisoned
    /// the write lock by panicking mid-frame — a stream that may be half-written is a dead
    /// connection, and reporting it as one is the only honest answer.
    pub fn send(&self, body: &[u8]) -> Result<(), FrameError> {
        let Ok(_guard) = self.writing.lock() else {
            return Err(FrameError::PeerClosed);
        };
        frame::write(self.socket.as_fd(), body)
    }

    /// Reads one frame. Blocks. Called from the reader thread and nowhere else.
    ///
    /// # Errors
    /// [`FrameError`] from the framing. Every one of them ends the connection.
    pub fn receive(&self) -> Result<Frame, FrameError> {
        frame::read(self.socket.as_fd())
    }

    /// The descriptor, for a caller that needs to name it. Borrowed, so it cannot outlive this.
    #[must_use]
    pub fn as_fd(&self) -> BorrowedFd<'_> {
        self.socket.as_fd()
    }

    /// Ends the connection and wakes the reader.
    ///
    /// Idempotent in the only sense that matters: a second call answers `ENOTCONN` and is ignored.
    pub fn close(&self) {
        let _ignored = nix::sys::socket::shutdown(self.socket.as_raw_fd(), Shutdown::Both);
    }
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::os::fd::OwnedFd;

    use nix::sys::socket::{AddressFamily, SockFlag, SockType, socketpair};

    use super::Connection;
    use crate::frame::FrameError;

    fn pair() -> (OwnedFd, OwnedFd) {
        socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty()).unwrap()
    }

    #[test]
    fn a_body_written_here_is_read_there() {
        let (ours, theirs) = pair();
        let ours = Connection::adopt(ours);
        let theirs = Connection::adopt(theirs);
        ours.send(br#"{"id":1}"#).unwrap();
        assert_eq!(theirs.receive().unwrap().body, br#"{"id":1}"#);
    }

    /// The whole reason `close` shuts down: a reader parked in `recvmsg` has to come back, or the
    /// thread never joins and the process never exits.
    #[test]
    fn closing_wakes_a_parked_reader() {
        let (ours, theirs) = pair();
        let theirs = std::sync::Arc::new(Connection::adopt(theirs));
        let reader = std::sync::Arc::clone(&theirs);
        let parked = std::thread::spawn(move || reader.receive().map(|frame| frame.body));
        theirs.close();
        assert!(matches!(parked.join().unwrap(), Err(FrameError::PeerClosed)));
        drop(ours);
    }

    /// A closed connection reports its writes as failures rather than pretending they left.
    #[test]
    fn a_write_after_close_fails() {
        let (ours, theirs) = pair();
        let ours = Connection::adopt(ours);
        drop(theirs);
        // The first write may succeed into the kernel buffer of a socket whose peer is gone; the
        // one after the resulting EPIPE cannot.
        let _ignored = ours.send(b"first");
        assert!(ours.send(b"second").is_err());
    }
}
