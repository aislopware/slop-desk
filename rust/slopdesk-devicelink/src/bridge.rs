//! The Android bridge's socket: one request line, one reply line, and — for two of the four
//! operations — everything after it, verbatim.
//!
//! The grammar of both lines is `slopdesk_devicepanel::android_bridge`'s and stays there. What is
//! here is the FRAMING, and one part of it is subtle enough that the Swift original wrote a
//! paragraph about it:
//!
//! > the reply line and the first bytes of the stream arrive in the SAME receive. `logcat` starts
//! > printing and the encoder starts emitting the moment the host acks, so a read-until-newline
//! > that discards its remainder loses the head of the stream — for `open`, that is the codec id
//! > and the parameter sets, which is the difference between a picture and a permanently black
//! > rectangle.
//!
//! [`split`] is that rule, and it is pure so the test does not need a host.
//!
//! ## One connection per request
//!
//! Kept from the Swift, with its reason: two of the four operations take the socket over entirely
//! and never give it back, so a pool would have to multiplex a protocol that has no request ids. A
//! TCP connect over the mesh costs one round trip and the operations are a poll every couple of
//! seconds plus a handful of user actions.

use std::io::Read as _;
use std::sync::Arc;

use slopdesk_devicepanel::android_bridge::{HOST_CLOSED, UNREADABLE_REPLY};

use crate::session::{Link, Session};

/// The most this side will buffer looking for the end of the reply line.
///
/// A peer that never sends a newline is a bounded mistake rather than an unbounded allocation —
/// the same ceiling the Swift socket carried, in the one place that now reads the claim it bounds.
pub const REPLY_CEILING: usize = 1 << 20;

/// How much is asked for per `read`. Wide, because `open`'s access units run to tens of kilobytes.
const READ_WINDOW: usize = 64 << 10;

