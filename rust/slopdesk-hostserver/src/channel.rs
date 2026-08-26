//! The channel ladders: what happens when a client opens one, and what happens when it ends.
//!
//! `spawnMuxChannel`, `performJoin`, `performReattach`, `spawnFreshShell` and `removeMuxSession` —
//! five functions and about five hundred lines of `HostServer.swift`, which between them decide
//! whether a `channelOpen` becomes a second window on a pane somebody is already watching, a
//! returning client picking up a pane it left running, or a brand-new shell.
//!
//! ## There is no engine here either
//!
//! The PRECEDENCE between those outcomes — channel class, then the host's condition, then the
//! incumbent, then the store — is [`slopdesk_muxsession::open_route`] and has been since before
//! this stage started. So is the resume clamp, the restore gate and the repaint verdict. The
//! transport is [`slopdesk_hostnet`]'s, the tables are D.1's, one pane is
//! [`slopdesk_hostsession::PaneSession`]'s. What is left — and it is the whole file — is the ORDER
//! those are called in, and the ONE critical section that makes the first four indivisible.
//!
//! ## The one critical section, and the invariant it is the only guard for
//!
//! Exactly one `openpty()` + `fork()` per session id, ever. Not "usually", not "unless two clients
//! race": ever. Two attachments aliasing one id would let one client's close kill the OTHER
//! client's live PTY and delete its scrollback journal. So the idempotency guard, the stopping
//! gate, the "already attached elsewhere" lookup, the JOIN's key-and-subscriber registration and
//! the detached store's exclusive claim all happen under ONE acquisition of the registry lock —
//! and the two mutations are done there rather than after, because a route decided under the lock
//! and acted on outside it is the TOCTOU the lock was taken to close.
//!
//! Two things deliberately happen OUTSIDE it, and both are the same reason: they can block. A join
//! composes an O(retained history) screen and ships it through the joining client's credit window;
//! a reattach replays a tail through the same window. [`SubChannel::send`] parks on a condvar until
//! the peer grants credit, and the grants arrive on the connection's own link threads — so an
//! inline replay would not deadlock, but it WOULD stall every other open on that connection for as
//! long as the replay takes. Both go through [`Offload`], which is a seam so the suite can run them
//! on the calling thread and assert without joining anything.
//!
//! ## What is a seam, and what is a documented hole
//!
//! [`Spawner::open`](crate::Spawner::open) is the fork, for the reason D.6.1 put the standalone
//! fork behind the same trait: everything on this side of it is assertable without a PTY.
//! [`Peer`] is the connection — an ack and an id, which is all four ladders ever ask of one.
//! [`Offload`] is the thread. [`HookRoutes`] is the agent-hook listener's half of a hook route: the
//! TABLE half is [`Sessions::register_hook`](crate::Sessions::register_hook) and lands here, the
//! listener half is a socket this crate does not own yet. [`HostObserver`] is the three things
//! hostd tells the outside — the connection count, the log line, and "the workspace document is
//! stale".
//!
//! The holes, named rather than skipped:
//!
//! - [`WorkspaceChannels`] — a workspace channel carries no PTY and none of the reasoning above
//!   applies to it (`docs/45` §5.1). Its own ladder is **D.6.4**; until then [`NoWorkspace`]
//!   DECLINES, which is what this host does today for a class it does not serve.
//! - The transcript store is still Swift's, so [`Transcripts`](crate::Transcripts) grows two more
//!   questions rather than a client.
//! - The ADOPTION ladder is **D.6.3** and the link-down/stop order is **D.6.5**
//!   ([`crate::lifecycle`]). This file owns the close ([`Host::close_channel`]) because that is the
//!   exit route a fresh spawn WIRES, and a spawn whose exit closure pointed at a hole would be a
//!   leak with a doc comment on it. It is the UNREFCOUNTED door: a peer's `channelClose` must go
//!   through [`Host::leave_channel`] instead, or a fan-out close takes another client's agent with
//!   it.

use core::fmt;
use core::time::Duration;
use std::sync::{Arc, Weak};
use std::thread;

use slopdesk_hostnet::connection::ChannelOpen;
use slopdesk_hostsession::{SessionObserver, StatusObserver};
use slopdesk_ids::uuid_text;
use slopdesk_muxsession::open_route::{
    self, Claim as ClaimOutcome, Incumbent, OpenFacts, Redraw, Route, Settled,
};
use slopdesk_muxsession::registry::{Key, PRIMARY_SUBSCRIBER, Subscriber, Uuid};
use slopdesk_wire::message::NEW_SESSION_ID;
use slopdesk_wire::mux::envelope::MuxCloseReason;

use crate::detached::Claim;
use crate::host::{Fan, Host};
use crate::pane::{Pane, Wires};

/// How long after a reattach the foreground program is asked to repaint.
///
/// The delay is not politeness. It lets the returning client's FIRST `resize` land and its
/// sub-channels finish wiring, so the shell redraws at the dimensions it is about to be told about
/// rather than the ones it is leaving. The other delay — the hold BETWEEN the two `SIGWINCH`es of a
/// jiggle — is a fact about the program rather than about the reattach, and lives with the pane.
const REDRAW_DELAY: Duration = Duration::from_millis(200);

