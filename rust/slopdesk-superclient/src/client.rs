//! hostd's end of the superd control socket: the verbs, the reader thread, and the writer behind
//! it.
//!
//! The port of `Sources/SlopDeskSupervisor/SupervisorClient.swift`. Requests are synchronous on the
//! caller's thread, because every caller is on a path that used to call `openpty` + `fork` inline
//! and blocked for exactly as long. Notifications and every pane's output arrive on one reader
//! thread, and the per-pane sink runs ON it, synchronously.
//!
//! ## The synchronous sink is the backpressure gate
//!
//! It would be natural to hand each pane a channel — that is the shape [`crate::connection`]'s
//! neighbours in `slopdesk-hostnet` use, and it is the right one there because flow-control credit
//! bounds the queue. Nothing bounds a subscription queue. A sink that took its time would fill an
//! unbounded `Vec` in this process instead of stopping the reads, and stopping the reads is the
//! entire mechanism: hostd stops reading, superd's writes block, superd stops reading the master,
//! the kernel PTY buffer fills, and the SHELL is paused. That chain is what "nothing is buffered on
//! the way and nothing is dropped" means, and a per-pane queue anywhere in it turns the never-drop
//! invariant into an unbounded buffer.
//!
//! So [`PaneSink`] is called on the reader thread with a payload BORROWED out of the frame that
//! carried it. No copy, no allocation, no hop.
//!
//! ## Why a write never happens on the reader thread
//!
//! A sink re-enters this client: crossing the bounded-queue high-water mark fires
//! [`SupervisorClient::set_paused`] from inside the ingest it just performed. If that were a
//! blocking `write` on the socket the reader is responsible for draining, then with superd blocked
//! writing output into hostd's full receive buffer and hostd blocked writing a pause into superd's,
//! neither side ever moves again and every terminal freezes with no timeout to break it.
//!
//! One writer thread behind an unbounded queue removes the cycle by construction: the reader hands
//! the bytes over and goes straight back to `recvmsg`. The queue is SERIAL because order is
//! meaning — an `unsubscribe` overtaken by a later `subscribe` for the same pane would cancel the
//! live subscription and leave a pane that renders nothing.
//!
//! ## Two Swift mechanisms that are absent rather than ported
//!
//! `unawaited`, a set of request ids whose replies must be dropped, existed because the Swift
//! parked arriving REPLIES in a map keyed by id and a reply nobody claimed would sit there for
//! ever. Here it is the WAITER that is registered, so an un-awaited request registers nothing and
//! its reply finds no channel to go to. The set has nothing to hold.
//!
//! `connection === link`, the identity check guarding the disconnect path, existed because the
//! Swift client reconnected IN PLACE and a superseded reader could otherwise tear down its
//! successor's live socket. A client here is one connection for its whole life; reconnecting means
//! building another, with the same observer. There is no second reader to confuse it with.

use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::{self, JoinHandle};

use slopdesk_superwire::blockwire::BlockEvent;
use slopdesk_superwire::protocol::{
    BlocksReply, ExitedNotice, HelloReply, JournalReply, PaneRecord, Reply, Request, Status, StreamPosition,
    VERSION_MAJOR, VERSION_MINOR, event, listener_kind, verb,
};
use slopdesk_superwire::sniffwire::SniffEvent;

use crate::connection::Connection;
use crate::frame::FrameError;

/// Why a verb did not answer the way its caller needed.
#[derive(Debug)]
pub enum ClientError {
    /// The socket is gone. Every pending and future verb fails this way.
    NotConnected,
    /// superd speaks a major version this build cannot talk to. Both sides are carried so the
    /// message can name the fix rather than just the mismatch.
    Incompatible {
        /// What superd said in its `hello`.
        superd_major: i32,
        /// What this build was compiled against.
        ours_major: i32,
    },
    /// superd knows the verb and refused it.
    Refused(String),
    /// The verb is not in this superd's vocabulary — it is older than us. Recoverable: the caller
    /// falls back rather than failing (`docs/51` §3 rule 3).
    Unsupported {
        /// The verb that was not understood.
        verb: String,
        /// superd's own words.
        message: String,
    },
    /// The reply was not this protocol's JSON, or was missing the field its verb promises.
    MalformedReply,
    /// A reply that should have carried a master descriptor did not.
    MissingDescriptor,
    /// The framing or the socket failed.
    Link(FrameError),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match *self {
            Self::NotConnected => write!(formatter, "not connected to superd"),
            Self::Incompatible {
                superd_major,
                ours_major,
            } => {
                write!(
                    formatter,
                    "superd speaks protocol {superd_major}, this build speaks {ours_major}",
                )
            },
            Self::Refused(ref message) => write!(formatter, "superd refused: {message}"),
            Self::Unsupported {
                ref verb,
                ref message,
            } => write!(formatter, "superd does not know `{verb}`: {message}"),
            Self::MalformedReply => write!(formatter, "superd's reply did not decode"),
            Self::MissingDescriptor => write!(formatter, "superd's reply carried no descriptor"),
            Self::Link(ref error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for ClientError {}

/// Names one registered disconnect handler, for the caller to forget it by.
///
/// A number rather than a name because these are per-OBJECT and several are live at once: two panel
/// services register the same shape of handler, and a name would make them one.
pub type DisconnectToken = u64;

/// Which child-facing socket a handed-over connection arrived on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListenerKind {
    /// The Claude-hook socket, advertised to children as `SLOPDESK_SOCKET_PATH`.
    Hook,
    /// The agent-control socket, advertised to children as `SLOPDESK_CONTROL_SOCKET`.
    Control,
}

impl ListenerKind {
    /// The wire spelling, which is `slopdesk_superwire`'s and never constructed here.
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Hook => listener_kind::HOOK,
            Self::Control => listener_kind::CONTROL,
        }
    }

