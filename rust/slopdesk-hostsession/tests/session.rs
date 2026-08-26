//! One pane's session, end to end: a fake superd on a real `AF_UNIX` socket, a real PTY, and real
//! sub-channels whose framed bytes are decoded back out of the link.
//!
//! Nothing between this file and the kernel is a stand-in. superd's own framing goes over a real
//! socket, the master crosses by `SCM_RIGHTS`, and what the session "sent" is read back by running
//! [`FrameDecoder`] over the bytes the link actually received — so a message that never encoded
//! fails here rather than passing as an assertion against an intent.
//!
//! Three of these are load-bearing rather than illustrative.
//! [`the_exit_lands_behind_the_last_byte`] is the EOF gate's whole purpose, and it is invisible
//! from either end alone. [`a_torn_down_session_leaves_no_thread_running`] is the leak that Rust's
//! missing `Task.cancel` creates: every relay and sender has to END on something the teardown can
//! cause, and a session that merely stops using a thread still has it.
//! [`a_relinquish_signals_nothing_and_keeps_the_child`] is the line `docs/51` draws between "this
//! daemon is going away" and "this pane is over" — the distinction that stopped a host restart from
//! costing the user every running agent.

#![expect(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::collections::BTreeMap;
use std::io::{self, IoSlice};
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nix::sys::socket::{ControlMessage, MsgFlags, sendmsg};
use slopdesk_hostnet::link::ByteLink;
use slopdesk_hostnet::subchannel::SubChannel;
use slopdesk_hostpane::PtyProcess;
use slopdesk_hostsession::{PaneSession, SessionConfig, SessionLog, SessionObserver};
use slopdesk_superclient::client::{ClientThreads, SupervisorClient, SupervisorObserver};
use slopdesk_superwire::blockwire::BlockEvent;
use slopdesk_superwire::protocol::{
    ExitedNotice, HelloReply, PaneRecord, Reply, Request, SpawnRequest, StreamPosition, VERSION_MAJOR,
    VERSION_MINOR, event, verb,
};
use slopdesk_superwire::sniffwire::SniffEvent;
use slopdesk_wire::message::{CommandStatus, WireMessage};
use slopdesk_wire::{FrameDecoder, MuxFrame, MuxFrameDecoder};

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// The exit thread's two gates, restated here so a test that must sit one out says WHICH one. They
/// are production constants and deliberately not shortened for the suite.
const EOF_GATE: Duration = Duration::from_secs(2);
const EXIT_SENT_GATE: Duration = Duration::from_secs(10);

// MARK: - The fake superd

/// One side of the control socket, driven by the test.
struct FakeSuperd {
    socket: OwnedFd,
    requests: Receiver<Request>,
}

impl FakeSuperd {
    fn next_request_for(&self, wanted: &str) -> Request {
        loop {
            let request = self
                .requests
                .recv_timeout(GENEROUS)
                .expect("the client sends a request");
            if request.verb == wanted {
                return request;
            }
        }
    }

    /// Runs `act` on another thread, answering every request it sends with a bare OK, and hands
    /// back whatever `act` returned.
    ///
    /// The signal ladder is why this exists: `SupervisorClient::request` parks for superd's reply
    /// with NO timeout, deliberately — a wedged superd should be a visible hang rather than a
    /// second shell forked over the first. So a teardown that signals, run against a fake that
    /// never answers, would hang this suite for ever instead of failing it.
    ///
    /// The teardown is not the only ladder that asks. `join` and `rebind` both re-send the pane's
    /// held blocks to the arriving member, and `blockSnapshot` is a round trip — the Swift's is too
    /// (`resendBlocksOnReattach`). A test that called either DIRECTLY would park the only thread
    /// able to answer it, inside the call it is waiting on, which is exactly the hang this wraps.
    fn answer_everything_while<R: Send>(&self, act: impl FnOnce() -> R + Send) -> R {
        let done = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let acting = scope.spawn(|| {
                let outcome = act();
                done.store(true, Ordering::Release);
                outcome
            });
            // `act` cannot return while it is parked on a reply, so the flag is only ever read as
            // set once nothing is left to answer.
            while !done.load(Ordering::Acquire) {
                if let Ok(request) = self.requests.recv_timeout(Duration::from_millis(10)) {
                    self.reply(&Reply::ok(request.id), None);
                }
            }
            acting.join().expect("the acting thread finishes")
        })
    }

    fn no_request_within(&self, bound: Duration) {
        assert!(
            self.requests.recv_timeout(bound).is_err(),
            "expected silence on the control socket",
        );
    }

    fn reply(&self, reply: &Reply, descriptor: Option<&OwnedFd>) {
        let body = serde_json::to_vec(reply).expect("a reply encodes");
        let tag = [if descriptor.is_some() {
            slopdesk_superwire::TAG_WITH_DESCRIPTOR
        } else {
            slopdesk_superwire::TAG_PLAIN
        }];
        self.write_frame(tag, &body, descriptor);
    }

    fn output(&self, pane_id: &str, offset: u64, payload: &[u8]) {
        let body = slopdesk_superwire::pack_output(pane_id, offset, payload).expect("output packs");
        self.write_frame([slopdesk_superwire::TAG_OUTPUT], &body, None);
    }

    fn sniff(&self, pane_id: &str, events: &[SniffEvent]) {
        let json = slopdesk_superwire::sniffwire::encode_batch(events);
        let body = slopdesk_superwire::pack_pane_json(pane_id, &json).expect("a sniff batch packs");
        self.write_frame([slopdesk_superwire::TAG_SNIFF], &body, None);
    }

    fn blocks(&self, pane_id: &str, events: &[BlockEvent]) {
        let json = slopdesk_superwire::blockwire::encode_batch(events);
        let body = slopdesk_superwire::pack_pane_json(pane_id, &json).expect("a blocks batch packs");
        self.write_frame([slopdesk_superwire::TAG_BLOCKS], &body, None);
    }

    fn announce_exit(&self, pane_id: &str, code: i32) {
        let mut reply = Reply::ok(slopdesk_superwire::protocol::NOTIFICATION_ID);
        reply.event = Some(event::EXITED.to_owned());
        reply.exited = Some(ExitedNotice {
            pane_id: pane_id.to_owned(),
            pid: 4242,
            code,
        });
        self.reply(&reply, None);
    }

    fn write_frame(&self, tag: [u8; 1], body: &[u8], descriptor: Option<&OwnedFd>) {
        let iov = [IoSlice::new(&tag)];
        match descriptor {
            Some(carried) => {
                let fds = [carried.as_raw_fd()];
                let cmsgs = [ControlMessage::ScmRights(&fds)];
                sendmsg::<()>(self.socket.as_raw_fd(), &iov, &cmsgs, MsgFlags::empty(), None)
                    .expect("the tag and its descriptor go out");
            },
            None => {
                sendmsg::<()>(self.socket.as_raw_fd(), &iov, &[], MsgFlags::empty(), None)
                    .expect("the tag goes out");
            },
        }
        let header = slopdesk_superwire::header(body.len()).expect("the body fits a frame");
        write_all(&self.socket, &header);
        write_all(&self.socket, body);
    }
}

