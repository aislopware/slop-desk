//! One pane against a fake superd on a real `AF_UNIX` socket, with a real PTY behind it.
//!
//! Nothing is stubbed between this crate and the kernel. The fake writes superd's own framing,
//! hands the master of a real `openpty` across by `SCM_RIGHTS`, and builds every body with
//! `slopdesk_superwire` — so an ioctl test drives an actual terminal and a descriptor that failed
//! to cross fails as a dead fd rather than as a wrong number.
//!
//! Three of these are load-bearing rather than illustrative:
//! [`a_spawn_hears_an_exit_announced_before_its_own_reply`] — the ordering the register-first rule
//! exists for; [`a_survivor_another_daemon_holds_is_not_stolen`] — the line between taking a pane
//! back and stealing one; and [`a_backlog_that_already_ended_declares_the_end_after_its_last_byte`]
//! — the race that used to hang a pane which finished before anyone subscribed.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::collections::BTreeMap;
use std::io::IoSlice;
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nix::sys::socket::{ControlMessage, MsgFlags, sendmsg};
use slopdesk_hostpane::stream::PaneChunkSink;
use slopdesk_hostpane::{PaneOutputStream, PtyProcess, WindowSize};
use slopdesk_superclient::client::{ClientThreads, SupervisorClient, SupervisorObserver};
use slopdesk_superwire::blockwire::{BlockEvent, SyntheticProgress};
use slopdesk_superwire::protocol::{
    ExitedNotice, HelloReply, PaneRecord, Reply, Request, SpawnRequest, Status, StreamPosition,
    VERSION_MAJOR, VERSION_MINOR, event, verb,
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

    /// The `exited` notification, which is how every exit hostd ever learns about arrives.
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

/// The record superd answers a `spawn` or an `adopt` with.
fn pane_record(pane_id: &str, pid: i32, attached: bool) -> PaneRecord {
    PaneRecord {
        pane_id: pane_id.to_owned(),
        session_id: "session-1".to_owned(),
        pid,
        executable: "/bin/zsh".to_owned(),
        cwd: None,
        rows: 24,
        cols: 80,
        spawned_at: 1_700_000_000,
        attached,
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

// MARK: - The observed side

#[derive(Debug, Default)]
struct Watcher {
    logs: Mutex<Vec<String>>,
}

impl SupervisorObserver for Watcher {
    fn exited(&self, _notice: &ExitedNotice) {}
    fn connection(&self, _kind: slopdesk_superclient::client::ListenerKind, descriptor: OwnedFd) {
        drop(descriptor);
    }
    fn disconnected(&self) {}
    fn log(&self, line: &str) {
        if let Ok(mut logs) = self.logs.lock() {
            logs.push(line.to_owned());
        }
    }
}

/// Everything a sink was told, as one ordered transcript — because the ORDER is what most of these
/// tests are about.
#[derive(Debug, PartialEq, Eq)]
enum Told {
    /// Payload, the offset it ends at, and how many events of each kind rode with it.
    Chunk(Vec<u8>, u64, usize, usize),
    Ended,
}

#[derive(Debug)]
struct Recorder {
    told: Mutex<Vec<Told>>,
    logs: Mutex<Vec<String>>,
    tick: Mutex<Sender<()>>,
}

impl Recorder {
    fn new() -> (Arc<Self>, Receiver<()>) {
        let (tick, ticks) = channel();
        (
            Arc::new(Self {
                told: Mutex::new(Vec::new()),
                logs: Mutex::new(Vec::new()),
                tick: Mutex::new(tick),
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

    fn said(&self, fragment: &str) -> bool {
        self.logs
            .lock()
            .is_ok_and(|logs| logs.iter().any(|line| line.contains(fragment)))
    }

    /// The same recorder as the trait object a stream takes. A helper rather than an `as` cast.
    fn as_sink(self: &Arc<Self>) -> Arc<dyn PaneChunkSink> {
        let concrete: Arc<Self> = Arc::clone(self);
        concrete
    }
}

impl PaneChunkSink for Recorder {
    fn chunk(&self, payload: &[u8], ends_at: u64, sniffed: &[SniffEvent], blocks: &[BlockEvent]) {
        self.note(Told::Chunk(
            payload.to_vec(),
            ends_at,
            sniffed.len(),
            blocks.len(),
        ));
    }

    fn ended(&self) {
        self.note(Told::Ended);
    }

    fn log(&self, line: &str) {
        if let Ok(mut logs) = self.logs.lock() {
            logs.push(line.to_owned());
        }
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
            "slopdesk-hostpane-{}-{}.sock",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
        ));
        drop(std::fs::remove_file(&path));
        let listener = UnixListener::bind(&path).expect("bind the fake superd");

        let accepted = std::thread::spawn(move || {
            let (stream, _address) = listener.accept().expect("the client dials");
            OwnedFd::from(stream)
        });

        let observer: Arc<dyn SupervisorObserver> = Arc::new(Watcher::default());
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
        }
    }

    /// A pane that has been through `spawn`, with a real PTY master behind it.
    ///
    /// The slave is handed back too and must be kept alive: dropping it is the child hanging up,
    /// and every ioctl on the master would then be talking to a dead terminal.
    fn spawned(&self, pane_id: &str, pid: i32) -> (Arc<PtyProcess>, OwnedFd) {
        let terminal = nix::pty::openpty(None, None).expect("a real pty");
        let pty = Arc::new(PtyProcess::new(Arc::clone(&self.client)));
        let running = Arc::clone(&pty);
        let request = spawn_request(pane_id);
        let spawning = std::thread::spawn(move || running.spawn(request));

        let asked = self.superd.next_request_for(verb::SPAWN);
        let mut reply = Reply::ok(asked.id);
        reply.pane = Some(pane_record(pane_id, pid, false));
        self.superd.reply(&reply, Some(&terminal.master));
        spawning
            .join()
            .expect("the spawn thread finishes")
            .expect("superd accepts the spawn");
        (pty, terminal.slave)
    }

    /// Opens a stream on `pane_id` and answers superd's side of the subscribe with `position`.
    fn stream(
        &self,
        pane_id: &str,
        position: StreamPosition,
    ) -> (PaneOutputStream, Arc<Recorder>, Receiver<()>) {
        let (recorder, ticks) = Recorder::new();
        let stream = PaneOutputStream::new(
            Arc::clone(&self.client),
            Some(pane_id.to_owned()),
            0,
            recorder.as_sink(),
        );
        self.answer_subscribe_while(position, || stream.start());
        (stream, recorder, ticks)
    }

    /// Runs `act` on another thread and answers the `subscribe` it sends.
    fn answer_subscribe_while(&self, position: StreamPosition, act: impl FnOnce() + Send) {
        std::thread::scope(|scope| {
            let acting = scope.spawn(act);
            let request = self.superd.next_request_for(verb::SUBSCRIBE);
            let mut reply = Reply::ok(request.id);
            reply.stream = Some(position);
            self.superd.reply(&reply, None);
            acting.join().expect("the subscribing thread finishes");
        });
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

fn wait_for(ticks: &Receiver<()>, count: usize) {
    for _step in 0..count {
        ticks.recv_timeout(GENEROUS).expect("the sink is told something");
    }
}

const fn running_stream() -> StreamPosition {
    StreamPosition {
        start: 0,
        head: 0,
        lossy: false,
        ended: false,
    }
}

// MARK: - Spawn, takeover, exit

/// The reason the exit route is registered BEFORE the spawn request goes out.
///
/// A child that dies instantly — a bad executable, an `exit 1` — is reaped and broadcast while the
/// spawning thread is still inside `spawn`. With the handler installed afterwards that notice lands
/// nowhere, and the pane looks alive until someone types into it.
#[test]
fn a_spawn_hears_an_exit_announced_before_its_own_reply() {
    let wired = Wired::up();
    let terminal = nix::pty::openpty(None, None).expect("a real pty");
    let pty = Arc::new(PtyProcess::new(Arc::clone(&wired.client)));
    let running = Arc::clone(&pty);
    let spawning = std::thread::spawn(move || running.spawn(spawn_request("pane-fast")));

    let asked = wired.superd.next_request_for(verb::SPAWN);
    // The child was reaped between the fork and the reply, which is a real ordering rather than a
    // contrived one: superd's reaper is a thread of its own.
    wired.superd.announce_exit("pane-fast", 127);
    let mut reply = Reply::ok(asked.id);
    reply.pane = Some(pane_record("pane-fast", 999, false));
    wired.superd.reply(&reply, Some(&terminal.master));
    spawning
        .join()
        .expect("the spawn thread finishes")
        .expect("superd accepts the spawn");

    assert!(pty.wait_until_exited(GENEROUS), "the exit was heard");
    assert_eq!(pty.exit_code(), Some(127));
    drop(terminal.slave);
    wired.shut_down();
}

/// A duplicate pane id does not mean a mistake: it means the pane is still running, left behind by
/// a hostd that relinquished it and never adopted it back. Refusing would hand the user a dead tab
/// per surviving shell.
#[test]
fn a_refused_spawn_takes_over_an_unattached_survivor() {
    let wired = Wired::up();
    let terminal = nix::pty::openpty(None, None).expect("a real pty");
    let pty = Arc::new(PtyProcess::new(Arc::clone(&wired.client)));
    let running = Arc::clone(&pty);
    let spawning = std::thread::spawn(move || running.spawn(spawn_request("pane-survivor")));

    let asked = wired.superd.next_request_for(verb::SPAWN);
    let mut refusal = Reply::ok(asked.id);
    refusal.status = Status::Error;
    refusal.message = Some("a pane with that id already exists".to_owned());
    wired.superd.reply(&refusal, None);

    let listing = wired.superd.next_request_for(verb::LIST);
    let mut records = Reply::ok(listing.id);
    records.panes = Some(vec![pane_record("pane-survivor", 4242, false)]);
    wired.superd.reply(&records, None);

    let adopting = wired.superd.next_request_for(verb::ADOPT);
    let mut adopted = Reply::ok(adopting.id);
    adopted.pane = Some(pane_record("pane-survivor", 4242, false));
    wired.superd.reply(&adopted, Some(&terminal.master));

    spawning
        .join()
        .expect("the spawn thread finishes")
        .expect("the takeover stands in for the spawn");
    assert!(pty.took_over_a_survivor(), "the caller is told it is a survivor");
    assert_eq!(pty.pane_id().as_deref(), Some("pane-survivor"));
    assert_eq!(pty.pid(), Some(4242));
    drop(terminal.slave);
    wired.shut_down();
}

/// The `attached` flag is the whole line between taking a pane back and stealing one: it means some
/// hostd holds a duplicate of that master right now.
///
/// The second half matters as much as the first. A refused spawn must leave nothing behind, and the
/// exit handler registered before the request is the thing that would be left — so an `exited` for
/// that pane afterwards must reach nobody.
#[test]
fn a_survivor_another_daemon_holds_is_not_stolen() {
    let wired = Wired::up();
    let pty = Arc::new(PtyProcess::new(Arc::clone(&wired.client)));
    let running = Arc::clone(&pty);
    let spawning = std::thread::spawn(move || running.spawn(spawn_request("pane-theirs")));

    let asked = wired.superd.next_request_for(verb::SPAWN);
    let mut refusal = Reply::ok(asked.id);
    refusal.status = Status::Error;
    refusal.message = Some("a pane with that id already exists".to_owned());
    wired.superd.reply(&refusal, None);

    let listing = wired.superd.next_request_for(verb::LIST);
    let mut records = Reply::ok(listing.id);
    records.panes = Some(vec![pane_record("pane-theirs", 4242, true)]);
    wired.superd.reply(&records, None);

    let refused = spawning.join().expect("the spawn thread finishes");
    assert!(refused.is_err(), "the original refusal is what the caller sees");
    assert!(!pty.took_over_a_survivor());
    assert!(pty.pane_id().is_none(), "no identity was installed");

    // No `adopt` was sent — the pane belongs to somebody else.
    wired.superd.no_request_within(Duration::from_millis(200));
    // And the exit route that was registered before the request is gone with it.
    wired.superd.announce_exit("pane-theirs", 1);
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(pty.exit_code(), None, "another daemon's pane is not ours to reap");
    wired.shut_down();
}

/// When superd itself restarts, the shells it held died with it and no notice is coming from
/// anybody. A session left waiting for one waits for ever and its tab never closes.
#[test]
fn a_lost_supervisor_declares_the_child_hung_up() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    assert_eq!(pty.exit_code(), None);
    pty.complete_exit_from_supervisor_loss();
    assert_eq!(pty.exit_code(), Some(128 + libc::SIGHUP));
    // And it is one-shot: a real notice arriving afterwards cannot overwrite it.
    wired.superd.announce_exit("pane-1", 0);
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(pty.exit_code(), Some(128 + libc::SIGHUP));
    drop(slave);
    wired.shut_down();
}

// MARK: - The descriptor

/// The ioctls, on a terminal the kernel really made. `TIOCGWINSZ` reading back what `TIOCSWINSZ`
/// wrote is the only proof that hostd's duplicate is the same terminal superd opened.
#[test]
fn the_window_size_round_trips_through_a_real_terminal() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    let wanted = WindowSize {
        rows: 50,
        cols: 200,
        px_width: 1600,
        px_height: 900,
    };
    pty.set_window_size(wanted);
    assert_eq!(pty.window_size(), Some(wanted));
    // And superd is told, so its record stops being a lie.
    let recorded = wired.superd.next_request_for(verb::RESIZE);
    let resize = recorded.resize.expect("the resize carries its numbers");
    assert_eq!((resize.rows, resize.cols), (50, 200));
    drop(slave);
    wired.shut_down();
}

/// The jiggle is a REAL size change in both directions — that is the entire point, because a
/// `SIGWINCH` at an unchanged size only makes a differential renderer repaint what it believes
/// changed.
#[test]
fn the_redraw_jiggle_shrinks_by_a_row_and_restores() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    pty.set_window_size(WindowSize {
        rows: 40,
        cols: 100,
        px_width: 800,
        px_height: 600,
    });
    drop(wired.superd.next_request_for(verb::RESIZE));

    let jiggle = pty.begin_redraw_jiggle().expect("a jiggle on a live terminal");
    assert_eq!(pty.window_size().map(|size| size.rows), Some(39));
    assert_eq!(
        pty.window_size().map(|size| size.px_height),
        Some(600),
        "the pixel fields are preserved",
    );
    pty.end_redraw_jiggle(jiggle);
    assert_eq!(pty.window_size().map(|size| size.rows), Some(40));
    drop(slave);
    wired.shut_down();
}

/// If a client resize landed during the hold, its own `SIGWINCH` already forced the full repaint at
/// the size the client actually wants — restoring the stale pre-jiggle size would stomp it.
#[test]
fn a_restore_yields_to_a_resize_that_landed_during_the_hold() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    pty.set_window_size(WindowSize {
        rows: 40,
        cols: 100,
        px_width: 0,
        px_height: 0,
    });
    drop(wired.superd.next_request_for(verb::RESIZE));

    let jiggle = pty.begin_redraw_jiggle().expect("a jiggle on a live terminal");
    let intervening = WindowSize {
        rows: 24,
        cols: 80,
        px_width: 0,
        px_height: 0,
    };
    pty.set_window_size(intervening);
    drop(wired.superd.next_request_for(verb::RESIZE));

    pty.end_redraw_jiggle(jiggle);
    assert_eq!(
        pty.window_size(),
        Some(intervening),
        "the client's own size survives the restore",
    );
    drop(slave);
    wired.shut_down();
}

/// Input never leaves this process: it goes straight down hostd's own duplicate of the master. The
/// slave reading back what was written is that path, end to end.
#[test]
fn keystrokes_go_straight_down_the_master() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    pty.write(b"echo hi\r").expect("the write lands");
    let mut buffer = [0_u8; 64];
    let read = nix::unistd::read(&slave, &mut buffer).expect("the child's side sees it");
    // `\r` arrives as `\n`: the tty line discipline's `ICRNL` is on by default, and seeing that
    // translation is the proof this is a real terminal rather than a pipe with the right shape.
    assert_eq!(buffer.get(..read), Some(b"echo hi\n".as_slice()));
    drop(slave);
    wired.shut_down();
}

/// Closing hostd's duplicate is "hostd is done looking at this pane", never "this pane is over" —
/// superd holds the original, and the shell must not notice. Idempotent, and it sends nothing.
#[test]
fn closing_the_master_is_idempotent_and_releases_nothing() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    pty.close_master();
    pty.close_master();
    assert_eq!(pty.window_size(), None, "there is no descriptor left to ask");
    pty.write(b"x").expect_err("a write after the close cannot land");
    wired.superd.no_request_within(Duration::from_millis(200));
    // The identity survives: a closed duplicate is not a forgotten pane.
    assert_eq!(pty.pane_id().as_deref(), Some("pane-1"));
    drop(slave);
    wired.shut_down();
}