/// The connection a channel arrived on, as the four ladders see it.
///
/// Four questions, which is all any of them asks: which connection this is, "answer the open", and
/// the two ways a ladder ENDS something — one channel, or the whole link. Narrow on purpose — a
/// ladder that could reach the whole [`slopdesk_hostnet::connection::MuxConnection`] could send
/// frames out of band, and the frames a pane emits are the pane's.
pub trait Peer: Send + Sync + fmt::Debug {
    /// The connection id. Half of every table key, and the key the size-passivity table is under.
    fn connection(&self) -> Uuid;

    /// Answers the open. `resume_from` is read only when `accepted`, and a refusal supersedes an
    /// acceptance already sent — the client's router marks the channel dead and reconnects.
    fn ack(&self, channel: u32, accepted: bool, resume_from: i64);

    /// Closes ONE channel on this connection, telling the peer why.
    ///
    /// The reason is load-bearing rather than diagnostic: `Retired` says the session id is about to
    /// stop existing, so a re-open is a SPAWN, and `SubscriberEvicted` says the pane is still there
    /// and a re-open is a reattach. See [`MuxCloseReason`].
    fn close_channel(&self, channel: u32, reason: MuxCloseReason);

    /// Tears the whole connection down — its receive loops, its sockets, its handler cycle.
    ///
    /// Reached only from the stop. A link that drops on its own is already gone; this is the one
    /// that has to be told, and skipping it leaks a connection per Start→Stop cycle on the
    /// long-lived menu-bar host, which accumulates toward `EMFILE`.
    fn close(&self);
}

/// Where work that can BLOCK goes.
///
/// A seam rather than a bare `thread::spawn` for the reason every seam in this crate exists: the
/// two ladders behind it are the two that compose a screen and ship it through a credit window, and
/// a suite that had to join a thread to see the result would be asserting on a scheduler. The
/// production impl is [`Threads`]; a suite hands in one that runs inline.
pub trait Offload: Send + Sync + fmt::Debug {
    /// Runs `work` somewhere that is not the caller's thread.
    fn run(&self, work: Box<dyn FnOnce() + Send>);

    /// The same, after `delay`.
    fn after(&self, delay: Duration, work: Box<dyn FnOnce() + Send>);
}

/// One thread per piece of work, which is what a channel open can afford.
///
/// Opens are rare — one per pane per connection — and each of these threads exists for exactly one
/// replay. A pool would add a queue whose head-of-line blocking is the very thing the offload
/// exists to avoid: two clients reattaching at once must not serialise.
///
/// A thread that will not spawn runs the work INLINE. Only an exhausted process fails here, and at
/// that point a stalled open is a better outcome than a dropped one — the client is waiting for an
/// ack either way, and the inline path still sends it.
#[derive(Debug, Clone, Copy)]
pub struct Threads;

impl Offload for Threads {
    fn run(&self, work: Box<dyn FnOnce() + Send>) {
        match thread::Builder::new()
            .name(String::from("slopdesk-open"))
            .spawn(work)
        {
            Ok(handle) => drop(handle),
            Err(_refused) => {},
        }
    }

    fn after(&self, delay: Duration, work: Box<dyn FnOnce() + Send>) {
        self.run(Box::new(move || {
            thread::sleep(delay);
            work();
        }));
    }
}

/// The workspace channel class, which is **D.6.4**'s.
///
/// A channel class rather than a pane: no PTY, no join, no detached claim, no transcript. The open
/// ladder routes it here and asks nothing else about it.
pub trait WorkspaceChannels: Send + Sync + fmt::Debug {
    /// Takes the open. `false` refuses it, and the caller sends the refusal.
    fn open(&self, open: Box<ChannelOpen>, peer: &Arc<dyn Peer>) -> bool;

    /// Says the pane topology moved, so a subscribed document should be re-reconciled now rather
    /// than on its next tick.
    ///
    /// A pane that just went away is the one case where a client MUST hear promptly, because the
    /// row is still on screen: the reconciler reaps by "not captured", so this kick is what turns a
    /// close into a delete instead of a wait.
    fn fact_changed(&self);

    /// Retires the subscriber this connection carried.
    ///
    /// A workspace subscriber lives and dies with its LINK: presence is connection-scoped, so the
    /// connection going away IS the expiry. Dropping it here also fans the departure to everyone
    /// else, because a roster that merely stops arriving is indistinguishable from a stalled host.
    fn drop_connection(&self, connection: Uuid);

    /// The stop's workspace half, in its own order: flush the store, end the document, clear the
    /// subscriber map.
    ///
    /// The map is cleared LAST and separately from the document's own teardown, so a
    /// Start→Stop→Start cycle does not refuse the returning client's channel as a duplicate.
    fn shutdown(&self);
}

