//! The whole client against a fake superd on a real `AF_UNIX` socket.
//!
//! Nothing is stubbed between the client and the kernel: the fake writes superd's own framing with
//! `sendmsg`, attaches real descriptors with `SCM_RIGHTS`, and builds every body with
//! `slopdesk_superwire` — the same crate superd builds them with. A decode that disagreed with the
//! encoder would fail here rather than in production, and a descriptor that failed to cross would
//! fail as a dead fd rather than as a wrong number.
//!
//! The load-bearing test is [`a_pause_issued_from_inside_a_sink_does_not_deadlock`]. Everything
//! else in this file could pass with the reader thread writing to the socket directly; that one
//! could not, and it is the exact freeze the writer thread exists to prevent.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::collections::BTreeMap;
use std::io::IoSlice;
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nix::sys::socket::{AddressFamily, ControlMessage, MsgFlags, SockFlag, SockType, sendmsg, socketpair};
use slopdesk_superclient::client::{
    ClientError, ClientThreads, ListenerKind, PaneSink, SupervisorClient, SupervisorObserver,
};
use slopdesk_superwire::blockwire::BlockEvent;
use slopdesk_superwire::protocol::{
    ExitedNotice, HelloReply, PaneRecord, Reply, Request, Status, StreamPosition, VERSION_MAJOR,
    VERSION_MINOR, event,
};
use slopdesk_superwire::sniffwire::SniffEvent;

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

// MARK: - The fake superd

/// One side of the control socket, driven by the test.
struct FakeSuperd {
    socket: OwnedFd,
    requests: Receiver<Request>,
}

impl FakeSuperd {
    /// The next request the client sent.
    fn next_request(&self) -> Request {
        self.requests
            .recv_timeout(GENEROUS)
            .expect("the client sends a request")
    }

    /// Waits for a request with `verb`, discarding anything queued ahead of it.
    fn next_request_for(&self, verb: &str) -> Request {
        loop {
            let request = self.next_request();
            if request.verb == verb {
                return request;
            }
        }
    }

    /// Ends the connection the way a superd that died would.
    ///
    /// `shutdown`, not `drop`: the reading helper holds a DUP of this very socket, so dropping this
    /// descriptor leaves the connection open and the client's reader parked for ever. A shutdown is
    /// about the connection rather than about one descriptor, which is what makes it the real
    /// thing.
    fn hang_up(&self) {
        let _ignored = nix::sys::socket::shutdown(self.socket.as_raw_fd(), nix::sys::socket::Shutdown::Both);
    }

    fn no_request_within(&self, bound: Duration) {
        assert!(
            self.requests.recv_timeout(bound).is_err(),
            "expected silence on the control socket",
        );
    }

    /// Writes one JSON frame, optionally attaching a descriptor — superd's own lane.
    fn reply(&self, reply: &Reply, descriptor: Option<&OwnedFd>) {
        let body = serde_json::to_vec(reply).expect("a reply encodes");
        let tag = [if descriptor.is_some() {
            slopdesk_superwire::TAG_WITH_DESCRIPTOR
        } else {
            slopdesk_superwire::TAG_PLAIN
        }];
        self.write_frame(tag, &body, descriptor);
    }

    /// Writes one pane-output frame.
    fn output(&self, pane_id: &str, offset: u64, payload: &[u8]) {
        let body = slopdesk_superwire::pack_output(pane_id, offset, payload).expect("output packs");
        self.write_frame([slopdesk_superwire::TAG_OUTPUT], &body, None);
    }

    /// Writes one sniffed-events frame — always immediately before the chunk it describes.
    fn sniff(&self, pane_id: &str, events: &[SniffEvent]) {
        let json = slopdesk_superwire::sniffwire::encode_batch(events);
        let body = slopdesk_superwire::pack_pane_json(pane_id, &json).expect("a sniff batch packs");
        self.write_frame([slopdesk_superwire::TAG_SNIFF], &body, None);
    }