/// The teardown ladder leads with `SIGHUP` because an interactive zsh treats it as a deliberate end
/// of session and persists its history — it IGNORES `SIGTERM`, and `SIGKILL` discards everything
/// typed since launch. Every rung routes through superd so its record stays true.
#[test]
fn the_signal_ladder_routes_through_superd() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    for (act, expected) in [(0, libc::SIGHUP), (1, libc::SIGTERM), (2, libc::SIGKILL)] {
        let sending = {
            let pty = Arc::clone(&pty);
            std::thread::spawn(move || {
                match act {
                    0 => pty.hangup(),
                    1 => pty.terminate(),
                    _ => pty.force_terminate(),
                }
            })
        };
        let request = wired.superd.next_request_for(verb::SIGNAL);
        let carried = request.signal.clone().expect("the signal carries its number");
        assert_eq!(carried.signal, expected);
        assert_eq!(carried.pane_id, "pane-1");
        wired.superd.reply(&Reply::ok(request.id), None);
        sending.join().expect("the signalling thread finishes");
    }
    drop(slave);
    wired.shut_down();
}

/// Release is the LAST rung of the teardown ladder, and this is what makes it last: the client
/// drops the pane's sink and its exit handler before the verb goes out, so an `exited` arriving
/// afterwards is routed nowhere. A caller that needs the code must wait BEFORE releasing.
///
/// Pinned because the ordering is invisible from either side alone — nothing in `release`'s
/// signature says a `wait_for_exit` after it never returns.
#[test]
fn a_release_retires_the_pane_and_its_exit_route_together() {
    let wired = Wired::up();
    let (pty, slave) = wired.spawned("pane-1", 4242);
    let releasing = {
        let pty = Arc::clone(&pty);
        std::thread::spawn(move || pty.release(true))
    };
    let request = wired.superd.next_request_for(verb::RELEASE);
    let carried = request.release.clone().expect("the release names its pane");
    assert_eq!(carried.pane_id, "pane-1");
    assert!(carried.kill, "a deliberate close kills the child");
    wired.superd.reply(&Reply::ok(request.id), None);
    assert!(
        releasing.join().expect("the releasing thread finishes"),
        "superd accepted the release",
    );

    wired.superd.announce_exit("pane-1", 129);
    assert!(
        !pty.wait_until_exited(Duration::from_millis(200)),
        "the exit route went with the release",
    );
    assert_eq!(pty.exit_code(), None);
    drop(slave);
    wired.shut_down();
}

