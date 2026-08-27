//! The TCP listener and the per-connection protocol.
//!
//! ## Gated on subscribe
//! A connection does NOTHING until its first `Subscribe { from_seq }` frame arrives. The stream
//! does not start on connect — it starts on subscribe. That is what lets the client open the socket
//! eagerly and decide later how much history it wants.
//!
//! ## Two threads per connection, and why
//! The replay subscription only ends on daemon shutdown or an explicit detach — never on a client
//! disappearing. So a lone pump thread would run forever after the peer went away: a keep-alive
//! timer firing into a dead socket, a subscriber never detached, one leak per dropped client.
//!
//! The accepted thread therefore keeps READING (that is also where the disconnect shows up: the
//! inbound read returns 0 or errors) while a second thread WRITES. Whichever notices first shuts
//! the socket down in both directions, which unblocks the other, and detaches the subscription. The
//! detach is idempotent, so both racing to do it is fine.
//!
//! ## Read-only, by construction
//! `Subscribe` is the only thing a client may send, and the only thing it can affect is which
//! events that client receives. There is no path from this socket to the agent — no keystroke, no
//! signal, nothing. That is the whole premise of the inspector and it is enforced here by there
//! being nothing else in the match.

// stderr IS inspectord's log: the listener's threads report a dropped subscriber or a malformed
// frame there and nowhere else. Scoped to the listener so the event store and the frame codec
// cannot start printing.
#![expect(
    clippy::print_stderr,
    reason = "stderr is inspectord's log for the listener threads"
)]

use std::io::{ErrorKind, Read as _, Write as _};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use crate::replay::{Pull, ReplayLog, Subscription};
use crate::wire::{self, FrameDecoder, WireMessage};

/// Idle cadence for keep-alives, so a quiet run still reads as alive.
pub const DEFAULT_KEEP_ALIVE: Duration = Duration::from_secs(15);

/// The announce line's marker.
///
/// Spelled identically in `InspectorServiceManager.swift` and compared by
/// `rust/slopdesk-invariants` — this is how hostd re-learns the port after a restart, by
/// replaying superd's ring from offset 0 and reading the child's own words back.
pub const ANNOUNCE_PREFIX: &str = "inspectord: listening on 0.0.0.0:";

/// What the RUNNING build's version is prefixed with inside the announce parenthetical.
///
/// The announce line is already the one channel carrying facts about an inspectord hostd did not
/// start — that is what "re-learns the port after a restart" above means — so the running build's
/// version rides here rather than on a wire that has no handshake to add it to. FIRST in the
/// parenthetical and `v`-prefixed so the position is stable however the rest of that text grows.
/// Spelled identically in the other two announcing daemons and in `SidecarAnnounce.versionMarker`;
/// `rust/slopdesk-invariants` ratchets all four.
pub const ANNOUNCE_VERSION_PREFIX: &str = "(v";

/// The exact line [`Server::announce`] prints.
///
/// Split out so the shape hostd parses is a value a test can hold, rather than a side effect on a
/// file descriptor. `env!` reads THIS binary's compile-time version — never a number off disk.
#[must_use]
pub fn announce_line(port: u16, transcript: Option<&std::path::Path>) -> String {
    let source = transcript.map_or_else(
        || "no transcript".to_owned(),
        |path| format!("transcript {}", path.display()),
    );
    format!(
        "{ANNOUNCE_PREFIX}{port} {ANNOUNCE_VERSION_PREFIX}{}, {source})",
        env!("CARGO_PKG_VERSION"),
    )
}

/// Per-read buffer. Matches the frame decoder's compaction threshold, so in the common case the
/// buffer's consumed head is reclaimed at most once per read.
const READ_CHUNK: usize = 64 * 1024;

/// A bound inspector listener.
#[derive(Debug)]
pub struct Server {
    listener: TcpListener,
    log: Arc<ReplayLog>,
    keep_alive: Duration,
    stop: Arc<AtomicBool>,
}

impl Server {
    /// Binds `0.0.0.0:port` and serves `log`. Port `0` asks the OS for an ephemeral one, which is
    /// how the tests get a port nothing else can be holding.
    ///
    /// # Errors
    /// Any bind failure, verbatim — the caller decides whether that is fatal.
    pub fn bind(port: u16, log: Arc<ReplayLog>, keep_alive: Duration) -> std::io::Result<Self> {
        Ok(Self {
            listener: TcpListener::bind(("0.0.0.0", port))?,
            log,
            keep_alive,
            stop: Arc::new(AtomicBool::new(false)),
        })
    }

