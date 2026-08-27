//! One shared flow into N independent sessions — the daemon's side of the mux.
//!
//! `Sources/SlopDeskVideoHost/Mux/VideoMuxSessionRegistry.swift`.
//!
//! ## The asymmetry this exists for (`docs/01` §2)
//!
//! Two video panes on the SAME host watch DIFFERENT windows. So they send different hellos, naming
//! different windows, and need different sessions — the registry cannot pre-mint anything. It mints
//! LAZILY, on the first hello it sees for a never-seen lane, picking the window that hello names;
//! every later datagram for that lane goes to the session's sink.
//!
//! ## What is decided here, and what is asked
//!
//! Two facts cross into [`slopdesk_video::mux_routing::dispatch_decision`] as booleans — is this
//! lane live, and is a mint already in flight — because only this side can know them. Everything
//! after that (which control messages bootstrap a session, and that nothing on another channel ever
//! does) is the wire's rule and stays where the wire lives. A second reading of that grammar here
//! is exactly how `helloDisplay` once got left out of a hand-mirrored copy.
//!
//! ## The mint runs on its own thread, and that is not an optimisation
//!
//! Minting enumerates windows, may rescue a minimized one, and starts a capture — hundreds of
//! milliseconds, at best. The Swift ran it inside an ACTOR, whose reentrancy let sibling lanes keep
//! being delivered across the await. A receive thread that minted inline would hold every OTHER
//! lane's datagrams for that whole time, which the Swift never did. So the mint is spawned and the
//! triggering hello is delivered by that thread once the sink exists; `minting` — set before the
//! spawn — is what makes a hello retransmit burst deliver rather than mint a second session.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};
use slopdesk_video::mux_routing::{DispatchDecision, dispatch_decision};
use slopdesk_video::recovery_routing::VideoChannel;
use slopdesk_video::video_control::VideoControlMessage;

use crate::mux_lane::{LaneControl, LaneRetired};
use crate::mux_sink::MuxSinkTable;
use crate::mux_transport::MuxObserver;

/// A minted session, as the one verb the registry needs from it.
///
/// The capture, the encoder and the timers under this are `SlopDeskVideoHostSession`'s, which is
/// not ported yet; this trait is the seam it lands behind, so nothing above has to change when it
/// does.
pub trait LaneSession: Send + Sync + core::fmt::Debug {
    /// Stops capture, encode and every timer. Idempotent — a reap and a `bye` can both reach it.
    fn stop(&self);
}

/// Why a mint could not produce a session: the window is gone, or the hello was malformed.
///
/// One variant on purpose. The refusal on the wire carries no reason, so a richer error here would
/// be information that goes nowhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MintRefused;

/// Builds and starts the session a hello asks for.
///
/// GUI-only in the daemon: it enumerates the window the hello names, binds it to a
/// [`crate::mux_lane::MuxLaneTransport`] whose `start` registers the lane sink, and hands back the
/// running session. A test injects one that needs no window server.
pub trait SessionMinter: Send + Sync + core::fmt::Debug {
    /// Mints the session for `channel_id` from the hello that arrived on it.
    ///
    /// # Errors
    /// [`MintRefused`] when the window is gone or the hello is malformed; the registry then answers
    /// the client with a rejected `helloAck` and forgets the lane.
    fn mint(&self, channel_id: u32, hello: &VideoControlMessage)
    -> Result<Arc<dyn LaneSession>, MintRefused>;
}

/// The lanes this registry has begun or finished minting.
#[derive(Debug, Default)]
struct Minted {
    /// Lanes whose mint is in flight, so a hello retransmit burst mints exactly one session.
    minting: BTreeSet<u32>,
    /// Live sessions, kept so a shutdown can stop them all.
    sessions: BTreeMap<u32, Arc<dyn LaneSession>>,
}