/// What a bridge call tells its owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event<'a> {
    /// The host's reply line, without its newline. Delivered at most once.
    Reply(&'a [u8]),
    /// Bytes after the reply line. Only the streaming operations see these.
    Bytes(&'a [u8]),
    /// The call is over. `None` is a clean close.
    Ended(Option<&'a str>),
}

/// Where a call's events go. Called on the call's own thread, never concurrently with itself.
pub trait Sink: Send + Sync {
    /// One event. The borrow is valid for this call only.
    fn event(&self, event: Event<'_>);
}

/// One live bridge connection. Dropping it closes the socket and joins the reader, after which the
/// sink is not called again.
#[derive(Debug)]
pub struct Call {
    session: Session,
}

impl Call {
    /// Dial the bridge and write `request`, which is a whole line, newline included —
    /// `slopdesk_devicepanel::android_bridge::request_line` built it and is the only thing that can
    /// refuse to.
    ///
    /// Returns at once; the dial happens on the call's thread.
    #[must_use]
    pub fn open(host: &str, port: u16, request: &[u8], sink: Arc<dyn Sink>) -> Self {
        let host = host.to_owned();
        let request = request.to_vec();
        let link = Link::new();
        let session = Session::open(link, "slopdesk.devicelink.bridge", move |link| {
            let (replied, ending) = run(link, &host, port, &request, sink.as_ref());
            if link.is_torn() {
                return;
            }
            // A socket that died BEFORE the ack reports through the reply channel as well —
            // otherwise a caller awaiting a reply waits forever for a connection that is already
            // gone. The sentence is the panel's own table's, not this file's.
            if !replied {
                let said = ending.clone().unwrap_or_else(|| HOST_CLOSED.to_owned());
                sink.event(Event::Reply(said.as_bytes()));
            }
            sink.event(Event::Ended(ending.as_deref()));
        });
        Self { session }
    }

    /// Send bytes upstream — the control channel of `open`, and nothing else uses it.
    #[must_use]
    pub fn send(&self, bytes: &[u8]) -> bool {
        !bytes.is_empty() && self.session.link().write(bytes)
    }
}

/// Where the reply line ends and the stream begins.
///
/// `None` means the newline has not arrived yet. Otherwise: the line without its newline, and
/// everything after it, which may be empty and may be the head of a video stream.
#[must_use]
pub fn split(buffer: &[u8]) -> Option<(&[u8], &[u8])> {
    let at = buffer.iter().position(|byte| *byte == b'\n')?;
    Some((buffer.get(..at)?, buffer.get(at + 1..)?))
}

/// The whole of one call's life, on its thread. Answers whether the reply was delivered, and the
/// ending.
fn run(link: &Link, host: &str, port: u16, request: &[u8], sink: &dyn Sink) -> (bool, Option<String>) {
    let mut stream = match Link::dial(host, port) {
        Ok(stream) => stream,
        Err(error) => return (false, Some(error.to_string())),
    };
    if !link.adopt(&stream) {
        return (false, None);
    }
    if !link.write(request) {
        return (false, Some("the request could not be sent".to_owned()));
    }

    let mut pending = Vec::new();
    let mut replied = false;
    // On the heap, not the stack: see `ws::lane::run` — this thread's stack is not the caller's to
    // size, and a read window this size is exactly the local array the lints refuse.
    let mut scratch = vec![0_u8; READ_WINDOW];
    loop {
        let read = match stream.read(&mut scratch) {
            Ok(0) => return (replied, None),
            Ok(read) => read,
            Err(error) => {
                return (
                    replied,
                    if link.is_torn() {
                        None
                    } else {
                        Some(error.to_string())
                    },
                );
            },
        };
        if link.is_torn() {
            return (replied, None);
        }
        let arrived = scratch.get(..read).unwrap_or_default();

        if replied {
            sink.event(Event::Bytes(arrived));
        } else {
            pending.extend_from_slice(arrived);
            match split(&pending) {
                Some((answer, tail)) => {
                    replied = true;
                    sink.event(Event::Reply(answer));
                    if !tail.is_empty() {
                        sink.event(Event::Bytes(tail));
                    }
                    pending = Vec::new();
                },
                None if pending.len() > REPLY_CEILING => {
                    return (false, Some(UNREADABLE_REPLY.to_owned()));
                },
                None => {},
            }
        }
        if link.is_torn() {
            return (replied, None);
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]
    #![expect(clippy::indexing_slicing, reason = "a test drives a buffer it wrote itself")]

    use std::io::{Read as _, Write as _};
    use std::net::{Ipv4Addr, TcpListener, TcpStream};
    use std::sync::{Arc, Condvar, Mutex};
    use std::time::Duration;

    use super::{Call, Event, Sink, split};

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Seen {
        Reply(Vec<u8>),
        Bytes(Vec<u8>),
        Ended(Option<String>),
    }

    #[derive(Debug, Default)]
    struct Recorder {
        seen: Mutex<Vec<Seen>>,
        rang: Condvar,
    }

    impl Recorder {
        fn settled(&self, count: usize) -> Vec<Seen> {
            let mut seen = self.seen.lock().unwrap();
            while seen.len() < count {
                let (next, timed_out) = self.rang.wait_timeout(seen, Duration::from_secs(5)).unwrap();
                seen = next;
                if timed_out.timed_out() {
                    break;
                }
            }
            seen.clone()
        }
    }

    /// The coercion, once and named — an inline `as _` is a trivial cast the lints refuse.
    fn sink(recorder: &Arc<Recorder>) -> Arc<dyn Sink> {
        let held: Arc<Recorder> = Arc::clone(recorder);
        held
    }

    impl Sink for Recorder {
        fn event(&self, event: Event<'_>) {
            let folded = match event {
                Event::Reply(line) => Seen::Reply(line.to_vec()),
                Event::Bytes(bytes) => Seen::Bytes(bytes.to_vec()),
                Event::Ended(reason) => Seen::Ended(reason.map(str::to_owned)),
            };
            if let Ok(mut seen) = self.seen.lock() {
                seen.push(folded);
            }
            self.rang.notify_all();
        }
    }

    /// A bridge that reads the request line and then runs `after`.
    fn serving<After>(after: After) -> (u16, std::thread::JoinHandle<Vec<u8>>)
    where
        After: FnOnce(TcpStream) + Send + 'static,
    {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let served = std::thread::spawn(move || {
            let Ok((mut peer, _)) = listener.accept() else {
                return Vec::new();
            };
            let mut asked = Vec::new();
            let mut scratch = [0_u8; 1024];
            while !asked.contains(&b'\n') {
                let Ok(read) = peer.read(&mut scratch) else {
                    return asked;
                };
                if read == 0 {
                    return asked;
                }
                asked.extend_from_slice(&scratch[..read]);
            }
            after(peer);
            asked
        });
        (port, served)
    }

    #[test]
    fn a_one_shot_call_delivers_its_ack_and_ends() {
        let (port, served) = serving(|mut peer| {
            let _written = peer.write_all(b"{\"ok\":true,\"devices\":[]}\n");
            drop(peer);
        });
        let recorder = Arc::new(Recorder::default());
        let call = Call::open(
            &Ipv4Addr::LOCALHOST.to_string(),
            port,
            b"{\"op\":\"list\"}\n",
            sink(&recorder),
        );
        let seen = recorder.settled(2);
        drop(call);
        assert_eq!(served.join().unwrap(), b"{\"op\":\"list\"}\n");
        assert_eq!(seen, vec![
            Seen::Reply(b"{\"ok\":true,\"devices\":[]}".to_vec()),
            Seen::Ended(None)
        ]);
    }

    /// The paragraph in the module header, as a test: the ack and the head of the stream arrive in
    /// ONE receive, and losing the tail is the difference between a picture and a black rectangle.
    #[test]
    fn the_stream_head_that_shares_a_receive_with_the_ack_is_not_lost() {
        let (port, served) = serving(|mut peer| {
            let mut both = b"{\"ok\":true}\n".to_vec();
            both.extend_from_slice(&[0x00, 0x00, 0x00, 0x01, 0x67]);
            let _written = peer.write_all(&both);
            std::thread::sleep(Duration::from_millis(50));
            drop(peer);
        });
        let recorder = Arc::new(Recorder::default());
        let call = Call::open(
            &Ipv4Addr::LOCALHOST.to_string(),
            port,
            b"{\"op\":\"open\"}\n",
            sink(&recorder),
        );
        let seen = recorder.settled(3);
        drop(call);
        let _joined = served.join();
        assert_eq!(seen, vec![
            Seen::Reply(b"{\"ok\":true}".to_vec()),
            Seen::Bytes(vec![0x00, 0x00, 0x00, 0x01, 0x67]),
            Seen::Ended(None),
        ]);
    }

    /// A caller awaiting a reply must not wait forever for a connection that is already gone.
    #[test]
    fn a_socket_that_dies_before_the_ack_answers_through_the_reply_channel() {
        let (port, served) = serving(drop);
        let recorder = Arc::new(Recorder::default());
        let call = Call::open(
            &Ipv4Addr::LOCALHOST.to_string(),
            port,
            b"{\"op\":\"list\"}\n",
            sink(&recorder),
        );
        let seen = recorder.settled(2);
        drop(call);
        let _joined = served.join();
        assert!(matches!(seen.first(), Some(Seen::Reply(_))), "{seen:?}");
        assert_eq!(seen.get(1), Some(&Seen::Ended(None)));
    }

    #[test]
    fn the_split_takes_the_line_and_keeps_the_tail() {
        assert_eq!(split(b"line\ntail"), Some((&b"line"[..], &b"tail"[..])));
        assert_eq!(split(b"line\n"), Some((&b"line"[..], &b""[..])));
        assert_eq!(split(b"\ntail"), Some((&b""[..], &b"tail"[..])));
        assert_eq!(split(b"no newline yet"), None);
    }
}
