//! The accept loop and verb dispatch.
//!
//! One thread per connection, blocking reads. There is normally exactly one connection — hostd —
//! and the concurrency that matters is the reaper threads, not this. An event loop here would buy
//! nothing and cost the property that makes this daemon auditable: every code path is a straight
//! line you can read top to bottom.
//!
//! ## `hello` is mandatory and first
//! A connection that has not completed the handshake gets [`protocol::Status::Error`] for every
//! verb. Not because of security — the socket is `0600` in a per-user `$TMPDIR`, and the security
//! model is the WireGuard mesh, not app-layer auth — but because the version check is the only
//! thing standing between an old superd and a new hostd's assumptions (`docs/51` §3).

use std::collections::{HashMap, HashSet};
use std::io;
use std::os::fd::{AsFd, AsRawFd as _, BorrowedFd, OwnedFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::blocks::BlockEvent;
use crate::journal::JournalStore;
use crate::listeners::{ChildListeners, Claims, ConnectionDeliverer};
use crate::paths::{self, Paths};
use crate::protocol::{
    BlocksReply, ExitedNotice, HelloReply, JournalReply, OpenBlock, Reply, Request, StreamPosition,
    VERSION_MAJOR, VERSION_MINOR, verb,
};
use crate::pump::Pump;
use crate::registry::{ClientID, Registry, RegistryError};
use crate::sniffer::SniffEvent;
use crate::{frame, listeners, ring};

/// One connected client.
///
/// ## The lock guards the subscription set *because* it guards the wire
/// Three threads write to one socket — the connection thread answering requests, a reaper pushing
/// `exited`, and every pane's pump pushing output — so a lock is needed regardless, or two frames
/// interleave and the stream never resynchronises.
///
/// Making the SUBSCRIPTIONS the thing that lock guards, rather than `()`, buys the ordering
/// property that subscribing correctly depends on. `subscribe` snapshots the ring, registers the
/// pane and writes the backlog all inside one critical section, so a concurrent pump publish
/// either happens entirely before it — and is therefore already in the snapshot — or entirely
/// after, and lands behind the backlog. With two separate locks there is a window where a live
/// chunk overtakes the backlog it belongs after, and the receiver splices its terminal stream out
/// of order.
///
/// **The snapshot must be taken inside the same hold**, which is why `subscribe` takes a closure
/// rather than a ready-made [`ring::Resume`]. Taking it outside is not a smaller version of the
/// same guarantee, it is no guarantee at all, in the other direction: a chunk published between the
/// snapshot and the registration is past the snapshot's head AND not yet on this connection's wire
/// set, so `send_output` skips it and nobody ever sends it. The subscriber's next frame arrives at
/// an offset beyond what it was promised, and up to one [`crate::pump::READ_CHUNK_BYTES`] read of
/// the pane's output is gone for good — including from the scrollback journal hostd writes from it.
///
/// ## Lock order
/// `wire` → the registry's pane map → a pane's ring, and never the reverse. The publish path takes
/// the ring alone (`Worker::publish` releases it before calling the sink) and then `clients` →
/// `wire`, so nothing holds a ring or the pane map while waiting for a wire. Keep it that way: the
/// closure below runs with `wire` held, and if the registry ever started calling back into a
/// connection while holding its pane map, this would become a cycle.
#[derive(Debug)]
struct Connection {
    stream: UnixStream,
    wire: Mutex<HashSet<String>>,
}

/// What one [`Connection::subscribe`] did.
enum Subscribed {
    /// Registered, replied, and the backlog flushed behind the reply.
    Served(StreamPosition),
    /// The registry could not resume that pane. Nothing was registered and nothing was written, so
    /// the caller still owes the client an error reply.
    Rejected(RegistryError),
    /// The reply or the backlog did not leave. The connection is desynchronised or dead.
    Broken(String),
}

impl Connection {
    fn send(&self, reply: &Reply, descriptor: Option<BorrowedFd<'_>>) -> Result<(), String> {
        let body = serde_json::to_vec(reply).map_err(|error| error.to_string())?;
        let guard = self
            .wire
            .lock()
            .map_err(|_ignored| "write lock poisoned".to_owned())?;
        let result = frame::write(self.stream.as_fd(), &body, descriptor).map_err(|error| error.to_string());
        drop(guard);
        result
    }

    /// Snapshots the ring, registers the subscription and flushes the backlog — one hold of the
    /// wire lock for all three, which is what makes the handover atomic against the live stream.
    ///
    /// `resume` is called with the lock held; see the type docs for why it cannot be hoisted out.
    /// `sniff_backlog` is called with the same hold, on the bytes `resume` just handed back.
    fn subscribe(
        &self,
        request_id: u64,
        pane_id: &str,
        requested: u64,
        resume: impl FnOnce() -> Result<(ring::Resume, bool), RegistryError>,
        sniff_backlog: impl FnOnce(&[u8]) -> Option<Vec<SniffEvent>>,
    ) -> Subscribed {
        let Ok(mut guard) = self.wire.lock() else {
            return Subscribed::Broken("write lock poisoned".to_owned());
        };
        let (resumed, ended) = match resume() {
            Ok(answer) => answer,
            // Nothing registered, nothing written — the lock goes back untouched and the caller
            // sends the error itself, outside this hold.
            Err(error) => {
                drop(guard);
                return Subscribed::Rejected(error);
            },
        };
        let position = StreamPosition {
            start: resumed.start,
            head: resumed.head,
            lossy: resumed.is_lossy(requested),
            ended,
        };
        let outcome = serde_json::to_vec(&Reply {
            stream: Some(position),
            ..Reply::ok(request_id)
        })
        .map_err(|error| error.to_string())
        .and_then(|body| {
            let _ignored = guard.insert(pane_id.to_owned());
            frame::write(self.stream.as_fd(), &body, None).map_err(|error| error.to_string())
        })
        .and_then(|()| self.write_backlog(pane_id, &resumed, sniff_backlog));
        drop(guard);
        match outcome {
            Ok(()) => Subscribed::Served(position),
            Err(error) => Subscribed::Broken(error),
        }
    }

    /// Sends the retained bytes as as many output frames as it takes.
    ///
    /// Caller holds the wire lock. Splitting rather than sending one frame is not defensive
    /// rounding: the ring's default capacity and [`frame::MAX_BODY_BYTES`] are the same number, so
    /// a pane that filled its ring while hostd was away has a backlog that cannot fit in one frame
    /// once the per-frame header is counted — see [`frame::max_output_payload`]. Each chunk carries
    /// its own absolute offset, so the receiver reassembles by the numbers rather than by trust.
    fn write_backlog(
        &self,
        pane_id: &str,
        resumed: &ring::Resume,
        sniff_backlog: impl FnOnce(&[u8]) -> Option<Vec<SniffEvent>>,
    ) -> Result<(), String> {
        // BEFORE the first byte, so the receiver can attach the batch to the chunk that follows —
        // the same rule the live path keeps, and the reason a sniff frame precedes its output.
        // One batch for the whole backlog rather than one per split frame: the split is a frame-size
        // artefact, and the events are order-only facts that no split can reorder.
        if let Some(events) = sniff_backlog(&resumed.bytes)
            && !events.is_empty()
            && let Ok(json) = serde_json::to_vec(&SniffBatch { events: &events })
        {
            frame::write_sniff(self.stream.as_fd(), pane_id, &json).map_err(|error| error.to_string())?;
        }
        let limit = frame::max_output_payload(pane_id).max(1);
        let mut offset = resumed.start;
        for chunk in resumed.bytes.chunks(limit) {
            frame::write_output(self.stream.as_fd(), pane_id, offset, chunk)
                .map_err(|error| error.to_string())?;
            // Absolute, and the ring's own offsets are `u64` — a saturating add here would be a
            // silent lie about where the next chunk sits, so it stays a checked one.
            offset = u64::try_from(chunk.len())
                .ok()
                .and_then(|written| offset.checked_add(written))
                .ok_or_else(|| "pane output offset overflowed u64".to_owned())?;
        }
        Ok(())
    }

    /// Drops a subscription. Returns whether this connection had one.
    fn unsubscribe(&self, pane_id: &str) -> bool {
        self.wire.lock().is_ok_and(|mut guard| {
            let had = guard.remove(pane_id);
            drop(guard);
            had
        })
    }

    /// Everything this connection is following, for the disconnect sweep.
    fn subscriptions(&self) -> Vec<String> {
        self.wire.lock().map_or_else(
            |_poisoned| Vec::new(),
            |guard| {
                let names = guard.iter().cloned().collect();
                drop(guard);
                names
            },
        )
    }

    /// One chunk of a pane's output, sent only if this connection asked for that pane.
    ///
    /// The subscription test happens INSIDE the lock; see the type docs for why that is the whole
    /// point rather than an incidental detail.
    fn send_output(
        &self,
        pane_id: &str,
        offset: u64,
        bytes: &[u8],
        sniff: Option<&[u8]>,
        blocks: Option<&[u8]>,
    ) {
        let Ok(guard) = self.wire.lock() else {
            return;
        };
        if guard.contains(pane_id) {
            // BEFORE the bytes, under the same lock. superd sends a sniff frame only when a chunk
            // actually contained something, so the receiver cannot wait to see whether one is
            // coming — it can only hold what it has already been given. Events first means the
            // receiver latches them and hands them on WITH the chunk they were found in, which is
            // the pairing hostd's control stream has always had.
            if let Some(json) = sniff {
                let _ignored = frame::write_sniff(self.stream.as_fd(), pane_id, json);
            }
            // Sniff then blocks then bytes, matching the order hostd itself used to run the two
            // readers in — the block tap saw a chunk the sniffer had already been over.
            if let Some(json) = blocks {
                let _ignored = frame::write_blocks(self.stream.as_fd(), pane_id, json);
            }
            // A failed write means this client is gone; its connection thread will notice and clean
            // up, and blocking that discovery on a log line here would help nobody.
            let _ignored = frame::write_output(self.stream.as_fd(), pane_id, offset, bytes);
        }
        drop(guard);
    }
}

/// superd's server.
#[derive(Debug)]
pub struct Server {
    registry: Arc<Registry>,
    paths: Paths,
    clients: Arc<Mutex<HashMap<ClientID, Arc<Connection>>>>,
    /// Who serves each child-facing listener. Shared with the registry, which reads it to decide
    /// whether a socket path may be advertised into a spawned child's environment.
    claims: Arc<Claims>,
    /// The on-disk transcripts. Shared with the registry: it opens and closes writers with the
    /// panes, and the three journal verbs here read, remove and sweep the same table.
    journals: Arc<JournalStore>,
    next_client: AtomicU64,
}

impl Server {
    /// Builds a server and the registry it serves.
    ///
    /// `claims` comes from [`ChildListeners::claims`] so it already knows which binds succeeded —
    /// which is why the listeners are bound before this is called, not after.
    #[must_use]
    pub fn new(paths: Paths, claims: Claims) -> Arc<Self> {
        let clients: Arc<Mutex<HashMap<ClientID, Arc<Connection>>>> = Arc::new(Mutex::new(HashMap::new()));
        let fanout = Arc::clone(&clients);
        let notify = Arc::new(move |notice: ExitedNotice| {
            broadcast_exit(&fanout, notice);
        });
        let streaming = Arc::clone(&clients);
        let journals = Arc::new(JournalStore::start());
        let sink = Arc::new(
            move |pane_id: &str, offset: u64, bytes: &[u8], events: &[SniffEvent], blocks: &[BlockEvent]| {
                fan_out_output(&streaming, pane_id, offset, bytes, events, blocks);
            },
        );
        let claims = Arc::new(claims);
        Arc::new(Self {
            registry: Arc::new(Registry::new(
                paths.clone(),
                Arc::clone(&claims),
                notify,
                sink,
                ring::capacity_from_env(),
                Arc::clone(&journals),
            )),
            paths,
            clients,
            claims,
            journals,
            next_client: AtomicU64::new(1),
        })
    }

    /// Starts the accept threads for the child-facing sockets.
    ///
    /// Each accepted connection is handed to whichever client claimed that kind, as an `SCM_RIGHTS`
    /// descriptor on a [`crate::protocol::event::CONNECTION`] push. superd reads none of it.
    pub fn serve_children(self: &Arc<Self>, listeners: ChildListeners) {
        let server = Arc::clone(self);
        let deliver: ConnectionDeliverer = Arc::new(move |kind, stream: UnixStream| {
            server.hand_over(kind, &stream);
        });
        listeners.serve(&deliver);
    }

    /// Passes one accepted child connection to its claimant, or closes it.
    ///
    /// Closing is the right answer for an unclaimed kind and it must be immediate: the peer is a
    /// hook binary that blocks its agent until its write completes, so `EPIPE` now beats a queue it
    /// might wait seconds to leave. See the [`crate::listeners`] module docs for what that costs.
    ///
    /// The stream is borrowed, not consumed, purely so the descriptor is unambiguously still open
    /// at `sendmsg` time; the caller's drop closes our copy once the receiver has its own.
    fn hand_over(&self, kind: &'static str, stream: &UnixStream) {
        let Some(holder) = self.claims.holder(kind) else {
            eprintln!("superd: a {kind} connection arrived with no hostd serving it — closing");
            return;
        };
        let Some(connection) = self.client(holder) else {
            eprintln!("superd: client {holder} claims {kind} but is gone — closing the connection");
            return;
        };
        if let Err(error) = connection.send(&Reply::connection(kind), Some(listeners::descriptor_of(stream)))
        {
            eprintln!("superd: could not hand a {kind} connection to client {holder}: {error}");
        }
    }

    fn client(&self, id: ClientID) -> Option<Arc<Connection>> {
        let clients = self.clients.lock().ok()?;
        let found = clients.get(&id).map(Arc::clone);
        drop(clients);
        found
    }

    /// Binds the control socket, `0600`.
    ///
    /// Unlinks a stale socket file first. That is safe ONLY because `main` holds the exclusive
    /// `flock` before calling this — without the lock, unlinking would let a second superd steal
    /// the address from a live incumbent, and the incumbent is the process holding every pane's
    /// master fd. Those panes would survive but become permanently unreachable, which is worse
    /// than either alternative.
    ///
    /// # Errors
    /// A path that would not fit `sun_path`, or the `bind`/`listen` errno.
    pub fn bind(&self) -> io::Result<UnixListener> {
        paths::validate(&self.paths.control).map_err(io::Error::other)?;
        // A missing file is the normal case; only a real failure matters, and `bind` reports that.
        let _ignored = std::fs::remove_file(&self.paths.control);
        let listener = UnixListener::bind(&self.paths.control)?;
        slopdesk_posix::pty::set_cloexec(listener.as_raw_fd());
        std::fs::set_permissions(
            &self.paths.control,
            <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o600),
        )?;
        Ok(listener)
    }

    /// Accepts forever, one thread per connection. Never returns under normal operation.
    ///
    /// Every accepted socket is widened first — see [`SOCKET_BUFFER_BYTES`].
    ///
    /// # Errors
    /// Only a listener-level failure. A single connection failing is logged and dropped — one bad
    /// client must not take down a daemon holding live panes.
    pub fn serve(self: &Arc<Self>, listener: &UnixListener) -> io::Result<()> {
        eprintln!(
            "superd: listening on {} (protocol {VERSION_MAJOR}.{VERSION_MINOR}, pid {})",
            self.paths.control.display(),
            std::process::id()
        );
        loop {
            let stream = match listener.accept() {
                Ok((stream, _address)) => stream,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            };
            // A hostd's control connection lives as long as that hostd, i.e. across every pane it
            // ever spawns. Inherited, it would keep superd's peer-EOF from ever arriving.
            slopdesk_posix::pty::set_cloexec(stream.as_raw_fd());
            slopdesk_posix::sock::widen_buffers(stream.as_raw_fd(), SOCKET_BUFFER_BYTES);
            let id = self.next_client.fetch_add(1, Ordering::Relaxed);
            let connection = Arc::new(Connection {
                stream,
                wire: Mutex::new(HashSet::new()),
            });
            if let Ok(mut clients) = self.clients.lock() {
                let previous = clients.insert(id, Arc::clone(&connection));
                drop(clients);
                debug_assert!(previous.is_none(), "client ids are monotonic");
            }

            let server = Arc::clone(self);
            let spawned = std::thread::Builder::new()
                .name(format!("superd-client-{id}"))
                .spawn(move || {
                    server.run_connection(id, &connection);
                });
            if let Err(error) = spawned {
                eprintln!("superd: could not start a thread for client {id}: {error}");
                self.forget_client(id);
            }
        }
    }

    /// One connection's whole life.
    fn run_connection(&self, id: ClientID, connection: &Connection) {
        let mut greeted = false;
        loop {
            let incoming = match frame::read(connection.stream.as_fd()) {
                Ok(incoming) => incoming,
                Err(frame::FrameError::PeerClosed) => break,
                Err(error) => {
                    eprintln!("superd: client {id} framing error: {error}");
                    break;
                },
            };
            // hostd never sends a descriptor; one arriving is a peer we do not understand. Close it
            // rather than leak it.
            drop(incoming.descriptor);

            let Ok(request) = serde_json::from_slice::<Request>(&incoming.body) else {
                // Validate-then-drop, the same rule every untrusted decode in this repo follows.
                eprintln!("superd: client {id} sent an undecodable request");
                continue;
            };
            let Some((reply, descriptor)) = self.dispatch(id, &request, connection, &mut greeted) else {
                // `subscribe` answers on the wire itself, because its reply and the backlog that
                // follows have to leave inside one critical section.
                continue;
            };
            // The `spawn`/`adopt` duplicate lives exactly as long as this statement needs it to:
            // borrowed for the `sendmsg` that copies it into hostd, then dropped at the end of the
            // iteration. superd's own master, the one in the registry, is a different descriptor
            // and is not touched by either half.
            if let Err(error) = connection.send(&reply, descriptor.as_ref().map(AsFd::as_fd)) {
                eprintln!("superd: client {id} write failed: {error}");
                break;
            }
        }

        // The connection is gone. Panes are NOT — this is the whole design in three lines.
        // Its subscriptions go with it, and each one may be releasing a pause: hostd dying mid-flood
        // is exactly when one is outstanding, and a pause nobody is left to lift would freeze the
        // pane superd had just carried through the restart.
        for pane_id in connection.subscriptions() {
            self.registry.unsubscribed(&pane_id);
        }
        // Its listener claims go too, and with them the promise those addresses carried: a child
        // spawned during the gap is told nothing rather than the name of a socket no process is
        // reading. Only the claims this client still holds — its successor may already have taken
        // them, which is the ordinary restart order.
        self.claims.release_all(id);
        self.forget_client(id);
        match self.registry.detach_client(id) {
            Ok(0) => eprintln!("superd: client {id} disconnected, holding no panes"),
            Ok(count) => {
                eprintln!("superd: client {id} disconnected — {count} pane(s) stay alive and unattached");
            },
            Err(error) => eprintln!("superd: client {id} disconnected, detach failed: {error}"),
        }
    }

    fn forget_client(&self, id: ClientID) {
        if let Ok(mut clients) = self.clients.lock() {
            let _ignored = clients.remove(&id);
            drop(clients);
        }
    }

    /// One verb.
    ///
    /// Returns the reply and, for `spawn`/`adopt`, a master duplicate to attach.
    ///
    /// Owned, and owned by this function's caller: `SCM_RIGHTS` installs a *separate* descriptor in
    /// hostd, so sending it neither transfers nor consumes this one, and the registry keeps its own
    /// copy regardless. What that ownership buys is the guarantee the fd cannot be closed and
    /// reissued underneath the send — see [`crate::registry::Registry::spawn`].
    fn dispatch(
        &self,
        id: ClientID,
        request: &Request,
        connection: &Connection,
        greeted: &mut bool,
    ) -> Option<(Reply, Option<OwnedFd>)> {
        if request.verb == verb::HELLO {
            return Some((self.hello(id, request, greeted), None));
        }
        if !*greeted {
            return Some((Reply::error(request.id, "say hello before anything else"), None));
        }

        Some(match request.verb.as_str() {
            verb::SPAWN => self.spawn(id, request),
            verb::ADOPT => self.adopt(id, request),
            verb::LIST => (self.list(request), None),
            verb::SIGNAL => (self.signal(request), None),
            verb::RESIZE => (self.resize(request), None),
            verb::RELEASE => (self.release(request), None),
            verb::SUBSCRIBE => return self.subscribe(id, request, connection),
            verb::UNSUBSCRIBE => (self.unsubscribe(request, connection), None),
            verb::FORGET_TITLE => (self.forget_title(request), None),
            verb::PAUSE => (self.pause(request), None),
            verb::LISTEN => (self.listen(id, request), None),
            verb::BLOCK_OUTPUT => (self.block_output(request), None),
            verb::BLOCK_SNAPSHOT => (self.block_snapshot(request), None),
            verb::BLOCK_CONTROL => (self.block_control(request), None),
            verb::JOURNAL_INFO => (self.journal_info(request), None),
            verb::JOURNAL_DELETE => (self.journal_delete(request), None),
            verb::JOURNAL_SWEEP => (self.journal_sweep(request), None),
            // Rule 3: an unknown verb is answered, not dropped, so a newer hostd can discover this
            // superd's vocabulary by asking and fall back on its own terms.
            unknown => {
                (
                    Reply::unsupported(
                        request.id,
                        format!("superd {VERSION_MAJOR}.{VERSION_MINOR} does not know '{unknown}'"),
                    ),
                    None,
                )
            },
        })
    }

    /// Starts a client's output stream for one pane.
    ///
    /// Returns `None` in the success case because the answer has already gone out: the reply and
    /// the backlog that follows it must leave inside one hold of the connection's wire lock, or a
    /// live chunk can overtake the backlog it belongs after. See [`Connection::subscribe`].
    fn subscribe(
        &self,
        id: ClientID,
        request: &Request,
        connection: &Connection,
    ) -> Option<(Reply, Option<OwnedFd>)> {
        let subscribe = request.subscribe.as_ref()?;
        match connection.subscribe(
            request.id,
            &subscribe.pane_id,
            subscribe.from_offset,
            || self.registry.resume(&subscribe.pane_id, subscribe.from_offset),
            |bytes| {
                self.registry
                    .sniff_backlog(&subscribe.pane_id, bytes, crate::pump::now_ms())
            },
        ) {
            Subscribed::Rejected(error) => Some((Reply::error(request.id, error.to_string()), None)),
            Subscribed::Served(position) => {
                // Only after the frames are out: `subscribed` is a pause-accounting counter, and
                // counting a subscriber whose backlog write failed would leave a phantom holder.
                let _ignored = self.registry.subscribed(&subscribe.pane_id);
                if position.lossy {
                    eprintln!(
                        "superd: client {id} subscribed to pane {} at {} — asked for {}, so {} bytes were \
                         evicted before it got back (raise {})",
                        subscribe.pane_id,
                        position.start,
                        subscribe.from_offset,
                        position.start.saturating_sub(subscribe.from_offset),
                        ring::CAPACITY_ENV_KEY,
                    );
                } else {
                    eprintln!(
                        "superd: client {id} subscribed to pane {} at {} (head {}{})",
                        subscribe.pane_id,
                        position.start,
                        position.head,
                        if position.ended { ", already ended" } else { "" }
                    );
                }
                None
            },
            // The write failed, so the connection is already desynchronised or dead. Saying
            // anything more down it is pointless; the read loop will notice next time round.
            Subscribed::Broken(error) => {
                eprintln!("superd: client {id} subscribe write failed: {error}");
                None
            },
        }
    }

    fn unsubscribe(&self, request: &Request, connection: &Connection) -> Reply {
        let Some(unsubscribe) = request.unsubscribe.as_ref() else {
            return Reply::error(request.id, "unsubscribe without an unsubscribe payload");
        };
        if connection.unsubscribe(&unsubscribe.pane_id) {
            self.registry.unsubscribed(&unsubscribe.pane_id);
        }
        // Always ok, including for a pane that has since exited: "stop sending me this" cannot
        // meaningfully fail, and returning an error for an already-dead pane would make every
        // orderly teardown log a spurious one.
        Reply::ok(request.id)
    }

    fn forget_title(&self, request: &Request) -> Reply {
        let Some(forget) = request.forget_title.as_ref() else {
            return Reply::error(request.id, "forgetTitle without a forgetTitle payload");
        };
        self.registry.forget_title_coalescing(&forget.pane_id);
        // Always ok, for the same reason `unsubscribe` is: an anchor nobody holds cannot fail to be
        // dropped, and a pane that exited between the detector and this line is the common case.
        Reply::ok(request.id)
    }

    /// One finished block's retained output.
    ///
    /// A pane with no tap answers with no `blocks` at all; a tapped pane whose block has been
    /// evicted answers with a `blocks` object and no `output`. The caller needs to tell those
    /// apart: one means the feature is off, the other that the bytes have aged out.
    fn block_output(&self, request: &Request) -> Reply {
        let Some(ask) = request.block_output.as_ref() else {
            return Reply::error(request.id, "blockOutput without a blockOutput payload");
        };
        let answer = self
            .registry
            .read_blocks(&ask.pane_id, |pump| {
                pump.expected_next_block_index()
                    .map(|_tapped| pump.block_output(ask.index))
            })
            .map(|output| {
                BlocksReply {
                    output: output.as_deref().map(crate::blocks::base64),
                    ..BlocksReply::empty()
                }
            });
        Reply {
            blocks: answer,
            ..Reply::ok(request.id)
        }
    }

    /// Where a session's transcript is, and how much of a live stream it already holds.
    ///
    /// The bytes themselves are NOT in the answer. hostd opens the path and hands it to the screen
    /// engine, so a multi-megabyte transcript crosses no socket to be rendered by a third process.
    fn journal_info(&self, request: &Request) -> Reply {
        let Some(ask) = request.journal.as_ref() else {
            return Reply::error(request.id, "journalInfo without a journal payload");
        };
        let answer = self
            .journals
            .info(std::path::Path::new(&ask.directory), &ask.session_id)
            .map(|info| {
                JournalReply {
                    path: info.path.display().to_string(),
                    bytes: info.bytes,
                    rows: info.rows,
                    cols: info.cols,
                    head: info.head,
                }
            });
        Reply {
            journal: answer,
            ..Reply::ok(request.id)
        }
    }

    /// Removes a transcript — the deliberate end of a pane, and the only thing that unlinks one on
    /// purpose.
    fn journal_delete(&self, request: &Request) -> Reply {
        let Some(ask) = request.journal.as_ref() else {
            return Reply::error(request.id, "journalDelete without a journal payload");
        };
        self.journals
            .delete(std::path::Path::new(&ask.directory), &ask.session_id);
        Reply::ok(request.id)
    }

    /// Bounds the orphans. The caller sets the age and the count; superd knows which files a live
    /// pane is still writing, which is the one thing a sweep must not get wrong.
    fn journal_sweep(&self, request: &Request) -> Reply {
        let Some(ask) = request.journal.as_ref() else {
            return Reply::error(request.id, "journalSweep without a journal payload");
        };
        self.journals.sweep(
            std::path::Path::new(&ask.directory),
            std::time::Duration::from_secs(ask.max_age_seconds),
            ask.keep_newest,
        );
        Reply::ok(request.id)
    }

    /// Every block a pane's tap still knows.
    ///
    /// What a client reattaching to a running session is backfilled from: block metadata does not
    /// ride the replayed output stream, so without this the Commands panel comes back empty for a
    /// shell that never stopped.
    fn block_snapshot(&self, request: &Request) -> Reply {
        let Some(ask) = request.block_read.as_ref() else {
            return Reply::error(request.id, "blockSnapshot without a blockRead payload");
        };
        let answer = self
            .registry
            .read_blocks(&ask.pane_id, Pump::blocks_snapshot)
            .map(|snapshot| {
                BlocksReply {
                    snapshot: Some(snapshot),
                    ..BlocksReply::empty()
                }
            });
        Reply {
            blocks: answer,
            ..Reply::ok(request.id)
        }
    }

    /// The agent-control read: recent blocks with their bytes, the running one, and the baseline.
    ///
    /// Three facts in one round trip because `last-output` and `run --wait` want them together and
    /// they are only consistent with each other if they are read under one hold of the tap.
    fn block_control(&self, request: &Request) -> Reply {
        let Some(ask) = request.block_read.as_ref() else {
            return Reply::error(request.id, "blockControl without a blockRead payload");
        };
        let answer = self.registry.read_blocks(&ask.pane_id, |pump| {
            let recent = pump.recent_blocks(ask.limit)?;
            Some(BlocksReply {
                recent: Some(recent),
                open: pump.open_block().map(|open| {
                    OpenBlock {
                        command_text: open.command_text,
                        output_len: u32::try_from(open.output.len()).unwrap_or(u32::MAX),
                    }
                }),
                next_index: pump.expected_next_block_index(),
                ..BlocksReply::empty()
            })
        });
        Reply {
            blocks: answer,
            ..Reply::ok(request.id)
        }
    }

    fn pause(&self, request: &Request) -> Reply {
        let Some(pause) = request.pause.as_ref() else {
            return Reply::error(request.id, "pause without a pause payload");
        };
        self.registry
            .set_paused(&pause.pane_id, pause.paused)
            .map_or_else(
                |error| Reply::error(request.id, error.to_string()),
                |()| Reply::ok(request.id),
            )
    }

    /// Claims the child-facing listeners named in the request.
    ///
    /// All-or-nothing: an unknown or unbound kind fails the verb without claiming any of them, so a
    /// hostd never half-succeeds into believing it serves something it does not. It is also
    /// idempotent for a client re-claiming what it already holds, which is what makes it safe to
    /// send on every reconnect without tracking whether this is the first.
    fn listen(&self, id: ClientID, request: &Request) -> Reply {
        let Some(listen) = request.listen.as_ref() else {
            return Reply::error(request.id, "listen without a listen payload");
        };
        if listen.kinds.is_empty() {
            return Reply::error(request.id, "listen with no kinds");
        }
        for kind in &listen.kinds {
            if let Err(error) = self.claims.check(kind) {
                return Reply::error(request.id, error);
            }
        }
        for kind in &listen.kinds {
            match self.claims.claim(kind, id) {
                Ok(Some(previous)) if previous != id => {
                    eprintln!("superd: client {id} took the {kind} listener from client {previous}");
                },
                Ok(_unchanged) => eprintln!("superd: client {id} serves the {kind} listener"),
                Err(error) => return Reply::error(request.id, error),
            }
        }
        Reply::ok(request.id)
    }

    fn hello(&self, id: ClientID, request: &Request, greeted: &mut bool) -> Reply {
        let Some(hello) = request.hello.as_ref() else {
            return Reply::error(request.id, "hello without a hello payload");
        };
        if hello.version_major != VERSION_MAJOR {
            return Reply::error(
                request.id,
                format!(
                    "protocol major {} vs superd's {VERSION_MAJOR} — restart superd (`launchctl kickstart \
                     -k gui/$UID/{}`), which costs every pane",
                    hello.version_major,
                    paths::LAUNCH_AGENT_LABEL
                ),
            );
        }
        *greeted = true;
        eprintln!(
            "superd: client {id} is {} (protocol {}.{})",
            hello.client, hello.version_major, hello.version_minor
        );
        Reply {
            hello: Some(HelloReply {
                version_major: VERSION_MAJOR,
                version_minor: VERSION_MINOR,
                superd_pid: pid_as_i32(),
                hook_socket_path: Some(self.paths.hook.display().to_string()),
                control_socket_path: Some(self.paths.control_agent.display().to_string()),
            }),
            ..Reply::ok(request.id)
        }
    }

    fn spawn(&self, id: ClientID, request: &Request) -> (Reply, Option<OwnedFd>) {
        let Some(spawn) = request.spawn.as_ref() else {
            return (Reply::error(request.id, "spawn without a spawn payload"), None);
        };
        match self.registry.spawn(spawn, id) {
            Ok((record, descriptor)) => {
                eprintln!(
                    "superd: spawned pane {} as pid {} for client {id}",
                    record.pane_id, record.pid
                );
                (
                    Reply {
                        pane: Some(record),
                        ..Reply::ok(request.id)
                    },
                    Some(descriptor),
                )
            },
            Err(error) => (Reply::error(request.id, error.to_string()), None),
        }
    }

    fn adopt(&self, id: ClientID, request: &Request) -> (Reply, Option<OwnedFd>) {
        let Some(adopt) = request.adopt.as_ref() else {
            return (Reply::error(request.id, "adopt without an adopt payload"), None);
        };
        match self.registry.adopt(&adopt.pane_id, id) {
            Ok((record, descriptor)) => {
                eprintln!(
                    "superd: client {id} adopted pane {} (pid {}, alive since {})",
                    record.pane_id, record.pid, record.spawned_at
                );
                (
                    Reply {
                        pane: Some(record),
                        ..Reply::ok(request.id)
                    },
                    Some(descriptor),
                )
            },
            Err(error) => (Reply::error(request.id, error.to_string()), None),
        }
    }

    fn list(&self, request: &Request) -> Reply {
        self.registry.list().map_or_else(
            |error: RegistryError| Reply::error(request.id, error.to_string()),
            |panes| {
                Reply {
                    panes: Some(panes),
                    ..Reply::ok(request.id)
                }
            },
        )
    }

    fn signal(&self, request: &Request) -> Reply {
        let Some(signal) = request.signal.as_ref() else {
            return Reply::error(request.id, "signal without a signal payload");
        };
        self.registry.signal(&signal.pane_id, signal.signal).map_or_else(
            |error| Reply::error(request.id, error.to_string()),
            |()| Reply::ok(request.id),
        )
    }

    fn resize(&self, request: &Request) -> Reply {
        let Some(resize) = request.resize.as_ref() else {
            return Reply::error(request.id, "resize without a resize payload");
        };
        self.registry
            .resize(&resize.pane_id, resize.rows, resize.cols)
            .map_or_else(
                |error| Reply::error(request.id, error.to_string()),
                |()| Reply::ok(request.id),
            )
    }

    fn release(&self, request: &Request) -> Reply {
        let Some(release) = request.release.as_ref() else {
            return Reply::error(request.id, "release without a release payload");
        };
        match self.registry.release(&release.pane_id, release.kill) {
            Ok(()) => {
                eprintln!("superd: released pane {}", release.pane_id);
                Reply::ok(request.id)
            },
            Err(error) => Reply::error(request.id, error.to_string()),
        }
    }
}

