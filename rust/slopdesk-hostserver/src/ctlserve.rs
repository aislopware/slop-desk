//! The agent-control socket's connection half: NDJSON in, NDJSON out, one thread per connection.
//!
//! [`crate::control`] is the pure half — a line in, a line out, nothing that blocks on a
//! descriptor. This is the half that owns descriptors, and the split is the same one D.3 drew
//! between `slopdesk_muxsession::bridge_router` and `crate::bridge`: everything decidable is
//! decided where a test can reach it, and what is left here is the socket.
//!
//! ## hostd does not BIND this socket
//!
//! superd does — `rust/slopdesk-superd/src/listeners.rs` — for the reason that governs every
//! child-facing address in this repo: the path is baked into a spawned agent's environment at
//! `execve` and can never be corrected afterwards, so it has to outlive hostd's pid. superd accepts
//! and passes the connection over `SCM_RIGHTS`, reading none of it. What arrives here is one
//! already-accepted connection, and this crate takes ownership of it.
//!
//! ## One thread per connection, and why it is not a pool
//!
//! These connections are long-lived by design: an agent pipelines requests on one, `wait` parks on
//! one for a deadline, and `subscribe` hijacks one for a pane's whole life. The caller is the
//! supervisor client's single read-loop thread, which also carries every pane's output — serving a
//! connection inline there would stall every terminal in the host for as long as one agent held a
//! subscription.
//!
//! ## The departure from the Swift: one thread and a self-pipe, not two threads and a condition
//!
//! The Swift's `subscribe --all` ran a SECOND thread parked in `read(2)` purely to notice a
//! disconnect, and reaped it by having the first thread `close(2)` the descriptor the second was
//! inside. That works on Darwin, and it is the exact shape D.3's accept loop rejected: between the
//! close and the sleeper's return, any thread in the process can open something that lands on the
//! same number. Here the pump owns its connection and parks in `poll(2)` on TWO descriptors — the
//! connection and the read end of a pipe an observer writes one byte to. A disconnect is `POLLIN`
//! plus a zero-length read; a new event is the pipe. No second thread, no condition variable, and
//! no descriptor is ever closed out from under a syscall. That is superd's pump loop's shape, for
//! superd's reason.

use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::sync::{Arc, Mutex, PoisonError};

use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use serde_json::{Map, Value, json};
use slopdesk_hostsession::{CloseTap, OutputTap};
use slopdesk_workspace::control_request::{LineVerdict, MAX_REQUEST_BYTES, scan_line};

use crate::control::{
    AgentStatusEvent, AgentStatusTap, ControlHost, ForegroundName, IpcGuards, dispatch, encode_line, failure,
    lossy_text, parse_request,
};

/// One `read(2)` into this, per turn of the connection loop.
const READ_CHUNK: usize = 4096;

/// The id an answer carries when the request never parsed far enough to have one.
///
/// A refusal still gets a line: the caller is pipelining and would otherwise wait for an answer
/// that is never coming. `"?"` is the Swift's, and `slopdesk-ctl` already reads it.
const UNKNOWN_ID: &str = "?";

// ---------------------------------------------------------------------------------------------- //
// The server
// ---------------------------------------------------------------------------------------------- //

/// Serves the agent-control protocol on connections superd hands over.
#[derive(Debug)]
pub struct ControlConnections {
    host: Arc<dyn ControlHost>,
    guards: IpcGuards,
}

impl ControlConnections {
    /// A server over `host`, with the guards the environment resolves.
    #[must_use]
    pub fn new(host: Arc<dyn ControlHost>) -> Self {
        Self {
            host,
            guards: IpcGuards::resolved(),
        }
    }

    /// The same with `guards` supplied, which is what a test that is not about the guards wants.
    #[must_use]
    pub fn with_guards(host: Arc<dyn ControlHost>, guards: IpcGuards) -> Self {
        Self { host, guards }
    }

    /// Takes ownership of one accepted connection and serves it to EOF on its own thread.
    ///
    /// Returns immediately. The descriptor is closed when the thread ends, and by the thread — the
    /// `OwnedFd` moves in, so there is no window in which a second owner could close it.
    pub fn serve(&self, connection: OwnedFd) {
        let host = Arc::clone(&self.host);
        let guards = self.guards;
        // A named thread, because a control connection that wedges shows up in a sample and
        // "unnamed thread 47" names nothing.
        let spawned = std::thread::Builder::new()
            .name(String::from("slopdesk-ctl-conn"))
            .spawn(move || serve_connection(&connection, host.as_ref(), guards));
        // A thread that could not be spawned means the process is out of them, and there is nothing
        // useful to do with the connection: dropping it closes the descriptor, which the peer reads
        // as EOF — the same thing it would see if hostd had died mid-request.
        drop(spawned);
    }
}