    /// Writes one command-blocks frame, in the same place and for the same reason.
    fn blocks(&self, pane_id: &str, events: &[BlockEvent]) {
        let json = slopdesk_superwire::blockwire::encode_batch(events);
        let body = slopdesk_superwire::pack_pane_json(pane_id, &json).expect("a blocks batch packs");
        self.write_frame([slopdesk_superwire::TAG_BLOCKS], &body, None);
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

/// A hello reply superd would send.
fn hello_reply(id: u64) -> Reply {
    let mut reply = Reply::ok(id);
    reply.hello = Some(HelloReply {
        version_major: VERSION_MAJOR,
        version_minor: VERSION_MINOR,
        superd_pid: 4321,
        hook_socket_path: Some("/tmp/slopdesk-hook.sock".to_owned()),
        control_socket_path: Some("/tmp/slopdesk-control.sock".to_owned()),
        build_version: Some("0.0.0-test".to_owned()),
    });
    reply
}

// MARK: - The observed side

/// What the observer heard, in order.
#[derive(Debug, Default)]
struct Heard {
    exited: Vec<ExitedNotice>,
    connections: Vec<ListenerKind>,
    disconnects: u32,
    logs: Vec<String>,
}

#[derive(Debug, Default)]
struct Watcher {
    heard: Mutex<Heard>,
    /// Descriptors handed over by `connection` notices, kept alive so a test can use them.
    handed: Mutex<Vec<OwnedFd>>,
}

impl SupervisorObserver for Watcher {
    fn exited(&self, notice: &ExitedNotice) {
        if let Ok(mut heard) = self.heard.lock() {
            heard.exited.push(notice.clone());
        }
    }

    fn connection(&self, kind: ListenerKind, descriptor: OwnedFd) {
        if let Ok(mut heard) = self.heard.lock() {
            heard.connections.push(kind);
        }
        if let Ok(mut handed) = self.handed.lock() {
            handed.push(descriptor);
        }
    }

    fn disconnected(&self) {
        if let Ok(mut heard) = self.heard.lock() {
            heard.disconnects += 1;
        }
    }

    fn log(&self, line: &str) {
        if let Ok(mut heard) = self.heard.lock() {
            heard.logs.push(line.to_owned());
        }
    }
}

/// Everything a sink was told, as one ordered transcript — because the ORDER is what most of these
/// tests are about.
#[derive(Debug, PartialEq, Eq)]
enum Told {
    Bytes(u64, Vec<u8>),
    Sniffed(usize),
    Blocks(usize),
    Ended,
}

struct Recorder {
    told: Mutex<Vec<Told>>,
    /// Announced as each item lands, so a test can wait rather than sleep.
    tick: Mutex<Sender<()>>,
    /// Fired from inside `bytes`, if set — the re-entrancy the writer thread exists for.
    on_bytes: Mutex<Option<Box<dyn Fn() + Send>>>,
}

impl std::fmt::Debug for Recorder {
    /// Written out because `on_bytes` holds a bare closure, which has no `Debug`.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Recorder").finish_non_exhaustive()
    }
}

impl Recorder {
    fn new() -> (Arc<Self>, Receiver<()>) {
        let (tick, ticks) = channel();
        (
            Arc::new(Self {
                told: Mutex::new(Vec::new()),
                tick: Mutex::new(tick),
                on_bytes: Mutex::new(None),
            }),
            ticks,
        )
    }

    fn note(&self, item: Told) {
        if let Ok(mut told) = self.told.lock() {
            told.push(item);
        }
        if let Ok(tick) = self.tick.lock() {
            let _ignored = tick.send(());
        }
    }

    fn transcript(&self) -> Vec<String> {
        self.told
            .lock()
            .map(|told| told.iter().map(|item| format!("{item:?}")).collect())
            .unwrap_or_default()
    }
}

impl PaneSink for Recorder {
    fn bytes(&self, offset: u64, payload: &[u8]) {
        self.note(Told::Bytes(offset, payload.to_vec()));
        let hook = self.on_bytes.lock().ok().and_then(|mut slot| slot.take());
        if let Some(hook) = hook {
            hook();
        }
    }

    fn sniffed(&self, events: &[SniffEvent]) {
        self.note(Told::Sniffed(events.len()));
    }

    fn blocks(&self, events: &[BlockEvent]) {
        self.note(Told::Blocks(events.len()));
    }

