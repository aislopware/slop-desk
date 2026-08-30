//! One websocket, from the dial to the last frame.
//!
//! Both simulator sockets are this: the frame stream and the console differ in what they make of a
//! message, never in how one arrives. That was already true in Swift — the two classes shared a
//! protocol extension holding exactly this state machine — and the split survives the port with the
//! seam in the same place: what a message MEANS is the panel's, and it is decided by
//! `slopdesk_devicepanel`'s own decoders on the far side of the sink.
//!
//! ## The pong is explicit, and the reason is worth keeping after the trap is gone
//!
//! The Swift lanes did not set `NWProtocolWebSocket.Options.autoReplyPing`, and both carried the
//! same measured paragraph explaining why: inserting an options object into
//! `defaultProtocolStack.applicationProtocols` stores a COPY, so `stack.first === options` is
//! false and the copy reads the flag back as its default. Setting it LOOKED like keepalive
//! handling while providing none, and the failure was a socket the server dropped on its own idle
//! timer, minutes into a session, for no visible reason.
//!
//! That trap belonged to `Network.framework` and does not exist here — there is no options object
//! to copy. The BEHAVIOUR it forced is still the right one and is now the only one: [`run`] answers
//! every ping with a pong carrying the same payload, in the read loop, where it can be read.

use std::io::Read as _;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::session::{Link, Session};
use crate::ws::frame::{self, Folded, Message, Opcode, Step};
use crate::ws::handshake;

/// The most of a response head this client will buffer before calling the peer's answer nonsense.
///
/// A conforming upgrade response is a few hundred bytes. Sixteen kibibytes is generous room for a
/// server that adds headers and a hard stop for one that never sends the blank line.
const HEAD_CEILING: usize = 16 << 10;

/// How much is asked for per `read`.
///
/// A wide window on purpose: an access unit runs to tens of kilobytes and a 4 KiB window would
/// multiply the syscalls without changing what arrives — the same reasoning the Swift bridge socket
/// recorded for its own receive size.
const READ_WINDOW: usize = 64 << 10;