    /// The port actually bound.
    ///
    /// # Errors
    /// Any failure to read the local address back from the socket.
    pub fn port(&self) -> std::io::Result<u16> {
        Ok(self.listener.local_addr()?.port())
    }

    /// A handle that makes [`Server::run`] return. Held by the signal handler.
    #[must_use]
    pub fn stopper(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.stop)
    }

    /// Prints the announce line hostd parses the port out of, and returns that port.
    ///
    /// # Errors
    /// Any failure to read the bound address back.
    pub fn announce(&self, transcript: Option<&std::path::Path>) -> std::io::Result<u16> {
        let port = self.port()?;
        eprintln!("{}", announce_line(port, transcript));
        Ok(port)
    }

    /// Accepts until stopped, serving each connection on its own thread.
    ///
    /// One connection's failure is ITS failure: an accept error is logged and the loop carries on,
    /// because the alternative — exiting the daemon because one peer misbehaved — loses every other
    /// client's stream too.
    pub fn run(&self) {
        while !self.stop.load(Ordering::Relaxed) {
            let stream = match self.listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => {
                    eprintln!("inspectord: accept failed: {error}");
                    continue;
                },
            };
            let log = Arc::clone(&self.log);
            let keep_alive = self.keep_alive;
            let spawned = thread::Builder::new()
                .name("inspectord-conn".to_owned())
                .spawn(move || serve(&stream, &log, keep_alive));
            if let Err(error) = spawned {
                eprintln!("inspectord: could not spawn a connection thread: {error}");
            }
        }
    }
}