/// The daemon-side registry that turns ONE shared transport into N sessions.
#[derive(Debug)]
pub struct MuxSessionRegistry {
    sinks: Arc<MuxSinkTable>,
    lanes: Arc<dyn LaneControl>,
    minter: Arc<dyn SessionMinter>,
    minted: Mutex<Minted>,
}

impl MuxSessionRegistry {
    /// A registry over a shared transport and a session factory.
    #[must_use]
    pub fn new(
        sinks: Arc<MuxSinkTable>,
        lanes: Arc<dyn LaneControl>,
        minter: Arc<dyn SessionMinter>,
    ) -> Self {
        Self {
            sinks,
            lanes,
            minter,
            minted: Mutex::new(Minted::default()),
        }
    }

    /// The sink table the lane transports register into.
    #[must_use]
    pub const fn sinks(&self) -> &Arc<MuxSinkTable> {
        &self.sinks
    }

    /// The dispatch verdict for one demultiplexed datagram, with no effect of its own.
    #[must_use]
    pub fn decide(&self, channel_id: u32, channel: VideoChannel, payload: &[u8]) -> DispatchDecision {
        let lane_is_live = self.sinks.contains(channel_id);
        let mint_in_flight = self.locked().minting.contains(&channel_id);
        dispatch_decision(channel_id, channel, payload, lane_is_live, mint_in_flight)
    }

    /// Routes one demultiplexed datagram, minting on the first hello for a new lane.
    pub fn dispatch(self: &Arc<Self>, channel_id: u32, channel: VideoChannel, payload: &[u8]) {
        match self.decide(channel_id, channel, payload) {
            DispatchDecision::Deliver { .. } => {
                if let Some(sink) = self.sinks.sink(channel_id) {
                    sink(channel, payload);
                }
            },
            DispatchDecision::Mint { .. } => {
                // Marked BEFORE the spawn: the next retransmit is decided against this mark, and a
                // mark set inside the new thread would race the retransmit that provoked it.
                if !self.locked().minting.insert(channel_id) {
                    return;
                }
                let registry = Arc::clone(self);
                let hello = payload.to_vec();
                drop(std::thread::spawn(move || {
                    registry.run_mint(channel_id, channel, &hello);
                }));
            },
            DispatchDecision::DropUnbound { .. } => {},
        }
    }

    /// The mint, on its own thread: build the session, then deliver the hello that asked for it.
    fn run_mint(&self, channel_id: u32, channel: VideoChannel, hello: &[u8]) {
        // A decode failure cannot reach here — the lane minted BECAUSE the payload decoded as a
        // hello — but the minter takes a message, so an undecodable one becomes the message that
        // asks for nothing and the mint refuses it, rather than this file inventing a third answer.
        let message = VideoControlMessage::decode(hello).unwrap_or(VideoControlMessage::Bye);
        let Ok(session) = self.minter.mint(channel_id, &message) else {
            let _cleared = self.locked().minting.remove(&channel_id);
            // A TERMINAL refusal rather than a silent drop: the client's state machine resolves
            // `rejected` and stops retrying. A drop left it re-driving a doomed mint every few
            // seconds forever — black pane, no scrim. Sent BEFORE the retire, because the retire
            // drops the reply-flow stamp the bootstrap hello left and there is then no flow to
            // answer on.
            self.lanes
                .send(&REFUSAL.encode(), VideoChannel::Control, channel_id);
            self.lanes.retire(channel_id);
            return;
        };
        drop(self.locked().sessions.insert(channel_id, session));
        // The lane transport registered the sink synchronously inside the mint, so the hello that
        // triggered it is deliverable now and the session's state machine sees the message it was
        // built for.
        if let Some(sink) = self.sinks.sink(channel_id) {
            sink(channel, hello);
        }
    }