/// Reads NDJSON lines, answers each, and loops until EOF or an IO error.
fn serve_connection(connection: &OwnedFd, host: &dyn ControlHost, guards: IpcGuards) {
    let mut pending: Vec<u8> = Vec::with_capacity(READ_CHUNK);
    let mut chunk = [0_u8; READ_CHUNK];

    loop {
        let read = match read_once(connection, &mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(count) => count,
        };
        pending.extend_from_slice(chunk.get(..read).unwrap_or_default());

        while let Some(newline) = pending.iter().position(|byte| *byte == b'\n') {
            let line = pending.drain(..=newline).take(newline).collect::<Vec<u8>>();
            match answer(&line, host, guards) {
                Outcome::Answered(reply) => {
                    if write_all(connection, reply.as_bytes()).is_err() {
                        return;
                    }
                },
                Outcome::Silent => {},
                Outcome::Subscribe(request) => {
                    subscribe(connection, &request, host);
                    return;
                },
            }
        }

        // An oversized PARTIAL line — one with no newline yet — is dropped rather than buffered.
        // The alternative is a peer that can grow this buffer without bound by never sending a
        // newline, which the never-DoS posture forbids. There is no id to answer to, so the drop is
        // silent; the peer learns of it when its eventual line parses as garbage.
        if pending.len() > MAX_REQUEST_BYTES {
            pending.clear();
            pending.shrink_to(READ_CHUNK);
        }
    }
}

/// What one request line turned into.
enum Outcome {
    /// A line to write back.
    Answered(String),
    /// Nothing to answer — a blank line has no `id` to address a refusal to.
    Silent,
    /// A `subscribe`, to be pumped on this thread with this connection.
    Subscribe(SubscribeRequest),
}

/// Turns one raw request line into an outcome, refusing before parsing where the guard is about the
/// LINE rather than about the verb.
fn answer(line: &[u8], host: &dyn ControlHost, guards: IpcGuards) -> Outcome {
    // Non-UTF-8 is refused rather than lossily repaired: this is a request, and a repaired verb or
    // pane id would name something the caller did not ask for.
    let Ok(text) = std::str::from_utf8(line) else {
        return Outcome::Answered(failure(UNKNOWN_ID, "invalid UTF-8"));
    };
    let scan = scan_line(text);
    match scan.verdict {
        LineVerdict::Blank => return Outcome::Silent,
        LineVerdict::TooLarge => return Outcome::Answered(failure(UNKNOWN_ID, "request too large")),
        LineVerdict::Parse => {},
    }
    let Some(trimmed) = text.get(scan.start..scan.end) else {
        return Outcome::Answered(failure(UNKNOWN_ID, "malformed request"));
    };
    let Some(request) = parse_request(trimmed) else {
        return Outcome::Answered(failure(UNKNOWN_ID, "malformed request"));
    };

    // `subscribe` hijacks the connection: it streams event lines and never returns to this loop.
    // There is deliberately NO handshake line first — a subscriber's first line is its first event,
    // which is what makes an idle subscription indistinguishable from a busy one at the wire.
    if request.method == "subscribe" {
        return Outcome::Subscribe(SubscribeRequest {
            id: request.id,
            params: request.params,
        });
    }

    let foreground: ForegroundName<'_> = &crate::control::probe_foreground_name;
    Outcome::Answered(dispatch(&request, host, guards, foreground))
}

/// A parsed `subscribe`, before its two modes are told apart.
struct SubscribeRequest {
    id: String,
    params: Map<String, Value>,
}

// ---------------------------------------------------------------------------------------------- //
// The pump's wakeup
// ---------------------------------------------------------------------------------------------- //

/// Lines an observer has produced and the pump has not yet written.
#[derive(Debug, Default)]
struct Queue {
    lines: Vec<Vec<u8>>,
    /// Set by the close tap when the pane exits. Distinct from a client disconnect, and the
    /// distinction decides whether a final `closed` event is written at all.
    pane_closed: bool,
    /// `paneId` → the last `(state, presence)` written for it, for the cross-pane mode's dedupe.
    last_by_pane: std::collections::BTreeMap<String, String>,
}

