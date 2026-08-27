//! The two sockets, the three threads, and the one lock every mux decision is taken under.
//!
//! `Sources/SlopDeskVideoHost/Mux/NWVideoMuxDatagramTransport.swift`, and with it the Swift faces
//! that only reached rules through a door: `MuxFlowTable.swift`, `VideoMuxRouter.swift` and
//! `UnboundLaneByePolicy.swift`. Those three are called DIRECTLY here —
//! [`slopdesk_video::mux_flow`], [`slopdesk_video::mux_routing`] — so the port removes them rather
//! than re-facing them.
//!
//! ONE physical UDP flow per host — a media socket and a cursor socket — shared across N client
//! video channels and demultiplexed by the leading big-endian `u32` lane id:
//!
//! ```text
//!   [u32 BE channel_id][u8 channel tag][payload…]   (media socket)
//!   [u32 BE channel_id][payload…]                   (cursor socket)
//! ```
//!
//! ## Plain UDP, not `NWConnection` (`docs/00`, `docs/20` §9.1)
//!
//! The wire was always plain UDP; `NWListener` was the Swift host's way of reaching it, and its one
//! contribution — a pinned object per source endpoint — is [`crate::mux_peers`] here. Three things
//! fall out, and each is a simplification rather than a gap:
//!
//! * **A bind failure is synchronous.** `NWListener(using:on:)` threw only for an immediately
//!   invalid config and delivered a real `EADDRINUSE` asynchronously, where it vanished unless a
//!   state handler caught it: `start()` returned success, the daemon logged "listening…", and no
//!   video ever flowed. [`MuxDatagramTransport::bind`] returns that error to its caller. The Swift
//!   file's deferred "gate start on `.ready`" fix is free here.
//! * **A reaped flow has nothing to close.** An `NWConnection` was a descriptor and an armed
//!   receive callback; a flow here is two map entries. The reap still bounds the map, but the
//!   `cancel()` that had to happen outside the lock does not exist.
//! * **A flow never fails on its own.** `flow_did_reset` had `.failed`/`.cancelled` to drive it,
//!   and UDP gives a shared socket no such per-peer signal — which is why the reap is the only
//!   reclaim path and why it was always the load-bearing one (UDP has no FIN).
//!
//! ## Per-channel loss isolation
//!
//! A lost datagram, or one lane's retire, affects ONLY that lane. Sibling lanes keep routing, and
//! nothing here ever tears the shared flow down for one bad or late datagram.
//!
//! ## The threads
//!
//! Three, all real, none `async` — the daemon idiom this repo already uses. Two blocking receive
//! loops, one per socket, and a reaper parked on a condvar. Sends happen on the caller's thread:
//! `send_to` on a shared socket is the kernel's own serialisation and needs no queue of ours.
//! `stop` flips the flag, wakes the reaper, and pokes each socket with an empty datagram — which is
//! already a `DropEmpty` to [`slopdesk_video::mux_routing::VideoMuxRouter::route`] — so a join does
//! not wait out a receive timeout.

use std::io::Write as _;
use std::net::{SocketAddr, UdpSocket};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_video::idle_reap::IdleReapDecider;
use slopdesk_video::keepalive::{IDLE_TIMEOUT_SECONDS, REAPER_TICK_SECONDS};
use slopdesk_video::mux_flow::{
    FlowId, MuxFlowTable, UnboundByeRateLimiter, payload_is_keepalive, receive_backoff, should_rearm,
    warrants_bye,
};
use slopdesk_video::mux_header;
use slopdesk_video::mux_routing::{
    BootstrapAction, DispatchDecision, MuxDecision, VideoMuxRouter, bootstrap_action, dispatch_decision,
};
use slopdesk_video::recovery_routing::VideoChannel;
use slopdesk_video::video_control::VideoControlMessage;

use crate::mux_lane::LaneControl;
use crate::mux_peers::PeerRegistry;

/// What the transport hands its owner: a demultiplexed datagram, and a lane the reaper declared
/// dead.
///
/// Held WEAKLY by the receive threads. The observer is the session registry, which holds this
/// transport so its lanes can send — a strong edge back would close a cycle no drop could break.
/// An `Arc<Self>` receiver rather than `&self` because the registry spawns its mint from inside
/// `receive` and needs itself to still be there when that thread runs.
pub trait MuxObserver: Send + Sync + core::fmt::Debug {
    /// One datagram, already demultiplexed and stripped of its lane id and channel tag.
    fn receive(self: Arc<Self>, channel_id: u32, channel: VideoChannel, payload: &[u8]);
    /// A lane went silent past the idle timeout. Symmetric to a `bye`: unregister the sink AND stop
    /// the session, or the capture keeps running for nobody.
    fn reap_lane(self: Arc<Self>, channel_id: u32);
}

/// The four numbers the mux's own bookkeeping is timed by.
///
/// Parameters rather than constants for the reason the rule types already take them: a test that
/// had to wait thirty real seconds for a reap would not be written.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MuxTiming {
    /// How long a lane, or an unreferenced flow, may be silent before it is reaped.
    pub idle_timeout: f64,
    /// The reaper's scan cadence, and the receive loops' fallback wake.
    pub reaper_tick: f64,
    /// The minimum spacing between unbound-lane `bye` replies for the same lane.
    pub bye_min_interval: f64,
    /// How many lanes the `bye` limiter will track before it starts denying new ones.
    pub bye_capacity: usize,
}