/// A host that serves no workspace channels — every open of that class is declined.
///
/// Which is what this host DOES today for a class it does not serve, so the default is the honest
/// answer rather than a placeholder: falling through into the PTY path would hand a peer one
/// version ahead a login shell it never asked for.
#[derive(Debug, Clone, Copy)]
pub struct NoWorkspace;

impl WorkspaceChannels for NoWorkspace {
    fn open(&self, _open: Box<ChannelOpen>, _peer: &Arc<dyn Peer>) -> bool {
        false
    }

    fn fact_changed(&self) {}
    fn drop_connection(&self, _connection: Uuid) {}
    fn shutdown(&self) {}
}

/// The agent-hook listener's half of a hook route.
///
/// The route is two records: the TABLE entry, which is
/// [`Sessions::register_hook`](crate::Sessions::register_hook) and lands in this crate, and the
/// LISTENER entry, which is a socket that is still Swift's. Both are keyed by the pane's
/// ENV-BAKED id — never a per-reattach composite key, because the agent's POSTs carry the id that
/// was in its environment when it started, and a composite key could never route AND would leak one
/// dead sink per wifi flap for the daemon's life.
pub trait HookRoutes: Send + Sync + fmt::Debug {
    /// Points `pane_id`'s hook records at `pane`. Called again on a reattach, where it is a
    /// harmless refresh of the same route — the session object did not change.
    fn bind(&self, pane_id: &str, pane: &Arc<dyn Pane>);

    /// Retires `pane_id`'s route, so a late POST for a closed pane is dropped.
    fn unbind(&self, pane_id: &str);
}

/// A host with no hook listener bound: nothing to route, nothing to retire.
#[derive(Debug, Clone, Copy)]
pub struct NoHooks;

impl HookRoutes for NoHooks {
    fn bind(&self, _pane_id: &str, _pane: &Arc<dyn Pane>) {}
    fn unbind(&self, _pane_id: &str) {}
}

/// The three things a ladder tells the world outside the tables.
pub trait HostObserver: Send + Sync + fmt::Debug {
    /// How many client connections hold at least one pane, after a change.
    ///
    /// Emitted only when a ladder actually moved a registration: every ladder here is idempotent
    /// against the peer-close / child-exit race, and a second removal of the same key must not
    /// re-emit an unchanged count.
    fn connection_count(&self, count: usize);

    /// One daemon-log line.
    fn log(&self, line: &str);
}

/// A host nobody is listening to.
#[derive(Debug, Clone, Copy)]
pub struct Silent;

impl HostObserver for Silent {
    fn connection_count(&self, _count: usize) {}
    fn log(&self, _line: &str) {}
}

/// A PRIOR life's transcript, read back off disk before the shell that will append to it starts.
#[derive(Debug, Clone, Default)]
pub struct Restored {
    /// The bytes, ready to seed the new session's history.
    pub bytes: Vec<u8>,
    /// Whether they are a RENDERED snapshot rather than a distilled byte stream.
    pub snapshot_composed: bool,
}

/// One fresh mux shell, fully resolved — every decision made, nothing forked yet.
///
/// [`crate::Standalone`]'s sibling, and the split is the same one: everything here is a choice
/// [`Host`] made from the open and its own configuration, all of it assertable without a PTY.
///
/// No `shell_integration` field, unlike [`crate::Standalone`], and its absence is the difference
/// between the two paths: a mux channel is ALWAYS an interactive login shell, which is the one pane
/// shape prompt machinery applies to. A standalone spawn may be a raw `cmd`, so there the shim is a
/// question; here a field would carry the constant `true` to every implementor and invite one to
/// answer it differently.
#[derive(Debug)]
pub struct Fresh<'a> {
    /// The conversation this pane will be known by.
    pub session: Uuid,
    /// The channel it rides.
    pub channel: u32,
    /// The client's two lanes.
    pub wires: Wires,
    /// The login shell to exec.
    pub executable: String,
    /// The `argv[0]` it sees — a login shell's leading-dash form.
    pub argv0: String,
    /// The child's whole environment, `PWD` included.
    pub env: std::collections::BTreeMap<String, String>,
    /// Where the child actually lands, which is not necessarily what it asked for.
    pub cwd: Option<&'a str>,
    /// Whether superd segments this pane into command blocks.
    pub blocks: bool,
    /// Whether superd keeps this pane's transcript on disk as it pumps it.
    ///
    /// `false` for the zero sentinel, which can never be re-presented — asking superd to journal it
    /// would only produce an orphan file.
    pub journal: bool,
    /// A prior life's transcript to seed the history with, when this open earned a restore.
    pub restored: Option<Restored>,
    /// Whether the size fold treats this client's offer as passive.
    pub size_passive: bool,
    /// Where the pane's stream is subscribed from IF the fork finds superd already holding this id
    /// and takes that shell over.
    ///
    /// Both offsets ride together and the SPAWNER picks, because only the fork knows which happened
    /// — but neither value depends on the fork, so neither is computed after it. Usually `0`: a
    /// pane forked a moment ago has no history to arrive twice. On a take-over the ring holds the
    /// same bytes the restore above does, and subscribing from `0` would print the user's whole
    /// history a second time and re-feed the sniffer and the block ledger with it.
    pub resume_takeover: u64,
    /// Who hears the child's exit.
    pub exit: Arc<dyn SessionObserver>,
    /// Who hears the agent inside it move.
    pub status: Arc<dyn StatusObserver>,
}