    /// Drops a lane's bookkeeping after it retired itself. Idempotent, and siblings are untouched.
    ///
    /// Does NOT stop the session: this is the clean-`bye` path, where the lane transport has
    /// already torn itself down. The crash-without-`bye` reaper uses [`Self::retire_and_stop`].
    pub fn retire(&self, channel_id: u32) {
        self.sinks.unregister(channel_id);
        let mut minted = self.locked();
        let _cleared = minted.minting.remove(&channel_id);
        drop(minted.sessions.remove(&channel_id));
    }

    /// Retires a lane AND stops its session, so capture and encode actually stop.
    ///
    /// The gap [`Self::retire`] leaves, and the one the reaper exists to close: a client that
    /// vanished without a `bye` leaves its session minted and its capture running for nobody.
    pub fn retire_and_stop(&self, channel_id: u32) {
        let session = self.locked().sessions.get(&channel_id).map(Arc::clone);
        self.retire(channel_id);
        if let Some(session) = session {
            session.stop();
        }
    }

    /// Stops every live session, for a daemon shutdown. The shared transport stops separately.
    pub fn stop_all(&self) {
        let live: Vec<Arc<dyn LaneSession>> = {
            let mut minted = self.locked();
            let live = minted.sessions.values().map(Arc::clone).collect();
            minted.sessions.clear();
            minted.minting.clear();
            live
        };
        for session in live {
            session.stop();
        }
    }

    /// Every live session — the daemon-level push path, which ships one global truth to all lanes.
    #[must_use]
    pub fn sessions(&self) -> Vec<Arc<dyn LaneSession>> {
        self.locked().sessions.values().map(Arc::clone).collect()
    }

    /// Whether any session is live.
    ///
    /// The swipe-nav kicker's tick gate: with nobody attached its polling would otherwise run for
    /// the daemon's whole life for an audience of zero, and an idle daemon is the COMMON state.
    #[must_use]
    pub fn has_sessions(&self) -> bool {
        !self.locked().sessions.is_empty()
    }

    /// How many lanes are live.
    #[must_use]
    pub fn live_channel_count(&self) -> usize {
        self.sinks.count()
    }

    /// The live lanes' ids, which the daemon intersects with the parking ledger.
    #[must_use]
    pub fn live_channel_ids(&self) -> BTreeSet<u32> {
        self.sinks.channel_ids()
    }

    fn locked(&self) -> MutexGuard<'_, Minted> {
        self.minted.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl LaneRetired for MuxSessionRegistry {
    fn lane_retired(&self, channel_id: u32) {
        self.retire(channel_id);
    }
}

impl MuxObserver for MuxSessionRegistry {
    fn receive(self: Arc<Self>, channel_id: u32, channel: VideoChannel, payload: &[u8]) {
        self.dispatch(channel_id, channel, payload);
    }