fn write_all(socket: &OwnedFd, mut bytes: &[u8]) {
    while !bytes.is_empty() {
        let written = nix::unistd::write(socket, bytes).expect("the frame goes out");
        bytes = bytes.get(written..).expect("a short write stays in bounds");
    }
}

fn hello_reply(id: u64) -> Reply {
    let mut reply = Reply::ok(id);
    reply.hello = Some(HelloReply {
        version_major: VERSION_MAJOR,
        version_minor: VERSION_MINOR,
        superd_pid: 4321,
        hook_socket_path: None,
        control_socket_path: None,
        build_version: Some("0.0.0-test".to_owned()),
    });
    reply
}

fn pane_record(pane_id: &str, pid: i32) -> PaneRecord {
    PaneRecord {
        pane_id: pane_id.to_owned(),
        session_id: "session-1".to_owned(),
        pid,
        executable: "/bin/zsh".to_owned(),
        cwd: None,
        rows: 24,
        cols: 80,
        spawned_at: 1_700_000_000,
        attached: false,
        owner: None,
    }
}

fn spawn_request(pane_id: &str) -> SpawnRequest {
    SpawnRequest {
        pane_id: pane_id.to_owned(),
        session_id: "session-1".to_owned(),
        executable: "/bin/zsh".to_owned(),
        argv0: Some("-zsh".to_owned()),
        arguments: Vec::new(),
        environment: BTreeMap::new(),
        cwd: None,
        rows: 24,
        cols: 80,
        owner: None,
        shell_integration: true,
        journal: None,
        blocks: None,
    }
}

#[derive(Debug, Default)]
struct Watcher;

impl SupervisorObserver for Watcher {
    fn exited(&self, _notice: &ExitedNotice) {}
    fn connection(&self, _kind: slopdesk_superclient::client::ListenerKind, descriptor: OwnedFd) {
        drop(descriptor);
    }
    fn disconnected(&self) {}
    fn log(&self, _line: &str) {}
}

// MARK: - The client's side of the mux

/// One client's link: everything the session wrote to it, decodable back into messages.
///
/// A recorder rather than a socket pair because the assertion is about what the SESSION produced,
/// and a real socket would add a second failure mode — a short read — to every test that is not
/// about one.
#[derive(Debug, Default)]
struct Wire {
    written: Mutex<Vec<u8>>,
    closed: Mutex<bool>,
}

impl ByteLink for Wire {
    fn send(&self, bytes: &[u8]) -> io::Result<()> {
        self.written.lock().unwrap().extend_from_slice(bytes);
        Ok(())
    }

    fn recv(&self, _buf: &mut [u8]) -> io::Result<usize> {
        Ok(0)
    }

    fn close(&self) {
        *self.closed.lock().unwrap() = true;
    }
}

impl Wire {
    /// The messages this link carried, in order, for `channel_id`.
    ///
    /// Two decoders deep on purpose: the mux frame layer is what multiplexes the channels, and the
    /// wire message layer is what a client's reader would then run over one channel's payload. Both
    /// are the real ones.
    fn messages(&self, channel_id: u32) -> Vec<WireMessage> {
        let mut frames = MuxFrameDecoder::new();
        frames.append(&self.written.lock().unwrap());
        let mut payload = Vec::new();
        while let Some(frame) = frames.next_frame().expect("the link holds whole frames") {
            if let MuxFrame::ChannelData {
                channel_id: carried,
                payload: ref bytes,
            } = frame
                && carried == channel_id
            {
                payload.extend_from_slice(bytes);
            }
        }
        let mut messages = FrameDecoder::new();
        messages.append(&payload);
        let mut out = Vec::new();
        while let Some(message) = messages.next_message().expect("the channel holds whole messages") {
            out.push(message);
        }
        out
    }
}

