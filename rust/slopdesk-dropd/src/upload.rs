//! PATH 4's upload DRIVER — the order one client connection puts its frames in.
//!
//! [`client`](crate::client) owns every LAYOUT the initiating end writes and reads. This owns the
//! SEQUENCE: dial, pin the version, then per file offer → await accept → stream the body → finish →
//! await the verdict, reporting [`Progress`] as it goes.
//!
//! ## Why the sequence is here and not at the caller
//! It was Swift's — `Sources/SlopDeskFileTransfer/FileTransferClient.swift` — for as long as the
//! near side owned the socket, which meant eight doors vended the layouts while the LAW that orders
//! them lived a language away. `docs/55` §4b names that shape by its symptom: every answer correct
//! in isolation, and no way to check the order they are put together in. A driver whose steps and
//! whose frames live in one module cannot get the order wrong without a test in this file seeing
//! it.
//!
//! ## What a caller may not misorder
//! One entry point, [`to_host`], and one seam under it, [`over_link`], for a test that would
//! rather script a peer than run one. There is deliberately no "send an offer" verb to reach for: a
//! caller holding one would be holding half the law again.
//!
//! ## A batch is never silent
//! Every file reports either [`Progress::Completed`] or [`Progress::Failed`], including when the
//! host cannot be dialled at all. The near side draws a row per file before the first byte moves,
//! and a row that never settles is a worse answer than one that says why.

use std::borrow::Cow;
use std::fs::File;
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

use crate::client::{
    CHUNK_BYTE_COUNT, ReplyFrameDecoder, chunk_frame_len, encode_request_frame, write_chunk_frame,
};
use crate::protocol::{Reply, Request, VERSION};

/// How much of a reply stream one `read` may collect. A reply is tens of bytes; this is generous.
const RECEIVE_BUFFER: usize = 8 * 1024;

/// One upload's progress, in emission order.
///
/// Borrowed rather than owned throughout: every string is a local of the frame that reports it, and
/// an observer that wants to keep one copies it. A record that owned its text would allocate four
/// thousand times per gigabyte to say the same numbers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress<'a> {
    /// The file was opened and its size read; no body has moved yet.
    Started {
        /// The client-scoped transfer id — the file's index in the batch.
        transfer_id: u32,
        /// The leaf name the host is offered.
        name: &'a str,
        /// The body length the offer promises.
        total_bytes: u64,
    },
    /// A chunk went out. `sent_bytes` never runs backwards within a transfer.
    Advanced {
        /// Which transfer moved.
        transfer_id: u32,
        /// How much of the body has reached the socket.
        sent_bytes: u64,
        /// The body length the offer promised.
        total_bytes: u64,
    },
    /// The host wrote the whole body and moved the file into place.
    Completed {
        /// Which transfer finished.
        transfer_id: u32,
    },
    /// This transfer is over and the file did not land. The rest of the batch still tries.
    Failed {
        /// Which transfer failed.
        transfer_id: u32,
        /// Why, in words a toast can show. Never a path.
        reason: &'a str,
    },
}