/// What the lane tells its owner. Every borrow dies when the call returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event<'a> {
    /// The handshake completed. No messages yet.
    Connected,
    /// A whole text message. Not validated as UTF-8 — what a bad byte means belongs to the decoder
    /// the panel hands it to.
    Text(&'a [u8]),
    /// A whole binary message.
    Binary(&'a [u8]),
    /// The socket is over. `None` is a clean close — the peer's close frame, or a read that ended.
    Ended(Option<&'a str>),
}

/// Where a lane's events go. Called on the lane's own thread, never concurrently with itself.
pub trait Sink: Send + Sync {
    /// One event. The borrow is valid for this call only.
    fn event(&self, event: Event<'_>);
}

/// One live websocket. Dropping it tears the socket down and joins the reader, after which the
/// sink is not called again.
#[derive(Debug)]
pub struct Lane {
    session: Session,
}

impl Lane {
    /// Open `url` and start reading.
    ///
    /// Returns at once; the dial happens on the lane's thread. A URL this client will not open —
    /// see [`handshake::dial`] — ends the lane immediately rather than failing to construct one, so
    /// the caller has exactly one path for "it did not work" instead of two.
    #[must_use]
    pub fn open(url: &str, sink: Arc<dyn Sink>) -> Self {
        let url = url.to_owned();
        let link = Link::new();
        let session = Session::open(link, "slopdesk.devicelink.ws", move |link| {
            let ending = run(link, &url, sink.as_ref());
            if !link.is_torn() {
                sink.event(Event::Ended(ending.as_deref()));
            }
        });
        Self { session }
    }

    /// Send one text message. `false` when the socket is not up — see [`Link::write`] on why that
    /// is a drop rather than a queue.
    #[must_use]
    pub fn send_text(&self, text: &[u8]) -> bool {
        self.session
            .link()
            .write(&frame::encode(Opcode::Text, text, mask()))
    }
}

/// The whole of one socket's life, on the lane's thread.
///
/// The answer is the ENDING: `Some(reason)` for a failure worth wording, `None` for a clean close.
/// Delivering it is the caller's, because a lane torn down on purpose has an owner that already
/// knows and must not hear from a sink it is done with.
fn run(link: &Link, url: &str, sink: &dyn Sink) -> Option<String> {
    let plan = handshake::dial(url, seed())?;
    let mut stream = match Link::dial(&plan.host, plan.port) {
        Ok(stream) => stream,
        Err(error) => return Some(error.to_string()),
    };
    if !link.adopt(&stream) {
        return None;
    }
    if !link.write(&plan.request) {
        return Some("the handshake could not be sent".to_owned());
    }

    let mut buffer = Vec::new();
    // On the heap, not the stack: a read window this size is exactly the local array the lints
    // refuse, and this one lives on a thread whose stack is not the caller's to size.
    let mut scratch = vec![0_u8; READ_WINDOW];
    // Phase one: everything up to the blank line is the response head.
    let body = loop {
        match stream.read(&mut scratch) {
            Ok(0) => return Some("the host closed the connection during the handshake".to_owned()),
            Ok(read) => buffer.extend_from_slice(scratch.get(..read).unwrap_or_default()),
            Err(error) => return Some(error.to_string()),
        }
        if link.is_torn() {
            return None;
        }
        if let Some(at) = find_blank_line(&buffer) {
            let head = buffer.get(..at).unwrap_or_default();
            if !handshake::accepted(head, &plan.accept) {
                return Some("the host did not accept the websocket upgrade".to_owned());
            }
            break buffer.get(at..).unwrap_or_default().to_vec();
        }
        if buffer.len() > HEAD_CEILING {
            return Some("the host's answer to the upgrade made no sense".to_owned());
        }
    };

    sink.event(Event::Connected);

    // Phase two: frames, starting with whatever arrived in the same read as the head.
    let mut buffer = body;
    let mut fold = frame::Reassembler::new();
    loop {
        loop {
            match frame::step(&buffer) {
                Step::Partial => break,
                Step::Invalid => return Some("the host sent a frame this build cannot read".to_owned()),
                Step::Frame(read, consumed) => {
                    let folded = fold.push(read);
                    buffer.drain(..consumed);
                    match folded {
                        Folded::Pending => {},
                        Folded::Invalid => {
                            return Some("the host sent a frame this build cannot read".to_owned());
                        },
                        Folded::Message(Message::Close) => return None,
                        Folded::Message(Message::Ping(payload)) => {
                            // Answered here rather than by an option somewhere — see the module
                            // header. A pong that cannot be written is a socket that is going away
                            // anyway, so the failure is the read loop's to notice.
                            let _ignored = link.write(&frame::encode(Opcode::Pong, &payload, mask()));
                        },
                        Folded::Message(Message::Text(payload)) => sink.event(Event::Text(&payload)),
                        Folded::Message(Message::Binary(payload)) => {
                            sink.event(Event::Binary(&payload));
                        },
                    }
                },
            }
            if link.is_torn() {
                return None;
            }
        }

        match stream.read(&mut scratch) {
            Ok(0) => return None,
            Ok(read) => buffer.extend_from_slice(scratch.get(..read).unwrap_or_default()),
            Err(error) => {
                return if link.is_torn() {
                    None
                } else {
                    Some(error.to_string())
                };
            },
        }
        if link.is_torn() {
            return None;
        }
    }
}

/// Where the head ends: the offset of the first byte AFTER the blank line, or `None`.
fn find_blank_line(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|at| at + 4)
}

/// A per-frame mask, and a per-dial key, from the clock. See [`handshake`] on why this is not an
/// entropy source: on this link the value's only job is to differ from the last one.
fn seed() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX))
}