    /// The kind a wire word names, or `None` for one this build has no name for — which is a
    /// superd newer than this hostd, not a corrupt frame.
    #[must_use]
    pub fn from_wire(word: &str) -> Option<Self> {
        match word {
            listener_kind::HOOK => Some(Self::Hook),
            listener_kind::CONTROL => Some(Self::Control),
            _ => None,
        }
    }
}

/// Where one pane's output goes.
///
/// Every method runs on the client's single reader thread, synchronously, and the bytes are
/// borrowed out of the frame that carried them — see this module's header for why both of those are
/// requirements rather than conveniences.
pub trait PaneSink: Send + Sync + std::fmt::Debug {
    /// Bytes superd read off the master, with the absolute offset of the first one in the pane's
    /// life. An EMPTY payload is legal: a subscriber that resumed exactly at the head gets one.
    fn bytes(&self, offset: u64, payload: &[u8]);

    /// What the shell said out of band in the chunk that arrives NEXT.
    ///
    /// superd writes this frame and the [`PaneSink::bytes`] frame it precedes under one hold of its
    /// own wire lock, so the pairing is guaranteed and it is this sink's to make.
    fn sniffed(&self, events: &[SniffEvent]);

    /// What the command-block tap found in the chunk that arrives NEXT. Same placement and the same
    /// guarantee as [`PaneSink::sniffed`].
    fn blocks(&self, events: &[BlockEvent]);

    /// The master is finished. Delivered from the pane's `exited` notice, which superd broadcasts
    /// only after draining the pump to EOF — so every byte the shell ever wrote has already been
    /// through [`PaneSink::bytes`] by the time this runs. That ordering is what lets a session keep
    /// its exit frame behind its last output frame on the wire.
    fn ended(&self);
}

/// What happens to this client that is not about one pane.
///
/// Installed at [`SupervisorClient::connect`] rather than settable afterwards: the reader thread
/// starts inside that call, and a handler installed after it has a window in which superd's news
/// lands nowhere. Every method runs on the reader thread.
pub trait SupervisorObserver: Send + Sync + std::fmt::Debug {
    /// A supervised child exited. Fires for every pane, after that pane's own handlers.
    fn exited(&self, notice: &ExitedNotice);

    /// superd accepted a connection on a listener this client claimed, and handed it over.
    ///
    /// The descriptor is OWNED — dropping it closes it, which is the right answer for a kind
    /// nothing serves. It arrives on the reader thread, so an implementation must hand it straight
    /// to a worker: parking here stops every pane's output and every reply, and the peer on the
    /// other end is a hook binary blocking its agent.
    fn connection(&self, kind: ListenerKind, descriptor: OwnedFd);

    /// The socket dropped. The panes are still alive on superd's side; this is the control channel,
    /// not the shells.
    fn disconnected(&self);

    /// Something worth a line in hostd's log.
    fn log(&self, line: &str);
}

/// The threads one client runs. Joining them is how a caller knows the socket is finished with.
#[derive(Debug)]
pub struct ClientThreads {
    joins: Vec<JoinHandle<()>>,
}

impl ClientThreads {
    /// Waits for the reader and the writer to unwind. Both end when the connection does.
    pub fn join(self) {
        for handle in self.joins {
            drop(handle.join());
        }
    }
}

/// One request queued for the writer thread.
#[derive(Debug)]
struct Outbound {
    body: Vec<u8>,
    /// Present for an AWAITED request: the caller parks until the bytes have actually left, so a
    /// broken socket is reported to it rather than swallowed. Absent for a fire-and-forget verb.
    written: Option<Sender<Result<(), FrameError>>>,
}

/// One reply, as it comes back off the reader thread.
#[derive(Debug)]
struct Answer {
    reply: Reply,
    descriptor: Option<OwnedFd>,
}

/// What superd said about itself at `hello`.
#[derive(Debug, Clone)]
pub struct Handshake {
    /// superd's pid, for logs and for telling one daemon from its successor.
    pub superd_pid: i32,
    /// The hook socket's stable path. hostd MUST advertise this into every spawned child rather
    /// than a path of its own — that is the whole point of superd owning the addresses.
    pub hook_socket_path: Option<String>,
    /// The agent-control socket's stable path, for the same reason.
    pub control_socket_path: Option<String>,
    /// The lower of the two minors — what both ends may actually use.
    pub negotiated_minor: i32,
    /// The crate version of the superd process on the other end, or `None` from a superd that
    /// predates minor 8 and did not send one. Never read as "current".
    pub build_version: Option<String>,
}

/// hostd's connection to superd.
pub struct SupervisorClient {
    connection: Arc<Connection>,
    observer: Arc<dyn SupervisorObserver>,
    next_request_id: AtomicU64,
    /// Who is parked on which reply. The WAITER is registered, never the reply — see the module
    /// header for the Swift mechanism that dissolves.
    waiters: Mutex<HashMap<u64, Sender<Answer>>>,
    sinks: Mutex<HashMap<String, Arc<dyn PaneSink>>>,
    #[expect(
        clippy::type_complexity,
        reason = "one boxed callback per pane; naming the type would not make the field clearer"
    )]
    exit_handlers: Mutex<HashMap<String, Arc<dyn Fn(i32) + Send + Sync>>>,
    disconnect_handlers: Mutex<HashMap<DisconnectToken, Arc<dyn Fn() + Send + Sync>>>,
    next_disconnect_token: AtomicU64,
    // NOTE: `Debug` is written out below rather than derived, because an exit handler is a bare
    // `Fn` and there is nothing to print about one.
    /// The writer's inbox. Taken at teardown, which is what ends the writer thread.
    outbound: Mutex<Option<Sender<Outbound>>>,
    handshake: OnceLock<Handshake>,
    live: AtomicBool,
}