    fn ended(&self) {
        self.note(Told::Ended);
    }
}

// MARK: - The harness

/// A connected client, the fake superd behind it, and the observer watching.
struct Wired {
    client: Arc<SupervisorClient>,
    superd: FakeSuperd,
    watcher: Arc<Watcher>,
    threads: Option<ClientThreads>,
    path: PathBuf,
}

impl Wired {
    /// Binds a socket, dials it, answers `hello`, and hands back everything.
    fn up() -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "slopdesk-superclient-{}-{}.sock",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
        ));
        drop(std::fs::remove_file(&path));
        let listener = UnixListener::bind(&path).expect("bind the fake superd");

        let accepted = std::thread::spawn(move || {
            let (stream, _address) = listener.accept().expect("the client dials");
            OwnedFd::from(stream)
        });

        let watcher = Arc::new(Watcher::default());
        let observer: Arc<dyn SupervisorObserver> = Arc::clone(&watcher).as_observer();
        let dialled = path.clone();
        let connecting = std::thread::spawn(move || {
            SupervisorClient::connect(&dialled.to_string_lossy(), "hostd-test", observer)
        });

        let socket = accepted.join().expect("the accept thread finishes");
        let (requests, inbox) = channel();
        let reading = clone_fd(&socket);
        std::thread::spawn(move || {
            while let Ok(frame) = slopdesk_superclient::frame::read(reading.as_fd_ref()) {
                let Some(request) = serde_json::from_slice::<Request>(&frame.body).ok() else {
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

        // The handshake, answered from this thread while `connect` is parked on it.
        let hello = superd.next_request_for(slopdesk_superwire::protocol::verb::HELLO);
        superd.reply(&hello_reply(hello.id), None);

        let (client, threads) = connecting
            .join()
            .expect("the connect thread finishes")
            .expect("the handshake succeeds");
        Self {
            client,
            superd,
            watcher,
            threads: Some(threads),
            path,
        }
    }

    /// Subscribes a fresh recorder to `pane_id` and answers superd's side of it.
    fn subscribe(&self, pane_id: &str) -> (Arc<Recorder>, Receiver<()>) {
        let (recorder, ticks) = Recorder::new();
        let sink: Arc<dyn PaneSink> = Arc::clone(&recorder).as_sink();
        let client = Arc::clone(&self.client);
        let pane = pane_id.to_owned();
        let subscribing = std::thread::spawn(move || client.subscribe(&pane, 0, sink));
        let request = self
            .superd
            .next_request_for(slopdesk_superwire::protocol::verb::SUBSCRIBE);
        let mut reply = Reply::ok(request.id);
        reply.stream = Some(StreamPosition {
            start: 0,
            head: 0,
            lossy: false,
            ended: false,
        });
        self.superd.reply(&reply, None);
        let _position = subscribing
            .join()
            .expect("the subscribe thread finishes")
            .expect("superd accepts the subscribe");
        (recorder, ticks)
    }

    fn shut_down(mut self) {
        self.client.disconnect();
        if let Some(threads) = self.threads.take() {
            threads.join();
        }
        drop(std::fs::remove_file(&self.path));
    }
}

/// A second descriptor for the same socket, so the reading helper and the writing fake can both
/// hold one. `dup` through `try_clone` — no raw fd ever becomes visible.
fn clone_fd(socket: &OwnedFd) -> Held {
    let borrowed = std::os::fd::AsFd::as_fd(socket);
    Held(borrowed.try_clone_to_owned().expect("dup the socket"))
}

/// An owned descriptor with a borrow helper, so the reading thread can name it every iteration.
struct Held(OwnedFd);

impl Held {
    fn as_fd_ref(&self) -> std::os::fd::BorrowedFd<'_> {
        std::os::fd::AsFd::as_fd(&self.0)
    }
}

/// Trait-object coercion helpers. An `as` cast is refused by this crate's `trivial_casts`.
trait AsObserver {
    fn as_observer(self: Arc<Self>) -> Arc<dyn SupervisorObserver>;
}

impl AsObserver for Watcher {
    fn as_observer(self: Arc<Self>) -> Arc<dyn SupervisorObserver> {
        self
    }
}

trait AsSink {
    fn as_sink(self: Arc<Self>) -> Arc<dyn PaneSink>;
}

impl AsSink for Recorder {
    fn as_sink(self: Arc<Self>) -> Arc<dyn PaneSink> {
        self
    }
}

fn wait_for(ticks: &Receiver<()>, count: usize) {
    for _step in 0..count {
        ticks.recv_timeout(GENEROUS).expect("the sink is told something");
    }
}

// MARK: - The tests

/// The handshake fills in what hostd must advertise into every child's environment. Getting these
/// from anywhere but superd is the whole failure `docs/51` §1 exists to prevent.
#[test]
fn the_handshake_carries_superds_own_socket_paths() {
    let wired = Wired::up();
    let handshake = wired.client.handshake().expect("hello was answered");
    assert_eq!(handshake.superd_pid, 4321);
    assert_eq!(
        handshake.hook_socket_path.as_deref(),
        Some("/tmp/slopdesk-hook.sock")
    );
    assert_eq!(handshake.negotiated_minor, VERSION_MINOR);
    assert!(wired.client.is_connected());
    wired.shut_down();
}

/// A `spawn` answers with a record and a LIVE descriptor: the master hostd writes keystrokes to for
/// the pane's whole life. A number that crossed but does not work would look identical here without
/// the write-and-read.
#[test]
fn a_spawn_hands_over_a_working_descriptor() {
    let wired = Wired::up();
    let client = Arc::clone(&wired.client);
    let spawning = std::thread::spawn(move || {
        client.spawn(slopdesk_superwire::protocol::SpawnRequest {
            pane_id: "pane-1".to_owned(),
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
        })
    });

    let request = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::SPAWN);
    assert_eq!(
        request.spawn.as_ref().map(|spawn| spawn.pane_id.as_str()),
        Some("pane-1"),
    );
    let (carried, other) = socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty())
        .expect("a stand-in for the master");
    let mut reply = Reply::ok(request.id);
    reply.pane = Some(pane_record("pane-1"));
    wired.superd.reply(&reply, Some(&carried));

    let (record, master) = spawning
        .join()
        .expect("the spawn thread finishes")
        .expect("superd accepts the spawn");
    assert_eq!(record.pane_id, "pane-1");
    // A real dup of a real socket: a byte written on the far end arrives on the adopted one.
    nix::unistd::write(&other, b"k").expect("write the far end");
    let mut byte = [0_u8; 1];
    nix::unistd::read(&master, &mut byte).expect("read the adopted master");
    assert_eq!(byte, *b"k");
    wired.shut_down();
}