// MARK: - The output stream

/// A pane that was never spawned has no stream to open, and that is not a fault. Most of the host
/// suite wants the SESSION and never a child: a `ping` must still be answered by a session whose
/// shell does not exist.
#[test]
fn a_stream_with_no_pane_ends_at_once_and_says_nothing() {
    let wired = Wired::up();
    let (recorder, ticks) = Recorder::new();
    let stream = PaneOutputStream::new(Arc::clone(&wired.client), None, 0, recorder.as_sink());
    stream.start();
    wait_for(&ticks, 1);
    assert_eq!(recorder.transcript(), vec!["Ended".to_owned()]);
    wired.superd.no_request_within(Duration::from_millis(200));
    drop(stream);
    wired.shut_down();
}

/// superd sends the sniff and blocks frames immediately BEFORE the chunk they were found in, and
/// the pairing is what keeps a title latch and the bytes that carried it in step. A batch must
/// never outlive its chunk and attach itself to the next one.
#[test]
fn events_arrive_with_the_chunk_they_were_found_in() {
    let wired = Wired::up();
    let (stream, recorder, ticks) = wired.stream("pane-1", running_stream());

    wired
        .superd
        .sniff("pane-1", &[SniffEvent::Title("✳ Claude Code".to_owned())]);
    wired.superd.blocks("pane-1", &[BlockEvent::Progress(
        SyntheticProgress::Indeterminate,
    )]);
    wired.superd.output("pane-1", 0, b"hello");
    // A second chunk with nothing preceding it must carry EMPTY batches.
    wired.superd.output("pane-1", 5, b"world");
    wait_for(&ticks, 2);

    assert_eq!(recorder.transcript(), vec![
        format!("{:?}", Told::Chunk(b"hello".to_vec(), 5, 1, 1)),
        format!("{:?}", Told::Chunk(b"world".to_vec(), 10, 0, 0)),
    ]);
    drop(stream);
    wired.shut_down();
}