impl MuxTiming {
    /// The minimum spacing between unbound-lane `bye` replies, in seconds.
    ///
    /// ⚠️ **This number has no home in `slopdesk-video`.** [`UnboundByeRateLimiter::new`] takes it
    /// as a parameter and no constant stands beside it; on the Swift side it was a default argument
    /// in `UnboundByeRateLimiter.init`. `docs/20` §9.2 states the contract — "rate-limited, one per
    /// second per channelID" — so the value is pinned by a doc and by nothing a test can reach. It
    /// belongs beside the limiter that enforces it.
    pub const UNBOUND_BYE_MIN_INTERVAL_SECONDS: f64 = 1.0;
    /// How many lanes the `bye` limiter tracks. Same finding as the interval above: a Swift default
    /// argument with no constant in the rule crate.
    pub const UNBOUND_BYE_CAPACITY: usize = 256;

    /// The shipping contract: the keepalive constants both ends already share, and the two numbers
    /// above.
    #[must_use]
    pub const fn contract() -> Self {
        Self {
            idle_timeout: IDLE_TIMEOUT_SECONDS,
            reaper_tick: REAPER_TICK_SECONDS,
            bye_min_interval: Self::UNBOUND_BYE_MIN_INTERVAL_SECONDS,
            bye_capacity: Self::UNBOUND_BYE_CAPACITY,
        }
    }
}

impl Default for MuxTiming {
    fn default() -> Self {
        Self::contract()
    }
}

/// The receive buffer, sized to the largest datagram UDP itself can carry.
///
/// NOT [`slopdesk_video::fragment::MAX_DATAGRAM_SIZE`], which is the size this host SENDS to stay
/// inside the path MTU. A buffer sized to that would silently TRUNCATE anything a peer sent over
/// it, turning a misbehaving client into a stream of undecodable datagrams rather than a decode
/// that fails honestly. One allocation per receive thread, for the daemon's whole life.
const DATAGRAM_BUFFER_BYTES: usize = 65_536;

/// The mux bookkeeping, all of it under one lock, exactly as the Swift held it.
#[derive(Debug)]
struct State {
    /// Which flow answers a lane, and which flows a tick may forget.
    flows: MuxFlowTable,
    /// Which peer address each flow id names — the `NWConnection` registry's replacement.
    peers: PeerRegistry,
    /// The reconnect-generation-safe admit / retire / drain table.
    router: VideoMuxRouter,
    /// Bounds the unbound-lane `bye` replies.
    limiter: UnboundByeRateLimiter,
    /// The per-lane idle-timeout reaper, keyed by lane so a crashed lane is reaped independently of
    /// its siblings.
    reaper: IdleReapDecider<u32>,
    stopped: bool,
}

impl State {
    /// Interns a peer and refreshes its flow's last-inbound stamp.
    ///
    /// Any decoded inbound datagram proves the tuple alive, whatever the routing decision says
    /// about the lane — a wedged-but-talking client's flow must not be reaped out from under the
    /// `bye` replies that un-wedge it.
    fn observe(&mut self, peer: SocketAddr, is_media: bool, now: f64) -> FlowId {
        let (flow, fresh) = self.peers.intern(peer, is_media);
        if fresh {
            self.flows.accept(flow, is_media, now);
        }
        self.flows.note_inbound(flow, now);
        flow
    }
}

/// Everything the threads share: the sockets, the clock anchor and the state.
#[derive(Debug)]
struct Inner {
    media: UdpSocket,
    cursor: UdpSocket,
    /// Monotonic, and deliberately not a wall clock: an NTP step or a sleep-wake must never
    /// spuriously reap a live lane.
    anchor: Instant,
    timing: MuxTiming,
    state: Mutex<State>,
    /// Woken on stop, so a reaper parked on its tick does not hold the join open.
    tick: Condvar,
}

/// The host UDP video transport.
#[derive(Debug)]
pub struct MuxDatagramTransport {
    inner: Arc<Inner>,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

impl Drop for MuxDatagramTransport {
    fn drop(&mut self) {
        self.stop();
    }
}

impl MuxDatagramTransport {
    /// Binds the shared media and cursor sockets.
    ///
    /// The two ports are distinct by contract (`docs/20` §9.1): the cursor lane is split onto its
    /// own socket so pointer latency is RTT, decoupled from video-burst head-of-line blocking. A
    /// port of `0` binds an ephemeral one, which is how a test talks to itself.
    ///
    /// # Errors
    /// Whatever the bind failed with — `EADDRINUSE` above all, which is the one the Swift lost.
    pub fn bind(media_port: u16, cursor_port: u16, timing: MuxTiming) -> std::io::Result<Self> {
        let media = UdpSocket::bind(SocketAddr::from(([0, 0, 0, 0], media_port)))?;
        let cursor = UdpSocket::bind(SocketAddr::from(([0, 0, 0, 0], cursor_port)))?;
        // A bounded receive so a lost wake datagram cannot hold a join open for ever. The cadence
        // is the reaper's, because a coarse poll is all this is; the datagram is what makes a stop
        // prompt.
        let poll = Duration::from_secs_f64(timing.reaper_tick);
        media.set_read_timeout(Some(poll))?;
        cursor.set_read_timeout(Some(poll))?;
        Ok(Self {
            inner: Arc::new(Inner {
                media,
                cursor,
                anchor: Instant::now(),
                timing,
                state: Mutex::new(State {
                    flows: MuxFlowTable::new(timing.idle_timeout),
                    peers: PeerRegistry::new(),
                    router: VideoMuxRouter::new(),
                    limiter: UnboundByeRateLimiter::new(timing.bye_min_interval, timing.bye_capacity),
                    reaper: IdleReapDecider::new(timing.idle_timeout),
                    stopped: false,
                }),
                tick: Condvar::new(),
            }),
            threads: Mutex::new(Vec::new()),
        })
    }