/// What [`Host::route_open`]'s critical section decided, and what it did while deciding.
///
/// The two `Option`s are not alternatives to the route — they are the MUTATIONS the route already
/// performed, carried out so the caller can act on them without re-reading a table that has moved.
#[derive(Debug)]
struct Routed {
    route: Route,
    /// The pane this key joined, and the member id reserved for it.
    joining: Option<(Arc<dyn Pane>, Subscriber)>,
    /// The pane taken out of the store, already filed under this key.
    claimed: Option<Arc<dyn Pane>>,
    /// A pane the claim found already dead, and reaped on the way past.
    reaped: Option<Arc<dyn Pane>>,
    settled: Settled,
}

impl Host {
    // ------------------------------------------------------------------------------ the open

    /// A client opened a channel. Decide what it is, then be it.
    ///
    /// See the module doc for why the decision and the two mutations it implies are ONE critical
    /// section, and why two of the five outcomes leave it before they do their work.
    pub fn open_channel(self: &Arc<Self>, open: Box<ChannelOpen>, peer: &Arc<dyn Peer>) {
        // File the link before deciding anything about the channel. The accept path files it too;
        // this is the second half of the belt, and it is what makes an eviction or a topology reap
        // able to close a channel on a connection it was not called from.
        self.note_peer(peer);
        let key = Key::new(peer.connection(), open.channel_id);
        let channel = open.channel_id;
        let decided = self.route_open(&open, key);

        if decided.settled == Settled::ReapThenSpawn
            && let Some(dead) = decided.reaped
        {
            // Prevent-sleep strict balance: the dead pane may still carry a `working` status
            // nobody will ever clear, because the claim gated its own exit closure off. And its
            // hook route goes BEFORE the fresh spawn below re-registers the same id. The journal
            // is deliberately NOT deleted — the same-id fresh spawn rotates it, which is what keeps
            // the transcript file continuous.
            self.fan_teardown(&dead);
            self.retire_hook(&dead);
        }

        match decided.route {
            Route::Workspace => {
                if !self.workspace().open(open, peer) {
                    peer.ack(channel, false, 0);
                }
            },
            // Never guessed at. A class this host does not serve gets a refusal, not a login shell
            // addressed by nobody.
            Route::Decline => {
                self.observer().log(&format!(
                    "mux channel {channel}: declined — channel class {} is not served by this host",
                    open.channel_class
                ));
                peer.ack(channel, false, 0);
            },
            // Shutting down: never fork a PTY that would outlive the daemon.
            Route::RefuseStopping => peer.ack(channel, false, 0),
            Route::ReAck => peer.ack(channel, true, 0),
            Route::Join => {
                // Both are `Some` by construction — `.join` is only returned for `OtherKey`, which
                // only exists when the lookup found a pane, which is exactly when the registration
                // above ran. The `else` is unreachable, but a dropped open with no ack hangs the
                // client until its own timeout, so it refuses rather than falling silent.
                let Some((pane, reserved)) = decided.joining else {
                    peer.ack(channel, false, 0);
                    return;
                };
                let host = Arc::clone(self);
                let peer = Arc::clone(peer);
                // The `Box` is captured and dereferenced INSIDE, so the move across the seam costs
                // a pointer rather than the open's whole body.
                self.offload().run(Box::new(move || {
                    host.perform_join(&pane, reserved, *open, &peer);
                }));
            },
            Route::Claim | Route::SpawnFresh => {
                if decided.settled == Settled::Reattach
                    && let Some(pane) = decided.claimed
                {
                    let host = Arc::clone(self);
                    let peer = Arc::clone(peer);
                    self.offload().run(Box::new(move || {
                        host.perform_reattach(&pane, *open, &peer);
                    }));
                } else {
                    // Inline, unlike the two above, and the asymmetry is the point: a fork is
                    // bounded work with no credit window in it, while a replay is neither. The
                    // Swift made the same split for the same reason.
                    self.spawn_fresh(*open, peer, key);
                }
            },
        }
    }