    fn reap_lane(self: Arc<Self>, channel_id: u32) {
        self.retire_and_stop(channel_id);
    }
}

/// The rejected `helloAck` a failed mint answers with.
///
/// The EXISTING wire message, with every reported field zeroed — no new format, and the golden
/// vectors are untouched. `docs/20` §9.2: `accepted = 0` is the refusal, and the rest is not read.
const REFUSAL: VideoControlMessage = VideoControlMessage::HelloAck {
    accepted: false,
    stream_id: 0,
    capture_width: 0,
    capture_height: 0,
    window_bounds_cg: VideoRect {
        origin: VideoPoint { x: 0.0, y: 0.0 },
        size: VideoSize {
            width: 0.0,
            height: 0.0,
        },
    },
    full_range: false,
};

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, Weak};
    use std::time::{Duration, Instant};

    use slopdesk_video::geometry::VideoSize;
    use slopdesk_video::mux_routing::DispatchDecision;
    use slopdesk_video::recovery_routing::VideoChannel;
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{LaneSession, MintRefused, MuxSessionRegistry, SessionMinter};
    use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;

    /// The shared transport, recorded rather than dialled.
    #[derive(Debug, Default)]
    struct Wire {
        acts: Mutex<Vec<String>>,
    }

    impl Wire {
        fn acts(&self) -> Vec<String> {
            self.acts.lock().expect("uncontended").clone()
        }
    }

    impl LaneControl for Wire {
        fn admit(&self, channel_id: u32) {
            self.acts
                .lock()
                .expect("uncontended")
                .push(format!("admit {channel_id}"));
        }

        fn retire(&self, channel_id: u32) {
            self.acts
                .lock()
                .expect("uncontended")
                .push(format!("retire {channel_id}"));
        }

        fn send(&self, datagram: &[u8], _channel: VideoChannel, channel_id: u32) {
            let named = VideoControlMessage::decode(datagram).map_or_else(
                |_| "undecodable".to_owned(),
                |message| format!("type {}", message.message_type()),
            );
            self.acts
                .lock()
                .expect("uncontended")
                .push(format!("send {channel_id} {named}"));
        }
    }

    /// A session that only records that it was stopped.
    #[derive(Debug, Default)]
    struct Recorded {
        stops: AtomicUsize,
    }

    impl LaneSession for Recorded {
        fn stop(&self) {
            let _prior = self.stops.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// A minter with no window server: it starts a lane transport, which is what the real one does.
    #[derive(Debug)]
    struct Factory {
        accept: bool,
        wire: Arc<Wire>,
        sinks: Arc<MuxSinkTable>,
        seen: Arc<Mutex<Vec<u8>>>,
        registry: Mutex<Weak<MuxSessionRegistry>>,
        session: Arc<Recorded>,
    }

    impl SessionMinter for Factory {
        fn mint(
            &self,
            channel_id: u32,
            _hello: &VideoControlMessage,
        ) -> Result<Arc<dyn LaneSession>, MintRefused> {
            if !self.accept {
                return Err(MintRefused);
            }
            let observer: Weak<dyn LaneRetired> = self.registry.lock().expect("uncontended").clone();
            let strong = Arc::clone(&self.wire);
            let wire: Arc<dyn LaneControl> = strong;
            let lane = MuxLaneTransport::new(channel_id, wire, Arc::clone(&self.sinks), observer);
            let seen = Arc::clone(&self.seen);
            lane.start(Arc::new(move |_channel, payload: &[u8]| {
                seen.lock().expect("uncontended").extend_from_slice(payload);
            }));
            let strong = Arc::clone(&self.session);
            let session: Arc<dyn LaneSession> = strong;
            Ok(session)
        }
    }

    struct Harness {
        registry: Arc<MuxSessionRegistry>,
        wire: Arc<Wire>,
        seen: Arc<Mutex<Vec<u8>>>,
        session: Arc<Recorded>,
    }

    fn harness(accept: bool) -> Harness {
        let wire = Arc::new(Wire::default());
        let sinks = Arc::new(MuxSinkTable::new());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let session = Arc::new(Recorded::default());
        let factory = Arc::new(Factory {
            accept,
            wire: Arc::clone(&wire),
            sinks: Arc::clone(&sinks),
            seen: Arc::clone(&seen),
            registry: Mutex::new(Weak::new()),
            session: Arc::clone(&session),
        });
        let wire_strong = Arc::clone(&wire);
        let factory_strong = Arc::clone(&factory);
        let lanes: Arc<dyn LaneControl> = wire_strong;
        let minter: Arc<dyn SessionMinter> = factory_strong;
        let registry = Arc::new(MuxSessionRegistry::new(sinks, lanes, minter));
        *factory.registry.lock().expect("uncontended") = Arc::downgrade(&registry);
        Harness {
            registry,
            wire,
            seen,
            session,
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

    /// The mint runs on its own thread, so every assertion about it waits for the effect.
    fn settle(mut done: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if done() {
                return;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        assert!(done(), "the mint never landed");
    }

    #[test]
    fn a_new_lanes_first_hello_mints_and_then_receives_that_very_hello() {
        let case = harness(true);
        assert_eq!(
            case.registry.decide(7, VideoChannel::Control, &hello()),
            DispatchDecision::Mint { channel_id: 7 },
        );
        case.registry.dispatch(7, VideoChannel::Control, &hello());
        settle(|| !case.seen.lock().expect("uncontended").is_empty());
        assert_eq!(*case.seen.lock().expect("uncontended"), hello());
        assert!(case.registry.has_sessions());
        assert_eq!(case.registry.live_channel_count(), 1);
        assert_eq!(case.wire.acts(), vec!["admit 7".to_owned()]);
    }

    /// UDP makes a hello retransmit burst likely; it must mint exactly one session.
    #[test]
    fn a_hello_burst_mints_once_and_delivers_the_rest() {
        let case = harness(true);
        for _ in 0..8 {
            case.registry.dispatch(7, VideoChannel::Control, &hello());
        }
        settle(|| case.registry.has_sessions());
        // One admit, whatever else was delivered to the live sink.
        assert_eq!(case.wire.acts(), vec!["admit 7".to_owned()]);
        assert_eq!(case.registry.sessions().len(), 1);
    }

    /// A silent drop left the client re-driving a doomed mint forever.
    #[test]
    fn a_refused_mint_answers_a_rejected_hello_ack_before_it_forgets_the_lane() {
        let case = harness(false);
        case.registry.dispatch(7, VideoChannel::Control, &hello());
        settle(|| case.wire.acts().len() == 2);
        assert_eq!(
            case.wire.acts(),
            vec!["send 7 type 2".to_owned(), "retire 7".to_owned()],
            "the refusal rides the flow the bootstrap hello stamped, which the retire then drops",
        );
        assert!(!case.registry.has_sessions());
        // The mint mark is cleared, so a later hello may try again.
        assert_eq!(
            case.registry.decide(7, VideoChannel::Control, &hello()),
            DispatchDecision::Mint { channel_id: 7 },
        );
    }

    #[test]
    fn an_unknown_lane_whose_first_datagram_is_not_a_hello_binds_nothing() {
        let case = harness(true);
        let keepalive = VideoControlMessage::Keepalive.encode();
        assert_eq!(
            case.registry.decide(7, VideoChannel::Control, &keepalive),
            DispatchDecision::DropUnbound { channel_id: 7 },
        );
        case.registry.dispatch(7, VideoChannel::Control, &keepalive);
        assert!(!case.registry.has_sessions());
        assert!(case.wire.acts().is_empty());
    }

    #[test]
    fn a_clean_bye_forgets_the_lane_without_stopping_it_twice() {
        let case = harness(true);
        case.registry.dispatch(7, VideoChannel::Control, &hello());
        settle(|| case.registry.has_sessions());
        case.registry.lane_retired(7);
        assert!(!case.registry.has_sessions());
        assert_eq!(
            case.session.stops.load(Ordering::Relaxed),
            0,
            "the lane transport already tore itself down",
        );
        case.registry.retire(7); // idempotent
        assert_eq!(case.registry.live_channel_ids().len(), 0);
    }

    /// The crash-without-bye gap: the reaper must STOP the session, not just forget the sink.
    #[test]
    fn a_reaped_lane_has_its_capture_stopped() {
        let case = harness(true);
        case.registry.dispatch(7, VideoChannel::Control, &hello());
        settle(|| case.registry.has_sessions());
        case.registry.retire_and_stop(7);
        assert_eq!(case.session.stops.load(Ordering::Relaxed), 1);
        case.registry.retire_and_stop(7); // idempotent: nothing left to stop
        assert_eq!(case.session.stops.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_shutdown_stops_every_live_session() {
        let case = harness(true);
        case.registry.dispatch(7, VideoChannel::Control, &hello());
        settle(|| case.registry.has_sessions());
        case.registry.stop_all();
        assert_eq!(case.session.stops.load(Ordering::Relaxed), 1);
        assert!(!case.registry.has_sessions());
        assert!(case.registry.sessions().is_empty());
    }
}