/// An empty chunk with a non-empty batch is possible and is still delivered: it is the backlog a
/// resubscribe replays, whose events belong to bytes this stream already saw.
#[test]
fn an_empty_chunk_carrying_only_events_is_still_delivered() {
    let wired = Wired::up();
    let (stream, recorder, ticks) = wired.stream("pane-1", running_stream());
    wired
        .superd
        .sniff("pane-1", &[SniffEvent::Title("vim".to_owned())]);
    wired.superd.output("pane-1", 0, b"");
    wait_for(&ticks, 1);
    assert_eq!(recorder.transcript(), vec![format!(
        "{:?}",
        Told::Chunk(Vec::new(), 0, 1, 0)
    )]);
    drop(stream);
    wired.shut_down();
}

/// A gap is not recoverable, only reportable: the bytes are gone from superd's ring. Passing the
/// chunk on anyway is still the best answer — a terminal missing a region redraws on the next full
/// frame, whereas dropping the rest of the stream never recovers at all.
#[test]
fn a_gap_is_logged_and_the_chunk_is_delivered_anyway() {
    let wired = Wired::up();
    let (stream, recorder, ticks) = wired.stream("pane-1", running_stream());
    wired.superd.output("pane-1", 0, b"abc");
    wired.superd.output("pane-1", 100, b"xyz");
    wait_for(&ticks, 2);
    assert!(recorder.said("output gap — expected offset 3, got 100"));
    assert!(recorder.said("97 bytes lost"));
    assert_eq!(recorder.transcript(), vec![
        format!("{:?}", Told::Chunk(b"abc".to_vec(), 3, 0, 0)),
        format!("{:?}", Told::Chunk(b"xyz".to_vec(), 103, 0, 0)),
    ]);
    drop(stream);
    wired.shut_down();
}