fn as_link(wire: &Arc<Wire>) -> Arc<dyn ByteLink> {
    let concrete: Arc<Wire> = Arc::clone(wire);
    concrete
}

/// One attached client: its two channels, and the link it reads them off.
struct Member {
    data: Arc<SubChannel>,
    control: Arc<SubChannel>,
    wire: Arc<Wire>,
    data_id: u32,
    control_id: u32,
    /// The roster id the session admitted this member under.
    id: u64,
}

impl Member {
    /// The output frames this member received, as (seq, bytes).
    fn output(&self) -> Vec<(i64, Vec<u8>)> {
        self.wire
            .messages(self.data_id)
            .into_iter()
            .filter_map(|message| {
                match message {
                    WireMessage::Output { seq, bytes } => Some((seq, bytes)),
                    _ => None,
                }
            })
            .collect()
    }

    /// The data lane as a plain transcript, so a test can assert ORDER across kinds.
    fn data_transcript(&self) -> Vec<String> {
        self.wire
            .messages(self.data_id)
            .iter()
            .map(|message| {
                match *message {
                    WireMessage::Output { seq, ref bytes } => {
                        format!("output {seq} {}", String::from_utf8_lossy(bytes))
                    },
                    WireMessage::Exit { code } => format!("exit {code}"),
                    ref other => format!("{:?}", other.message_type()),
                }
            })
            .collect()
    }

    fn control(&self) -> Vec<WireMessage> {
        self.wire.messages(self.control_id)
    }

    /// Feeds one message INBOUND on the data lane, as a peer's demux would.
    fn send_data(&self, message: &WireMessage) {
        self.data.deliver(&message.encode());
    }

    /// The same, on the control lane.
    fn send_control(&self, message: &WireMessage) {
        self.control.deliver(&message.encode());
    }

    /// Ends both channels, as a dropped connection does.
    fn hang_up(&self) {
        self.data.finish();
        self.control.finish();
    }
}

// MARK: - The observed side

#[derive(Debug, Default)]
struct Sink {
    lines: Mutex<Vec<String>>,
    exits: Mutex<Vec<i32>>,
    exited: AtomicUsize,
}

impl SessionLog for Sink {
    fn line(&self, message: &str) {
        self.lines.lock().unwrap().push(message.to_owned());
    }
}

impl SessionObserver for Sink {
    fn exited(&self, code: i32) {
        self.exits.lock().unwrap().push(code);
        self.exited.fetch_add(1, Ordering::AcqRel);
    }
}

/// Coerces the concrete sink into the trait objects a config takes. Free functions because the
/// coercion has to happen at a return position; an `as` cast is a trivial cast the lint block
/// refuses.
fn as_log(sink: &Arc<Sink>) -> Arc<dyn SessionLog> {
    let concrete: Arc<Sink> = Arc::clone(sink);
    concrete
}

fn as_observer(sink: &Arc<Sink>) -> Arc<dyn SessionObserver> {
    let concrete: Arc<Sink> = Arc::clone(sink);
    concrete
}

impl Sink {
    fn exit_codes(&self) -> Vec<i32> {
        self.exits.lock().unwrap().clone()
    }
}

// MARK: - The harness

struct Wired {
    client: Arc<SupervisorClient>,
    superd: FakeSuperd,
    threads: Option<ClientThreads>,
    path: PathBuf,
    channels: AtomicU32,
}