/// The per-connection protocol. Returns when the peer is gone or the daemon is shutting down.
fn serve(stream: &TcpStream, log: &Arc<ReplayLog>, keep_alive: Duration) {
    // Nagle would hold a small event frame back waiting for a companion; the whole point of this
    // channel is that a card appears the moment it is known.
    drop(stream.set_nodelay(true));

    let mut decoder = FrameDecoder::new();
    let mut buffer = vec![0_u8; READ_CHUNK];
    let mut subscription: Option<Subscription> = None;
    let mut writer: Option<thread::JoinHandle<()>> = None;

    let mut inbound = match stream.try_clone() {
        Ok(clone) => clone,
        Err(error) => {
            eprintln!("inspectord: could not clone the connection: {error}");
            return;
        },
    };

    loop {
        let read = match inbound.read(&mut buffer) {
            Ok(0) => break, // clean FIN
            Ok(count) => count,
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        let Some(chunk) = buffer.get(..read) else {
            break;
        };
        decoder.append(chunk);

        let mut desynced = false;
        loop {
            match decoder.next_message() {
                Ok(None) => break,
                Ok(Some(WireMessage::Subscribe { from_seq })) => {
                    // The FIRST subscribe opens the stream; a later one is ignored rather than
                    // opening a second pump onto the same socket, which would interleave two
                    // replays into one frame stream and desync the client's rendering.
                    if subscription.is_none() {
                        let opened = log.subscribe(from_seq);
                        let pump_subscription = opened.clone();
                        let pump_log = Arc::clone(log);
                        let Ok(pump_stream) = stream.try_clone() else {
                            break;
                        };
                        writer = thread::Builder::new()
                            .name("inspectord-pump".to_owned())
                            .spawn(move || {
                                pump(&pump_stream, &pump_subscription, &pump_log, keep_alive);
                            })
                            .ok();
                        subscription = Some(opened);
                    }
                },
                // The client sends nothing else. A frame that decodes to one of the host→client
                // kinds is simply not for us; dropping it keeps the stream in sync.
                Ok(Some(WireMessage::Event(_) | WireMessage::KeepAlive)) => {},
                Err(error) if error.is_recoverable() => {},
                Err(error) => {
                    eprintln!("inspectord: framing desync, dropping the connection: {error}");
                    desynced = true;
                    break;
                },
            }
        }
        if desynced {
            break;
        }
    }

    // The peer is gone (or its framing is unusable): detach, then shut the socket down so the pump
    // thread's next write fails and it unwinds too.
    if let Some(subscription) = subscription {
        log.unsubscribe(subscription.id);
        subscription.subscriber.finish();
    }
    drop(stream.shutdown(Shutdown::Both));
    if let Some(writer) = writer {
        drop(writer.join());
    }
}

/// Pumps replay-then-live events to one client, with a keep-alive on every idle interval.
fn pump(stream: &TcpStream, subscription: &Subscription, log: &Arc<ReplayLog>, keep_alive: Duration) {
    let mut outbound = stream;
    loop {
        let message = match subscription.subscriber.pull(keep_alive) {
            Pull::Event(event) => WireMessage::Event(event),
            Pull::Idle => WireMessage::KeepAlive,
            Pull::Finished => break,
        };

        let frame = match wire::encode(&message) {
            Ok(frame) => frame,
            Err(error) => {
                // One un-encodable event (a >16 MiB tool output) must not kill the stream: skipping
                // it keeps the client's framing intact, which sending a half-frame would not.
                eprintln!("inspectord: skipping an unsendable event: {error}");
                continue;
            },
        };
        if outbound.write_all(&frame).is_err() {
            break;
        }
    }

    // A failed write means the peer is gone: detach here too, so a client that stops READING but
    // never closes cannot hold a subscriber forever.
    log.unsubscribe(subscription.id);
    drop(stream.shutdown(Shutdown::Both));
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::{Read as _, Write as _};
    use std::net::TcpStream;
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::{ANNOUNCE_PREFIX, ANNOUNCE_VERSION_PREFIX, Server, announce_line};
    use crate::event::InspectorEvent;
    use crate::replay::ReplayLog;
    use crate::wire::{self, FrameDecoder, WireMessage};

    /// A keep-alive interval long enough that no test observes one. The tests that DO want
    /// keep-alives ask for a short one explicitly.
    const NEVER_IDLE: Duration = Duration::from_mins(1);

    fn event(index: i64) -> InspectorEvent {
        InspectorEvent::HistoryTruncated { dropped_count: index }
    }

    #[test]
    fn the_announce_line_still_leads_with_the_port_hostd_parses() {
        let line = announce_line(7413, None);
        let rest = line
            .strip_prefix(ANNOUNCE_PREFIX)
            .expect("the announce marker is the line's prefix");
        // hostd takes the digits directly after the marker as a run, so nothing may sit between.
        assert!(rest.starts_with("7413 "), "port must follow the marker: {line}");
    }

    #[test]
    fn the_announce_line_carries_the_running_builds_version_first_in_the_parenthetical() {
        for transcript in [None, Some(std::path::Path::new("/tmp/t.jsonl"))] {
            let line = announce_line(7413, transcript);
            let at = line
                .find(ANNOUNCE_VERSION_PREFIX)
                .expect("the version marker is on the line");
            let after = line
                .get(at + ANNOUNCE_VERSION_PREFIX.len()..)
                .expect("the marker is not the line's tail");
            let version = after
                .split([',', ')'])
                .next()
                .expect("split always yields a first field");
            assert_eq!(version, env!("CARGO_PKG_VERSION"), "in {line}");
        }
    }

    struct Harness {
        port: u16,
        log: Arc<ReplayLog>,
        stop: Arc<std::sync::atomic::AtomicBool>,
        accept: Option<thread::JoinHandle<()>>,
    }

    impl Harness {
        fn start(keep_alive: Duration) -> Self {
            let log = Arc::new(ReplayLog::default());
            let server = Server::bind(0, Arc::clone(&log), keep_alive).expect("an ephemeral port binds");
            let port = server.port().expect("the bound port is readable");
            let stop = server.stopper();
            let accept = thread::Builder::new()
                .name("test-accept".to_owned())
                .spawn(move || server.run())
                .expect("spawnable");
            Self {
                port,
                log,
                stop,
                accept: Some(accept),
            }
        }

        fn connect(&self) -> TcpStream {
            let stream = TcpStream::connect(("127.0.0.1", self.port)).expect("connects");
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("timeout settable");
            stream
        }
    }

    impl Drop for Harness {
        fn drop(&mut self) {
            self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
            // Unblock the accept loop with one throwaway connection.
            drop(TcpStream::connect(("127.0.0.1", self.port)));
            if let Some(accept) = self.accept.take() {
                drop(accept.join());
            }
        }
    }

    fn subscribe(stream: &mut TcpStream, from_seq: i64) {
        let frame = wire::encode(&WireMessage::Subscribe { from_seq }).expect("encodes");
        stream.write_all(&frame).expect("the subscribe is sent");
    }

    /// Reads until `wanted` messages have arrived or the budget expires. Generous, because the
    /// assertion is delivery, not latency.
    fn read_messages(stream: &mut TcpStream, wanted: usize) -> Vec<WireMessage> {
        let mut decoder = FrameDecoder::new();
        let mut out = Vec::new();
        let mut buffer = [0_u8; 4096];
        let deadline = Instant::now() + Duration::from_secs(5);
        while out.len() < wanted && Instant::now() < deadline {
            let Ok(read) = stream.read(&mut buffer) else {
                break;
            };
            if read == 0 {
                break;
            }
            decoder.append(&buffer[..read]);
            while let Ok(Some(message)) = decoder.next_message() {
                out.push(message);
            }
        }
        out
    }

    #[test]
    fn nothing_is_sent_before_the_client_subscribes() {
        let harness = Harness::start(NEVER_IDLE);
        harness.log.append(&event(0));
        let mut client = harness.connect();
        client
            .set_read_timeout(Some(Duration::from_millis(300)))
            .expect("settable");
        let mut buffer = [0_u8; 64];
        assert!(
            client.read(&mut buffer).is_err(),
            "the stream starts on subscribe, not on connect"
        );
    }

    #[test]
    fn a_subscribe_replays_the_history_then_streams_live() {
        let harness = Harness::start(NEVER_IDLE);
        harness.log.append(&event(0));
        harness.log.append(&event(1));

        let mut client = harness.connect();
        subscribe(&mut client, 0);
        let replayed = read_messages(&mut client, 2);
        assert_eq!(replayed, vec![
            WireMessage::Event(Box::new(event(0))),
            WireMessage::Event(Box::new(event(1))),
        ]);

        harness.log.append(&event(2));
        assert_eq!(read_messages(&mut client, 1), vec![WireMessage::Event(Box::new(
            event(2)
        ))]);
    }

    #[test]
    fn a_resume_skips_what_the_client_already_has() {
        let harness = Harness::start(NEVER_IDLE);
        for index in 0..4 {
            harness.log.append(&event(index));
        }
        let mut client = harness.connect();
        subscribe(&mut client, 3);
        assert_eq!(read_messages(&mut client, 1), vec![WireMessage::Event(Box::new(
            event(3)
        ))]);
    }

    #[test]
    fn an_idle_subscription_receives_keep_alives() {
        let harness = Harness::start(Duration::from_millis(50));
        let mut client = harness.connect();
        subscribe(&mut client, 0);
        let messages = read_messages(&mut client, 2);
        assert_eq!(messages, vec![WireMessage::KeepAlive, WireMessage::KeepAlive]);
    }

    #[test]
    fn two_clients_each_get_the_whole_stream() {
        let harness = Harness::start(NEVER_IDLE);
        harness.log.append(&event(0));

        let mut first = harness.connect();
        let mut second = harness.connect();
        subscribe(&mut first, 0);
        subscribe(&mut second, 0);

        assert_eq!(read_messages(&mut first, 1).len(), 1);
        assert_eq!(read_messages(&mut second, 1).len(), 1);

        harness.log.append(&event(1));
        assert_eq!(read_messages(&mut first, 1), vec![WireMessage::Event(Box::new(
            event(1)
        ))]);
        assert_eq!(read_messages(&mut second, 1), vec![WireMessage::Event(Box::new(
            event(1)
        ))]);
    }

    #[test]
    fn a_disconnect_detaches_the_subscriber_rather_than_leaking_it() {
        let harness = Harness::start(NEVER_IDLE);
        let mut client = harness.connect();
        subscribe(&mut client, 0);
        harness.log.append(&event(0));
        assert_eq!(read_messages(&mut client, 1).len(), 1);
        assert_eq!(harness.log.subscriber_count(), 1);

        drop(client);

        let deadline = Instant::now() + Duration::from_secs(5);
        while harness.log.subscriber_count() > 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            harness.log.subscriber_count(),
            0,
            "the subscription is detached when the peer goes away"
        );
    }

    #[test]
    fn a_second_subscribe_on_one_connection_does_not_open_a_second_pump() {
        let harness = Harness::start(NEVER_IDLE);
        harness.log.append(&event(0));
        let mut client = harness.connect();
        subscribe(&mut client, 0);
        assert_eq!(read_messages(&mut client, 1).len(), 1);
        subscribe(&mut client, 0);

        // A generous settle, then exactly one attached subscriber — not two replays interleaved.
        thread::sleep(Duration::from_millis(200));
        assert_eq!(harness.log.subscriber_count(), 1);
    }

    #[test]
    fn a_garbage_length_prefix_drops_only_that_connection() {
        let harness = Harness::start(NEVER_IDLE);
        let mut noisy = harness.connect();
        noisy.write_all(&[0xFF, 0xFF, 0xFF, 0xFF]).expect("sent");

        // The daemon is still serving: a fresh client works.
        harness.log.append(&event(0));
        let mut healthy = harness.connect();
        subscribe(&mut healthy, 0);
        assert_eq!(read_messages(&mut healthy, 1).len(), 1);
    }
}