    /// The ONE critical section: every fact the route turns on, and the two mutations it implies.
    ///
    /// Split out of [`Host::open_channel`] so the section is a function rather than a block — which
    /// is also what makes "nothing between the read and the write" a property a reader can check by
    /// looking at one scope.
    fn route_open(&self, open: &ChannelOpen, key: Key) -> Routed {
        // The ZERO sentinel is a first-connect preamble from a raw or old client. Our own client
        // replaces it with a fresh real id before sending, so this is normally always true — but a
        // sentinel can never be re-presented, which is what rules out every path below that would
        // save something under it.
        let real = open.session_id != NEW_SESSION_ID;
        // `SpawnFresh` twice, and neither is a placeholder: an open that reaches no other branch IS
        // a fresh spawn, and a claim that finds nothing settles the same way.
        let mut decided = Routed {
            route: Route::SpawnFresh,
            joining: None,
            claimed: None,
            reaped: None,
            settled: Settled::SpawnFresh,
        };

        let mut sessions = self.sessions();
        let stopping = self.is_stopping();
        // Idempotency, defence in depth with the connection's own new-channel gate: a duplicate
        // `channelOpen` must not spawn a SECOND PTY under a key that already names a live pane,
        // orphaning the first one's descriptor and its reaper.
        let held = sessions.pane(key).is_some();
        // The same id live under a DIFFERENT key is the JOIN. A pane is SHARED, never handed over
        // and never duplicated.
        let elsewhere = if stopping || held || !real {
            None
        } else {
            sessions.pane_elsewhere(open.session_id, key).map(Arc::clone)
        };
        let incumbent = if held {
            Incumbent::ThisKey
        } else if elsewhere.is_some() {
            Incumbent::OtherKey
        } else {
            Incumbent::None
        };
        decided.route = open_route::route(OpenFacts {
            channel_class: open.channel_class,
            incumbent,
            stopping,
            real_session_id: real,
            detached_store: self.detached().is_some(),
        });
        // JOIN: take THAT pane — never a second one — and register this key against it HERE, so a
        // third concurrent open sees the pane as held and routes here too. The key and its reserved
        // subscriber go in as ONE record: a key registered without its subscriber resolves to the
        // pane's PRIMARY, so a joiner whose link died mid-transfer would retire the incumbent
        // instead of itself.
        if decided.route == Route::Join
            && let Some(pane) = elsewhere
        {
            let reserved = pane.reserve_subscriber();
            sessions.attach(key, &pane, reserved);
            decided.joining = Some((pane, reserved));
        }
        // CLAIM: exclusively TAKE the parked pane — the removal and the TTL cancellation are one
        // operation inside the store — and register it under its NEW key in this same section,
        // which is what closes the two-concurrent-reattach and the reattach-vs-TTL races. The
        // store's lock is taken while the registry's is held, which is the one-way nesting
        // `crate::host`'s module doc fixes.
        if decided.route == Route::Claim
            && let Some(store) = self.detached()
        {
            match store.claim(open.session_id) {
                Claim::Claimed(pane) => {
                    decided.settled = open_route::settle(ClaimOutcome::Claimed);
                    sessions.attach_primary(key, &pane);
                    decided.claimed = Some(pane);
                },
                Claim::ReapedDeadChild(pane) => {
                    decided.settled = open_route::settle(ClaimOutcome::ReapedDeadChild);
                    decided.reaped = Some(pane);
                },
                Claim::NotFound => decided.settled = open_route::settle(ClaimOutcome::NotFound),
            }
        }
        drop(sessions);
        decided
    }

    // ------------------------------------------------------------------------------ path D: join

    /// Adds a SECOND (third, …) client to a pane somebody is already watching.
    ///
    /// Ack FIRST, then the state transfer — the reattach's ordering against a drain that is LIVE.
    /// The verdict rides the data lane ahead of the first byte, so the awaiting client learns the
    /// session resumed before anything is painted. A joiner is current from here on, hence a
    /// `resume_from` of its own number.
    fn perform_join(
        &self,
        pane: &Arc<dyn Pane>,
        reserved: Subscriber,
        open: ChannelOpen,
        peer: &Arc<dyn Peer>,
    ) {
        let key = Key::new(peer.connection(), open.channel_id);
        let channel = open.channel_id;
        let session = open.session_id;
        let passive = self.size_passive(peer.connection());
        peer.ack(channel, true, open.last_received_seq);

        let ChannelOpen {
            data,
            data_inbound,
            control,
            control_inbound,
            ..
        } = open;
        let joined = pane.join(
            reserved,
            Wires {
                data,
                data_inbound,
                control,
                control_inbound,
            },
            passive,
        );
        let Some(subscriber) = joined else {
            // The pane emptied, or the joining link died while the screen was being composed.
            // Unregister and refuse; the client reconnects and takes whichever path is true then.
            // The reservation goes too: a workspace `subscribe` landing mid-join registers it as a
            // size contributor, and a phantom would clamp the pane for ever with no window behind
            // it.
            let _unfiled = self.sessions().detach_if_names(key, pane);
            pane.remove_resize_contributor(reserved);
            self.observer().log(&format!(
                "mux channel {channel}: refused — session {} was not joinable (link died mid-join or pane \
                 emptied)",
                uuid_text(session)
            ));
            peer.ack(channel, false, 0);
            return;
        };
        self.emit_connection_count();
        self.workspace().fact_changed();
        self.observer().log(&format!(
            "mux channel {channel}: joined live session {} as subscriber {subscriber}",
            uuid_text(session)
        ));
    }

    // -------------------------------------------------------------------------- path A: reattach

