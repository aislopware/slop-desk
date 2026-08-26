//! A raw byte link — write bytes, read bytes, hang up. Nothing above this knows what a socket is.
//!
//! This is `MuxByteLink`, minus one method. The Swift protocol has FOUR: `send` (suspends until the
//! stack accepts), `sendPipelined` (enqueue in call order, never suspend), `receiveChunks` and
//! `close`. The split between the first two exists because `NWConnection.send` is asynchronous, so
//! "in call order" and "await each one" are different programs and the hot path needed the former.
//!
//! A blocking `write` is already both: it returns when the bytes are handed to the kernel, and two
//! writes on one socket from one thread are in call order by construction. So [`ByteLink`] has one
//! `send`, and the ordering bug class the Swift doc warns about — "an internal `Task { await send
//! }` hop breaks per-channel FIFO" — cannot be written here at all. That is the port SIMPLIFYING
//! the contract rather than transcribing it, which is the only kind of port worth doing.
//!
//! ## Reading is a loan, not a delivery
//!
//! `receiveChunks` yields a `Data` per chunk: an allocation and a copy, per read, forever.
//! [`ByteLink::recv`] fills a caller-owned buffer instead and returns how many bytes landed in it.
//! The caller reuses one buffer for the life of the link and `slopdesk_wire::mux::MuxFrameDecoder`
//! borrows its payloads straight back out of it (`next_frame_leaving_payload` + `payload_bytes`).
//! `docs/59` §7's constraint is zero allocations added per chunk; this is how it is met.

use std::io;
use std::net::{Shutdown, TcpStream};
use std::sync::Mutex;

/// Write bytes, read bytes, hang up.
///
/// Object-safe on purpose: the pending map holds `Box<dyn ByteLink>` so a test can pair two
/// in-memory halves with no socket, exactly as `InMemoryMuxLink` does for the Swift tests.
pub trait ByteLink: Send + Sync + core::fmt::Debug {
    /// Writes every byte, or fails. Bytes are on the wire in call order.
    ///
    /// # Errors
    /// Whatever the transport reports. A failed write means the link is dead; the caller's next
    /// [`Self::recv`] will agree.
    fn send(&self, bytes: &[u8]) -> io::Result<()>;

    /// Reads into `buf` and returns how many bytes landed there.
    ///
    /// `Ok(0)` is a clean close (FIN), the same event `receiveChunks` reports by finishing without
    /// an error. Chunk boundaries are arbitrary — a read may hold a partial frame, several frames,
    /// or one frame split across two reads.
    ///
    /// # Errors
    /// Whatever the transport reports. Any error is terminal for this link.
    fn recv(&self, buf: &mut [u8]) -> io::Result<usize>;

    /// Tears the link down. Idempotent: closing a link that is already closed is not an error, and
    /// the reaper closes links it cannot know the state of.
    fn close(&self);
}

/// One `TcpStream`, with the PATH-1 socket options already applied.
///
/// ## The lock is on the WRITE side only, and it is not optional
///
/// `TcpStream` implements `Read` and `Write` for `&self`, so a read thread and a write thread hold
/// the same socket concurrently — which is exactly the shape the mux needs, and exactly what a lock
/// around the whole stream would serialise away: a bulk write would block the read loop that is
/// meant to be draining the peer's window.
///
/// But `write_all` is a LOOP over partial writes. Two threads calling it concurrently on one socket
/// can interleave in the middle of a frame, and a mux stream with two frames' bytes shuffled
/// together is not a corrupt frame — it is a desynchronised decoder, for the life of the
/// connection, on every channel that socket carries. So writes take a mutex and reads do not. The
/// Swift original got this property for free from actor isolation and spent a doc comment warning
/// that an internal `Task` hop would break it; here it is one lock, on the side that needs it.
#[derive(Debug)]
pub struct TcpByteLink {
    stream: TcpStream,
    /// Held for the duration of one `send`, so a frame reaches the wire whole.
    write: Mutex<()>,
    /// Which end of the pair this is, for logs. Not read by any decision.
    label: &'static str,
}

impl TcpByteLink {
    /// Adopts an accepted stream. The caller has already applied [`crate::params`].
    #[must_use]
    pub const fn new(stream: TcpStream, label: &'static str) -> Self {
        Self {
            stream,
            write: Mutex::new(()),
            label,
        }
    }

    /// Which end of the pair this is.
    #[must_use]
    pub const fn label(&self) -> &'static str {
        self.label
    }
}

impl ByteLink for TcpByteLink {
    fn send(&self, bytes: &[u8]) -> io::Result<()> {
        use std::io::Write as _;
        // A poisoned write lock means a thread panicked mid-frame: the stream's position is
        // unknown, so the only honest answer is that this link is finished.
        let _guard = self
            .write
            .lock()
            .map_err(|_poisoned| io::Error::other("slopdesk-hostnet: write lock poisoned mid-frame"))?;
        (&self.stream).write_all(bytes)
    }

    fn recv(&self, buf: &mut [u8]) -> io::Result<usize> {
        use std::io::Read as _;
        (&self.stream).read(buf)
    }

    fn close(&self) {
        // `Shutdown::Both` rather than dropping the stream: the pending map may still hold this
        // link when the reaper decides to close it, and a shutdown wakes a blocked reader on
        // another thread where a drop would not. An error here means it was already down.
        drop(self.stream.shutdown(Shutdown::Both));
    }
}