/// A missing descriptor is a distinct failure from a missing record: one means superd forgot the
/// master, the other means it forgot the pane, and a caller that conflated them would report the
/// wrong thing to the user.
#[test]
fn a_spawn_without_a_descriptor_is_refused_as_such() {
    let wired = Wired::up();
    let client = Arc::clone(&wired.client);
    let adopting = std::thread::spawn(move || client.adopt("pane-9"));
    let request = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::ADOPT);
    let mut reply = Reply::ok(request.id);
    reply.pane = Some(pane_record("pane-9"));
    wired.superd.reply(&reply, None);
    assert!(matches!(
        adopting.join().expect("the adopt thread finishes"),
        Err(ClientError::MissingDescriptor),
    ));
    wired.shut_down();
}

/// The output path, end to end: bytes reach the sink with their offset, in the order superd wrote
/// them, and an EMPTY chunk is delivered rather than swallowed — a subscriber that resumed exactly
/// at the head gets one.
#[test]
fn output_frames_reach_the_pane_sink_in_order() {
    let wired = Wired::up();
    let (recorder, ticks) = wired.subscribe("pane-1");
    wired.superd.output("pane-1", 0, b"first");
    wired.superd.output("pane-1", 5, b"second");
    wired.superd.output("pane-1", 11, b"");
    wait_for(&ticks, 3);
    assert_eq!(recorder.transcript(), vec![
        format!("{:?}", Told::Bytes(0, b"first".to_vec())),
        format!("{:?}", Told::Bytes(5, b"second".to_vec())),
        format!("{:?}", Told::Bytes(11, Vec::new())),
    ]);
    wired.shut_down();
}

/// A sniff frame and a blocks frame precede the chunk they were found in, and the client must not
/// reorder them: the pairing is what lets a title latch and the bytes that carried it stay in step.
#[test]
fn out_of_band_batches_arrive_before_the_chunk_they_describe() {
    let wired = Wired::up();
    let (recorder, ticks) = wired.subscribe("pane-1");
    wired
        .superd
        .sniff("pane-1", &[SniffEvent::Title("claude".to_owned())]);
    wired.superd.blocks("pane-1", &[BlockEvent::Unknown {
        kind: "block".to_owned(),
    }]);
    wired.superd.output("pane-1", 0, b"bytes");
    wait_for(&ticks, 3);
    assert_eq!(recorder.transcript(), vec![
        format!("{:?}", Told::Sniffed(1)),
        format!("{:?}", Told::Blocks(1)),
        format!("{:?}", Told::Bytes(0, b"bytes".to_vec())),
    ]);
    wired.shut_down();
}

