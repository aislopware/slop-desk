//! One request out, one reply in, and the error type that says which of the two failed.
//!
//! The port of `ScreenClient.exchange`, `writeAll` and `readExactly`.
//!
//! ## The four bytes in the middle
//! The length prefix is ASKED for rather than shifted apart here. It used to be four
//! `Int(bytes[i]) <<` terms, a `>= 1` and a re-spelling of the 64 MiB cap in Swift, against an
//! encoder `slopdesk-screenwire` already owned — a hand-written parser on the one field of this
//! lane an untrusted peer fully controls. [`slopdesk_screenwire::reply_body_length`] is that
//! question, and its refusal is what stands between a peer's four bytes and this process's
//! allocator.
//!
//! The Swift version had to phrase the refusal as `> 0` because `size_t` reaches Swift as the
//! SIGNED `Int`, so a sentinel of `usize::MAX` arrived as `-1` and the obvious `!= .max` did not
//! catch it. That whole paragraph dissolves here: the door answers `Option<usize>` and `None` is
//! `None`.

use std::io::{Read as _, Write as _};
use std::os::unix::net::UnixStream;

use nix::errno::Errno;
use slopdesk_screenwire::{LENGTH_PREFIX_LEN, Status, reply_body_length};

/// Why a call to screend did not answer.
///
/// Four cases and they mean four different things to a caller. `Unavailable` and `Transport` are
/// both "no answer" and a caller falls back — each verb's caller has a documented PASSTHROUGH
/// (replay the raw bytes; skip this detection tick), never a second parser, because a Swift-side or
/// Rust-side fallback implementation is the cross-language mirror this tree forbids. `Rejected` is
/// screend ANSWERING and is the caller's own bug. `MalformedReply` is a lost frame boundary, which
/// no socket resynchronises from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientError {
    /// Nothing is listening and nothing could be started.
    Unavailable {
        /// What was tried, in one line, for a log.
        reason: String,
    },
    /// The socket failed mid-exchange. `EPIPE` for a peer that closed while this end wrote,
    /// `ECONNRESET` for an EOF mid-frame — which is how this lane spells "screend died holding the
    /// answer".
    Transport {
        /// The `errno` the syscall reported.
        errno: i32,
    },
    /// screend refused the request. The connection is still good; the question was not.
    Rejected {
        /// [`Status::BadRequest`] or [`Status::Internal`].
        status: Status,
        /// screend's UTF-8 message, empty when it was not UTF-8.
        message: String,
    },
    /// A reply that did not decode: a length prefix this end will not read, an empty body, or a
    /// status byte this build does not know.
    MalformedReply,
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable { reason } => write!(formatter, "screend unavailable: {reason}"),
            Self::Transport { errno } => {
                write!(formatter, "screend transport failed: {}", Errno::from_raw(*errno))
            },
            Self::Rejected { status, message } => {
                write!(formatter, "screend rejected the request ({status:?}): {message}")
            },
            Self::MalformedReply => formatter.write_str("screend sent a reply that did not decode"),
        }
    }
}

impl std::error::Error for ClientError {}

/// Writes the frame and reads the reply BODY — the status byte included, the length prefix not.
///
/// # Errors
/// [`ClientError::Transport`] for either half of the round trip, [`ClientError::MalformedReply`]
/// for a length prefix [`reply_body_length`] refuses.
pub fn exchange(stream: &UnixStream, frame: &[u8]) -> Result<Vec<u8>, ClientError> {
    write_all(stream, frame)?;
    let mut prefix = [0_u8; LENGTH_PREFIX_LEN];
    read_exactly(stream, &mut prefix)?;
    let declared = reply_body_length(prefix).ok_or(ClientError::MalformedReply)?;
    let mut body = vec![0_u8; declared];
    read_exactly(stream, &mut body)?;
    Ok(body)
}

/// Same must-report contract as the supervisor lane's frame writer: a peer that closed reads as
/// `EPIPE`, which is what this lane's error type spells a lost socket with.
///
/// That it ARRIVES as an errno rather than as a fatal signal is std's doing, not this function's —
/// `crate::client::dial` says where the `SO_NOSIGPIPE` the Swift original set by hand went.
fn write_all(mut stream: &UnixStream, bytes: &[u8]) -> Result<(), ClientError> {
    stream.write_all(bytes).map_err(|error| {
        ClientError::Transport {
            errno: error.raw_os_error().unwrap_or(Errno::EPIPE as i32),
        }
    })
}

/// `read(2)` until the whole frame is in. An EOF mid-frame reads as `ECONNRESET`.
fn read_exactly(mut stream: &UnixStream, into: &mut [u8]) -> Result<(), ClientError> {
    stream.read_exact(into).map_err(|error| {
        ClientError::Transport {
            errno: error.raw_os_error().unwrap_or(Errno::ECONNRESET as i32),
        }
    })
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::io::Write as _;
    use std::os::unix::net::UnixStream;

    use nix::errno::Errno;
    use slopdesk_screenwire::{MAX_FRAME, Status, encode_reply};

    use super::{ClientError, exchange};

    #[test]
    fn a_reply_comes_back_whole() {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        theirs.write_all(&encode_reply(Status::Ok, b"payload")).unwrap();
        let body = exchange(&ours, b"request").unwrap();
        assert_eq!(
            slopdesk_screenwire::decode_reply(&body).unwrap(),
            (Status::Ok, &b"payload"[..])
        );
    }

    /// Half-closed, not dropped: the peer still takes the request and answers it with EOF, which is
    /// exactly what a screend that died holding the answer looks like from here. Dropping it
    /// outright fails the WRITE instead — the other errno, and the test below.
    #[test]
    fn an_eof_before_the_prefix_is_econnreset_and_not_a_hang() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        theirs.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(
            exchange(&ours, b"request"),
            Err(ClientError::Transport {
                errno: Errno::ECONNRESET as i32
            }),
        );
    }

    #[test]
    fn an_eof_midway_through_the_body_is_econnreset_too() {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        theirs.write_all(&[0, 0, 0, 8, 0, 1, 2]).unwrap();
        theirs.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(
            exchange(&ours, b"request"),
            Err(ClientError::Transport {
                errno: Errno::ECONNRESET as i32
            }),
        );
    }

    /// A peer that is gone entirely. Which half reports it is the kernel's business — a write may
    /// still land in the buffer of a socket whose peer has closed — so what this pins is the
    /// property that matters: never a success without an answer.
    #[test]
    fn a_peer_that_is_gone_is_reported_rather_than_silently_succeeding() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        drop(theirs);
        assert!(matches!(
            exchange(&ours, b"request"),
            Err(ClientError::Transport { .. })
        ));
    }

    /// The refusal that keeps a peer's four bytes away from this process's allocator. A `0` cannot
    /// be a reply — a reply is at least its status byte — and anything past `MAX_FRAME` is more
    /// than screend would ever have sent.
    #[test]
    fn a_prefix_this_end_will_not_read_is_refused_before_the_allocation() {
        for prefix in [0_u32, u32::try_from(MAX_FRAME).unwrap() + 1, u32::MAX] {
            let (ours, mut theirs) = UnixStream::pair().unwrap();
            theirs.write_all(&prefix.to_be_bytes()).unwrap();
            assert_eq!(
                exchange(&ours, b"request"),
                Err(ClientError::MalformedReply),
                "{prefix}"
            );
        }
    }
}