impl Wired {
    fn up() -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "slopdesk-hostsession-{}-{}.sock",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
        ));
        drop(std::fs::remove_file(&path));
        let listener = UnixListener::bind(&path).expect("bind the fake superd");

        let accepted = std::thread::spawn(move || {
            let (stream, _address) = listener.accept().expect("the client dials");
            OwnedFd::from(stream)
        });

        let observer: Arc<dyn SupervisorObserver> = Arc::new(Watcher);
        let dialled = path.clone();
        let connecting = std::thread::spawn(move || {
            SupervisorClient::connect(&dialled.to_string_lossy(), "hostd-test", observer)
        });

        let socket = accepted.join().expect("the accept thread finishes");
        let (requests, inbox) = channel();
        let reading = Held(
            std::os::fd::AsFd::as_fd(&socket)
                .try_clone_to_owned()
                .expect("dup the socket"),
        );
        std::thread::spawn(move || {
            while let Ok(frame) = slopdesk_superclient::frame::read(reading.as_fd_ref()) {
                let Ok(request) = serde_json::from_slice::<Request>(&frame.body) else {
                    continue;
                };
                if requests.send(request).is_err() {
                    return;
                }
            }
        });
        let superd = FakeSuperd {
            socket,
            requests: inbox,
        };

        let hello = superd.next_request_for(verb::HELLO);
        superd.reply(&hello_reply(hello.id), None);

        let (client, threads) = connecting
            .join()
            .expect("the connect thread finishes")
            .expect("the handshake succeeds");
        Self {
            client,
            superd,
            threads: Some(threads),
            path,
            channels: AtomicU32::new(1),
        }
    }

    /// A pane that has been through `spawn`, with a real PTY master behind it.
    ///
    /// The slave is handed back and must be kept alive: dropping it is the child hanging up, and
    /// every write on the master would then be talking to a dead terminal.
    fn spawned(&self, pane_id: &str) -> (Arc<PtyProcess>, OwnedFd) {
        let terminal = nix::pty::openpty(None, None).expect("a real pty");
        let pty = Arc::new(PtyProcess::new(Arc::clone(&self.client)));
        let running = Arc::clone(&pty);
        let request = spawn_request(pane_id);
        let spawning = std::thread::spawn(move || running.spawn(request));

        let asked = self.superd.next_request_for(verb::SPAWN);
        let mut reply = Reply::ok(asked.id);
        reply.pane = Some(pane_record(pane_id, 4242));
        self.superd.reply(&reply, Some(&terminal.master));
        spawning
            .join()
            .expect("the spawn thread finishes")
            .expect("superd accepts the spawn");
        (pty, terminal.slave)
    }

    /// A started session over a spawned pane, with superd's `subscribe` answered.
    fn session(&self, pane_id: &str) -> (Arc<PaneSession>, Arc<PtyProcess>, OwnedFd, Arc<Sink>) {
        let (pty, slave) = self.spawned(pane_id);
        let sink = Arc::new(Sink::default());
        let mut config = SessionConfig::new(as_log(&sink), as_observer(&sink));
        // Both windows are shortened for the same reason the suite has no fixed sleeps: the
        // assertion is that the ladder RUNS, not that it runs at the production cadence, and 750 ms
        // of settle per resize test is wall clock spent proving nothing.
        config.resize_debounce = Duration::from_millis(2);
        config.size_settle = Duration::from_millis(5);
        let session = PaneSession::new(Arc::clone(&pty), config);
        let starting = Arc::clone(&session);
        self.answer_subscribe_while(|| starting.start());
        (session, pty, slave, sink)
    }

    /// Runs `act` on another thread and answers the `subscribe` it sends.
    /// Answers a rebind's SUBSCRIBE with a stream position, and everything else it asks with a bare
    /// OK, until `act` returns.
    ///
    /// The second half is not optional: a rebind re-sends the pane's held blocks to the returning
    /// member, and `blockSnapshot` is a round trip that parks with no timeout. Answering only the
    /// subscribe and then joining would leave `act` waiting for a reply on the very thread that had
    /// just stopped listening.
    fn answer_subscribe_while(&self, act: impl FnOnce() + Send) {
        let done = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let acting = scope.spawn(|| {
                act();
                done.store(true, Ordering::Release);
            });
            while !done.load(Ordering::Acquire) {
                let Ok(request) = self.superd.requests.recv_timeout(Duration::from_millis(10)) else {
                    continue;
                };
                let mut reply = Reply::ok(request.id);
                if request.verb == verb::SUBSCRIBE {
                    reply.stream = Some(StreamPosition {
                        start: 0,
                        head: 0,
                        lossy: false,
                        ended: false,
                    });
                }
                self.superd.reply(&reply, None);
            }
            acting.join().expect("the subscribing thread finishes");
        });
    }

    /// A client's two channels and their inbound halves, WITHOUT giving them to a session yet.
    ///
    /// Split out because a rebind and a join take the same pair through different doors, and a
    /// helper that also attached would make either untestable.
    fn pair(&self) -> (Member, Receiver<WireMessage>, Receiver<WireMessage>) {
        let wire = Arc::new(Wire::default());
        let data_id = self.channels.fetch_add(2, Ordering::Relaxed);
        let control_id = data_id + 1;
        let (control, control_inbound) = SubChannel::control(control_id, as_link(&wire));
        let (data, data_inbound) = SubChannel::data(data_id, as_link(&wire), as_link(&wire));
        (
            Member {
                data,
                control,
                wire,
                data_id,
                control_id,
                id: 0,
            },
            data_inbound,
            control_inbound,
        )
    }

    /// Attaches one client to `session` and answers with its two channels.
    fn attach(&self, session: &Arc<PaneSession>) -> Member {
        let (mut member, data_inbound, control_inbound) = self.pair();
        member.id = session.attach(
            Arc::clone(&member.data),
            data_inbound,
            Arc::clone(&member.control),
            control_inbound,
            false,
        );
        member
    }

    /// JOINS one client to a pane somebody else is already watching.
    ///
    /// Through [`FakeSuperd::answer_everything_while`] because the join's block backfill is a round
    /// trip; see the note there.
    fn join(&self, session: &Arc<PaneSession>) -> Member {
        let (mut member, data_inbound, control_inbound) = self.pair();
        let data = Arc::clone(&member.data);
        let control = Arc::clone(&member.control);
        member.id = self
            .superd
            .answer_everything_while(|| {
                session.join(None, data, data_inbound, control, control_inbound, false)
            })
            .expect("the joiner is admitted");
        member
    }

    fn shut_down(mut self) {
        self.client.disconnect();
        if let Some(threads) = self.threads.take() {
            threads.join();
        }
        drop(std::fs::remove_file(&self.path));
    }
}

/// An owned descriptor with a borrow helper, so the reading thread can name it every iteration.
struct Held(OwnedFd);

impl Held {
    fn as_fd_ref(&self) -> std::os::fd::BorrowedFd<'_> {
        std::os::fd::AsFd::as_fd(&self.0)
    }
}

/// Waits — bounded — for `ready`.
///
/// The session's threads are what satisfy every predicate here, so the alternative would be a fixed
/// sleep long enough for the slowest machine, which is both slower and less honest: this fails at
/// [`GENEROUS`] with the assertion that did not come true, rather than passing because the sleep
/// happened to be long enough.
fn eventually(what: &str, ready: impl Fn() -> bool) {
    eventually_within(GENEROUS, what, ready);
}