    /// The port the media socket actually bound.
    ///
    /// # Errors
    /// Whatever `getsockname` failed with.
    pub fn media_port(&self) -> std::io::Result<u16> {
        Ok(self.inner.media.local_addr()?.port())
    }

    /// The port the cursor socket actually bound.
    ///
    /// # Errors
    /// Whatever `getsockname` failed with.
    pub fn cursor_port(&self) -> std::io::Result<u16> {
        Ok(self.inner.cursor.local_addr()?.port())
    }

    /// Starts the two receive loops and the reaper.
    ///
    /// Idempotent in the only sense that matters: calling it twice would run two of each, so it
    /// refuses once threads are up.
    pub fn start(&self, observer: &Arc<dyn MuxObserver>) {
        let mut threads = self.threads.lock().unwrap_or_else(PoisonError::into_inner);
        if !threads.is_empty() {
            return;
        }
        let weak = Arc::downgrade(observer);
        for is_media in [true, false] {
            let inner = Arc::clone(&self.inner);
            let observer = Weak::clone(&weak);
            threads.push(std::thread::spawn(move || {
                receive_loop(&inner, is_media, &observer);
            }));
        }
        let inner = Arc::clone(&self.inner);
        threads.push(std::thread::spawn(move || {
            reaper_loop(&inner, &weak);
        }));
    }

    /// Admits a lane as live — the daemon minted or looked up its session. Idempotent.
    pub fn admit(&self, channel_id: u32) {
        self.inner.locked().router.admit(channel_id);
    }

    /// Retires a lane: its still-in-flight datagrams drop, and SIBLING lanes are untouched.
    ///
    /// The reaper record goes too, whether this came from a clean `bye` or from the reaper itself,
    /// so a reconnect under the same lane id starts a FRESH record and has to prove keepalive
    /// again.
    pub fn retire(&self, channel_id: u32) {
        let mut state = self.inner.locked();
        state.router.retire(channel_id);
        state.flows.retire_lane(channel_id);
        state.reaper.forget(&channel_id);
    }

    /// Whether a lane is currently routable.
    #[must_use]
    pub fn is_admitted(&self, channel_id: u32) -> bool {
        self.inner.locked().router.is_admitted(channel_id)
    }

    /// Sends one datagram for a lane, framed for the socket its channel rides.
    ///
    /// Fire-and-forget, as UDP is. A lane with no known reply flow drops — the client has not
    /// opened it — and never blocks or errors the shared flow out.
    pub fn send(&self, datagram: &[u8], channel: VideoChannel, channel_id: u32) {
        self.inner.send(datagram, channel, channel_id);
    }

    /// Stops the threads and drops every flow. Idempotent, and `Drop` calls it.
    pub fn stop(&self) {
        let already = {
            let mut state = self.inner.locked();
            let already = state.stopped;
            state.stopped = true;
            if !already {
                // Nothing to close: a flow is a map entry here, not a descriptor.
                drop(state.flows.remove_all());
                state.peers.release_all();
            }
            already
        };
        self.inner.tick.notify_all();
        if !already {
            self.inner.poke();
        }
        let handles: Vec<JoinHandle<()>> = self
            .threads
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .drain(..)
            .collect();
        for handle in handles {
            drop(handle.join());
        }
    }
}

impl LaneControl for MuxDatagramTransport {
    fn admit(&self, channel_id: u32) {
        Self::admit(self, channel_id);
    }

    fn retire(&self, channel_id: u32) {
        Self::retire(self, channel_id);
    }