/// One frame's mask.
fn mask() -> [u8; 4] {
    let bytes = seed().to_le_bytes();
    let mut mask = [0_u8; 4];
    for (slot, byte) in mask.iter_mut().zip(bytes) {
        *slot = byte;
    }
    mask
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]
    #![expect(clippy::indexing_slicing, reason = "a test drives a buffer it wrote itself")]
    #![expect(
        clippy::similar_names,
        reason = "a recorder and its held clone are the same subject"
    )]

    use std::io::{Read as _, Write as _};
    use std::net::{Ipv4Addr, TcpListener, TcpStream};
    use std::sync::{Arc, Condvar, Mutex};
    use std::time::Duration;

    use super::{Event, Lane, Sink, find_blank_line};
    use crate::ws::frame::{Opcode, encode};
    use crate::ws::handshake;

    /// Every event a lane delivered, in order, as owned copies.
    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Seen {
        Connected,
        Text(Vec<u8>),
        Binary(Vec<u8>),
        Ended(Option<String>),
    }

    #[derive(Debug, Default)]
    struct Recorder {
        seen: Mutex<Vec<Seen>>,
        rang: Condvar,
    }

    impl Recorder {
        /// Wait until `count` events have arrived, or give up and answer what there is.
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
                Event::Connected => Seen::Connected,
                Event::Text(bytes) => Seen::Text(bytes.to_vec()),
                Event::Binary(bytes) => Seen::Binary(bytes.to_vec()),
                Event::Ended(reason) => Seen::Ended(reason.map(str::to_owned)),
            };
            if let Ok(mut seen) = self.seen.lock() {
                seen.push(folded);
            }
            self.rang.notify_all();
        }
    }

    /// A server that performs the upgrade and then runs `after` with the socket.
    fn serving<After>(after: After) -> (u16, std::thread::JoinHandle<()>)
    where
        After: FnOnce(TcpStream) + Send + 'static,
    {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let served = std::thread::spawn(move || {
            let Ok((mut peer, _)) = listener.accept() else {
                return;
            };
            let mut head = Vec::new();
            let mut scratch = [0_u8; 1024];
            let key = loop {
                let Ok(read) = peer.read(&mut scratch) else {
                    return;
                };
                if read == 0 {
                    return;
                }
                head.extend_from_slice(&scratch[..read]);
                if let Some(at) = find_blank_line(&head) {
                    let text = String::from_utf8_lossy(&head[..at]).into_owned();
                    let key = text
                        .lines()
                        .find_map(|line| line.strip_prefix("Sec-WebSocket-Key: "))
                        .map(|key| key.trim().to_owned());
                    break key.unwrap_or_default();
                }
            };
            let answer = format!(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: \
                 Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
                handshake::accept_for(&key)
            );
            if peer.write_all(answer.as_bytes()).is_err() {
                return;
            }
            after(peer);
        });
        (port, served)
    }

    #[test]
    fn a_lane_connects_and_delivers_both_kinds_of_message() {
        let (port, served) = serving(|mut peer| {
            let _written = peer.write_all(&server_frame(0x1, b"{\"type\":\"error\"}"));
            let _written = peer.write_all(&server_frame(0x2, &[0x01, 0xAA, 0xBB]));
            std::thread::sleep(Duration::from_millis(50));
            drop(peer);
        });
        let recorder = Arc::new(Recorder::default());
        let lane = Lane::open(&format!("ws://127.0.0.1:{port}/stream"), sink(&recorder));
        let seen = recorder.settled(4);
        drop(lane);
        let _joined = served.join();
        assert_eq!(seen, vec![
            Seen::Connected,
            Seen::Text(b"{\"type\":\"error\"}".to_vec()),
            Seen::Binary(vec![0x01, 0xAA, 0xBB]),
            Seen::Ended(None),
        ]);
    }

    /// The property `NWConnection` provided and this had to write: a message split across
    /// continuations arrives as one message.
    #[test]
    fn a_fragmented_message_arrives_whole() {
        let (port, served) = serving(|mut peer| {
            let mut first = vec![0x02, 3];
            first.extend_from_slice(&[1, 2, 3]);
            let mut last = vec![0x80, 2];
            last.extend_from_slice(&[4, 5]);
            let _written = peer.write_all(&first);
            let _written = peer.write_all(&last);
            std::thread::sleep(Duration::from_millis(50));
            drop(peer);
        });
        let recorder = Arc::new(Recorder::default());
        let lane = Lane::open(&format!("ws://127.0.0.1:{port}/stream"), sink(&recorder));
        let seen = recorder.settled(3);
        drop(lane);
        let _joined = served.join();
        assert_eq!(seen.get(1), Some(&Seen::Binary(vec![1, 2, 3, 4, 5])));
    }

    /// The measured behaviour the Swift comment was about: a ping is answered, so the server's idle
    /// timer never fires on a live session.
    #[test]
    fn a_ping_is_answered_with_a_pong_carrying_the_same_payload() {
        let (answered, told) = (Arc::new(Mutex::new(Vec::new())), Arc::new(Condvar::new()));
        let (recorded, ringing) = (Arc::clone(&answered), Arc::clone(&told));
        let (port, served) = serving(move |mut peer| {
            let _written = peer.write_all(&server_frame(0x9, b"beat"));
            let mut scratch = [0_u8; 64];
            if let Ok(read) = peer.read(&mut scratch)
                && let Ok(mut slot) = recorded.lock()
            {
                slot.extend_from_slice(&scratch[..read]);
            }
            ringing.notify_all();
            drop(peer);
        });
        let recorder = Arc::new(Recorder::default());
        let lane = Lane::open(&format!("ws://127.0.0.1:{port}/stream"), sink(&recorder));

        let mut slot = answered.lock().unwrap();
        while slot.is_empty() {
            let (next, timed_out) = told.wait_timeout(slot, Duration::from_secs(5)).unwrap();
            slot = next;
            if timed_out.timed_out() {
                break;
            }
        }
        let pong = slot.clone();
        drop(slot);
        drop(lane);
        let _joined = served.join();

        assert_eq!(pong.first().copied(), Some(0x8A), "a pong, and a final one");
        assert_eq!(pong.get(1).copied(), Some(0x80 | 4), "masked, four bytes");
        let unmasked: Vec<u8> = pong
            .get(6..)
            .unwrap_or_default()
            .iter()
            .enumerate()
            .map(|(at, byte)| byte ^ pong.get(2 + (at & 3)).copied().unwrap_or(0))
            .collect();
        assert_eq!(unmasked, b"beat");
    }

    /// A plain TCP service on a forwarded port is the failure this validation exists for: it must
    /// read as a handshake that did not happen, not as a websocket sending malformed frames.
    #[test]
    fn a_server_that_does_not_upgrade_ends_the_lane_rather_than_reading_its_bytes_as_frames() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let served = std::thread::spawn(move || {
            if let Ok((mut peer, _)) = listener.accept() {
                let mut scratch = [0_u8; 1024];
                let _read = peer.read(&mut scratch);
                let _written = peer.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        let recorder = Arc::new(Recorder::default());
        let lane = Lane::open(&format!("ws://127.0.0.1:{port}/stream"), sink(&recorder));
        let seen = recorder.settled(1);
        drop(lane);
        let _joined = served.join();
        assert_eq!(seen, vec![Seen::Ended(Some(
            "the host did not accept the websocket upgrade".to_owned()
        ))]);
    }

    /// A URL the client will not open answers through the sink, so the caller has ONE failure path.
    #[test]
    fn a_url_this_client_will_not_open_ends_through_the_sink() {
        let recorder = Arc::new(Recorder::default());
        let lane = Lane::open("wss://simulator.local/stream", sink(&recorder));
        assert_eq!(recorder.settled(1), vec![Seen::Ended(None)]);
        drop(lane);
    }

    /// Dropping the lane must not word an ending for a teardown its owner asked for.
    #[test]
    fn a_lane_torn_down_on_purpose_says_nothing_on_the_way_out() {
        let (port, served) = serving(|peer| {
            std::thread::sleep(Duration::from_secs(2));
            drop(peer);
        });
        let recorder = Arc::new(Recorder::default());
        let lane = Lane::open(&format!("ws://127.0.0.1:{port}/stream"), sink(&recorder));
        let _connected = recorder.settled(1);
        drop(lane);
        let _joined = served.join();
        assert_eq!(recorder.settled(1), vec![Seen::Connected]);
    }

    #[test]
    fn the_blank_line_is_found_at_its_end_and_nowhere_else() {
        assert_eq!(find_blank_line(b"HTTP/1.1 101\r\n\r\nbody"), Some(16));
        assert_eq!(find_blank_line(b"HTTP/1.1 101\r\n"), None);
    }

    /// One unmasked server frame with a short length.
    fn server_frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![0x80 | opcode, u8::try_from(payload.len()).unwrap()];
        out.extend_from_slice(payload);
        out
    }

    /// A client frame the lane would write, kept so the mask helper stays exercised from the one
    /// place that reads its output.
    #[test]
    fn the_lane_writes_masked_text() {
        let written = encode(Opcode::Text, b"{}", super::mask());
        assert_eq!(written.first().copied(), Some(0x81));
        assert_eq!(written.get(1).copied(), Some(0x80 | 2));
    }
}