    /// Reattaches a returning client to a pane it left running.
    ///
    /// The pane was already CLAIMED and registered under `key` in [`Host::open_channel`]'s one
    /// critical section, so this only rebinds and acks. If a stop raced in after the claim, the
    /// stop's own drain finds the pane in the table and ends it like any other live one.
    fn perform_reattach(self: &Arc<Self>, pane: &Arc<dyn Pane>, open: ChannelOpen, peer: &Arc<dyn Peer>) {
        let key = Key::new(peer.connection(), open.channel_id);
        let channel = open.channel_id;
        let session = open.session_id;
        // The returning client may be a DIFFERENT device from the one that detached — a Mac's pane
        // picked up on a phone — so the fold's predicate is re-resolved for the connection this
        // pane now rides, BEFORE any of its resize frames can land.
        pane.add_resize_contributor(PRIMARY_SUBSCRIBER, self.size_passive(peer.connection()));
        // Host-authoritative, so it must not exceed what this pane can actually number.
        let resume = open_route::resume_from(open.last_received_seq, pane.highest_assigned_seq());
        // Ack FIRST, before the replay: the verdict rides the data lane FIFO-ahead of the replayed
        // frames. If the rebind below then fails, the refusal supersedes this — the same outcome a
        // mid-replay link death always had.
        peer.ack(channel, true, resume);

        let cold = open.last_received_seq == 0;
        let ChannelOpen {
            data,
            data_inbound,
            control,
            control_inbound,
            ..
        } = open;
        // BEFORE the rebind, because the rebind starts the live drain and live output must not
        // interleave with the replay. And `resume`, not the client's own number: replaying "after
        // 4000" out of a buffer that never issued a seq above 1 selects nothing, so an adopted pane
        // would come back blank even with the ack right.
        let composed = pane.replay_tail(resume, &data);
        let rebound = pane.rebind(
            Wires {
                data,
                data_inbound,
                control,
                control_inbound,
            },
            Arc::new(CloseOnExit {
                host: self.weak(),
                key,
            }),
        );
        if !rebound {
            // The new link can die MID-REPLAY: link-down parks the pane while the replay is still
            // iterating, and the rebind then refuses the finished channels. Refuse the channel AND
            // recover the claimed pane, so it is never stranded outside both the table and the
            // store.
            self.recover_failed_rebind(pane, key);
            self.observer().log(&format!(
                "mux channel {channel}: refused — session {} was claimed but not rebindable (link died \
                 mid-reattach or not detached); session recovered",
                uuid_text(session)
            ));
            peer.ack(channel, false, 0);
            return;
        }
        self.emit_connection_count();
        self.refresh_hook(pane);
        self.observer().log(&format!(
            "mux channel {channel}: reattached session {} ({} replay)",
            uuid_text(session),
            if composed { "snapshot" } else { "raw" }
        ));
        // See `REDRAW_DELAY`. The verdict is decided here and carried, so the delayed thread makes
        // no decision of its own — the pane's state may have moved by the time it runs, and a
        // repaint is about what the REPLAY was.
        let jiggle = open_route::redraw(cold, composed) == Redraw::Jiggle;
        let pane = Arc::clone(pane);
        self.offload()
            .after(REDRAW_DELAY, Box::new(move || pane.redraw(jiggle)));
    }

    /// Recovers a claimed pane whose rebind refused.
    ///
    /// The claim already removed it from the store, so merely unregistering the key would strand a
    /// live shell and a running agent in NO table and NO store — unreachable by the stop, by the
    /// TTL, by a ctl `kill` and by every future reconnect, for ever. One snapshot decides, and it
    /// is taken atomically w.r.t. [`Host::open_channel`]'s claim section so no reconnect can claim
    /// mid-decision.
    fn recover_failed_rebind(self: &Arc<Self>, pane: &Arc<dyn Pane>, key: Key) {
        let (elsewhere, parked) = {
            let mut sessions = self.sessions();
            let _unfiled = sessions.detach_if_names(key, pane);
            (
                sessions.is_attached(pane),
                self.detached().is_some_and(|store| store.contains(pane.id())),
            )
        };
        // Attached under another key: a later reconnect owns it. Already back in the store:
        // link-down won the race and re-parked it. Either way, leave it alone.
        if elsewhere || parked {
            return;
        }
        if pane.is_child_exited() {
            // A non-deliberate end of life reached OUTSIDE the close ladder, so the hook route is
            // dropped here. The transcript is KEPT: a reconnect may still cold-restore it, and
            // superd closed its writer when the pane was released.
            self.fan_teardown(pane);
            self.end_off_thread(pane);
            self.retire_hook(pane);
            return;
        }
        // Re-park — tmux semantics: the running agent survives and is claimable again. Idempotent
        // end to end even if link-down lands between the snapshot above and here.
        self.park(key, pane);
    }

    // ----------------------------------------------------------------------- paths B/C: a fresh shell