/// superd's subscribe seam can ship the chunk that straddles the backlog and the live stream twice.
/// Offsets are absolute, so the overlap is cut off and the mark never rewinds: the session sees
/// every byte once, and the chunk after the overlap is not reported as a gap.
#[test]
fn an_overlapping_chunk_is_trimmed_and_a_repeated_one_is_dropped() {
    let wired = Wired::up();
    let (stream, recorder, ticks) = wired.stream("pane-1", running_stream());
    wired.superd.output("pane-1", 0, b"abcd");
    wired.superd.output("pane-1", 2, b"cdef");
    wired
        .superd
        .sniff("pane-1", &[SniffEvent::Title("vim".to_owned())]);
    wired.superd.output("pane-1", 0, b"abcdef");
    wired.superd.output("pane-1", 6, b"gh");
    wait_for(&ticks, 3);
    assert!(!recorder.said("output gap"));
    assert_eq!(recorder.transcript(), vec![
        format!("{:?}", Told::Chunk(b"abcd".to_vec(), 4, 0, 0)),
        format!("{:?}", Told::Chunk(b"ef".to_vec(), 6, 0, 0)),
        format!("{:?}", Told::Chunk(b"gh".to_vec(), 8, 0, 0)),
    ]);
    drop(stream);
    wired.shut_down();
}