impl std::fmt::Debug for SupervisorClient {
    /// Names the connection and its state, and stops there.
    ///
    /// Written out rather than derived because `exit_handlers` holds bare closures, which have no
    /// `Debug`. Counting what is registered is the useful half anyway — the callbacks themselves
    /// would print as an address.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SupervisorClient")
            .field("live", &self.is_connected())
            .field("handshake", &self.handshake.get())
            .field("sinks", &self.sinks.lock().map_or(0, |sinks| sinks.len()))
            .finish_non_exhaustive()
    }
}

impl SupervisorClient {
    /// Dials superd, starts the threads, and completes the `hello` handshake.
    ///
    /// The observer is installed before either thread exists, so the earliest notification superd
    /// can send already has somewhere to go.
    ///
    /// # Errors
    /// [`ClientError::Link`] when superd is not running — which is fatal to panes rather than
    /// degradable, since nothing else in this process can fork a shell — and
    /// [`ClientError::Incompatible`] when it is running a major version this build cannot talk to.
    pub fn connect(
        socket_path: &str,
        client_name: &str,
        observer: Arc<dyn SupervisorObserver>,
    ) -> Result<(Arc<Self>, ClientThreads), ClientError> {
        let connection = Connection::dial(socket_path).map_err(|errno| ClientError::Link(errno.into()))?;
        let (client, threads) = Self::serve(Arc::new(connection), observer);
        match client.hello(client_name) {
            Ok(()) => Ok((client, threads)),
            Err(error) => {
                client.disconnect();
                Err(error)
            },
        }
    }

    /// Starts the threads over an already-connected socket, without saying `hello`.
    ///
    /// The seam every test uses, and the one honest way to drive this client against a fake superd.
    #[must_use]
    pub fn serve(
        connection: Arc<Connection>,
        observer: Arc<dyn SupervisorObserver>,
    ) -> (Arc<Self>, ClientThreads) {
        let (queue, inbox) = channel();
        let client = Arc::new(Self {
            connection,
            observer,
            next_request_id: AtomicU64::new(1),
            waiters: Mutex::new(HashMap::new()),
            sinks: Mutex::new(HashMap::new()),
            exit_handlers: Mutex::new(HashMap::new()),
            disconnect_handlers: Mutex::new(HashMap::new()),
            next_disconnect_token: AtomicU64::new(1),
            outbound: Mutex::new(Some(queue)),
            handshake: OnceLock::new(),
            live: AtomicBool::new(true),
        });

        let mut joins = Vec::with_capacity(2);
        let writer = Arc::clone(&client);
        if let Ok(join) = thread::Builder::new()
            .name("slopdesk-superd-writer".to_owned())
            .spawn(move || writer.write_loop(&inbox))
        {
            joins.push(join);
        }
        let reader = Arc::clone(&client);
        if let Ok(join) = thread::Builder::new()
            .name("slopdesk-superd-reader".to_owned())
            .spawn(move || reader.read_loop())
        {
            joins.push(join);
        }
        // A client with one thread cannot work: with no writer no verb ever leaves, and with no
        // reader no reply ever comes back. Only an exhausted process gets here, and limping is
        // worse than failing, so tear down and let every verb report `NotConnected`.
        if joins.len() < 2 {
            client.tear_down();
        }
        (client, ClientThreads { joins })
    }

    /// What superd said about itself, once `hello` has been answered.
    #[must_use]
    pub fn handshake(&self) -> Option<&Handshake> {
        self.handshake.get()
    }

    /// Whether the socket is still up.
    #[must_use]
    pub fn is_connected(&self) -> bool {
        self.live.load(Ordering::Acquire)
    }

    /// Hangs up. The panes keep running — superd holds every master.
    pub fn disconnect(&self) {
        self.tear_down();
    }

    // MARK: Verbs