    fn send(&self, datagram: &[u8], channel: VideoChannel, channel_id: u32) {
        Self::send(self, datagram, channel, channel_id);
    }
}

impl Inner {
    fn locked(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn stopped(&self) -> bool {
        self.locked().stopped
    }

    /// Monotonic host seconds since this transport bound.
    fn now(&self) -> f64 {
        self.anchor.elapsed().as_secs_f64()
    }

    /// Wakes both receive loops with an EMPTY datagram — already a `DropEmpty` to the router, and
    /// short of the four bytes the header codec needs, so it can never be mistaken for traffic.
    fn poke(&self) {
        for socket in [&self.media, &self.cursor] {
            if let Ok(bound) = socket.local_addr() {
                let itself = SocketAddr::from(([127, 0, 0, 1], bound.port()));
                if let Err(error) = socket.send_to(&[], itself) {
                    note(&format!("stop wake failed on {itself}: {error}"));
                }
            }
        }
    }

    /// One media datagram: `[channel_id][tag][payload]`, routed by lane.
    ///
    /// **Bootstrap.** A lane is admitted only once its session is minted, so the very FIRST hello
    /// for a never-seen lane arrives unadmitted. A hello — or a session-less discovery request —
    /// on the control channel is therefore still delivered, and its reply flow stamped, so the
    /// registry can mint or answer.
    ///
    /// **Cross-process lane reuse.** A retired lane id can collide with a restarted client's fresh
    /// one. A retired lane hard-drops everything EXCEPT a real hello, which re-admits it: the dead
    /// old process has no in-flight datagrams left, so stale video and input still drop and
    /// reconnect-generation safety holds.
    ///
    /// **The stray-control leak guard.** A reply flow is remembered ONLY for a lane whose first
    /// unadmitted datagram actually decodes as a hello or a list request. A stray or adversarial
    /// one drops WITHOUT a stamp, which would otherwise grow a map entry per lane id that never
    /// helloed. Every rule above is [`bootstrap_action`]'s; the peeks are fed to it, once.
    fn route_media(&self, datagram: &[u8], peer: SocketAddr, observer: &Weak<dyn MuxObserver>) {
        let Ok((channel_id, rest)) = mux_header::decode(datagram) else {
            return;
        };
        let Some(&tag) = rest.first() else {
            return;
        };
        let Some(channel) = VideoChannel::from_raw_value(tag) else {
            return;
        };
        let payload = rest.get(1..).unwrap_or_default();

        let outcome = {
            let mut state = self.locked();
            let now = self.now();
            let flow = state.observe(peer, true, now);
            // The WHOLE datagram's length, prefix and tag included, exactly as the Swift passed it:
            // the empty-datagram drop is about the datagram, not about what survived parsing.
            match state.router.route(channel_id, datagram.len()) {
                MuxDecision::Route { .. } => {
                    state.flows.stamp_media_reply(channel_id, flow);
                    // The lane's liveness stamp is taken for an ADMITTED lane only. An un-minted
                    // lane has no session to reap, and stamping one would grow the decider's map
                    // for every stray id.
                    let keepalive = payload_is_keepalive(channel, payload);
                    state.reaper.note_inbound(channel_id, now, keepalive);
                    Outcome::Deliver
                },
                decision @ (MuxDecision::RejectUnadmitted | MuxDecision::DropRetired) => {
                    let action = bootstrap_action(
                        decision,
                        channel,
                        payload_is_hello(channel_id, channel, payload),
                        payload_is_list_request(channel, payload),
                    );
                    match action {
                        BootstrapAction::BootstrapDeliver => {
                            state.flows.stamp_media_bootstrap(channel_id, flow, now);
                            Outcome::Deliver
                        },
                        BootstrapAction::DropNoStamp => {
                            // A dropped datagram that proves its sender still believes a session
                            // exists — typically a client that survived a daemon restart — is
                            // answered with a `bye` on the arrival flow, so it tears down and
                            // re-hellos instead of freezing for ever. No bookkeeping is stamped:
                            // the reply rides the arrival address directly, so the leak guard above
                            // still holds.
                            if warrants_bye(channel, payload) && state.limiter.admit(channel_id, now) {
                                Outcome::Bye
                            } else {
                                Outcome::Drop
                            }
                        },
                    }
                },
                // Draining: mid-teardown, so even a hello drops until the drain ends — no false
                // accept to a dying sink, no premature re-mint. Empty: nothing to route. Both
                // benign, neither fatal, and neither touches a sibling.
                MuxDecision::DropDraining | MuxDecision::DropEmpty => Outcome::Drop,
            }
        };
        match outcome {
            Outcome::Deliver => {
                if let Some(observer) = observer.upgrade() {
                    observer.receive(channel_id, channel, payload);
                }
            },
            Outcome::Bye => self.send_unbound_bye(channel_id, peer),
            Outcome::Drop => {},
        }
    }

    /// One cursor datagram: `[channel_id][payload]`, which binds a reply flow and nothing else.
    ///
    /// Inbound cursor bytes are never delivered to a session — the cursor socket is host→client
    /// after the prime — but the host MUST learn the lane's flow from it. The stamp is accepted for
    /// a not-yet-admitted lane because the prime legitimately races AHEAD of the media hello; the
    /// `is_admitted` bit is what makes a never-admitted stamp time-tracked, so a lane that never
    /// arrives is swept rather than left behind.
    ///
    /// Deliberately NOT stamped for the per-lane reaper: keepalives ride the MEDIA socket's control
    /// channel, so that stamp is the sole authoritative lane liveness.
    fn route_cursor(&self, datagram: &[u8], peer: SocketAddr) {
        let Ok((channel_id, _rest)) = mux_header::decode(datagram) else {
            return;
        };
        let mut state = self.locked();
        let now = self.now();
        let flow = state.observe(peer, false, now);
        let admitted = state.router.is_admitted(channel_id);
        state.flows.stamp_cursor_reply(channel_id, flow, now, admitted);
    }

    /// Answers an unbound lane on the SAME address its datagram arrived from, leaving the lane
    /// forgotten. Fire-and-forget: the client's next keepalive re-triggers it if this one is lost.
    fn send_unbound_bye(&self, channel_id: u32, peer: SocketAddr) {
        let framed = mux_header::encode_media(
            channel_id,
            VideoChannel::Control.raw_value(),
            &VideoControlMessage::Bye.encode(),
        );
        note(&format!(
            "unbound lane {channel_id} still talking (host restarted?) — answering bye"
        ));
        if let Err(error) = self.media.send_to(&framed, peer) {
            note(&format!("unbound-lane bye send failed for {channel_id}: {error}"));
        }
    }

    fn send(&self, datagram: &[u8], channel: VideoChannel, channel_id: u32) {
        // `docs/20` §9.1: the cursor channel is the ONE that rides its own socket; every other
        // channel is a tagged datagram on the media socket.
        let is_media = !matches!(channel, VideoChannel::Cursor);
        let peer = {
            let state = self.locked();
            let flow = if is_media {
                state.flows.media_reply_flow(channel_id)
            } else {
                state.flows.cursor_reply_flow(channel_id)
            };
            flow.and_then(|flow| state.peers.peer(flow))
        };
        let Some(peer) = peer else {
            return;
        };
        // One allocation: the payload bytes are appended exactly once, producing the same wire
        // bytes a naive inner `[tag][payload]` buffer plus a prefix encode would.
        let framed = if is_media {
            mux_header::encode_media(channel_id, channel.raw_value(), datagram)
        } else {
            mux_header::encode(channel_id, datagram)
        };
        let socket = if is_media { &self.media } else { &self.cursor };
        if let Err(error) = socket.send_to(&framed, peer) {
            note(&format!(
                "mux send failed channel={} lane={channel_id}: {error}",
                channel.raw_value()
            ));
        }
    }

    /// One reaper scan: hold each dead lane DRAINING, stop its session, free the lane LAST.
    ///
    /// The order is the whole point. Retiring the router lane before stopping the session would let
    /// a reconnect hello racing that window route as a retired re-admit, reach the OLD sink, and
    /// take a false accept from a dying session — a client stuck on a dead stream. So the drain
    /// begins synchronously (a racing reconnect drops as `DropDraining`, not into the old sink),
    /// the reaper record is forgotten so the next tick will not re-schedule it, the session is
    /// stopped, and only THEN does the drain end, where a fresh hello may cleanly re-admit.
    fn reaper_tick(&self, observer: &Weak<dyn MuxObserver>) {
        let now = self.now();
        let due = {
            let mut state = self.locked();
            let due = state.reaper.reap(now);
            for channel_id in &due {
                state.router.begin_drain(*channel_id);
                state.reaper.forget(channel_id);
            }
            due
        };
        for channel_id in due {
            if let Some(observer) = observer.upgrade() {
                observer.reap_lane(channel_id);
            }
            let mut state = self.locked();
            state.router.end_drain(channel_id);
            state.flows.retire_lane(channel_id);
        }
        // The FLOW sweep: never-admitted reply stamps first, then the idle flows no stamp
        // references. Both rules are `mux_flow.rs`'s; `is_admitted` is the question it asks back,
        // because the answer lives in the router beside it.
        let mut state = self.locked();
        let State {
            flows, router, peers, ..
        } = &mut *state;
        let asking = &*router;
        let dead = flows.reap(now, |channel_id| asking.is_admitted(channel_id));
        for flow in dead {
            peers.release(flow);
        }
        drop(state);
    }
}

/// What [`Inner::route_media`] decided under the lock. The send happens outside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Deliver,
    Drop,
    Bye,
}

/// One socket's whole life.
///
/// The re-arm question is [`should_rearm`]'s, and its input here is the SOCKET's liveness rather
/// than a per-peer connection's: a shared UDP socket is alive until this transport stops, and a
/// per-datagram error — an ICMP port-unreachable surfacing on the next receive — is exactly the
/// transient the rule exists to survive. A read timeout is not an error at all; it is the poll that
/// lets a stop that lost its wake datagram still land.
fn receive_loop(inner: &Arc<Inner>, is_media: bool, observer: &Weak<dyn MuxObserver>) {
    let socket = if is_media { &inner.media } else { &inner.cursor };
    let mut buffer = vec![0_u8; DATAGRAM_BUFFER_BYTES];
    let mut consecutive_errors = 0_u32;
    loop {
        if inner.stopped() {
            return;
        }
        match socket.recv_from(&mut buffer) {
            Ok((read, peer)) => {
                consecutive_errors = 0;
                if inner.stopped() {
                    return;
                }
                if let Some(datagram) = buffer.get(..read) {
                    if is_media {
                        inner.route_media(datagram, peer, observer);
                    } else {
                        inner.route_cursor(datagram, peer);
                    }
                }
            },
            Err(error) if quiet(&error) => {},
            Err(error) => {
                if !should_rearm(!inner.stopped()) {
                    return;
                }
                consecutive_errors = consecutive_errors.saturating_add(1);
                note(&format!(
                    "mux {} receive error (transient, backing off): {error}",
                    if is_media { "media" } else { "cursor" }
                ));
                std::thread::sleep(Duration::from_secs_f64(receive_backoff(consecutive_errors)));
            },
        }
    }
}

/// Whether a receive error is "no datagram arrived" rather than a fault to back off from.
fn quiet(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted
    )
}