/// [`eventually`] for a predicate that must first wait out one of the exit thread's own gates,
/// which are seconds wide by design and are not shortened for the tests.
fn eventually_within(bound: Duration, what: &str, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + bound;
    while Instant::now() < deadline {
        if ready() {
            return;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    panic!("timed out waiting for {what}");
}

// MARK: - The drain

/// The whole pane→wire path in one: superd's bytes, through the sink, the FIFO, the drain, the ring
/// and out onto a member's data channel as a sequenced `.output`.
#[test]
fn a_chunk_reaches_the_member_as_one_sequenced_frame() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    wired.superd.output("pane-1", 0, b"hello");
    eventually("the chunk to reach the member", || !member.output().is_empty());

    assert_eq!(member.output(), vec![(1, b"hello".to_vec())]);
    assert_eq!(session.resume_offset(), 5, "the resume cursor advanced");

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// Successive chunks COALESCE into one frame when they are queued together, and the merge is what
/// keeps a burst of 32 KiB reads from becoming a burst of wire messages. What it may never do is
/// reorder: one frame, the bytes in arrival order.
#[test]
fn queued_chunks_merge_into_one_frame_in_order() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    for (offset, payload) in [(0_u64, b"aaa".as_slice()), (3, b"bbb"), (6, b"ccc")] {
        wired.superd.output("pane-1", offset, payload);
    }
    eventually("every byte to reach the member", || {
        member
            .output()
            .iter()
            .map(|(_seq, bytes)| bytes.len())
            .sum::<usize>()
            == 9
    });

    let carried = member
        .output()
        .into_iter()
        .flat_map(|(_seq, bytes)| bytes)
        .collect::<Vec<_>>();
    assert_eq!(carried, b"aaabbbccc".to_vec());
    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A JOINER is told the truths it was not there for, and in the order that survives the client's
/// own freshness test.
///
/// Every fact in the burst is control-only and edge-triggered: none of it is in the replayed output
/// bytes, and a client resets its mirrors on connect. So the running command and the title the
/// incumbent watched arrive have to be re-sent to the arriving member — and `Running` has to arrive
/// BEFORE `Title`, because the client judges a title's freshness against the command-start stamp
/// that first message republishes. A title that arrived first would lose that comparison and the
/// pane would show its raw command line for the rest of the session.
///
/// The incumbent is checked too, and for the opposite property: a re-assert is addressed, so the
/// client that was already up to date must not be told anything a second time.
#[test]
fn a_joiner_is_told_the_truths_it_missed_with_the_title_last() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let incumbent = wired.attach(&session);

    wired.superd.sniff("pane-1", &[
        SniffEvent::Status(slopdesk_superwire::sniffwire::CommandStatus::Running),
        SniffEvent::Title("cargo test".to_owned()),
    ]);
    wired.superd.output("pane-1", 0, b"x");
    eventually("the incumbent to hear both edges live", || {
        incumbent.control().len() >= 2
    });
    let incumbent_heard = incumbent.control().len();

    let joiner = wired.join(&session);
    eventually("the joiner to receive its arrival burst", || {
        joiner
            .control()
            .iter()
            .any(|message| matches!(*message, WireMessage::Title(_)))
    });

    let ladder = joiner
        .control()
        .into_iter()
        .filter_map(|message| {
            match message {
                WireMessage::CommandStatus(CommandStatus::Running) => Some("running"),
                WireMessage::Title(_) => Some("title"),
                _ => None,
            }
        })
        .collect::<Vec<_>>();
    assert_eq!(
        ladder,
        vec!["running", "title"],
        "the burst re-asserts both, and the title is LAST",
    );
    assert_eq!(
        incumbent.control().len(),
        incumbent_heard,
        "the incumbent was told these truths when they happened and is not told again",
    );

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A title sniffed inside a chunk rides the CONTROL lane, not the data one — a latest-state fold
/// must never queue behind the output it describes.
#[test]
fn a_sniffed_title_reaches_the_control_lane() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    wired
        .superd
        .sniff("pane-1", &[SniffEvent::Title("✳ Claude Code".to_owned())]);
    wired.superd.output("pane-1", 0, b"x");
    eventually("the title to reach the control lane", || {
        !member.control().is_empty()
    });

    let titles = member
        .control()
        .into_iter()
        .filter_map(|message| {
            match message {
                WireMessage::Title(text) => Some(text),
                _ => None,
            }
        })
        .collect::<Vec<_>>();
    assert_eq!(titles, vec!["✳ Claude Code".to_owned()]);
    // And the bytes it was found in still went out, on the other lane.
    assert_eq!(member.output(), vec![(1, b"x".to_vec())]);

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A block's metadata is a BROADCAST fact: it describes no byte offset, so it goes to every member
/// over the control sender rather than riding one member's data lane.
#[test]
fn a_block_batch_broadcasts_to_the_control_lane() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    wired.superd.blocks("pane-1", &[BlockEvent::Progress(
        slopdesk_superwire::blockwire::SyntheticProgress::Indeterminate,
    )]);
    wired.superd.output("pane-1", 0, b"y");
    eventually("the block fact to reach the control lane", || {
        !member.control().is_empty()
    });

    assert!(
        member
            .control()
            .iter()
            .any(|message| matches!(*message, WireMessage::Progress { .. })),
        "the synthetic badge crossed as a progress fact",
    );
    session.relinquish();
    drop(slave);
    wired.shut_down();
}

// MARK: - The exit ladder

/// The EOF gate, which is the only reason this ordering holds.
///
/// superd reaps the child and announces it while its own ring still holds unread bytes. The exit
/// thread waits for the read loop to reach EOF before appending the barrier, so the final tail is
/// enqueued AHEAD of `.exit`. Without the gate the client sees a pane die mid-sentence and the last
/// line of a build never renders.
#[test]
fn the_exit_lands_behind_the_last_byte() {
    let wired = Wired::up();
    let (session, _pty, slave, sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    wired.superd.output("pane-1", 0, b"done\n");
    wired.superd.announce_exit("pane-1", 3);
    eventually("the observer to hear the exit", || !sink.exit_codes().is_empty());

    assert_eq!(sink.exit_codes(), vec![3]);
    assert_eq!(member.data_transcript(), vec![
        "output 1 done\n".to_owned(),
        "exit 3".to_owned(),
    ]);

    // The shutdown path SIGNALS, and every signal parks for superd's reply.
    wired.superd.answer_everything_while(|| session.shutdown());
    drop(slave);
    wired.shut_down();
}

// MARK: - Fan-out

/// With two members the drain stops sending inline: a shared frame must not be gated by whichever
/// peer's credit window is smaller, so every member gets a sender of its own and the SAME sequence
/// number.
#[test]
fn two_members_each_receive_every_frame_at_the_same_seq() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let first = wired.attach(&session);
    let second = wired.attach(&session);
    session.fan_out();
    assert_eq!(session.member_count(), 2);

    wired.superd.output("pane-1", 0, b"shared");
    eventually("both members to receive the frame", || {
        !first.output().is_empty() && !second.output().is_empty()
    });

    assert_eq!(first.output(), vec![(1, b"shared".to_vec())]);
    assert_eq!(second.output(), first.output(), "one sequence, two members");

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

// MARK: - Input

/// Keystrokes go straight down hostd's own duplicate of the master, and the credit for them is
/// granted only AFTER the write returns — so a PTY that has stopped reading parks the CLIENT rather
/// than buffering its paste in host RAM.
#[test]
fn a_members_keystrokes_reach_the_terminal() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    member.send_data(&WireMessage::Input(b"echo hi\r".to_vec()));

    let mut buffer = [0_u8; 64];
    let read = nix::unistd::read(&slave, &mut buffer).expect("the child's side sees it");
    // `\r` arrives as `\n`: the tty line discipline's `ICRNL` is on by default, and seeing that
    // translation is the proof this is a real terminal rather than a pipe with the right shape.
    assert_eq!(buffer.get(..read), Some(b"echo hi\n".as_slice()));

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A ping is answered on the control lane by the control relay, which proves that lane is live
/// independently of any output — the pane in this test never says a byte.
#[test]
fn a_ping_is_answered_on_the_control_lane() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    member.send_control(&WireMessage::Ping { timestamp_ms: 1_234 });
    eventually("the pong to come back", || !member.control().is_empty());

    assert_eq!(member.control(), vec![WireMessage::Pong { timestamp_ms: 1_234 }]);
    session.relinquish();
    drop(slave);
    wired.shut_down();
}

// MARK: - The join ladder

/// The property the join lock exists for: the joiner's transcript has no HOLE and no DUPLICATE.
///
/// It opens on the state transfer — every byte the incumbent already received — and then rides the
/// same fan-out for everything after, at the same seqs. A frame sequenced between the snapshot and
/// the admission would be either missing or shipped twice depending on which side of the race won,
/// and this is the assertion that would catch it.
#[test]
fn a_joiner_opens_on_the_incumbents_transcript_and_shares_it_from_there() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let incumbent = wired.attach(&session);

    wired.superd.output("pane-1", 0, b"before");
    eventually("the incumbent to receive the first frame", || {
        !incumbent.output().is_empty()
    });

    let joiner = wired.join(&session);
    assert_eq!(session.member_count(), 2);
    assert_eq!(
        joiner.output(),
        vec![(1, b"before".to_vec())],
        "the state transfer carried what the incumbent already had",
    );

    wired.superd.output("pane-1", 6, b"after");
    eventually("both members to receive the live frame", || {
        incumbent.output().len() == 2 && joiner.output().len() == 2
    });
    assert_eq!(
        joiner.output(),
        incumbent.output(),
        "one sequence, no byte twice and none missing",
    );

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A join to a DETACHED session is refused rather than admitted to a pane with no drain — that is
/// `rebind`'s door, and admitting here would leave a member attached to nothing.
#[test]
fn a_join_to_a_detached_session_is_refused() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let first = wired.attach(&session);

    let parked = Arc::new(Sink::default());
    session.detach(as_observer(&parked));
    drop(wired.superd.next_request_for(verb::UNSUBSCRIBE));

    let (member, data_inbound, control_inbound) = wired.pair();
    assert_eq!(
        session.join(
            None,
            Arc::clone(&member.data),
            data_inbound,
            Arc::clone(&member.control),
            control_inbound,
            false,
        ),
        None,
        "a detached session has no drain to join",
    );
    assert_eq!(session.member_count(), 0);

    drop(first);
    drop(member);
    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A refcounted LEAVE is not a detach: one client closing its lid must not engage the offline gate
/// that pauses the pane for everyone else.
#[test]
fn removing_one_of_two_members_leaves_the_pane_running() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let incumbent = wired.attach(&session);
    let joiner = wired.join(&session);

    assert!(
        !session.remove_subscriber(joiner.id),
        "somebody still holds the pane",
    );
    assert_eq!(session.member_count(), 1);

    wired.superd.output("pane-1", 0, b"still here");
    eventually("the survivor to keep receiving", || {
        !incumbent.output().is_empty()
    });

    assert!(
        session.remove_subscriber(incumbent.id),
        "the last one out empties the set",
    );
    session.relinquish();
    drop(slave);
    wired.shut_down();
}