/// Uploads `files` to `host:port` over ONE connection, reporting to `observe`.
///
/// Returns once every file has completed or failed and the socket is closed. Each file is offered
/// under its INDEX in `files`, which is the id every [`Progress`] carries.
pub fn to_host<O>(host: &str, port: u16, connect_timeout: Duration, files: &[&Path], observe: &mut O)
where
    O: FnMut(Progress<'_>),
{
    match dial(host, port, connect_timeout) {
        Ok(link) => over_link(link, files, observe),
        Err(error) => refuse_batch(files, observe, &format!("cannot reach {host}:{port} — {error}")),
    }
}

/// [`to_host`] over an already-open link — the seam a test scripts a peer against.
///
/// The link is CONSUMED, so it closes when this returns, however it returns.
pub fn over_link<S, O>(link: S, files: &[&Path], observe: &mut O)
where
    S: Read + Write,
    O: FnMut(Progress<'_>),
{
    let mut session = Session::new(link);
    match session.handshake() {
        Ok(true) => {},
        Ok(false) => {
            refuse_batch(files, observe, "the host refused this protocol version");
            return;
        },
        Err(error) => {
            refuse_batch(files, observe, &format!("the handshake failed — {error}"));
            return;
        },
    }
    for (index, path) in files.iter().enumerate() {
        send_one(
            &mut session,
            u32::try_from(index).unwrap_or(u32::MAX),
            path,
            observe,
        );
    }
}

/// Connects to the first address `host:port` resolves to that answers inside `timeout`.
///
/// Bounded on purpose: an unreachable host must fail rather than park the calling thread forever,
/// and `TcpStream::connect` has no bound of its own.
fn dial(host: &str, port: u16, timeout: Duration) -> io::Result<TcpStream> {
    let mut refusal = io::Error::new(io::ErrorKind::NotFound, "the host resolved to no address");
    for address in (host, port).to_socket_addrs()? {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(link) => return Ok(link),
            Err(error) => refusal = error,
        }
    }
    Err(refusal)
}

/// Fails every file in the batch for a reason that is about the CONNECTION, not about any one file.
fn refuse_batch<O>(files: &[&Path], observe: &mut O, why: &str)
where
    O: FnMut(Progress<'_>),
{
    for (index, path) in files.iter().enumerate() {
        let reason = format!("{why} — {}", leaf(path));
        observe(Progress::Failed {
            transfer_id: u32::try_from(index).unwrap_or(u32::MAX),
            reason: &reason,
        });
    }
}

/// Offers, streams and finishes ONE file, reporting whatever became of it.
///
/// A file that cannot be opened never reports [`Progress::Started`]: nothing was offered, so there
/// is no transfer to have started.
fn send_one<S, O>(session: &mut Session<S>, transfer_id: u32, path: &Path, observe: &mut O)
where
    S: Read + Write,
    O: FnMut(Progress<'_>),
{
    let name = leaf(path);
    let Ok((mut body, total_bytes)) = open(path) else {
        let reason = format!("cannot read {name}");
        observe(Progress::Failed {
            transfer_id,
            reason: &reason,
        });
        return;
    };
    observe(Progress::Started {
        transfer_id,
        name: &name,
        total_bytes,
    });
    match stream(session, transfer_id, &mut body, total_bytes, &name, observe) {
        Ok(None) => observe(Progress::Completed { transfer_id }),
        Ok(Some(reason)) => {
            observe(Progress::Failed {
                transfer_id,
                reason: &reason,
            });
        },
        Err(error) => {
            // The link may already be dead; the cancel is a courtesy to a host still holding a
            // half-written file open, so its own failure is not the interesting one.
            drop(session.send(&Request::Cancel { transfer_id }));
            let reason = format!("upload error for {name} — {error}");
            observe(Progress::Failed {
                transfer_id,
                reason: &reason,
            });
        },
    }
}

/// The whole exchange for one file: `None` once it has landed, or the reason it did not.
///
/// The `Err` arm is reserved for the LINK — a send or a read that failed — which is a different
/// thing for the caller to do: it cancels, where a refusal is simply the host's answer.
fn stream<S, O>(
    session: &mut Session<S>,
    transfer_id: u32,
    body: &mut File,
    total_bytes: u64,
    name: &str,
    observe: &mut O,
) -> io::Result<Option<String>>
where
    S: Read + Write,
    O: FnMut(Progress<'_>),
{
    session.send(&Request::Offer {
        transfer_id,
        file_size: total_bytes,
        name: name.to_owned(),
    })?;
    if !matches!(session.reply_about(transfer_id)?, Some(Reply::Accept { .. })) {
        return Ok(Some(format!("the host did not accept {name}")));
    }

    let mut chunk = vec![0_u8; CHUNK_BYTE_COUNT];
    let mut sent = 0_u64;
    loop {
        let filled = fill(body, &mut chunk)?;
        let Some(payload) = chunk.get(..filled).filter(|slice| !slice.is_empty()) else {
            break;
        };
        session.send_chunk(transfer_id, payload)?;
        sent = sent.saturating_add(u64::try_from(filled).unwrap_or(u64::MAX));
        observe(Progress::Advanced {
            transfer_id,
            sent_bytes: sent,
            total_bytes,
        });
    }

    session.send(&Request::Finish { transfer_id })?;
    Ok(match session.reply_about(transfer_id)? {
        Some(Reply::Complete { .. }) => None,
        Some(Reply::Failed { reason, .. }) => Some(reason),
        // An `accept` arriving here, or a stream that ended with nothing said: neither is the host
        // reporting that the file landed, and only that reading may be shown as success.
        _ => Some(format!("no completion for {name}")),
    })
}

/// The file and the size its offer promises.
fn open(path: &Path) -> io::Result<(File, u64)> {
    let body = File::open(path)?;
    let size = body.metadata()?.len();
    Ok((body, size))
}

/// The leaf name a host is offered, or the whole path when there is no leaf.
///
/// Lossy, because the name is UNTRUSTED at the far end anyway: dropd sanitises it before it touches
/// a filesystem, so a path this side cannot spell as UTF-8 is better offered approximately than
/// refused locally.
fn leaf(path: &Path) -> Cow<'_, str> {
    path.file_name().unwrap_or(path.as_os_str()).to_string_lossy()
}

/// Reads until `chunk` is full or the file ends, answering how many bytes landed.
///
/// A short read is not the end of a file, and one frame per short read would hand the framing
/// overhead of a whole upload to whatever block size the filesystem felt like.
fn fill(body: &mut File, chunk: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while let Some(room) = chunk.get_mut(filled..).filter(|room| !room.is_empty()) {
        match body.read(room) {
            Ok(0) => break,
            Ok(read) => filled = filled.saturating_add(read),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {},
            Err(error) => return Err(error),
        }
    }
    Ok(filled)
}

/// Which transfer a reply is about, or `None` for one that is about the connection.
const fn about(reply: &Reply) -> Option<u32> {
    match *reply {
        Reply::Accept { transfer_id }
        | Reply::Complete { transfer_id }
        | Reply::Failed { transfer_id, .. } => Some(transfer_id),
        Reply::HelloAck { .. } => None,
    }
}

/// One connection: the link, the splitter reading it, and the buffers both reuse.
struct Session<S> {
    link: S,
    replies: ReplyFrameDecoder,
    received: Vec<u8>,
    frame: Vec<u8>,
}

impl<S: Read + Write> Session<S> {
    /// A session over `link`, having sent nothing.
    fn new(link: S) -> Self {
        Self {
            link,
            replies: ReplyFrameDecoder::new(),
            received: vec![0_u8; RECEIVE_BUFFER],
            frame: Vec::new(),
        }
    }

    /// Pins the version and answers whether the host speaks it.
    fn handshake(&mut self) -> io::Result<bool> {
        self.send(&Request::Hello { version: VERSION })?;
        Ok(matches!(
            self.next_reply()?,
            Some(Reply::HelloAck { accepted: true })
        ))
    }

    /// Writes one whole frame.
    fn send(&mut self, request: &Request) -> io::Result<()> {
        self.link.write_all(&encode_request_frame(request))
    }

    /// Writes one chunk frame, with the body copied ONCE — from the caller's buffer into this one.
    fn send_chunk(&mut self, transfer_id: u32, data: &[u8]) -> io::Result<()> {
        self.frame.resize(chunk_frame_len(data.len()), 0);
        if !write_chunk_frame(&mut self.frame, transfer_id, data) {
            return Err(io::Error::other(
                "a chunk frame did not fit the length it asked for",
            ));
        }
        self.link.write_all(&self.frame)
    }

    /// The host's next word ABOUT `transfer_id`, skipping anything it says about another.
    ///
    /// `None` once the stream ends with nothing said.
    fn reply_about(&mut self, transfer_id: u32) -> io::Result<Option<Reply>> {
        while let Some(reply) = self.next_reply()? {
            if about(&reply) == Some(transfer_id) {
                return Ok(Some(reply));
            }
        }
        Ok(None)
    }

    /// The next whole reply, reading the link until one is buffered. `None` at end of stream.
    fn next_reply(&mut self) -> io::Result<Option<Reply>> {
        loop {
            if let Some(reply) = self.replies.next_reply().map_err(io::Error::other)? {
                return Ok(Some(reply));
            }
            match self.link.read(&mut self.received) {
                Ok(0) => return Ok(None),
                Ok(read) => self.replies.append(self.received.get(..read).unwrap_or(&[])),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {},
                Err(error) => return Err(error),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::{self, Read, Write};
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::Duration;
    use std::{fs, thread};

    use super::{Progress, over_link, to_host};
    use crate::client::CHUNK_BYTE_COUNT;
    use crate::protocol::{Reply, Request, decode_request, encode_reply_frame};

    /// A scripted peer: its replies are queued up front, its requests collected as they arrive.
    ///
    /// Pre-loading every reply is sound because the driver reads only when it WANTS one — the
    /// splitter buffers whatever else arrived — so a whole conversation is one literal and the test
    /// never has to schedule anything.
    struct ScriptedPeer {
        inbound: Vec<u8>,
        read_from: usize,
        outbound: Vec<u8>,
        writes_left: usize,
    }

    impl ScriptedPeer {
        fn answering(replies: &[Reply]) -> Self {
            Self {
                inbound: replies.iter().flat_map(encode_reply_frame).collect(),
                read_from: 0,
                outbound: Vec::new(),
                writes_left: usize::MAX,
            }
        }

        /// The same peer, whose link dies once `writes` more frames have reached it.
        fn dying_after(mut self, writes: usize) -> Self {
            self.writes_left = writes;
            self
        }
    }

    impl Read for ScriptedPeer {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            let rest = self.inbound.get(self.read_from..).unwrap_or(&[]);
            let taken = rest.len().min(out.len());
            let (Some(room), Some(source)) = (out.get_mut(..taken), rest.get(..taken)) else {
                return Ok(0);
            };
            room.copy_from_slice(source);
            self.read_from = self.read_from.saturating_add(taken);
            Ok(taken)
        }
    }

    impl Write for ScriptedPeer {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            if self.writes_left == 0 {
                return Err(io::Error::from(io::ErrorKind::BrokenPipe));
            }
            self.writes_left = self.writes_left.saturating_sub(1);
            self.outbound.extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// The payload of the frame starting at `cursor`, once all of it is buffered.
    fn whole_frame(buffer: &[u8], cursor: usize) -> Option<Vec<u8>> {
        let prefix = buffer.get(cursor..cursor.checked_add(4)?)?;
        let length = usize::try_from(u32::from_be_bytes(prefix.try_into().ok()?)).ok()?;
        let start = cursor.checked_add(4)?;
        Some(buffer.get(start..start.checked_add(length)?)?.to_vec())
    }

    /// Every request the driver put on the wire, in order.
    fn requests(wire: &[u8]) -> Vec<Request> {
        let mut sent = Vec::new();
        let mut cursor = 0;
        while let Some(payload) = whole_frame(wire, cursor) {
            cursor = cursor.saturating_add(4).saturating_add(payload.len());
            sent.push(decode_request(&payload).expect("a frame this end wrote"));
        }
        sent
    }

    /// A directory of this test's own, removed when the guard drops.
    struct Scratch(PathBuf);

    impl Scratch {
        fn made() -> Self {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let root = std::env::temp_dir().join(format!(
                "slopdesk-drop-upload-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).expect("a scratch directory");
            Self(root)
        }

        fn holding(&self, name: &str, body: &[u8]) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, body).expect("a scratch file");
            path
        }

        fn missing(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            drop(fs::remove_dir_all(&self.0));
        }
    }

    /// One reported event, owned so a test can assert on the whole sequence at once.
    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Seen {
        Started(u32, String, u64),
        Advanced(u32, u64, u64),
        Completed(u32),
        Failed(u32, String),
    }

    /// An observer that appends to `seen`.
    fn collecting(seen: &mut Vec<Seen>) -> impl FnMut(Progress<'_>) + '_ {
        |progress| {
            seen.push(match progress {
                Progress::Started {
                    transfer_id,
                    name,
                    total_bytes,
                } => Seen::Started(transfer_id, name.to_owned(), total_bytes),
                Progress::Advanced {
                    transfer_id,
                    sent_bytes,
                    total_bytes,
                } => Seen::Advanced(transfer_id, sent_bytes, total_bytes),
                Progress::Completed { transfer_id } => Seen::Completed(transfer_id),
                Progress::Failed { transfer_id, reason } => Seen::Failed(transfer_id, reason.to_owned()),
            });
        }
    }

    /// Runs a batch against a scripted peer; answers what was seen and what was sent.
    fn run(peer: ScriptedPeer, files: &[&Path]) -> (Vec<Seen>, Vec<Request>) {
        let mut seen = Vec::new();
        let mut peer = peer;
        {
            let mut observe = collecting(&mut seen);
            over_link(&mut peer, files, &mut observe);
        }
        let sent = requests(&peer.outbound);
        (seen, sent)
    }

    /// The three replies a single-file happy path needs.
    fn welcoming() -> Vec<Reply> {
        vec![
            Reply::HelloAck { accepted: true },
            Reply::Accept { transfer_id: 0 },
            Reply::Complete { transfer_id: 0 },
        ]
    }

    #[test]
    fn one_file_walks_hello_offer_chunk_finish_and_reports_each_step() {
        let scratch = Scratch::made();
        let source = scratch.holding("notes.txt", b"a short body");

        let (seen, sent) = run(ScriptedPeer::answering(&welcoming()), &[source.as_path()]);

        assert_eq!(seen, vec![
            Seen::Started(0, "notes.txt".to_owned(), 12),
            Seen::Advanced(0, 12, 12),
            Seen::Completed(0),
        ]);
        assert_eq!(sent, vec![
            Request::Hello { version: 1 },
            Request::Offer {
                transfer_id: 0,
                file_size: 12,
                name: "notes.txt".to_owned(),
            },
            Request::Chunk {
                transfer_id: 0,
                data: b"a short body".to_vec(),
            },
            Request::Finish { transfer_id: 0 },
        ]);
    }

    #[test]
    fn an_empty_file_completes_without_a_single_chunk() {
        let scratch = Scratch::made();
        let source = scratch.holding("empty.txt", b"");

        let (seen, sent) = run(ScriptedPeer::answering(&welcoming()), &[source.as_path()]);

        assert_eq!(seen, vec![
            Seen::Started(0, "empty.txt".to_owned(), 0),
            Seen::Completed(0),
        ]);
        assert!(
            !sent
                .iter()
                .any(|request| matches!(*request, Request::Chunk { .. })),
            "a zero-byte body has no chunk to send"
        );
    }

    #[test]
    fn progress_climbs_one_chunk_at_a_time_and_lands_on_the_whole_size() {
        let scratch = Scratch::made();
        let size = CHUNK_BYTE_COUNT.saturating_mul(2).saturating_add(17);
        let source = scratch.holding("big.bin", &vec![0xAB_u8; size]);

        let (seen, sent) = run(ScriptedPeer::answering(&welcoming()), &[source.as_path()]);

        let climb: Vec<u64> = seen
            .iter()
            .filter_map(|event| {
                match *event {
                    Seen::Advanced(_, sent_bytes, _) => Some(sent_bytes),
                    _ => None,
                }
            })
            .collect();
        assert_eq!(climb.len(), 3, "two whole chunks and the tail");
        assert!(
            climb.windows(2).all(|pair| pair.first() < pair.last()),
            "progress must never run backwards"
        );
        assert_eq!(climb.last().copied(), u64::try_from(size).ok());
        assert_eq!(
            sent.iter()
                .filter(|request| matches!(**request, Request::Chunk { .. }))
                .count(),
            3,
            "a short read must not become a frame of its own"
        );
    }

    #[test]
    fn a_refused_version_fails_every_file_and_offers_none() {
        let scratch = Scratch::made();
        let first = scratch.holding("one.txt", b"1");
        let second = scratch.holding("two.txt", b"2");
        let peer = ScriptedPeer::answering(&[Reply::HelloAck { accepted: false }]);

        let (seen, sent) = run(peer, &[first.as_path(), second.as_path()]);

        assert_eq!(seen.len(), 2);
        assert!(matches!(seen.first(), Some(&Seen::Failed(0, _))));
        assert!(matches!(seen.last(), Some(&Seen::Failed(1, _))));
        assert_eq!(sent, vec![Request::Hello { version: 1 }], "nothing was offered");
    }

    #[test]
    fn a_host_that_says_nothing_at_all_fails_the_batch_rather_than_returning_silent() {
        let scratch = Scratch::made();
        let source = scratch.holding("one.txt", b"1");

        let (seen, _sent) = run(ScriptedPeer::answering(&[]), &[source.as_path()]);

        assert_eq!(seen.len(), 1);
        assert!(matches!(seen.first(), Some(&Seen::Failed(0, _))));
    }

    #[test]
    fn a_file_that_cannot_be_read_fails_before_it_ever_starts() {
        let scratch = Scratch::made();
        let absent = scratch.missing("gone.txt");
        let present = scratch.holding("here.txt", b"x");
        let peer = ScriptedPeer::answering(&[
            Reply::HelloAck { accepted: true },
            Reply::Accept { transfer_id: 1 },
            Reply::Complete { transfer_id: 1 },
        ]);

        let (seen, sent) = run(peer, &[absent.as_path(), present.as_path()]);

        assert!(
            !seen.iter().any(|event| matches!(*event, Seen::Started(0, _, _))),
            "nothing was offered, so nothing started"
        );
        assert!(matches!(seen.first(), Some(&Seen::Failed(0, _))));
        assert_eq!(
            seen.last(),
            Some(&Seen::Completed(1)),
            "the rest of the batch still runs"
        );
        assert!(
            !sent
                .iter()
                .any(|request| matches!(*request, Request::Offer { transfer_id: 0, .. })),
            "an unreadable file is never offered"
        );
    }

    #[test]
    fn a_host_that_does_not_accept_ends_that_file_and_the_next_is_still_offered() {
        let scratch = Scratch::made();
        let refused = scratch.holding("no.txt", b"n");
        let taken = scratch.holding("yes.txt", b"y");
        let peer = ScriptedPeer::answering(&[
            Reply::HelloAck { accepted: true },
            Reply::Failed {
                transfer_id: 0,
                reason: "disk full".to_owned(),
            },
            Reply::Accept { transfer_id: 1 },
            Reply::Complete { transfer_id: 1 },
        ]);

        let (seen, sent) = run(peer, &[refused.as_path(), taken.as_path()]);

        assert_eq!(
            seen.iter()
                .filter(|event| matches!(**event, Seen::Failed(0, _)))
                .count(),
            1
        );
        assert_eq!(seen.last(), Some(&Seen::Completed(1)));
        assert_eq!(
            sent.iter()
                .filter(|request| matches!(**request, Request::Offer { .. }))
                .count(),
            2
        );
    }

    #[test]
    fn a_reply_about_another_transfer_is_skipped_rather_than_taken_for_this_one() {
        let scratch = Scratch::made();
        let source = scratch.holding("one.txt", b"1");
        let peer = ScriptedPeer::answering(&[
            Reply::HelloAck { accepted: true },
            Reply::Complete { transfer_id: 41 },
            Reply::Accept { transfer_id: 7 },
            Reply::Accept { transfer_id: 0 },
            Reply::Failed {
                transfer_id: 9,
                reason: "another file".to_owned(),
            },
            Reply::Complete { transfer_id: 0 },
        ]);

        let (seen, _sent) = run(peer, &[source.as_path()]);

        assert_eq!(seen.last(), Some(&Seen::Completed(0)));
    }

    #[test]
    fn a_failed_verdict_carries_the_hosts_own_words() {
        let scratch = Scratch::made();
        let source = scratch.holding("one.txt", b"1");
        let peer = ScriptedPeer::answering(&[
            Reply::HelloAck { accepted: true },
            Reply::Accept { transfer_id: 0 },
            Reply::Failed {
                transfer_id: 0,
                reason: "the disk is full".to_owned(),
            },
        ]);

        let (seen, _sent) = run(peer, &[source.as_path()]);

        assert_eq!(seen.last(), Some(&Seen::Failed(0, "the disk is full".to_owned())));
    }

    #[test]
    fn a_link_that_dies_mid_transfer_cancels_and_fails_only_that_file() {
        let scratch = Scratch::made();
        let source = scratch.holding("one.txt", b"body");
        // The hello and the offer go out; the chunk write is the one that fails.
        let peer = ScriptedPeer::answering(&[Reply::HelloAck { accepted: true }, Reply::Accept {
            transfer_id: 0,
        }])
        .dying_after(2);

        let (seen, sent) = run(peer, &[source.as_path()]);

        assert!(matches!(seen.first(), Some(&Seen::Started(0, _, 4))));
        assert!(matches!(seen.last(), Some(&Seen::Failed(0, _))));
        assert!(
            !sent
                .iter()
                .any(|request| matches!(*request, Request::Finish { .. })),
            "a dead link never reached the finish"
        );
    }

    #[test]
    fn an_unreachable_host_fails_the_batch_instead_of_parking_the_thread() {
        let scratch = Scratch::made();
        let source = scratch.holding("one.txt", b"1");
        // Bound and immediately dropped, so nothing is listening on that port any more.
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port");
            listener.local_addr().expect("a bound address").port()
        };

        let mut seen = Vec::new();
        {
            let mut observe = collecting(&mut seen);
            to_host(
                "127.0.0.1",
                port,
                Duration::from_millis(500),
                &[source.as_path()],
                &mut observe,
            );
        }

        assert_eq!(seen.len(), 1);
        assert!(matches!(seen.first(), Some(&Seen::Failed(0, _))));
    }

    #[test]
    fn a_whole_upload_crosses_a_real_loopback_socket() {
        let scratch = Scratch::made();
        let body = vec![0x5A_u8; CHUNK_BYTE_COUNT.saturating_add(3)];
        let source = scratch.holding("real.bin", &body);
        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        let port = listener.local_addr().expect("a bound address").port();

        // A minimal peer: read whole frames, answer each request the protocol expects, keep the body.
        let peer = thread::spawn(move || -> Vec<u8> {
            let (mut link, _from) = listener.accept().expect("one connection");
            let mut received = Vec::new();
            let mut window = vec![0_u8; 64 * 1024];
            let mut cursor = 0;
            let mut landed = Vec::new();
            loop {
                while let Some(payload) = whole_frame(&received, cursor) {
                    cursor = cursor.saturating_add(4).saturating_add(payload.len());
                    let answer = match decode_request(&payload).expect("a frame the driver wrote") {
                        Request::Hello { .. } => Some(Reply::HelloAck { accepted: true }),
                        Request::Offer { transfer_id, .. } => Some(Reply::Accept { transfer_id }),
                        Request::Chunk { ref data, .. } => {
                            landed.extend_from_slice(data);
                            None
                        },
                        Request::Finish { transfer_id } => Some(Reply::Complete { transfer_id }),
                        _ => None,
                    };
                    if let Some(reply) = answer {
                        link.write_all(&encode_reply_frame(&reply))
                            .expect("the reply goes out");
                    }
                }
                match link.read(&mut window) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => received.extend_from_slice(window.get(..read).unwrap_or(&[])),
                }
            }
            landed
        });

        let mut seen = Vec::new();
        {
            let mut observe = collecting(&mut seen);
            to_host(
                "127.0.0.1",
                port,
                Duration::from_secs(5),
                &[source.as_path()],
                &mut observe,
            );
        }

        assert_eq!(seen.last(), Some(&Seen::Completed(0)));
        assert_eq!(
            peer.join().expect("the peer thread"),
            body,
            "every byte arrived intact"
        );
    }
}