/// The EOF ordering hostd's whole exit path rests on: the sink hears `ended` BEFORE the exit
/// handler and before the observer, so a session can keep its exit frame behind its last output
/// frame on the wire.
#[test]
fn an_exit_ends_the_stream_before_it_reports_the_code() {
    let wired = Wired::up();
    let (recorder, ticks) = wired.subscribe("pane-1");
    let seen_at_exit = Arc::new(Mutex::new(Vec::new()));
    let watched = Arc::clone(&recorder);
    let captured = Arc::clone(&seen_at_exit);
    wired.client.observe_exit(
        "pane-1",
        Arc::new(move |code| {
            if let Ok(mut seen) = captured.lock() {
                seen.push(format!("code {code} after {:?}", watched.transcript()));
            }
        }),
    );

    wired.superd.output("pane-1", 0, b"bye");
    wait_for(&ticks, 1);
    let mut reply = Reply::ok(slopdesk_superwire::protocol::NOTIFICATION_ID);
    reply.event = Some(event::EXITED.to_owned());
    reply.exited = Some(ExitedNotice {
        pane_id: "pane-1".to_owned(),
        pid: 99,
        code: 130,
    });
    wired.superd.reply(&reply, None);
    wait_for(&ticks, 1);

    assert_eq!(recorder.transcript().last().map(String::as_str), Some("Ended"));
    let seen = seen_at_exit.lock().expect("the exit handler ran").clone();
    assert_eq!(seen.len(), 1, "the exit handler fires exactly once");
    assert!(
        seen.first().is_some_and(|line| line.contains("Ended")),
        "the stream had already ended when the code was reported: {seen:?}",
    );
    wired.shut_down();
}

/// A handed-over child connection arrives as an OWNED descriptor that still works, and its kind is
/// carried. A kind this build has no name for is closed rather than leaked — superd being newer
/// than hostd must not cost an fd per connection.
#[test]
fn a_connection_notice_hands_over_a_live_descriptor_and_an_unknown_kind_closes_one() {
    let wired = Wired::up();
    let (carried, mut other) = UnixStream::pair().expect("a stand-in for an accepted child");
    let carried = OwnedFd::from(carried);
    let mut notice = Reply::ok(slopdesk_superwire::protocol::NOTIFICATION_ID);
    notice.event = Some(event::CONNECTION.to_owned());
    notice.connection = Some(slopdesk_superwire::protocol::ConnectionNotice {
        kind: slopdesk_superwire::protocol::listener_kind::HOOK.to_owned(),
    });
    wired.superd.reply(&notice, Some(&carried));

    // The unknown kind, right behind it — so one read loop handles both and the assertion below
    // proves the first was not simply the last thing to arrive.
    let (stranger, _stranger_far_end) = UnixStream::pair().expect("a second stand-in");
    let stranger = OwnedFd::from(stranger);
    let mut unknown = Reply::ok(slopdesk_superwire::protocol::NOTIFICATION_ID);
    unknown.event = Some(event::CONNECTION.to_owned());
    unknown.connection = Some(slopdesk_superwire::protocol::ConnectionNotice {
        kind: "a-kind-from-the-future".to_owned(),
    });
    wired.superd.reply(&unknown, Some(&stranger));

    // The handed-over descriptor is live: a byte written through it arrives on the far end.
    let deadline = std::time::Instant::now() + GENEROUS;
    let handed = loop {
        if let Ok(handed) = wired.watcher.handed.lock()
            && let Some(first) = handed.first()
        {
            break std::os::fd::AsFd::as_fd(first)
                .try_clone_to_owned()
                .expect("dup the handed-over descriptor");
        }
        assert!(
            std::time::Instant::now() < deadline,
            "no connection was handed over"
        );
        std::thread::yield_now();
    };
    nix::unistd::write(&handed, b"h").expect("write through the handed-over socket");
    let mut byte = [0_u8; 1];
    std::io::Read::read_exact(&mut other, &mut byte).expect("read the far end");
    assert_eq!(byte, *b"h");

    let heard = wired
        .watcher
        .heard
        .lock()
        .expect("the watcher heard")
        .connections
        .clone();
    assert_eq!(
        heard,
        vec![ListenerKind::Hook],
        "only the known kind is handed on"
    );
    wired.shut_down();
}