// MARK: - Detach and rebind

/// The detached window is superd's ring: hostd drops the subscription, records the cursor, and the
/// rebind re-opens at exactly that offset. What this pins is the whole round trip — the returning
/// client's state transfer, then live output resuming on a restarted drain.
#[test]
fn a_detached_pane_comes_back_on_the_cursor_it_left() {
    let wired = Wired::up();
    let (session, _pty, slave, sink) = wired.session("pane-1");
    let first = wired.attach(&session);

    wired.superd.output("pane-1", 0, b"before");
    eventually("the first client to receive the frame", || {
        !first.output().is_empty()
    });

    let parked = Arc::new(Sink::default());
    session.detach(as_observer(&parked));
    assert!(session.is_detached());
    assert_eq!(session.member_count(), 0);
    assert_eq!(session.resume_offset(), 6, "the cursor is where the bytes ended");
    drop(wired.superd.next_request_for(verb::UNSUBSCRIBE));

    // The returning client's state transfer goes out BEFORE the live drain restarts, so the tail is
    // delivered in order without interleaving.
    let (second, data_inbound, control_inbound) = wired.pair();
    assert!(
        !session.replay_tail(0, &second.data),
        "no snapshot policy is injected, so the tail replays raw",
    );
    assert_eq!(second.output(), vec![(1, b"before".to_vec())]);

    let rebound = Arc::new(AtomicBool::new(false));
    let rebinding = Arc::clone(&rebound);
    let returning = Arc::clone(&session);
    let data = Arc::clone(&second.data);
    let control = Arc::clone(&second.control);
    let observer = as_observer(&sink);
    wired.answer_subscribe_while(move || {
        let landed = returning.rebind(data, data_inbound, control, control_inbound, observer);
        rebinding.store(landed, Ordering::Release);
    });
    assert!(rebound.load(Ordering::Acquire), "the rebind proceeded");
    assert!(!session.is_detached());
    assert_eq!(session.member_count(), 1);

    wired.superd.output("pane-1", 6, b"after");
    eventually("the restarted drain to ship live output", || {
        second.output().len() == 2
    });
    assert_eq!(second.output().last(), Some(&(2, b"after".to_vec())));

    session.relinquish();
    drop(first);
    drop(slave);
    wired.shut_down();
}