/// The pump's wakeup: a pipe whose write end an observer thread pokes and whose read end the pump
/// parks on beside the connection.
///
/// A byte rather than a condition variable because the pump has TWO things to wait for — an event
/// and a disconnect — and only a descriptor can be waited on beside another descriptor.
#[derive(Debug)]
struct Wakeup {
    read: OwnedFd,
    write: OwnedFd,
}

impl Wakeup {
    /// A pipe with both ends non-blocking and close-on-exec.
    ///
    /// Non-blocking on the WRITE end is the load-bearing half: the poker is the PTY read-loop
    /// thread, and a full pipe there would park every pane's output behind one slow subscriber. A
    /// full pipe already means "the pump has an unread wakeup", so the byte is redundant and
    /// dropping it loses nothing.
    ///
    /// `pipe(2)` and two `fcntl`s rather than `pipe2(2)`, which macOS does not have — `nix` gates
    /// its wrapper off Darwin for exactly that reason. The window between the two calls is the same
    /// one [`crate::bridge`]'s accept pipe lives with, and it is not a leak risk here: hostd forks
    /// nothing between them, because the only thread that forks is asleep in `accept(2)`.
    fn new() -> nix::Result<Self> {
        let (read, write) = nix::unistd::pipe()?;
        for end in [&read, &write] {
            slopdesk_posix::pty::set_cloexec(end.as_raw_fd());
            nix::fcntl::fcntl(end, nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK))?;
        }
        Ok(Self { read, write })
    }

    /// Wakes the pump, dropping the byte when one is already pending.
    fn poke(&self) {
        let _ignored = nix::unistd::write(&self.write, &[1_u8]);
    }
}

/// The state one subscription's observers and pump share.
#[derive(Debug)]
struct Subscription {
    queue: Mutex<Queue>,
    wakeup: Wakeup,
}

impl Subscription {
    fn new() -> nix::Result<Arc<Self>> {
        Ok(Arc::new(Self {
            queue: Mutex::new(Queue::default()),
            wakeup: Wakeup::new()?,
        }))
    }

    /// Buffers one encoded event line and wakes the pump.
    ///
    /// A poisoned lock is taken anyway. The only writers are these taps and the pump, none of which
    /// can panic while holding it — every one does `push`, `take` or a `BTreeMap` insert and
    /// nothing else — so a poison here means a panic elsewhere in the process, and dropping a
    /// subscriber's events because an unrelated thread died is a worse answer than serving them.
    fn enqueue(&self, line: Vec<u8>) {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        if queue.pane_closed {
            return;
        }
        queue.lines.push(line);
        drop(queue);
        self.wakeup.poke();
    }

    /// Marks the pane gone and wakes the pump, which drains and then stops.
    fn close(&self) {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.pane_closed = true;
        drop(queue);
        self.wakeup.poke();
    }

    /// Takes everything pending, and whether the pane has closed.
    fn drain(&self) -> (Vec<Vec<u8>>, bool) {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        (std::mem::take(&mut queue.lines), queue.pane_closed)
    }
}

// ---------------------------------------------------------------------------------------------- //
// `subscribe` — the per-pane output stream
// ---------------------------------------------------------------------------------------------- //

/// Streams a pane's output as `{"event":"output","text":…}` lines, then one `{"event":"closed"}`.
///
/// A `subscribe` with a `paneId` is this; one WITHOUT is the cross-pane supervision stream, and an
/// absent `paneId` is a valid mode rather than a missing argument.
fn subscribe(connection: &OwnedFd, request: &SubscribeRequest, host: &dyn ControlHost) {
    match request.params.get("paneId") {
        Some(Value::String(pane_id)) => {
            subscribe_pane(connection, &request.id, pane_id, &request.params, host);
        },
        // A `paneId` that is present but not a string is an error, not the all-mode: the caller
        // meant one pane and named it wrongly, and answering with every pane's status would be a
        // silent substitution.
        Some(_) => {
            let _ignored = write_all(
                connection,
                failure(&request.id, "params.paneId must be a string").as_bytes(),
            );
        },
        None => subscribe_all(connection, host),
    }
}

/// Buffers a pane's output chunks as event lines.
#[derive(Debug)]
struct OutputPump {
    subscription: Arc<Subscription>,
    /// Whether to strip ANSI before the text crosses. Default ON — a subscriber is an agent reading
    /// text, and a subscriber that wants the colour codes asks for them.
    ansi_strip: bool,
}