/// The reaper thread: park on the tick, wake early for a stop.
fn reaper_loop(inner: &Arc<Inner>, observer: &Weak<dyn MuxObserver>) {
    let tick = Duration::from_secs_f64(inner.timing.reaper_tick);
    loop {
        // `wait_timeout_while` rather than a check-then-wait: the predicate is re-read under the
        // lock the condvar re-takes, so a stop that lands between the two cannot be slept through.
        let stopped = {
            let (parked, _elapsed) = inner
                .tick
                .wait_timeout_while(inner.locked(), tick, |state| !state.stopped)
                .unwrap_or_else(PoisonError::into_inner);
            parked.stopped
        };
        if stopped {
            return;
        }
        inner.reaper_tick(observer);
    }
}

/// Whether a control payload decodes as a session-MINTING hello — the window `hello` or the
/// full-desktop `helloDisplay`.
///
/// Asked of [`dispatch_decision`] rather than answered here, because that function already IS the
/// rule: with no live lane and no mint in flight, it answers `Mint` for exactly the payloads that
/// bootstrap a session, on exactly the channel that can carry one. A `matches!` over the control
/// grammar written beside it would be a second reader of that grammar — which is precisely how
/// `helloDisplay` once got left out of a hand-mirrored copy.
fn payload_is_hello(channel_id: u32, channel: VideoChannel, payload: &[u8]) -> bool {
    matches!(
        dispatch_decision(channel_id, channel, payload, false, false),
        DispatchDecision::Mint { .. }
    )
}