/// Pushes an `exited` to every connected client.
///
/// Every client, not just the pane's holder: a pane may have no holder at all (hostd is restarting)
/// and the record is gone either way, so the notice is the only chance anyone has to learn of it.
fn broadcast_exit(clients: &Mutex<HashMap<ClientID, Arc<Connection>>>, notice: ExitedNotice) {
    eprintln!(
        "superd: pane {} (pid {}) exited with {}",
        notice.pane_id, notice.pid, notice.code
    );
    let Ok(guard) = clients.lock() else {
        return;
    };
    let targets: Vec<Arc<Connection>> = guard.values().map(Arc::clone).collect();
    drop(guard);
    let reply = Reply::exited(notice);
    for connection in targets {
        // A failed push means that client is gone; its connection thread will notice and clean up.
        let _ignored = connection.send(&reply, None);
    }
}

/// Hands one chunk of a pane's output to every connection subscribed to that pane.
///
/// Runs on the pane's pump thread, so a slow client blocks its own pane's reader and nobody else's
/// — which is the correct shape: that back-pressure is the never-drop guarantee, expressed as the
/// kernel PTY buffer filling and the shell pausing.
fn fan_out_output(
    clients: &Mutex<HashMap<ClientID, Arc<Connection>>>,
    pane_id: &str,
    offset: u64,
    bytes: &[u8],
    events: &[SniffEvent],
    blocks: &[BlockEvent],
) {
    let Ok(guard) = clients.lock() else {
        return;
    };
    let targets: Vec<Arc<Connection>> = guard.values().map(Arc::clone).collect();
    drop(guard);
    // Serialised ONCE for every subscriber rather than per connection: the batches are identical,
    // and the common case is two empty lists that never reach `to_vec` at all.
    let sniff = (!events.is_empty())
        .then(|| serde_json::to_vec(&SniffBatch { events }).ok())
        .flatten();
    let blocks = (!blocks.is_empty())
        .then(|| serde_json::to_vec(&BlockBatch { blocks }).ok())
        .flatten();
    for connection in targets {
        connection.send_output(pane_id, offset, bytes, sniff.as_deref(), blocks.as_deref());
    }
}