/// A rebind onto a LIVE session is refused, so the loser of a concurrent double-reattach cannot
/// believe it owns the pane.
#[test]
fn a_rebind_of_a_session_that_never_detached_is_refused() {
    let wired = Wired::up();
    let (session, _pty, slave, sink) = wired.session("pane-1");
    let first = wired.attach(&session);

    let (second, data_inbound, control_inbound) = wired.pair();
    assert!(
        !session.rebind(
            Arc::clone(&second.data),
            data_inbound,
            Arc::clone(&second.control),
            control_inbound,
            as_observer(&sink),
        ),
        "nothing was changed",
    );
    assert_eq!(session.member_count(), 1);

    drop(first);
    drop(second);
    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// The exit handler is read at FIRE time, not captured at `start()`.
///
/// A shell that exits while the session is parked in the detached store must reach the handler
/// detach installed — the store's — and not the connection that has already gone. A captured `Arc`
/// would send it to the original observer, which is how a reattach ends up killing the pane it just
/// restored.
#[test]
fn an_exit_while_detached_reaches_the_handler_detach_installed() {
    let wired = Wired::up();
    let (session, _pty, slave, sink) = wired.session("pane-1");
    let first = wired.attach(&session);

    let parked = Arc::new(Sink::default());
    session.detach(as_observer(&parked));
    drop(wired.superd.next_request_for(verb::UNSUBSCRIBE));

    // The detach stopped the stream rather than ending it, so no EOF is ever signalled and the exit
    // thread sits out both of its gates — 2s for the EOF, then 10s for an `.exit` the closed drain
    // can never ship — before it reaches the observer. That IS the Swift behaviour: the latches are
    // one-way, and tripping them at detach would let a rebind's `.exit` overtake the output tail.
    wired.superd.announce_exit("pane-1", 7);
    eventually_within(
        EOF_GATE + EXIT_SENT_GATE + GENEROUS,
        "the detached handler to hear the exit",
        || !parked.exit_codes().is_empty(),
    );
    assert_eq!(parked.exit_codes(), vec![7]);
    assert!(
        sink.exit_codes().is_empty(),
        "the connection that is gone heard nothing",
    );

    drop(first);
    wired.superd.answer_everything_while(|| session.shutdown());
    drop(slave);
    wired.shut_down();
}

// MARK: - The size fold

/// The ONE writer, reached through the debounce: a client's offer lands on the PTY, and the redraw
/// nudge is armed behind it.
#[test]
fn a_clients_offer_resizes_the_terminal_and_arms_one_nudge() {
    let wired = Wired::up();
    let (session, pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    member.send_control(&WireMessage::Resize {
        cols: 100,
        rows: 40,
        px_width: 800,
        px_height: 640,
    });
    eventually("the fold to reach TIOCSWINSZ", || {
        pty.window_size()
            .is_some_and(|size| size.cols == 100 && size.rows == 40)
    });
    assert_eq!(session.resolved_grid(), (100, 40));
    assert!(
        session.has_armed_redraw_nudge(),
        "a size change schedules exactly one delayed SIGWINCH",
    );

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// The fold is a MIN over whoever is holding the pane, and the smaller client wins each axis
/// independently — the rule that stops a phone from cropping a Mac's output and a Mac from
/// promising a phone a width it has no pixels for.
#[test]
fn two_clients_hold_the_pane_at_the_smaller_of_their_offers() {
    let wired = Wired::up();
    let (session, pty, slave, _sink) = wired.session("pane-1");
    let wide = wired.attach(&session);
    let tall = wired.join(&session);

    wide.send_control(&WireMessage::Resize {
        cols: 200,
        rows: 30,
        px_width: 1600,
        px_height: 480,
    });
    tall.send_control(&WireMessage::Resize {
        cols: 90,
        rows: 60,
        px_width: 720,
        px_height: 960,
    });
    eventually("the fold to settle on the minimum in each axis", || {
        pty.window_size()
            .is_some_and(|size| size.cols == 90 && size.rows == 30)
    });
    assert_eq!(session.resolved_grid(), (90, 30));

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// A drag emits an offer per frame, and the debounce is what keeps that from being a `TIOCSWINSZ`
/// per frame: the LAST offer is the one that lands.
#[test]
fn a_burst_of_offers_lands_only_the_last_one() {
    let wired = Wired::up();
    let (session, pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    for cols in 100_u16..140 {
        session.offer_size(member.id, cols, 40, cols * 8, 640);
    }
    eventually("the trailing edge to land", || {
        pty.window_size().is_some_and(|size| size.cols == 139)
    });
    assert_eq!(session.resolved_grid(), (139, 40));

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

/// The ctl verb is an ORCHESTRATOR saying "make this pane 132×50", and it means it now — it goes
/// through the same one writer, but it is not debounced.
#[test]
fn the_ctl_override_applies_at_once_and_the_next_client_offer_retires_it() {
    let wired = Wired::up();
    let (session, pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    session.set_ctl_size(132, 50);
    assert!(
        pty.window_size()
            .is_some_and(|size| size.cols == 132 && size.rows == 50),
        "the verb returns with the pane already that size",
    );

    session.offer_size(member.id, 80, 24, 640, 384);
    eventually("the next client offer to take it back", || {
        pty.window_size()
            .is_some_and(|size| size.cols == 80 && size.rows == 24)
    });

    session.relinquish();
    drop(slave);
    wired.shut_down();
}

// MARK: - Teardown

/// The leak Rust's missing `Task.cancel` creates.
///
/// Every relay and sender has to END on something the teardown can cause — a receiver that ends, a
/// lane that closes — because a session that merely stops USING a thread still has it. The failure
/// this catches is one leaked thread per rebind, which no test that attaches once and asserts on
/// output can see.
#[test]
fn a_torn_down_session_leaves_no_thread_running() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    let first = wired.attach(&session);
    let second = wired.attach(&session);
    session.fan_out();
    assert!(session.live_thread_count() > 0, "the pane has threads to leak");

    // One member leaves the way a dropped connection does, WITHOUT a teardown. Its four threads
    // must go with it while the pane keeps running.
    first.hang_up();
    eventually("the departed member to leave the roster", || {
        session.member_count() == 1
    });

    session.relinquish();
    assert_eq!(session.teardown_completions(), 1);
    eventually("every thread to return", || session.live_thread_count() == 0);

    drop(second);
    drop(slave);
    wired.shut_down();
}

/// `docs/51`'s whole distinction: relinquishing is hostd going away, not the pane ending. No signal
/// and no release cross the socket, so superd keeps the shell and the next hostd adopts it back.
#[test]
fn a_relinquish_signals_nothing_and_keeps_the_child() {
    let wired = Wired::up();
    let (session, pty, slave, _sink) = wired.session("pane-1");
    let member = wired.attach(&session);

    session.relinquish();
    // The unsubscribe that the dropped stream sends is expected and is not a signal; anything after
    // it would be.
    drop(wired.superd.next_request_for(verb::UNSUBSCRIBE));
    wired.superd.no_request_within(Duration::from_millis(200));
    assert_eq!(
        pty.pane_id().as_deref(),
        Some("pane-1"),
        "the pane is still named"
    );

    drop(member);
    drop(slave);
    wired.shut_down();
}

/// A teardown is idempotent and its ladder runs to the END each time, which is what
/// `teardown_completions` counts. `HostServer::stop` reaches every pane and a pane whose exit
/// already tore it down must not wedge there.
#[test]
fn a_second_teardown_is_harmless() {
    let wired = Wired::up();
    let (session, _pty, slave, _sink) = wired.session("pane-1");
    session.relinquish();
    session.relinquish();
    assert_eq!(session.teardown_completions(), 2);
    assert_eq!(session.live_thread_count(), 0);
    drop(slave);
    wired.shut_down();
}
