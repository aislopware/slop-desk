//! The service handle against a fake superd on a real `AF_UNIX` socket.
//!
//! Nothing is stubbed between this crate and the kernel: the fake writes superd's own framing with
//! `sendmsg`, hands the master across with `SCM_RIGHTS`, and builds every body with
//! `slopdesk_superwire` — the same crate superd builds them with. This is the one piece of stage
//! D.2 that IS its connection, so a seam here would test nothing.
//!
//! The load-bearing one is [`a_survivor_whose_ring_lost_the_announce_line_is_ended_not_adopted`].
//! Every other case would pass with the adopt taken on trust; that one is the difference between a
//! panel that comes back and a panel that reports `starting` for the rest of the daemon's life.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::collections::BTreeMap;
use std::io::IoSlice;
use std::os::fd::{AsFd as _, AsRawFd as _, BorrowedFd, OwnedFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use nix::sys::socket::{AddressFamily, ControlMessage, MsgFlags, SockFlag, SockType, sendmsg, socketpair};
use slopdesk_hostserver::service::{LogSink, ServiceHandle};
use slopdesk_hostserver::{ServiceProcess, pane_id_for};
use slopdesk_superclient::client::{ClientThreads, ListenerKind, SupervisorClient, SupervisorObserver};
use slopdesk_superwire::protocol::{
    ExitedNotice, HelloReply, PaneRecord, Reply, Request, Status, StreamPosition, VERSION_MAJOR,
    VERSION_MINOR, verb,
};

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// The announce line both real backends print, in the dialect the code panel parses.
const ANNOUNCE: &[u8] = b"info  HTTP server listening on http://0.0.0.0:41234/\r\n";

// MARK: - The fake superd

/// One side of the control socket, driven by the test.
struct FakeSuperd {
    socket: OwnedFd,
    requests: Receiver<Request>,
}

impl FakeSuperd {
    fn next_request(&self) -> Request {
        self.requests
            .recv_timeout(GENEROUS)
            .expect("the client sends a request")
    }

    /// Waits for a request with `verb`, discarding anything queued ahead of it.
    fn next_request_for(&self, wanted: &str) -> Request {
        loop {
            let request = self.next_request();
            if request.verb == wanted {
                return request;
            }
        }
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

    /// The `exited` notification, which is how every exit hostd ever learns about arrives.
    fn announce_exit(&self, pane_id: &str, code: i32) {
        let mut reply = Reply::ok(slopdesk_superwire::protocol::NOTIFICATION_ID);
        reply.event = Some(slopdesk_superwire::protocol::event::EXITED.to_owned());
        reply.exited = Some(ExitedNotice {
            pane_id: pane_id.to_owned(),
            pid: 4242,
            code,
        });
        self.reply(&reply, None);
    }

    /// Ends the connection the way a superd that died would.
    ///
    /// `shutdown`, not `drop`: the reading helper holds a DUP of this very socket, so dropping this
    /// descriptor leaves the connection open and the client's reader parked for ever.
    fn hang_up(&self) {
        let _ignored = nix::sys::socket::shutdown(self.socket.as_raw_fd(), nix::sys::socket::Shutdown::Both);
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

/// The record superd answers a `spawn` or an `adopt` with.
fn pane_record(pane_id: &str) -> PaneRecord {
    PaneRecord {
        pane_id: pane_id.to_owned(),
        session_id: pane_id.to_owned(),
        pid: 4242,
        executable: "/bin/sh".to_owned(),
        cwd: None,
        rows: 24,
        cols: 200,
        spawned_at: 1_700_000_000,
        attached: false,
        owner: None,
    }
}

/// A descriptor to stand in for the master superd hands over. The handle closes it immediately, so
/// what it is behind never matters — only that one crossed.
fn a_descriptor() -> OwnedFd {
    let (one, other) =
        socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty()).expect("a socket pair");
    drop(other);
    one
}

// MARK: - The observed side

#[derive(Debug, Default)]
struct Watcher;

impl SupervisorObserver for Watcher {
    fn exited(&self, _notice: &ExitedNotice) {}
    fn connection(&self, _kind: ListenerKind, descriptor: OwnedFd) {
        drop(descriptor);
    }
    fn disconnected(&self) {}
    fn log(&self, _line: &str) {}
}

/// Every assembled line the handle reported, in order.
#[derive(Debug, Default)]
struct Log {
    lines: Mutex<Vec<String>>,
}

impl Log {
    fn record(self: &Arc<Self>) -> LogSink {
        let ledger = Arc::clone(self);
        Arc::new(move |line: &str| {
            ledger
                .lines
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(line.to_owned());
        })
    }

    fn all(&self) -> Vec<String> {
        self.lines.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Blocks until some line contains `needle`.
    fn waited_for(&self, needle: &str) -> bool {
        let deadline = Instant::now() + GENEROUS;
        while Instant::now() < deadline {
            if self.all().iter().any(|line| line.contains(needle)) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        false
    }
}

// MARK: - The harness

struct Wired {
    client: Arc<SupervisorClient>,
    superd: FakeSuperd,
    threads: Option<ClientThreads>,
    path: PathBuf,
}

impl Wired {
    fn up() -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "slopdesk-hostserver-{}-{}.sock",
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
            SupervisorClient::connect(&dialled.to_string_lossy(), "hostd-services-test", observer)
        });

        let socket = accepted.join().expect("the accept thread finishes");
        let (requests, inbox) = channel();
        let reading = Held(socket.as_fd().try_clone_to_owned().expect("dup the socket"));
        std::thread::spawn(move || {
            while let Ok(frame) = slopdesk_superclient::frame::read(reading.borrow()) {
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
        }
    }

    /// Runs `act` on another thread while this side plays superd's half of the spawn-or-adopt.
    ///
    /// `survivor` is what the `adopt` gets: `Some(position)` for a superd that still holds the
    /// service — the position being where the ring can replay from — and `None` for one that does
    /// not, which sends the handle down the spawn path.
    fn service(
        &self,
        name: &'static str,
        log: &Arc<Log>,
        survivor: Option<StreamPosition>,
    ) -> Arc<ServiceProcess> {
        let client = Arc::clone(&self.client);
        let on_line = log.record();
        let pane_id = pane_id_for(name);
        std::thread::scope(|scope| {
            let acting = scope.spawn(move || {
                ServiceProcess::spawn_or_adopt(
                    name,
                    "/bin/sh",
                    vec!["-c".to_owned(), "exec sleep 30".to_owned()],
                    BTreeMap::new(),
                    &client,
                    on_line,
                    None,
                )
            });
            let adopting = self.superd.next_request_for(verb::ADOPT);
            if let Some(position) = survivor {
                let mut reply = Reply::ok(adopting.id);
                reply.pane = Some(pane_record(&pane_id));
                self.superd.reply(&reply, Some(&a_descriptor()));
                self.answer_subscribe(position);
            } else {
                let mut refusal = Reply::ok(adopting.id);
                refusal.status = Status::Error;
                refusal.message = Some("no such pane".to_owned());
                self.superd.reply(&refusal, None);
                let spawning = self.superd.next_request_for(verb::SPAWN);
                let mut reply = Reply::ok(spawning.id);
                reply.pane = Some(pane_record(&pane_id));
                self.superd.reply(&reply, Some(&a_descriptor()));
                self.answer_subscribe(FROM_THE_START);
            }
            acting
                .join()
                .expect("the spawning thread finishes")
                .expect("superd accepts it")
        })
    }

    /// Runs `handle.terminate()` while this side answers the `release` it parks on.
    ///
    /// `release` is one of the client's AWAITED verbs. The `unsubscribe` ahead of it is dispatched
    /// and forgotten, but the release blocks the calling thread until superd replies — so a test
    /// that terminates on the test thread without answering HANGS rather than fails. Every teardown
    /// goes through here for that reason.
    fn ended(&self, handle: &Arc<ServiceProcess>) {
        std::thread::scope(|scope| {
            let acting = scope.spawn(|| handle.terminate());
            let released = self.superd.next_request_for(verb::RELEASE);
            self.superd.reply(&Reply::ok(released.id), None);
            acting.join().expect("the terminate thread finishes");
        });
    }

    /// The `subscribe` every handle sends the instant it is wired.
    fn answer_subscribe(&self, position: StreamPosition) {
        let request = self.superd.next_request_for(verb::SUBSCRIBE);
        let mut reply = Reply::ok(request.id);
        reply.stream = Some(position);
        self.superd.reply(&reply, None);
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
    fn borrow(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

/// The position a superd whose ring still reaches offset zero answers with.
const FROM_THE_START: StreamPosition = StreamPosition {
    start: 0,
    head: 0,
    lossy: false,
    ended: false,
};

// MARK: - The tests

/// The plain path: nothing is running under the name, so superd forks one, and its announce line
/// reaches the parser as ONE line with no carriage return in it.
#[test]
fn a_spawn_subscribes_from_the_start_and_assembles_the_announce_line() {
    let wired = Wired::up();
    let log = Arc::new(Log::default());
    let handle = wired.service("test-announce", &log, None);

    wired
        .superd
        .output(&pane_id_for("test-announce"), ANNOUNCE.len() as u64, ANNOUNCE);

    assert!(!handle.adopted(), "nothing was running under that name yet");
    assert!(handle.is_running());
    assert!(
        log.waited_for("listening on http://0.0.0.0:41234/"),
        "the port is learned from the child's own line, never pre-allocated: {:?}",
        log.all(),
    );
    assert!(
        log.all().iter().all(|line| !line.contains('\r')),
        "the PTY's carriage returns must not survive the assembler: {:?}",
        log.all(),
    );
    wired.ended(&handle);
    wired.shut_down();
}

/// The reason this file exists. A survivor is taken back rather than restarted, and the port is
/// re-learned by replaying the ring from offset 0 — where the announce line still is.
#[test]
fn a_survivor_is_adopted_and_its_port_re_learned_from_the_ring() {
    let wired = Wired::up();
    let log = Arc::new(Log::default());
    let handle = wired.service("test-adopt", &log, Some(FROM_THE_START));

    wired
        .superd
        .output(&pane_id_for("test-adopt"), ANNOUNCE.len() as u64, ANNOUNCE);

    assert!(handle.adopted(), "the service ran straight through the restart");
    assert!(
        log.waited_for("listening on http://0.0.0.0:41234/"),
        "no state file, no port handshake — the child's own words are the record: {:?}",
        log.all(),
    );
    wired.ended(&handle);
    wired.shut_down();
}

/// The load-bearing one. A survivor whose ring no longer reaches the announce line is ENDED and the
/// caller spawns a fresh child, because a live handle with no port never respawns and leaves the
/// panel reporting `starting` for the rest of the daemon's life.
#[test]
fn a_survivor_whose_ring_lost_the_announce_line_is_ended_not_adopted() {
    let wired = Wired::up();
    let log = Arc::new(Log::default());
    let pane_id = pane_id_for("test-lossy");
    let client = Arc::clone(&wired.client);
    let on_line = log.record();

    let handle = std::thread::scope(|scope| {
        let acting = scope.spawn(move || {
            ServiceProcess::spawn_or_adopt(
                "test-lossy",
                "/bin/sh",
                vec!["-c".to_owned(), "exec sleep 30".to_owned()],
                BTreeMap::new(),
                &client,
                on_line,
                None,
            )
        });
        // superd still holds it — but the ring has scrolled past the announce line.
        let adopting = wired.superd.next_request_for(verb::ADOPT);
        let mut adopted = Reply::ok(adopting.id);
        adopted.pane = Some(pane_record(&pane_id));
        wired.superd.reply(&adopted, Some(&a_descriptor()));
        wired.answer_subscribe(StreamPosition {
            start: 8192,
            head: 8192,
            lossy: true,
            ended: false,
        });
        // The refusal ends it and the caller falls through to a spawn: a few seconds of boot in the
        // rare case, rather than a panel that never comes back.
        let released = wired.superd.next_request_for(verb::RELEASE);
        assert_eq!(
            released.release.as_ref().map(|request| request.kill),
            Some(true),
            "a survivor hostd can never address is ended, not let go",
        );
        wired.superd.reply(&Reply::ok(released.id), None);

        let spawning = wired.superd.next_request_for(verb::SPAWN);
        let mut spawned = Reply::ok(spawning.id);
        spawned.pane = Some(pane_record(&pane_id));
        wired.superd.reply(&spawned, Some(&a_descriptor()));
        wired.answer_subscribe(FROM_THE_START);
        acting
            .join()
            .expect("the spawning thread finishes")
            .expect("the fresh spawn lands")
    });

    assert!(
        !handle.adopted(),
        "a lossy resume is a FAILED adoption, and the handle must say so",
    );
    wired.ended(&handle);
    wired.shut_down();
}

/// The counterpart to letting go, and the line `docs/51` §5.5 draws for panes drawn here.
#[test]
fn a_terminate_releases_the_pane_with_kill() {
    let wired = Wired::up();
    let log = Arc::new(Log::default());
    let handle = wired.service("test-terminate", &log, None);

    std::thread::scope(|scope| {
        let acting = scope.spawn(|| handle.terminate());
        let released = wired.superd.next_request_for(verb::RELEASE);
        assert_eq!(released.release.as_ref().map(|request| request.kill), Some(true));
        wired.superd.reply(&Reply::ok(released.id), None);
        acting.join().expect("the terminate thread finishes");
    });

    assert!(!handle.is_running());
    // Idempotent, and the second call must not ask superd to end something twice.
    handle.terminate();
    wired.superd.no_request_within(Duration::from_millis(120));
    wired.shut_down();
}

/// What a daemon shutdown calls: hostd stops listening, superd keeps the child, and superd is told
/// NOTHING. The next hostd finds the service in `list` and adopts it.
#[test]
fn a_relinquish_unsubscribes_and_tells_superd_nothing_else() {
    let wired = Wired::up();
    let log = Arc::new(Log::default());
    let handle = wired.service("test-relinquish", &log, None);

    std::thread::scope(|scope| {
        let acting = scope.spawn(|| handle.relinquish());
        // The unsubscribe is the ONLY verb a relinquish may send.
        let unsubscribed = wired.superd.next_request_for(verb::UNSUBSCRIBE);
        wired.superd.reply(&Reply::ok(unsubscribed.id), None);
        acting.join().expect("the relinquish thread finishes");
    });

    wired.superd.no_request_within(Duration::from_millis(120));
    assert!(
        handle.is_running(),
        "letting go is not ending — the child is still superd's, and still up",
    );
    wired.shut_down();
}

/// A child that dies on its own stops reporting itself running, which is the next ensure round's
/// cue to respawn. The stream's end is what says so; the `exited` notice only precedes it.
#[test]
fn a_service_that_dies_on_its_own_stops_reporting_itself_running() {
    let wired = Wired::up();
    let log = Arc::new(Log::default());
    let handle = wired.service("test-crash", &log, None);
    assert!(handle.is_running());

    // The `exited` notice is the whole of it: the client ends the pane's stream on the way through,
    // before it reports the code, and the sink's `ended` is what latches the handle.
    wired.superd.announce_exit(&pane_id_for("test-crash"), 1);

    let deadline = Instant::now() + GENEROUS;
    while handle.is_running() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!handle.is_running(), "crash recovery needs no reaper");
    wired.shut_down();
}

/// superd holds the ONLY master for a service, so superd dying kills the child — and the `exited`
/// notice that would have said so travels the connection that just died. Every service hears the
/// drop instead.
#[test]
fn every_service_hears_the_supervisor_connection_drop() {
    let mut wired = Wired::up();
    let log = Arc::new(Log::default());
    let one = wired.service("test-drop-one", &log, None);
    let other = wired.service("test-drop-two", &log, None);
    assert!(one.is_running() && other.is_running());

    wired.superd.hang_up();
    if let Some(threads) = wired.threads.take() {
        threads.join();
    }

    assert!(!one.is_running(), "the next ensure re-runs spawn-or-adopt");
    assert!(!other.is_running(), "both, not just the first registered");
    drop(std::fs::remove_file(&wired.path));
}

/// The id is `service:<name>`, and a non-UUID id is what keeps these out of the survivor sweep,
/// which parses one and leaves anything else running untouched.
#[test]
fn the_service_pane_id_is_stable_and_not_a_uuid() {
    assert_eq!(pane_id_for("code-server"), "service:code-server");
    assert_eq!(pane_id_for("baguette"), "service:baguette");
    assert!(
        uuid_parse(&pane_id_for("code-server")).is_none(),
        "a UUID here would put a panel backend in the sweep that adopts this hostd's panes",
    );
}

/// The sweep's own parse, in the one shape this test needs it: 36 characters with dashes in the
/// four places, or nothing.
fn uuid_parse(candidate: &str) -> Option<&str> {
    if candidate.len() != 36 {
        return None;
    }
    let dashes = [8_usize, 13, 18, 23];
    let bytes = candidate.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        let wanted_dash = dashes.contains(&index);
        if wanted_dash != (*byte == b'-') {
            return None;
        }
        if !wanted_dash && !byte.is_ascii_hexdigit() {
            return None;
        }
    }
    Some(candidate)
}