/// An `unsupported` status is its own answer, not an error: it is what lets a newer hostd discover
/// an older superd's capability set at runtime and fall back rather than fail.
#[test]
fn an_unsupported_verb_is_reported_as_recoverable() {
    let wired = Wired::up();
    let client = Arc::clone(&wired.client);
    let listening = std::thread::spawn(move || client.listen(&[ListenerKind::Hook, ListenerKind::Control]));
    let request = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::LISTEN);
    assert_eq!(request.listen.as_ref().map(|listen| listen.kinds.len()), Some(2),);
    let mut reply = Reply::ok(request.id);
    reply.status = Status::Unsupported;
    reply.message = Some("this superd predates listen".to_owned());
    wired.superd.reply(&reply, None);
    assert!(matches!(
        listening.join().expect("the listen thread finishes"),
        Err(ClientError::Unsupported { .. }),
    ));
    wired.shut_down();
}

/// A status a newer superd invented must reach the caller as a REFUSAL. The one thing it may not be
/// is silence, which is what a failed decode used to buy: the frame dropped, the waiter never
/// woken, the pane never opened.
#[test]
fn a_status_from_the_future_is_a_refusal_rather_than_silence() {
    let wired = Wired::up();
    let client = Arc::clone(&wired.client);
    let listing = std::thread::spawn(move || client.list());
    let request = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::LIST);
    let body = format!(r#"{{"id":{},"status":"deferred"}}"#, request.id);
    wired
        .superd
        .write_frame([slopdesk_superwire::TAG_PLAIN], body.as_bytes(), None);
    assert!(matches!(
        listing.join().expect("the list thread finishes"),
        Err(ClientError::Refused(_)),
    ));
    wired.shut_down();
}

/// The load-bearing one. A pause fired from INSIDE a sink — which is where the bounded-queue gate
/// fires it — must not wait on the socket the reader is responsible for draining. If it did, superd
/// blocked writing output into hostd's full receive buffer and hostd blocked writing a pause into
/// superd's would wedge both sides for ever, with no timeout to break it.
///
/// The fake superd here never reads while the sink runs, so the only way this test finishes is if
/// the pause left on a different thread.
#[test]
fn a_pause_issued_from_inside_a_sink_does_not_deadlock() {
    let wired = Wired::up();
    let (recorder, ticks) = wired.subscribe("pane-1");
    let client = Arc::clone(&wired.client);
    if let Ok(mut hook) = recorder.on_bytes.lock() {
        *hook = Some(Box::new(move || client.set_paused("pane-1", true)));
    }

    wired.superd.output("pane-1", 0, b"a flood");
    wait_for(&ticks, 1);
    // The reader thread is free again, which is the whole claim: it delivers the next chunk while
    // the pause is still only queued.
    wired.superd.output("pane-1", 7, b"and more");
    wait_for(&ticks, 1);

    let pause = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::PAUSE);
    assert_eq!(
        pause
            .pause
            .as_ref()
            .map(|pause| (pause.pane_id.as_str(), pause.paused)),
        Some(("pane-1", true)),
    );
    wired.shut_down();
}

/// An un-awaited verb still leaves, and its reply is dropped where it lands rather than parked for
/// a waiter that will never come. The Swift kept a set of ids for exactly this; here there is no
/// waiter registered, so there is nothing to hold — and the connection must survive the reply.
#[test]
fn an_unawaited_replys_arrival_is_harmless() {
    let wired = Wired::up();
    wired.client.resize("pane-1", 50, 200);
    let resize = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::RESIZE);
    assert_eq!(
        resize.resize.as_ref().map(|resize| (resize.rows, resize.cols)),
        Some((50, 200)),
    );
    wired.superd.reply(&Reply::ok(resize.id), None);

    // Still working afterwards: an awaited verb goes out and comes back on the same connection.
    let client = Arc::clone(&wired.client);
    let listing = std::thread::spawn(move || client.list());
    let request = wired
        .superd
        .next_request_for(slopdesk_superwire::protocol::verb::LIST);
    let mut reply = Reply::ok(request.id);
    reply.panes = Some(vec![pane_record("pane-1")]);
    wired.superd.reply(&reply, None);
    assert_eq!(
        listing
            .join()
            .expect("the list thread finishes")
            .expect("superd answers")
            .len(),
        1,
    );
    wired.shut_down();
}