/// Whether a control payload is a session-LESS discovery request, which bootstraps a reply flow so
/// the daemon can answer it WITHOUT minting a capture session.
///
/// ⚠️ **This set has no home in `slopdesk-video`, and it should.** `mux_flow.rs`'s `warrants_bye`
/// states the COMPLEMENT — "the list requests are session-LESS discovery, so neither is answered" —
/// but the positive predicate exists nowhere in the rule crate, and it cannot be derived from that
/// one (a stray `bye` and an undecodable payload are also un-answered without being discovery). So
/// it was hand-written in `NWVideoMuxDatagramTransport.swift`, and it is hand-written here.
///
/// The Swift's own warning applies verbatim and is the reason this is worth moving: EVERY new
/// client→host session-less type must be added here AND stay bye-exempt in `warrants_bye`, and a
/// missed site is a SILENT drop — no log, no bye, the client simply never hears back. Two lists in
/// two crates cannot be kept in step by anything; one list in `mux_flow.rs`, with the bye rule
/// derived from it, can.
fn payload_is_list_request(channel: VideoChannel, payload: &[u8]) -> bool {
    matches!(channel, VideoChannel::Control)
        && matches!(
            VideoControlMessage::decode(payload),
            Ok(VideoControlMessage::ListWindows
                | VideoControlMessage::ListSystemDialogs
                | VideoControlMessage::WindowFeedSubscribe { .. }
                | VideoControlMessage::AppIconRequest { .. }
                | VideoControlMessage::WindowPreviewRequest { .. }
                | VideoControlMessage::ListDisplays)
        )
}