impl OutputTap for OutputPump {
    fn chunk(&self, payload: &[u8]) {
        let text = if self.ansi_strip {
            lossy_text(&slopdesk_sanitize::plaintext::strip(payload))
        } else {
            lossy_text(payload)
        };
        if text.is_empty() {
            return;
        }
        self.subscription
            .enqueue(encode_line(&json!({ "event": "output", "text": text })).into_bytes());
    }
}

/// Wakes the pump when the pane exits.
#[derive(Debug)]
struct ExitPump {
    subscription: Arc<Subscription>,
}

impl CloseTap for ExitPump {
    fn closed(&self) {
        self.subscription.close();
    }
}

fn subscribe_pane(
    connection: &OwnedFd,
    id: &str,
    pane_id: &str,
    params: &Map<String, Value>,
    host: &dyn ControlHost,
) {
    let Some(pane) = host.lookup_pane(pane_id) else {
        let _ignored = write_all(
            connection,
            failure(id, &format!("pane not found: {pane_id}")).as_bytes(),
        );
        return;
    };
    let Ok(subscription) = Subscription::new() else {
        let _ignored = write_all(
            connection,
            failure(id, "no descriptors for a subscription").as_bytes(),
        );
        return;
    };
    let ansi_strip = params.get("ansiStrip").and_then(Value::as_bool).unwrap_or(true);

    let output = pane.add_output_tap(Arc::new(OutputPump {
        subscription: Arc::clone(&subscription),
        ansi_strip,
    }));
    let exit = pane.add_close_tap(Arc::new(ExitPump {
        subscription: Arc::clone(&subscription),
    }));

    let ended = pump(connection, &subscription);

    // Retire both taps BEFORE the last write. An observer that fires between the pump's last drain
    // and its own removal would enqueue into a queue nobody will read again, which leaks nothing
    // but is a line the caller was told it would get and never gets.
    pane.remove_output_tap(output);
    pane.remove_close_tap(exit);

    // `closed` is emitted ONLY on a clean pane exit. After a client disconnect the peer is gone and
    // the write would be an `EPIPE` on a descriptor nobody reads; after a write failure it would be
    // a second one. The distinction is why [`Ended`] has two variants rather than a bool.
    if matches!(ended, Ended::PaneClosed) {
        let _ignored = write_all(connection, encode_line(&json!({ "event": "closed" })).as_bytes());
    }
}

// ---------------------------------------------------------------------------------------------- //
// `subscribe` with no pane — the cross-pane supervision stream
// ---------------------------------------------------------------------------------------------- //

/// Buffers `agent_status_changed` events for every pane, deduped per pane.
#[derive(Debug)]
struct StatusPump {
    subscription: Arc<Subscription>,
}

impl AgentStatusTap for StatusPump {
    fn changed(&self, event: &AgentStatusEvent) {
        let mut queue = self
            .subscription
            .queue
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        // Dedupe on (state, presence) rather than state alone. The agent-GONE edge lands on the
        // same `"idle"` string the pane already reported — `.none` and `.idle` collapse together —
        // so a state-only key would swallow the one transition a supervisor most needs to see.
        let key = format!("{}|{}", event.state, event.agent_present);
        if queue.last_by_pane.get(&event.pane_id) == Some(&key) {
            return;
        }
        queue.last_by_pane.insert(event.pane_id.clone(), key);
        queue.lines.push(
            encode_line(&json!({
                "type": "agent_status_changed",
                "paneId": event.pane_id,
                "state": event.state,
                "agentPresent": event.agent_present,
                "title": event.title,
                "ts": event.ts,
            }))
            .into_bytes(),
        );
        drop(queue);
        self.subscription.wakeup.poke();
    }
}

fn subscribe_all(connection: &OwnedFd, host: &dyn ControlHost) {
    let Ok(subscription) = Subscription::new() else {
        return;
    };
    let token = host.add_status_tap(Arc::new(StatusPump {
        subscription: Arc::clone(&subscription),
    }));
    let _ended = pump(connection, &subscription);
    host.remove_status_tap(token);
    // No `closed` event: this stream has no pane to close, and it ends only when its client does.
}

// ---------------------------------------------------------------------------------------------- //
// The pump
// ---------------------------------------------------------------------------------------------- //