/// `unsubscribe` drops the sink BEFORE the verb reaches superd, so frames already in flight land at
/// a torn-down session's door and stop there. A late chunk reaching a dead session is a
/// use-after-teardown, and it is ordinary rather than rare.
#[test]
fn a_late_chunk_for_an_unsubscribed_pane_is_dropped() {
    let wired = Wired::up();
    let (recorder, ticks) = wired.subscribe("pane-1");
    wired.superd.output("pane-1", 0, b"before");
    wait_for(&ticks, 1);

    wired.client.unsubscribe("pane-1");
    wired.superd.output("pane-1", 6, b"after");
    // The unsubscribe verb arriving proves the reader has passed the frame behind it.
    drop(
        wired
            .superd
            .next_request_for(slopdesk_superwire::protocol::verb::UNSUBSCRIBE),
    );
    wired.superd.output("pane-1", 11, b"later still");
    wired.superd.no_request_within(Duration::from_millis(100));

    assert_eq!(recorder.transcript(), vec![format!(
        "{:?}",
        Told::Bytes(0, b"before".to_vec())
    )]);
    wired.shut_down();
}

/// A dropped socket must fail every parked request rather than leave it waiting for a reply that is
/// never coming — and it must say so once, to the observer, so a service that marked itself running
/// can mark itself dead.
#[test]
fn a_dropped_socket_wakes_every_waiter_and_is_announced_once() {
    let mut wired = Wired::up();
    let client = Arc::clone(&wired.client);
    let listing = std::thread::spawn(move || client.list());
    drop(
        wired
            .superd
            .next_request_for(slopdesk_superwire::protocol::verb::LIST),
    );

    // superd goes away without answering.
    wired.superd.hang_up();
    assert!(matches!(
        listing.join().expect("the list thread finishes"),
        Err(ClientError::NotConnected),
    ));
    if let Some(threads) = wired.threads.take() {
        threads.join();
    }
    assert!(!wired.client.is_connected());
    assert_eq!(
        wired.watcher.heard.lock().expect("the watcher heard").disconnects,
        1,
        "the drop is announced exactly once",
    );
    // And every verb afterwards fails rather than hanging.
    assert!(matches!(wired.client.list(), Err(ClientError::NotConnected)));
    wired.shut_down();
}

/// The registry beside the owner's one notification: every object that asked hears the drop too,
/// and one that forgot its token first hears nothing.
///
/// This is what a panel service waits on. superd holds the ONLY master for one of those, so superd
/// dying kills the child — and the `exited` notice that would have said so travels the connection
/// that just died.
#[test]
fn every_registered_observer_hears_the_drop_and_a_forgotten_one_does_not() {
    let mut wired = Wired::up();
    let watching = Arc::new(AtomicUsize::new(0));
    let forgotten = Arc::new(AtomicUsize::new(0));

    let heard = Arc::clone(&watching);
    let _kept = wired.client.observe_disconnect(Arc::new(move || {
        heard.fetch_add(1, Ordering::SeqCst);
    }));
    let missed = Arc::clone(&forgotten);
    let token = wired.client.observe_disconnect(Arc::new(move || {
        missed.fetch_add(1, Ordering::SeqCst);
    }));
    wired.client.forget_disconnect(token);

    wired.superd.hang_up();
    if let Some(threads) = wired.threads.take() {
        threads.join();
    }

    assert_eq!(watching.load(Ordering::SeqCst), 1);
    assert_eq!(
        forgotten.load(Ordering::SeqCst),
        0,
        "a handler forgotten before the drop is not one that heard it",
    );
    // Idempotent, and a miss is ordinary: the teardown took every handler with it.
    wired.client.forget_disconnect(token);
    wired.shut_down();
}

/// A record with the fields any of these tests reads.
fn pane_record(pane_id: &str) -> PaneRecord {
    PaneRecord {
        pane_id: pane_id.to_owned(),
        session_id: "session-1".to_owned(),
        pid: 99,
        executable: "/bin/zsh".to_owned(),
        cwd: None,
        rows: 24,
        cols: 80,
        spawned_at: 1_700_000_000,
        attached: true,
        owner: None,
    }
}