/// A pane can finish before its subscription exists — spawn an `ls` and it is reaped while the
/// reply is still travelling — so that `exited` went out to nobody. The subscribe reply is the only
/// thing left that knows, and the end must land AFTER the backlog it precedes.
#[test]
fn a_backlog_that_already_ended_declares_the_end_after_its_last_byte() {
    let wired = Wired::up();
    let (stream, recorder, ticks) = wired.stream("pane-1", StreamPosition {
        start: 0,
        head: 5,
        lossy: false,
        ended: true,
    });
    wired.superd.output("pane-1", 0, b"done\n");
    wait_for(&ticks, 2);
    assert_eq!(
        recorder.transcript(),
        vec![
            format!("{:?}", Told::Chunk(b"done\n".to_vec(), 5, 0, 0)),
            "Ended".to_owned(),
        ],
        "the end goes out behind the bytes it follows",
    );
    drop(stream);
    wired.shut_down();
}

/// With nothing left to wait for, the end is declared at once — and a real `exited` arriving
/// afterwards must not declare it a second time. Downstream this closes a session, and closing one
/// twice is a use-after-teardown.
#[test]
fn an_end_learned_two_ways_is_told_once() {
    let wired = Wired::up();
    let (stream, recorder, ticks) = wired.stream("pane-1", StreamPosition {
        start: 0,
        head: 0,
        lossy: false,
        ended: true,
    });
    wait_for(&ticks, 1);
    wired.superd.announce_exit("pane-1", 0);
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(recorder.transcript(), vec!["Ended".to_owned()]);
    assert!(stream.has_ended());
    drop(stream);
    wired.shut_down();
}