/// One diagnostic line on stderr, and only when `SLOPDESK_VIDEO_DEBUG` is set.
///
/// ONE `write_all` of ONE buffer, for the reason `main.rs` gives: two writes can interleave with
/// another thread's, and three threads run through here. The gate is read once — this is on the
/// per-datagram path, where an environment lookup is not.
fn note(message: &str) {
    static DEBUG: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if !DEBUG.get_or_init(|| std::env::var_os("SLOPDESK_VIDEO_DEBUG").is_some()) {
        return;
    }
    drop(std::io::stderr().write_all(format!("slopdesk-videohostd: {message}\n").as_bytes()));
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::net::{SocketAddr, UdpSocket};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use slopdesk_video::geometry::VideoSize;
    use slopdesk_video::mux_header;
    use slopdesk_video::recovery_routing::VideoChannel;
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{MuxDatagramTransport, MuxObserver, MuxTiming};

    /// Fast enough that a reap test finishes in a blink, and every rule under it is unchanged.
    const BRISK: MuxTiming = MuxTiming {
        idle_timeout: 0.08,
        reaper_tick: 0.02,
        bye_min_interval: 1.0,
        bye_capacity: 256,
    };

    /// Slow enough that nothing is reaped mid-test, with a tick short enough to keep a stop prompt.
    const PATIENT: MuxTiming = MuxTiming {
        idle_timeout: 60.0,
        reaper_tick: 0.02,
        bye_min_interval: 1.0,
        bye_capacity: 256,
    };

    #[derive(Debug, Default)]
    struct Watcher {
        received: Mutex<Vec<(u32, u8, Vec<u8>)>>,
        reaped: Mutex<Vec<u32>>,
    }

    impl MuxObserver for Watcher {
        fn receive(self: Arc<Self>, channel_id: u32, channel: VideoChannel, payload: &[u8]) {
            self.received.lock().expect("uncontended").push((
                channel_id,
                channel.raw_value(),
                payload.to_vec(),
            ));
        }

        fn reap_lane(self: Arc<Self>, channel_id: u32) {
            self.reaped.lock().expect("uncontended").push(channel_id);
        }
    }

    /// A transport talking to itself over the loopback: no peer, no hardware, no window server.
    struct Loop {
        transport: MuxDatagramTransport,
        watcher: Arc<Watcher>,
        client_media: UdpSocket,
        client_cursor: UdpSocket,
        media_to: SocketAddr,
        cursor_to: SocketAddr,
    }

    impl Loop {
        fn new(timing: MuxTiming) -> Self {
            let transport = MuxDatagramTransport::bind(0, 0, timing).expect("an ephemeral pair binds");
            let watcher = Arc::new(Watcher::default());
            let strong = Arc::clone(&watcher);
            let observer: Arc<dyn MuxObserver> = strong;
            transport.start(&observer);
            let client_media = UdpSocket::bind("127.0.0.1:0").expect("a client port");
            let client_cursor = UdpSocket::bind("127.0.0.1:0").expect("a client port");
            for socket in [&client_media, &client_cursor] {
                socket
                    .set_read_timeout(Some(Duration::from_millis(500)))
                    .expect("a read timeout");
            }
            let media_to = SocketAddr::from(([127, 0, 0, 1], transport.media_port().expect("bound")));
            let cursor_to = SocketAddr::from(([127, 0, 0, 1], transport.cursor_port().expect("bound")));
            Self {
                transport,
                watcher,
                client_media,
                client_cursor,
                media_to,
                cursor_to,
            }
        }

        fn send_media(&self, channel_id: u32, channel: VideoChannel, payload: &[u8]) {
            let framed = mux_header::encode_media(channel_id, channel.raw_value(), payload);
            let _sent = self.client_media.send_to(&framed, self.media_to).expect("sent");
        }

        fn prime_cursor(&self, channel_id: u32) {
            let framed = mux_header::encode(channel_id, &[]);
            let _sent = self.client_cursor.send_to(&framed, self.cursor_to).expect("sent");
        }

        fn received(&self) -> Vec<(u32, u8, Vec<u8>)> {
            self.watcher.received.lock().expect("uncontended").clone()
        }

        fn reaped(&self) -> Vec<u32> {
            self.watcher.reaped.lock().expect("uncontended").clone()
        }

        /// One reply on the client's media socket, or `None` inside the read timeout.
        fn reply(socket: &UdpSocket) -> Option<Vec<u8>> {
            let mut buffer = [0_u8; 2048];
            socket
                .recv_from(&mut buffer)
                .ok()
                .and_then(|(read, _)| buffer.get(..read).map(<[u8]>::to_vec))
        }
    }

    fn hello() -> Vec<u8> {
        VideoControlMessage::Hello {
            protocol_version: 1,
            requested_window_id: 42,
            viewport: VideoSize {
                width: 1280.0,
                height: 800.0,
            },
        }
        .encode()
    }

    /// Real threads, so every assertion about them waits rather than assuming.
    fn until(window: Duration, mut done: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + window;
        while Instant::now() < deadline {
            if done() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        done()
    }

    /// Long enough that a thread that was going to act has, on any machine this runs on.
    fn settle(done: impl FnMut() -> bool) -> bool {
        until(Duration::from_secs(5), done)
    }

    /// The negative form. Bounded far shorter, because it can only ever run its window out — and
    /// it is still fifteen reaper ticks at [`BRISK`], which is the fastest thing being waited on.
    fn never(done: impl FnMut() -> bool) -> bool {
        until(Duration::from_millis(300), done)
    }

    #[test]
    fn the_two_sockets_bind_distinct_ports_and_report_them() {
        let transport = MuxDatagramTransport::bind(0, 0, PATIENT).expect("binds");
        let media = transport.media_port().expect("bound");
        let cursor = transport.cursor_port().expect("bound");
        assert_ne!(media, 0);
        assert_ne!(cursor, 0);
        assert_ne!(media, cursor, "the cursor lane has its own socket (docs/20 §9.1)");
    }

    /// The failure the Swift lost to an async state handler: a second bind on a held port.
    #[test]
    fn a_port_already_held_fails_the_bind_rather_than_pretending_to_listen() {
        let first = MuxDatagramTransport::bind(0, 0, PATIENT).expect("binds");
        let held = first.media_port().expect("bound");
        assert!(
            MuxDatagramTransport::bind(held, 0, PATIENT).is_err(),
            "EADDRINUSE reaches the caller",
        );
    }

    #[test]
    fn a_first_hello_bootstraps_an_unadmitted_lane_and_reaches_the_observer() {
        let case = Loop::new(PATIENT);
        case.send_media(7, VideoChannel::Control, &hello());
        assert!(settle(|| !case.received().is_empty()), "the hello never arrived");
        assert_eq!(case.received(), vec![(
            7,
            VideoChannel::Control.raw_value(),
            hello()
        )],);
    }

    /// The stray-control leak guard: a non-hello for an unknown lane must leave no reply stamp.
    #[test]
    fn a_stray_control_datagram_is_neither_delivered_nor_remembered() {
        let case = Loop::new(PATIENT);
        // A `bye` warrants no reply and bootstraps nothing, so it is the pure stray.
        case.send_media(7, VideoChannel::Control, &VideoControlMessage::Bye.encode());
        assert!(!never(|| !case.received().is_empty()), "nothing may be delivered");
        // Nothing was stamped, so a host→client send for that lane has no flow and drops.
        case.transport.send(&[1, 2, 3], VideoChannel::Video, 7);
        assert_eq!(Loop::reply(&case.client_media), None);
    }

    #[test]
    fn an_admitted_lane_routes_and_replies_on_the_flow_it_arrived_on() {
        let case = Loop::new(PATIENT);
        case.transport.admit(7);
        assert!(case.transport.is_admitted(7));
        case.send_media(7, VideoChannel::Input, &[9, 9]);
        assert!(settle(|| !case.received().is_empty()));
        assert_eq!(case.received(), vec![(7, VideoChannel::Input.raw_value(), vec![
            9, 9
        ])]);

        case.transport.send(&[4, 5, 6], VideoChannel::Video, 7);
        let framed = Loop::reply(&case.client_media).expect("a media reply");
        assert_eq!(
            framed,
            mux_header::encode_media(7, VideoChannel::Video.raw_value(), &[4, 5, 6]),
        );
    }

    /// The prime legitimately races ahead of the media hello, so it binds an unadmitted lane too.
    #[test]
    fn a_cursor_prime_binds_the_lanes_cursor_reply_flow() {
        let case = Loop::new(PATIENT);
        case.prime_cursor(7);
        assert!(settle(|| {
            case.transport.send(&[1, 2], VideoChannel::Cursor, 7);
            Loop::reply(&case.client_cursor).is_some()
        }));
        case.transport.send(&[1, 2], VideoChannel::Cursor, 7);
        assert_eq!(
            Loop::reply(&case.client_cursor).expect("a cursor reply"),
            mux_header::encode(7, &[1, 2]),
            "the cursor socket is untagged (docs/20 §9.1)",
        );
        assert!(
            case.received().is_empty(),
            "inbound cursor bytes bind a flow and are never delivered",
        );
    }

    /// The reconnect wedge: a client that survived a daemon restart must be told its lane is gone.
    #[test]
    fn a_wedged_lane_is_answered_with_a_bye_at_most_once_an_interval() {
        let case = Loop::new(PATIENT);
        let keepalive = VideoControlMessage::Keepalive.encode();
        case.send_media(7, VideoChannel::Control, &keepalive);
        let framed = Loop::reply(&case.client_media).expect("a bye");
        assert_eq!(
            framed,
            mux_header::encode_media(
                7,
                VideoChannel::Control.raw_value(),
                &VideoControlMessage::Bye.encode()
            ),
        );
        case.send_media(7, VideoChannel::Control, &keepalive);
        assert_eq!(
            Loop::reply(&case.client_media),
            None,
            "one per interval per lane, and the interval is a second",
        );
        assert!(
            case.received().is_empty(),
            "a wedged lane is answered, never routed"
        );
    }

    /// The crash-without-bye gap the reaper closes: a lane that PROVED keepalive then went silent.
    #[test]
    fn a_lane_that_proved_keepalive_then_fell_silent_is_reaped() {
        let case = Loop::new(BRISK);
        case.transport.admit(1);
        case.send_media(1, VideoChannel::Control, &VideoControlMessage::Keepalive.encode());
        assert!(settle(|| !case.received().is_empty()), "the keepalive must route");
        assert!(
            settle(|| !case.reaped().is_empty()),
            "the silent lane was never reaped"
        );
        assert_eq!(case.reaped(), vec![1]);
        assert!(
            !case.transport.is_admitted(1),
            "the drain ended in retired, where a fresh hello may re-admit",
        );
    }

    /// A lane that never spoke keepalive degrades to no-reap rather than being torn down.
    #[test]
    fn a_lane_that_never_spoke_keepalive_is_left_alone() {
        let case = Loop::new(BRISK);
        case.transport.admit(1);
        case.send_media(1, VideoChannel::Input, &[1]);
        assert!(settle(|| !case.received().is_empty()));
        assert!(
            !never(|| !case.reaped().is_empty()),
            "a legacy client is never reaped"
        );
    }

    #[test]
    fn retiring_a_lane_leaves_its_siblings_streaming() {
        let case = Loop::new(PATIENT);
        case.transport.admit(7);
        case.transport.admit(8);
        case.send_media(7, VideoChannel::Input, &[1]);
        case.send_media(8, VideoChannel::Input, &[2]);
        assert!(settle(|| case.received().len() == 2));
        case.transport.retire(7);
        assert!(!case.transport.is_admitted(7));
        assert!(case.transport.is_admitted(8));
        // Lane 7's reply stamp went with it; lane 8's did not.
        case.transport.send(&[3], VideoChannel::Video, 7);
        assert_eq!(Loop::reply(&case.client_media), None);
        case.transport.send(&[3], VideoChannel::Video, 8);
        assert!(Loop::reply(&case.client_media).is_some());
    }

    #[test]
    fn a_stop_joins_promptly_and_is_idempotent() {
        let case = Loop::new(PATIENT);
        case.send_media(7, VideoChannel::Control, &hello());
        assert!(settle(|| !case.received().is_empty()));
        let started = Instant::now();
        case.transport.stop();
        case.transport.stop();
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "the wake datagram, not the receive timeout, is what ends a stop",
        );
    }

    #[test]
    fn a_truncated_or_unknown_tagged_datagram_drops_without_a_trace() {
        let case = Loop::new(PATIENT);
        case.transport.admit(7);
        let _short = case.client_media.send_to(&[0, 0], case.media_to).expect("sent");
        let _tagless = case
            .client_media
            .send_to(&mux_header::encode(7, &[]), case.media_to)
            .expect("sent");
        // Tag 99 names no channel.
        let _unknown_tag = case
            .client_media
            .send_to(&mux_header::encode_media(7, 99, &[1]), case.media_to)
            .expect("sent");
        assert!(!never(|| !case.received().is_empty()));
    }

    #[test]
    fn the_shipping_timing_is_the_keepalive_contract() {
        let timing = MuxTiming::default();
        assert_eq!(timing, MuxTiming::contract());
        assert!(timing.idle_timeout > timing.reaper_tick);
        assert_eq!(timing.bye_capacity, MuxTiming::UNBOUND_BYE_CAPACITY);
    }
}