    /// Forks a brand-new shell for this channel.
    ///
    /// The ORDER is the whole function: restore, fork, wire, file, start, seed, route, ack. Two of
    /// those are load-bearing and both are about a window in which the pane exists but nobody knows
    /// it. The RESTORE runs before the fork because the fork is what starts writing under the same
    /// id — superd appends the new shell's output below a returning id's transcript, so reading
    /// afterwards would hand the client bytes the live stream is about to deliver again. And the
    /// FILE runs before the start, because a pane that produced its first output byte before the
    /// table knew about it has dropped its own opening.
    fn spawn_fresh(self: &Arc<Self>, open: ChannelOpen, peer: &Arc<dyn Peer>, key: Key) {
        let channel = open.channel_id;
        let session = open.session_id;
        let real = session != NEW_SESSION_ID;
        // Both halves of the gate — a real id, and a COLD client — are the router's.
        let restored = open_route::restores_transcript(real, open.last_received_seq)
            .then(|| self.transcripts().restore(session))
            .flatten();
        if let Some(ref restored) = restored {
            self.observer().log(&format!(
                "mux channel {channel}: restored {} journaled bytes ({} replay)",
                restored.bytes.len(),
                if restored.snapshot_composed {
                    "snapshot"
                } else {
                    "distilled"
                }
            ));
        }

        let resolved = self.resolve_mux(session, open.initial_cwd.as_deref());
        let fan = Arc::new(Fan::unaimed(self.weak()));
        let status: Arc<dyn StatusObserver> = Arc::<Fan>::clone(&fan);
        let passive = self.size_passive(peer.connection());
        let ChannelOpen {
            data,
            data_inbound,
            control,
            control_inbound,
            ..
        } = open;
        let forked = self.spawner().open(Fresh {
            session,
            channel,
            wires: Wires {
                data,
                data_inbound,
                control,
                control_inbound,
            },
            executable: resolved.executable,
            argv0: resolved.argv0,
            env: resolved.env,
            cwd: resolved.cwd.as_deref(),
            // Where the shim went, blocks can go — superd holds the block ring, so the pane has to
            // be TAPPED at the fork. A tap cannot be added to a shell that is already running.
            blocks: self.blocks_enabled(),
            journal: real,
            restored,
            size_passive: passive,
            resume_takeover: self.transcripts().position(session).offset,
            exit: Arc::new(CloseOnExit {
                host: self.weak(),
                key,
            }),
            status,
        });
        let pane = match forked {
            Ok(pane) => pane,
            Err(refused) => {
                // Nothing to unwind on disk: a fork that failed never got a pane, and superd opens
                // the journal only as part of forking one.
                self.observer().log(&format!(
                    "mux channel {channel}: shell spawn failed: {}",
                    refused.0
                ));
                peer.ack(channel, false, 0);
                return;
            },
        };
        fan.aim(&pane);

        {
            let mut sessions = self.sessions();
            // Re-checked under the lock that files it: a stop that landed while the child was
            // forking would otherwise file a pane into a table whose drain has already run.
            if self.is_stopping() {
                drop(sessions);
                pane.shutdown();
                peer.ack(channel, false, 0);
                return;
            }
            sessions.attach_primary(key, &pane);
        }
        self.emit_connection_count();
        pane.start();
        // The RESOLVED cwd, and after the start so the enqueued control rides the live sender. A
        // pane that requested nothing still lands in a real directory, and skipping its seed left
        // it outside every project section until an OSC-7 edge an unshimmed shell never sends.
        if let Some(ref cwd) = resolved.cwd
            && !cwd.is_empty()
        {
            pane.seed_project(cwd);
        }
        self.register_hook(&pane);
        peer.ack(channel, true, 0);
        self.observer().log(&format!(
            "mux channel {channel}: shell (pid {}) attached for pane {}",
            pane.pid(),
            uuid_text(session)
        ));
    }

    // ----------------------------------------------------------------------------- the close

    /// A channel ended DELIBERATELY: the peer closed it, or the attached child exited.
    ///
    /// The exit route every fresh spawn and every rebind wires. Link-drop detach, TTL eviction and
    /// the daemon stop never come through here, which is what makes the transcript deletion below
    /// safe to be unconditional-but-for-the-stop.
    pub fn close_channel(&self, key: Key) {
        let (pane, stopping) = {
            let mut sessions = self.sessions();
            let pane = sessions.pane(key).map(Arc::clone);
            // A reap takes EVERY key that names this pane, not just the one that asked. Under a
            // fan-out N keys alias one pane, and leaving N−1 behind keeps a dead pane in
            // `list-panes`, re-shut by the stop, and read as still-attached by the rebind recovery.
            match pane {
                Some(ref pane) => drop(sessions.reap(pane)),
                None => drop(sessions.detach(key)),
            }
            let stopping = self.is_stopping();
            drop(sessions);
            (pane, stopping)
        };
        let Some(pane) = pane else {
            // Idempotent with the peer-close / child-exit race: a second close of the same key is a
            // no-op, and must not re-emit a count or re-fan a status.
            return;
        };
        self.workspace().fact_changed();
        // Disk-journal policy: a pane that ends DELIBERATELY takes its transcript with it. The
        // stopping guard keeps a child exit RACING the stop from wiping a journal the restart is
        // supposed to restore.
        if !stopping {
            self.transcripts().delete(pane.id());
        }
        self.retire_hook(&pane);
        self.emit_connection_count();
        // Prevent-sleep strict balance: a pane closed WHILE its agent is working never delivers a
        // non-working transition on its own.
        self.fan_teardown(&pane);
        // Off the caller's thread, because this is reached SYNCHRONOUSLY from the connection's
        // receive loop for a peer close. A shutdown blocks for the full SIGTERM → wait → SIGKILL
        // escalation of a shell that ignores the first signal, which would stall every OTHER pane
        // riding the same connection. The table removal above is the double-shut guard, so the
        // blocking kill is safe to run anywhere.
        self.end_off_thread(&pane);
    }