/// The body of a [`frame::write_sniff`] frame.
#[derive(Debug, serde::Serialize)]
struct SniffBatch<'a> {
    events: &'a [SniffEvent],
}

/// The body of a [`frame::write_blocks`] frame.
#[derive(Debug, serde::Serialize)]
struct BlockBatch<'a> {
    blocks: &'a [BlockEvent],
}

/// `getpid` as the `i32` the protocol carries.
fn pid_as_i32() -> i32 {
    i32::try_from(std::process::id()).unwrap_or(-1)
}

/// How much the control socket may hold in each direction.
///
/// `AF_UNIX` defaults to 8 KB on macOS (TCP gets 128 KB), and this socket carries the bulk path:
/// one output frame is up to [`crate::pump::READ_CHUNK_BYTES`] = 32 KiB, so at the default not even
/// a single frame fits and the pump parks mid-frame the instant hostd is a beat behind.
///
/// The number is superd's, the `setsockopt` is [`slopdesk_posix::sock::widen_buffers`]'s: how big a
/// buffer this protocol needs is a fact about the protocol, and the syscall that asks for it is a
/// fact about sockets.
const SOCKET_BUFFER_BYTES: libc::c_int = 256 * 1024;

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::collections::HashSet;
    use std::os::unix::net::UnixStream;
    use std::sync::Mutex;

    use super::{Connection, Subscribed};
    use crate::ring::Resume;

    /// The whole point of `Connection::subscribe` taking a closure.
    ///
    /// If the ring snapshot is taken before the lock — as it was — a chunk published in the gap is
    /// past the snapshot's head and not yet on the wire set, so it is written nowhere and the
    /// subscriber's stream has a hole in it that no later frame can fill. Asserting the lock is
    /// held while the snapshot is taken is the property, stated directly: `try_lock` on a `Mutex`
    /// already held fails for the holding thread too, so this needs no second thread and cannot
    /// flake.
    #[test]
    fn the_ring_snapshot_is_taken_under_the_wire_lock() {
        let (ours, _theirs) = UnixStream::pair().unwrap();
        let connection = Connection {
            stream: ours,
            wire: Mutex::new(HashSet::new()),
        };
        let mut asked = false;
        let outcome = connection.subscribe(
            7,
            "pane-x",
            0,
            || {
                asked = true;
                assert!(
                    connection.wire.try_lock().is_err(),
                    "the snapshot must be taken with the wire lock HELD, or a concurrent publish falls \
                     between the snapshot and the registration and is lost"
                );
                Ok((
                    Resume {
                        start: 0,
                        head: 0,
                        bytes: Vec::new(),
                    },
                    false,
                ))
            },
            |_bytes| None,
        );
        assert!(asked);
        assert!(matches!(outcome, Subscribed::Served(_)));
        assert!(
            connection.wire.lock().unwrap().contains("pane-x"),
            "a served subscribe must leave the pane on the wire"
        );
    }

    /// A rejected subscribe must leave no trace: no wire entry (which would make every later chunk
    /// of a pane this client never got a reply for arrive unannounced) and no bytes written.
    #[test]
    fn a_rejected_subscribe_registers_nothing() {
        let (ours, _theirs) = UnixStream::pair().unwrap();
        let connection = Connection {
            stream: ours,
            wire: Mutex::new(HashSet::new()),
        };
        let outcome = connection.subscribe(
            7,
            "pane-x",
            0,
            || Err(crate::registry::RegistryError::UnknownPane("pane-x".to_owned())),
            |_bytes| None,
        );
        assert!(matches!(outcome, Subscribed::Rejected(_)));
        assert!(connection.wire.lock().unwrap().is_empty());
    }
}