/// Why a pump stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ended {
    /// The pane exited and everything it produced has been written.
    PaneClosed,
    /// The peer went away, or a write to it failed.
    ClientGone,
}

/// Parks on the connection and the wakeup pipe, writing whatever the observers queue.
///
/// The connection is watched for READABILITY even though a subscriber never sends: a readable
/// connection with a zero-length read is EOF, which is how an idle subscriber that dropped is
/// reaped. Without it a client could open subscriptions and abandon them to accumulate taps,
/// descriptors and threads in the host, which the never-DoS posture forbids. Any actual chatter is
/// read and discarded — the protocol has nothing for a subscriber to say, and hanging up on a peer
/// for saying it would be a stricter contract than the Swift's.
fn pump(connection: &OwnedFd, subscription: &Subscription) -> Ended {
    let mut scratch = [0_u8; 256];
    loop {
        // Drain FIRST. An event enqueued between the previous write and this park has already
        // consumed its wakeup byte, and parking without draining would sleep on a line already
        // sitting in the queue.
        let (batch, pane_closed) = subscription.drain();
        for line in &batch {
            if write_all(connection, line).is_err() {
                return Ended::ClientGone;
            }
        }
        if pane_closed {
            return Ended::PaneClosed;
        }

        let connection_fd = PollFd::new(connection.as_fd(), PollFlags::POLLIN);
        let wakeup_fd = PollFd::new(subscription.wakeup.read.as_fd(), PollFlags::POLLIN);
        let mut watched = [connection_fd, wakeup_fd];
        match poll(&mut watched, PollTimeout::NONE) {
            Ok(_) => {},
            // `EINTR` is a signal, not an end. Anything else is a poll on descriptors this thread
            // owns and has not closed, which cannot be retried into working.
            Err(Errno::EINTR) => continue,
            Err(_) => return Ended::ClientGone,
        }

        if let Some(events) = watched.first().and_then(PollFd::revents) {
            if events.intersects(PollFlags::POLLHUP | PollFlags::POLLERR | PollFlags::POLLNVAL) {
                return Ended::ClientGone;
            }
            if events.contains(PollFlags::POLLIN) {
                match read_once(connection, &mut scratch) {
                    // EOF, or an error on a descriptor this thread owns — either way the peer is
                    // not going to read anything more.
                    Ok(0) | Err(_) => return Ended::ClientGone,
                    // Chatter. Discarded, and the pump keeps watching.
                    Ok(_) => {},
                }
            }
        }

        if let Some(events) = watched.get(1).and_then(PollFd::revents)
            && events.contains(PollFlags::POLLIN)
        {
            // Drain every pending byte: the wakeup is a doorbell, not a count, and one turn of
            // this loop writes whatever the queue holds regardless of how many rang it.
            while let Ok(read) = nix::unistd::read(&subscription.wakeup.read, &mut scratch) {
                if read < scratch.len() {
                    break;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// Descriptor IO
// ---------------------------------------------------------------------------------------------- //

/// One `read(2)`, retried past `EINTR`.
fn read_once(connection: &OwnedFd, into: &mut [u8]) -> Result<usize, Errno> {
    loop {
        match nix::unistd::read(connection, into) {
            Err(Errno::EINTR) => {},
            other => return other,
        }
    }
}

/// Writes every byte, retrying past `EINTR` and short writes.
///
/// `nix`'s `write` over the borrowed descriptor rather than a `std::fs::File` around it: `File`
/// would have to own what it wrote to, so it would have to be a `dup(2)` — and a `dup` per line,
/// held in a `ManuallyDrop` so it does not close the connection, is a descriptor leaked per line.
/// A subscriber writes thousands.
///
/// A reply that cannot be delivered is the caller's end of the story, not this listener's: the peer
/// is a control client that has gone away, and every caller here turns the error into "stop".
fn write_all(connection: &OwnedFd, bytes: &[u8]) -> Result<(), Errno> {
    let mut written = 0;
    while written < bytes.len() {
        match nix::unistd::write(connection, bytes.get(written..).unwrap_or_default()) {
            Err(Errno::EINTR) => {},
            // A zero-length write on a non-empty buffer is not progress, and looping on it would
            // spin. Treated as the peer being gone, which is the only way it happens on a socket.
            Ok(0) => return Err(Errno::EPIPE),
            Ok(count) => written = written.saturating_add(count),
            Err(error) => return Err(error),
        }
    }
    Ok(())
}