    /// The version handshake. First on every connection, and the only verb that may set
    /// [`SupervisorClient::handshake`].
    fn hello(&self, client_name: &str) -> Result<(), ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::HELLO);
        request.hello = Some(slopdesk_superwire::protocol::HelloRequest {
            version_major: VERSION_MAJOR,
            version_minor: VERSION_MINOR,
            client: client_name.to_owned(),
        });
        let answer = self.request(verb::HELLO, &request)?;
        let Some(hello) = answer.reply.hello else {
            return Err(ClientError::MalformedReply);
        };
        if hello.version_major != VERSION_MAJOR {
            return Err(ClientError::Incompatible {
                superd_major: hello.version_major,
                ours_major: VERSION_MAJOR,
            });
        }
        self.observer.log(&format!(
            "supervisor: attached to superd pid {} (protocol {}.{})",
            hello.superd_pid, hello.version_major, hello.version_minor,
        ));
        drop(self.handshake.set(handshake_of(hello)));
        Ok(())
    }

    /// Registers the callback for one pane's death, replacing any previous one.
    ///
    /// Call it BEFORE the `spawn` request goes out: a child that dies instantly — a bad executable,
    /// an `exit 1` — can be reaped and broadcast while the caller is still inside `spawn`, and a
    /// lost `exited` leaves a dead pane looking alive until someone types into it.
    pub fn observe_exit(&self, pane_id: &str, handler: Arc<dyn Fn(i32) + Send + Sync>) {
        if let Ok(mut handlers) = self.exit_handlers.lock() {
            drop(handlers.insert(pane_id.to_owned(), handler));
        }
    }

    /// Drops the handler for a pane that never came to exist.
    pub fn forget_exit_handler(&self, pane_id: &str) {
        if let Ok(mut handlers) = self.exit_handlers.lock() {
            drop(handlers.remove(pane_id));
        }
    }

    /// Registers a callback for the SOCKET dropping, and answers a token to forget it by.
    ///
    /// [`SupervisorObserver::disconnected`] is the owner's one notification and stays that; this is
    /// the registry beside it, for the objects that are not the owner. A panel service is the case
    /// it exists for: superd holds the ONLY master for one of those, so superd dying kills the
    /// child, and nothing else would ever tell hostd — the `exited` notice travels the connection
    /// that just died. A service that hears this marks itself ended, and its next round adopts the
    /// survivor if superd was merely unreachable or spawns a fresh one if it really restarted.
    ///
    /// A TOKEN rather than a name, because these are per-object and several can be live at once —
    /// a name would make two services with the same handler one handler.
    ///
    /// Register BEFORE the spawn, the way [`SupervisorClient::observe_exit`] is: the teardown
    /// drains this map, so a handler filed after the socket has already dropped is filed
    /// against a drop it missed and never fires. The registration is not a query — ask
    /// [`SupervisorClient::is_connected`] if the answer matters at that moment.
    pub fn observe_disconnect(&self, handler: Arc<dyn Fn() + Send + Sync>) -> DisconnectToken {
        let token = self.next_disconnect_token.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut handlers) = self.disconnect_handlers.lock() {
            drop(handlers.insert(token, handler));
        }
        token
    }

    /// Drops one registered disconnect handler. Idempotent, and a miss is ordinary: the teardown
    /// takes every handler with it, so an object released afterwards forgets one that is gone.
    pub fn forget_disconnect(&self, token: DisconnectToken) {
        if let Ok(mut handlers) = self.disconnect_handlers.lock() {
            drop(handlers.remove(&token));
        }
    }

    /// Forks a pane shell in superd and takes the master descriptor it hands back.
    ///
    /// # Errors
    /// [`ClientError::Refused`] for a duplicate pane id — which is not always a mistake; see
    /// `PTYProcess.spawn`'s takeover path — and [`ClientError::MissingDescriptor`] when the reply
    /// carried a record but no master.
    pub fn spawn(
        &self,
        spawn: slopdesk_superwire::protocol::SpawnRequest,
    ) -> Result<(PaneRecord, OwnedFd), ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::SPAWN);
        request.spawn = Some(spawn);
        self.pane_and_descriptor(verb::SPAWN, &request)
    }

    /// Takes back a pane that survived a restart.
    ///
    /// # Errors
    /// As [`SupervisorClient::spawn`].
    pub fn adopt(&self, pane_id: &str) -> Result<(PaneRecord, OwnedFd), ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::ADOPT);
        request.adopt = Some(slopdesk_superwire::protocol::AdoptRequest {
            pane_id: pane_id.to_owned(),
        });
        self.pane_and_descriptor(verb::ADOPT, &request)
    }

    /// Everything superd currently supervises.
    ///
    /// # Errors
    /// [`ClientError::NotConnected`] or superd's own refusal.
    pub fn list(&self) -> Result<Vec<PaneRecord>, ClientError> {
        let request = Request::new(self.allocate_id(), verb::LIST);
        Ok(self
            .request(verb::LIST, &request)?
            .reply
            .panes
            .unwrap_or_default())
    }

    /// Asks superd to signal a pane's child.
    ///
    /// Routed through superd rather than `kill(2)`-ed here even though hostd could: superd is the
    /// only holder of the pane's true state, and a shell that dies from a signal superd never saw
    /// is a pane superd still believes is alive.
    ///
    /// # Errors
    /// superd's own refusal, or [`ClientError::NotConnected`].
    pub fn signal(&self, pane_id: &str, signal: i32) -> Result<(), ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::SIGNAL);
        request.signal = Some(slopdesk_superwire::protocol::SignalRequest {
            pane_id: pane_id.to_owned(),
            signal,
        });
        self.request(verb::SIGNAL, &request).map(|_answer| ())
    }

    /// Claims the child-facing listeners this hostd will serve.
    ///
    /// Send it once per connection, after `hello` and BEFORE the first `spawn`: a pane spawned in
    /// between is handed hostd's own idea of the socket paths instead of superd's stable ones, and
    /// that snapshot can never be corrected.
    ///
    /// # Errors
    /// [`ClientError::Unsupported`] from a superd older than protocol 1.3, which is recoverable —
    /// that superd binds nothing, so hostd is free to fall back.
    pub fn listen(&self, kinds: &[ListenerKind]) -> Result<(), ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::LISTEN);
        request.listen = Some(slopdesk_superwire::protocol::ListenRequest {
            kinds: kinds.iter().map(|kind| kind.as_wire().to_owned()).collect(),
        });
        self.request(verb::LISTEN, &request).map(|_answer| ())
    }

    /// Starts receiving a pane's output.
    ///
    /// The sink is installed BEFORE the request goes out, under the same lock the reader takes, or
    /// the backlog frames superd writes straight after its reply arrive with nowhere to go.
    ///
    /// # Errors
    /// superd's refusal, with the sink taken back out again so a failed subscribe leaves nothing
    /// behind.
    pub fn subscribe(
        &self,
        pane_id: &str,
        from_offset: u64,
        sink: Arc<dyn PaneSink>,
    ) -> Result<StreamPosition, ClientError> {
        if let Ok(mut sinks) = self.sinks.lock() {
            drop(sinks.insert(pane_id.to_owned(), sink));
        }
        let mut request = Request::new(self.allocate_id(), verb::SUBSCRIBE);
        request.subscribe = Some(slopdesk_superwire::protocol::SubscribeRequest {
            pane_id: pane_id.to_owned(),
            from_offset,
        });
        match self.request(verb::SUBSCRIBE, &request) {
            Ok(answer) => answer.reply.stream.ok_or(ClientError::MalformedReply),
            Err(error) => {
                self.forget_sink(pane_id);
                Err(error)
            },
        }
    }

    /// Stops receiving a pane's output. The pane keeps running and superd keeps draining it.
    ///
    /// Un-awaited, and the local sink is dropped first: a failure to tell superd costs some wasted
    /// frames rather than output arriving at a torn-down session. Un-awaited also because teardown
    /// can reach here FROM the reader thread, and waiting there for a reply only that thread can
    /// deliver never ends.
    pub fn unsubscribe(&self, pane_id: &str) {
        self.forget_sink(pane_id);
        let mut request = Request::new(self.allocate_id(), verb::UNSUBSCRIBE);
        request.unsubscribe = Some(slopdesk_superwire::protocol::UnsubscribeRequest {
            pane_id: pane_id.to_owned(),
        });
        self.dispatch(&request);
    }

    /// Stops or resumes superd's reads on a pane — the backpressure gate.
    ///
    /// Un-awaited as a correctness requirement rather than a latency choice: this is called from
    /// inside the output-queue accounting, i.e. from whatever thread just ingested a chunk, which
    /// is usually the reader thread itself.
    pub fn set_paused(&self, pane_id: &str, paused: bool) {
        let mut request = Request::new(self.allocate_id(), verb::PAUSE);
        request.pause = Some(slopdesk_superwire::protocol::PauseRequest {
            pane_id: pane_id.to_owned(),
            paused,
        });
        self.dispatch(&request);
    }

    /// Tells superd the pane's new size.
    ///
    /// Un-awaited and non-throwing: hostd has already applied `TIOCSWINSZ` to its own duplicate of
    /// the master — that is the apply the shell feels — and this is the record. Left stale, a
    /// 200×50 pane comes back re-wrapped at 80 columns after the next restart.
    pub fn resize(&self, pane_id: &str, rows: u16, cols: u16) {
        let mut request = Request::new(self.allocate_id(), verb::RESIZE);
        request.resize = Some(slopdesk_superwire::protocol::ResizeRequest {
            pane_id: pane_id.to_owned(),
            rows,
            cols,
        });
        self.dispatch(&request);
    }

    /// Retires a pane sniffer's title-coalescing anchor.
    ///
    /// Best-effort and un-awaited for both of [`SupervisorClient::unsubscribe`]'s reasons. Losing
    /// it costs a stale pane title rather than a wrong one.
    pub fn forget_title_coalescing(&self, pane_id: &str) {
        let mut request = Request::new(self.allocate_id(), verb::FORGET_TITLE);
        request.forget_title = Some(slopdesk_superwire::protocol::ForgetTitleRequest {
            pane_id: pane_id.to_owned(),
        });
        self.dispatch(&request);
    }

    /// One finished command block's retained output, from superd's ring.
    ///
    /// # Errors
    /// superd's own refusal. `Ok(None)` means the pane has no tap at all, which is a different
    /// answer from an empty one: an EMPTY vector means the block aged out of the ring, or never
    /// existed.
    pub fn block_output(&self, pane_id: &str, index: u32) -> Result<Option<Vec<u8>>, ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::BLOCK_OUTPUT);
        request.block_output = Some(slopdesk_superwire::protocol::BlockOutputRequest {
            pane_id: pane_id.to_owned(),
            index,
        });
        let answer = self.request(verb::BLOCK_OUTPUT, &request)?;
        Ok(answer.reply.blocks.map(|blocks| {
            blocks
                .output
                .as_deref()
                .map(slopdesk_superwire::blockwire::unbase64)
                .unwrap_or_default()
        }))
    }

    /// Every block superd's tap still knows about this pane, ascending — the reattach backfill.
    ///
    /// # Errors
    /// superd's own refusal. `Ok(None)` means the pane has no tap.
    pub fn block_snapshot(
        &self,
        pane_id: &str,
    ) -> Result<Option<Vec<slopdesk_superwire::blockwire::BlockMeta>>, ClientError> {
        let answer = self.block_read(verb::BLOCK_SNAPSHOT, pane_id, 0)?;
        Ok(answer.and_then(|blocks| blocks.snapshot))
    }

    /// The agent-control read: recent blocks with their bytes, the running command, and the index
    /// the next one will close under — one round trip, because the three are only consistent with
    /// each other if superd read them together.
    ///
    /// # Errors
    /// superd's own refusal. `Ok(None)` means the pane has no tap.
    pub fn block_control(&self, pane_id: &str, limit: usize) -> Result<Option<BlocksReply>, ClientError> {
        self.block_read(verb::BLOCK_CONTROL, pane_id, limit)
    }

    /// Where a session's transcript is on disk, and how much of a live stream it already holds.
    ///
    /// The BYTES are not in the answer: hostd opens the returned path itself, so a multi-megabyte
    /// transcript never crosses this socket to be handed straight to the screen engine.
    ///
    /// # Errors
    /// superd's own refusal. `Ok(None)` means that session has no transcript — not the same as an
    /// empty one, because only "there is nothing here" may start a pane at offset 0.
    pub fn journal_info(
        &self,
        directory: &str,
        session_id: &str,
    ) -> Result<Option<JournalReply>, ClientError> {
        let mut request = Request::new(self.allocate_id(), verb::JOURNAL_INFO);
        request.journal = Some(journal_request(directory, session_id, 0, 0));
        Ok(self.request(verb::JOURNAL_INFO, &request)?.reply.journal)
    }

    /// Removes a session's transcript — the deliberate end of a pane.
    ///
    /// Routed through superd rather than unlinked here because superd may still hold the file open,
    /// and on POSIX an unlink under an open writer is not an error: it is a pane journaling the
    /// rest of its life into an inode nobody can ever open again.
    pub fn journal_delete(&self, directory: &str, session_id: &str) {
        let mut request = Request::new(self.allocate_id(), verb::JOURNAL_DELETE);
        request.journal = Some(journal_request(directory, session_id, 0, 0));
        self.dispatch(&request);
    }

    /// Bounds the orphans: unlinks transcripts past `max_age_seconds` or past the `keep_newest`
    /// newest. The age and the count are hostd's policy; which files a live pane is still writing
    /// is superd's knowledge, and it is the one thing a sweep must not get wrong.
    pub fn journal_sweep(&self, directory: &str, max_age_seconds: u64, keep_newest: usize) {
        let mut request = Request::new(self.allocate_id(), verb::JOURNAL_SWEEP);
        request.journal = Some(journal_request(directory, "", max_age_seconds, keep_newest));
        self.dispatch(&request);
    }

    /// The pane is closed for good.
    ///
    /// NEVER on hostd shutdown: a hostd that exits must RELINQUISH its panes, or the restart takes
    /// every running agent with it.
    ///
    /// # Errors
    /// superd's own refusal. The pane is still out there when this fails.
    pub fn release(&self, pane_id: &str, kill: bool) -> Result<(), ClientError> {
        self.forget_sink(pane_id);
        self.forget_exit_handler(pane_id);
        let mut request = Request::new(self.allocate_id(), verb::RELEASE);
        request.release = Some(slopdesk_superwire::protocol::ReleaseRequest {
            pane_id: pane_id.to_owned(),
            kill,
        });
        self.request(verb::RELEASE, &request).map(|_answer| ())
    }

    // MARK: Request plumbing

    /// The two block-reading verbs that share one request shape.
    fn block_read(
        &self,
        which: &str,
        pane_id: &str,
        limit: usize,
    ) -> Result<Option<BlocksReply>, ClientError> {
        let mut request = Request::new(self.allocate_id(), which);
        request.block_read = Some(slopdesk_superwire::protocol::BlockReadRequest {
            pane_id: pane_id.to_owned(),
            limit,
        });
        Ok(self.request(which, &request)?.reply.blocks)
    }

    /// The two verbs that answer with a pane record and a master descriptor.
    fn pane_and_descriptor(
        &self,
        which: &str,
        request: &Request,
    ) -> Result<(PaneRecord, OwnedFd), ClientError> {
        let answer = self.request(which, request)?;
        let record = answer.reply.pane.ok_or(ClientError::MalformedReply)?;
        let descriptor = answer.descriptor.ok_or(ClientError::MissingDescriptor)?;
        Ok((record, descriptor))
    }

    fn allocate_id(&self) -> u64 {
        self.next_request_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Queues a request nobody will wait for.
    ///
    /// The id is still allocated and still unique — superd answers every request, and rule 3 of the
    /// skew contract depends on that staying true — but no waiter is registered, so the reply finds
    /// no channel and is dropped where it lands.
    fn dispatch(&self, request: &Request) {
        let Some(body) = request.encode() else {
            return;
        };
        let Ok(queue) = self.outbound.lock() else {
            return;
        };
        if let Some(sender) = queue.as_ref() {
            drop(sender.send(Outbound { body, written: None }));
        }
    }

    /// Sends a request and parks until its reply comes back.
    ///
    /// Two waits, in order: for the bytes to LEAVE, so a broken socket is reported here rather than
    /// swallowed, and then for the reply. Neither has a timeout, and that is deliberate — superd
    /// answers every verb synchronously and a dropped socket wakes every waiter, so a hang here
    /// means superd is wedged. A timeout would only turn a visible hang into a second shell forked
    /// for the same pane.
    ///
    /// Never called from the reader thread: the reply can only arrive on it.
    fn request(&self, which: &str, request: &Request) -> Result<Answer, ClientError> {
        let body = request.encode().ok_or(ClientError::MalformedReply)?;
        let (answered, answer) = channel();
        {
            let Ok(mut waiters) = self.waiters.lock() else {
                return Err(ClientError::NotConnected);
            };
            drop(waiters.insert(request.id, answered));
        }

        let (written, write_result) = channel();
        let queued = {
            let Ok(queue) = self.outbound.lock() else {
                return Err(ClientError::NotConnected);
            };
            queue.as_ref().is_some_and(|sender| {
                sender
                    .send(Outbound {
                        body,
                        written: Some(written),
                    })
                    .is_ok()
            })
        };
        if !queued {
            self.forget_waiter(request.id);
            return Err(ClientError::NotConnected);
        }
        match write_result.recv() {
            Ok(Ok(())) => (),
            Ok(Err(error)) => {
                self.forget_waiter(request.id);
                return Err(ClientError::Link(error));
            },
            Err(_disconnected) => {
                self.forget_waiter(request.id);
                return Err(ClientError::NotConnected);
            },
        }

        // The sender is dropped when the connection tears down, so this ends either with a reply or
        // with a socket that is gone.
        let answer = answer.recv().map_err(|_disconnected| ClientError::NotConnected)?;
        classify(which, answer)
    }

    fn forget_waiter(&self, id: u64) {
        if let Ok(mut waiters) = self.waiters.lock() {
            drop(waiters.remove(&id));
        }
    }

    fn forget_sink(&self, pane_id: &str) {
        if let Ok(mut sinks) = self.sinks.lock() {
            drop(sinks.remove(pane_id));
        }
    }

    /// The sink for a pane, lifted out from under the lock.
    ///
    /// Cloned out rather than called in place: a sink re-enters this client — `unsubscribe` from
    /// inside an ingest is ordinary — and calling it while holding this lock would deadlock on the
    /// second acquisition.
    fn sink_for(&self, pane_id: &str) -> Option<Arc<dyn PaneSink>> {
        self.sinks.lock().ok()?.get(pane_id).map(Arc::clone)
    }

    // MARK: The threads

    /// Writes every queued frame, in the order it was queued, on a thread that never reads.
    fn write_loop(&self, inbox: &Receiver<Outbound>) {
        while let Ok(item) = inbox.recv() {
            let result = self.connection.send(&item.body);
            let failed = result.is_err();
            if let Some(report) = item.written {
                let _dropped = report.send(result);
            }
            if failed {
                // A frame that failed mid-write leaves the stream desynchronised, so there is
                // nothing to retry onto. Ending the connection is what turns that into every
                // waiter's `NotConnected` instead of silence.
                self.connection.close();
                return;
            }
        }
    }

    /// Reads every frame superd sends and routes it: pane output to its sink, a notification to the
    /// observer, a reply to whoever is parked on its id.
    fn read_loop(&self) {
        loop {
            let frame = match self.connection.receive() {
                Ok(frame) => frame,
                Err(_ended) => break,
            };
            // Output is not JSON and never carries a descriptor. The tag is the whole
            // discriminator, and decoding one as a reply would be a guaranteed failure on the
            // hottest path this socket has.
            match frame.tag {
                slopdesk_superwire::TAG_OUTPUT => self.deliver_output(&frame.body),
                slopdesk_superwire::TAG_SNIFF => self.deliver_sniff(&frame.body),
                slopdesk_superwire::TAG_BLOCKS => self.deliver_blocks(&frame.body),
                _ => self.deliver_json(&frame.body, frame.descriptor),
            }
        }
        self.tear_down();
    }

    /// Routes one pane-output frame, with the payload still borrowed out of the frame.
    fn deliver_output(&self, body: &[u8]) {
        let Some((pane_id, offset, payload)) = slopdesk_superwire::parse_output(body) else {
            self.observer.log(&format!(
                "supervisor: dropped an undecodable output frame ({} bytes)",
                body.len(),
            ));
            return;
        };
        // No sink is ordinary rather than an error: `unsubscribe` drops it before the verb reaches
        // superd, so the frames already in flight land here.
        if let Some(sink) = self.sink_for(pane_id) {
            sink.bytes(offset, payload);
        }
    }

    fn deliver_sniff(&self, body: &[u8]) {
        let Some((pane_id, json)) = slopdesk_superwire::parse_pane_json(body) else {
            self.observer
                .log("supervisor: dropped an undecodable sniff frame");
            return;
        };
        let Some(events) = slopdesk_superwire::sniffwire::decode_batch(json) else {
            self.observer.log(&format!(
                "supervisor: dropped a sniff batch for pane {pane_id} that would not decode",
            ));
            return;
        };
        if let Some(sink) = self.sink_for(pane_id) {
            sink.sniffed(&events);
        }
    }

    fn deliver_blocks(&self, body: &[u8]) {
        let Some((pane_id, json)) = slopdesk_superwire::parse_pane_json(body) else {
            self.observer
                .log("supervisor: dropped an undecodable blocks frame");
            return;
        };
        let Some(events) = slopdesk_superwire::blockwire::decode_batch(json) else {
            self.observer.log(&format!(
                "supervisor: dropped a blocks batch for pane {pane_id} that would not decode",
            ));
            return;
        };
        if let Some(sink) = self.sink_for(pane_id) {
            sink.blocks(&events);
        }
    }

    /// Routes one control frame: a notification to the observer, anything else to its waiter.
    fn deliver_json(&self, body: &[u8], descriptor: Option<OwnedFd>) {
        let Some(reply) = Reply::decode(body) else {
            // Loud, because the id went with it: a waiter registered under that id is now parked on
            // a reply that has already been delivered and thrown away, and this line is the only
            // trace of why. An unknown STATUS decodes to `Unrecognised`, so anything landing here
            // is a shape rather than a vocabulary.
            self.observer.log(&format!(
                "supervisor: dropped an undecodable reply frame ({} bytes)",
                body.len(),
            ));
            return;
        };
        if reply.id == slopdesk_superwire::protocol::NOTIFICATION_ID {
            self.deliver_notification(&reply, descriptor);
            return;
        }
        let waiter = self
            .waiters
            .lock()
            .ok()
            .and_then(|mut waiters| waiters.remove(&reply.id));
        // No waiter is the un-awaited case, and it is ordinary. Dropping the answer here closes any
        // descriptor with it, which is the right answer for a reply nobody asked to be told about.
        if let Some(waiter) = waiter {
            drop(waiter.send(Answer { reply, descriptor }));
        }
    }

    fn deliver_notification(&self, reply: &Reply, descriptor: Option<OwnedFd>) {
        match reply.event.as_deref() {
            Some(event::CONNECTION) => {
                self.deliver_connection(
                    reply.connection.as_ref().map(|notice| notice.kind.as_str()),
                    descriptor,
                );
            },
            Some(event::EXITED) => {
                let Some(notice) = reply.exited.as_ref() else {
                    return;
                };
                let sink = self
                    .sinks
                    .lock()
                    .ok()
                    .and_then(|mut sinks| sinks.remove(&notice.pane_id));
                let handler = self
                    .exit_handlers
                    .lock()
                    .ok()
                    .and_then(|mut handlers| handlers.remove(&notice.pane_id));
                // `ended` FIRST, and that ordering is the whole of hostd's EOF signal. superd
                // drains the pane's pump to EOF before it broadcasts `exited`, and both travel this
                // one socket in order, so by the time this line runs every byte the shell wrote has
                // already gone through the sink.
                if let Some(sink) = sink {
                    sink.ended();
                }
                if let Some(handler) = handler {
                    handler(notice.code);
                }
                self.observer.exited(notice);
            },
            _ => (),
        }
    }

    /// Hands one accepted child connection to the observer, or closes it.
    ///
    /// Every path here disposes of the descriptor exactly once. A `connection` event with no
    /// descriptor, or a kind this build cannot name, is a peer we do not understand — and a leaked
    /// fd per bad frame is the specific harm.
    fn deliver_connection(&self, kind: Option<&str>, descriptor: Option<OwnedFd>) {
        let Some(descriptor) = descriptor else {
            self.observer
                .log("supervisor: a connection event arrived with no descriptor — ignoring");
            return;
        };
        let Some(kind) = kind.and_then(ListenerKind::from_wire) else {
            self.observer.log(
                "supervisor: a connection arrived for a listener kind this build has no name for — closing \
                 the descriptor; superd is newer than this hostd",
            );
            return;
        };
        self.observer.connection(kind, descriptor);
    }

    /// Ends the connection once, and wakes everyone waiting on it.
    ///
    /// Idempotent through `live`: the reader reaches it when the socket dies and the owner reaches
    /// it through [`SupervisorClient::disconnect`], and both are ordinary.
    fn tear_down(&self) {
        if self
            .live
            .compare_exchange(true, false, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        self.connection.close();
        // Taking the queue ends the writer thread: its `recv` returns once the last sender is gone.
        if let Ok(mut queue) = self.outbound.lock() {
            drop(queue.take());
        }
        // Dropping every waiter's sender fails every parked request rather than leaving it on a
        // reply that is never coming.
        if let Ok(mut waiters) = self.waiters.lock() {
            waiters.clear();
        }
        if let Ok(mut sinks) = self.sinks.lock() {
            sinks.clear();
        }
        if let Ok(mut handlers) = self.exit_handlers.lock() {
            handlers.clear();
        }
        // Taken out under the lock and CALLED outside it. Every one of these is another object's
        // "I have lost my child" latch, and one of them re-entering this client — a service asking
        // whether it is still connected — under the handler lock would be a cycle the first
        // disconnect finds.
        let dropped: Vec<Arc<dyn Fn() + Send + Sync>> = self
            .disconnect_handlers
            .lock()
            .map(|mut handlers| handlers.drain().map(|(_, handler)| handler).collect())
            .unwrap_or_default();
        self.observer
            .log("supervisor: connection to superd lost — panes stay alive, control is gone");
        self.observer.disconnected();
        for handler in dropped {
            handler();
        }
    }
}

/// What a reply's status means to the caller of `which`.
///
/// The fourth status is the point: a word a newer superd invented is reported as a refusal, never
/// as success and never as silence — silence is what a throw during decode used to buy, which left
/// the waiter parked and the pane unopened.
fn classify(which: &str, answer: Answer) -> Result<Answer, ClientError> {
    match answer.reply.status {
        Status::Ok => Ok(answer),
        Status::Unsupported => {
            Err(ClientError::Unsupported {
                verb: which.to_owned(),
                message: answer.reply.message.unwrap_or_default(),
            })
        },
        Status::Error => {
            Err(ClientError::Refused(
                answer
                    .reply
                    .message
                    .unwrap_or_else(|| format!("superd refused {which}")),
            ))
        },
        Status::Unrecognised => {
            Err(ClientError::Refused(answer.reply.message.unwrap_or_else(|| {
                format!(
                    "superd answered {which} with a status this hostd does not know — it is newer than this \
                     build"
                )
            })))
        },
    }
}

/// The three journal verbs share one request shape and fill different halves of it.
fn journal_request(
    directory: &str,
    session_id: &str,
    max_age_seconds: u64,
    keep_newest: usize,
) -> slopdesk_superwire::protocol::JournalRequest {
    slopdesk_superwire::protocol::JournalRequest {
        directory: directory.to_owned(),
        session_id: session_id.to_owned(),
        max_age_seconds,
        keep_newest,
    }
}

/// The handshake, kept as the fields anyone actually reads.
fn handshake_of(hello: HelloReply) -> Handshake {
    Handshake {
        superd_pid: hello.superd_pid,
        hook_socket_path: hello.hook_socket_path,
        control_socket_path: hello.control_socket_path,
        negotiated_minor: hello.version_minor.min(VERSION_MINOR),
        build_version: hello.build_version,
    }
}