    // ------------------------------------------------------------------------------ the helpers

    /// Ends a pane somewhere that is not the caller's thread. See [`Host::close_channel`].
    fn end_off_thread(&self, pane: &Arc<dyn Pane>) {
        let pane = Arc::clone(pane);
        self.offload().run(Box::new(move || pane.shutdown()));
    }

    /// Parks a pane: the client goes, the shell stays, and a returning client may claim it.
    ///
    /// With no store there is nowhere to park, so the pane is ended instead — a fallback rather
    /// than a policy, and the same one the Swift took.
    pub(crate) fn park(self: &Arc<Self>, key: Key, pane: &Arc<dyn Pane>) {
        let Some(store) = self.detached() else {
            self.end_off_thread(pane);
            return;
        };
        let _unfiled = self.sessions().detach_if_names(key, pane);
        // The handler goes in with the DETACH rather than after it, so a child that dies during the
        // park is heard by the parked handler and not by the one the live channel installed.
        pane.detach(Arc::new(ParkedExit {
            host: self.weak(),
            pane: Arc::downgrade(pane),
            session: pane.id(),
        }));
        store.insert(pane, self.detach_ttl());
    }

    /// Files this pane's hook route, both halves, under its ENV-BAKED id.
    pub(crate) fn register_hook(&self, pane: &Arc<dyn Pane>) {
        let pane_id = uuid_text(pane.id());
        self.sessions().register_hook(pane, &pane_id);
        self.hooks().bind(&pane_id, pane);
    }

    /// Re-points an EXISTING route at the same pane after a reattach.
    ///
    /// Identity-guarded by the table: a pane whose hooks were off at spawn has no entry, and this
    /// registers nothing rather than inventing one.
    fn refresh_hook(&self, pane: &Arc<dyn Pane>) {
        let Some(pane_id) = self.sessions().rebind_hook(pane) else {
            return;
        };
        self.hooks().bind(&pane_id, pane);
    }

    /// Retires this pane's hook route, both halves. Idempotent, and identity-guarded by the table —
    /// a stale teardown for a same-id ghost stands down instead of dropping the key its live
    /// successor re-registered.
    fn retire_hook(&self, pane: &Arc<dyn Pane>) {
        let retired = self.sessions().unregister_hook(pane);
        if let Some(pane_id) = retired {
            self.hooks().unbind(&pane_id);
        }
    }

    /// Publishes how many connections hold at least one pane.
    pub(crate) fn emit_connection_count(&self) {
        let count = self.sessions().connection_count();
        self.observer().connection_count(count);
    }
}

/// The exit handler a mux pane is given: close its channel, in the host that made it.
///
/// The COMPOSITE key, so a fan-out's other members are untouched — and idempotent with the
/// peer-close path, which closes the same key.
#[derive(Debug)]
pub(crate) struct CloseOnExit {
    pub(crate) host: Weak<Host>,
    pub(crate) key: Key,
}

impl SessionObserver for CloseOnExit {
    fn exited(&self, _code: i32) {
        if let Some(host) = self.host.upgrade() {
            host.close_channel(self.key);
        }
    }
}

/// The exit handler a PARKED pane is given: the shell died while nobody was watching.
///
/// Not [`CloseOnExit`], and the difference is the whole detach: a parked pane has no channel left
/// to close, and its transcript is deliberately KEPT — a reconnect may still cold-restore it, and
/// superd closed its writer when the pane was released.
/// Both edges are WEAK, and both have to be. The pane owns the session that owns the thread that
/// calls this, so a strong edge to the pane is a cycle that outlives the process.
#[derive(Debug)]
struct ParkedExit {
    host: Weak<Host>,
    pane: Weak<dyn Pane>,
    session: Uuid,
}

impl SessionObserver for ParkedExit {
    fn exited(&self, _code: i32) {
        let Some(host) = self.host.upgrade() else {
            return;
        };
        let Some(store) = host.detached() else {
            return;
        };
        // OWNERSHIP GATE: proceed only when THIS call removed the entry. `false` means a claim, an
        // eviction or a drain already took it and owns the teardown — this handler is then a STALE
        // straggler, and it can fire seconds late (a claim-reaped dead child unblocking its own
        // exit wait). Running the per-id teardown anyway would release the journal writer and the
        // hook route a successor has already re-registered.
        if !store.remove(self.session) {
            return;
        }
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        // The transcript is deliberately kept — see the type doc.
        host.fan_teardown(&pane);
        host.retire_hook(&pane);
        host.end_off_thread(&pane);
    }
}