/// A caller that subscribed from `0` specifically to read something out of the backlog has to know
/// the backlog no longer reaches the start, because there is nothing in the bytes to say so.
#[test]
fn a_lossy_resume_is_readable_the_moment_start_returns() {
    let wired = Wired::up();
    let (stream, recorder, _ticks) = wired.stream("pane-1", StreamPosition {
        start: 4096,
        head: 8192,
        lossy: true,
        ended: false,
    });
    assert!(stream.resumed_lossily());
    assert!(recorder.said("resumed at 4096, 4096 bytes retained"));
    drop(stream);
    wired.shut_down();
}

/// The gate asserts its first pause while a restore preamble is being enqueued, BEFORE the stream
/// starts. Dropping that call is worse than a missed pause: the gate latches the decision as
/// applied and only re-sends it on a change, so the subscription would open wide with no
/// backpressure asserted at all.
#[test]
fn a_pause_before_start_reaches_superd_and_stop_lifts_it() {
    let wired = Wired::up();
    let (recorder, _ticks) = Recorder::new();
    let stream = PaneOutputStream::new(
        Arc::clone(&wired.client),
        Some("pane-1".to_owned()),
        0,
        recorder.as_sink(),
    );
    stream.set_paused(true);
    let asserted = wired.superd.next_request_for(verb::PAUSE);
    assert!(asserted.pause.expect("the pause carries its flag").paused);

    // Never subscribed, so nobody else will ever lift it — the un-pause rides the last unsubscribe,
    // and there was never a subscribe. A paused pane with no reader is the frozen agent superd
    // exists to prevent.
    stream.stop();
    let lifted = wired.superd.next_request_for(verb::PAUSE);
    assert!(!lifted.pause.expect("the resume carries its flag").paused);
    drop(stream);
    wired.shut_down();
}

/// A started stream unsubscribes instead, because superd lifts any pause when the last subscriber
/// leaves — one verb covers both jobs. And dropping the stream must do it even when nobody called
/// `stop`, or the sink stays in the client's table and the pane leaks for the daemon's life.
#[test]
fn dropping_a_started_stream_unsubscribes() {
    let wired = Wired::up();
    let (stream, _recorder, _ticks) = wired.stream("pane-1", running_stream());
    drop(stream);
    let request = wired.superd.next_request_for(verb::UNSUBSCRIBE);
    assert_eq!(
        request
            .unsubscribe
            .expect("the unsubscribe names its pane")
            .pane_id,
        "pane-1",
    );
    wired.superd.no_request_within(Duration::from_millis(200));
    wired.shut_down();
}

/// The client's sink table went with the dropped connection, so without a resubscribe the terminal
/// renders nothing ever again while keystrokes still travel. The gate's last decision has to be
/// restated too: it lives in superd, and this is a different connection from the one that heard it.
#[test]
fn a_resubscribe_resumes_where_it_left_off_and_restates_the_pause() {
    let wired = Wired::up();
    let (stream, _recorder, ticks) = wired.stream("pane-1", running_stream());
    wired.superd.output("pane-1", 0, b"abcdef");
    wait_for(&ticks, 1);

    stream.set_paused(true);
    drop(wired.superd.next_request_for(verb::PAUSE));

    wired.answer_subscribe_while(
        StreamPosition {
            start: 6,
            head: 6,
            lossy: false,
            ended: false,
        },
        || assert!(stream.resubscribe(), "the pane is still there"),
    );
    // The gate's decision, restated on the new connection.
    let restated = wired.superd.next_request_for(verb::PAUSE);
    assert!(restated.pause.expect("the pause carries its flag").paused);
    drop(stream);
    wired.shut_down();
}
