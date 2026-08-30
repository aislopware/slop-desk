//! Which flow a lane replies on, which flow the reaper may close, and what an unbound lane is told.
//!
//! The transport pins one UDP "flow" per source endpoint and hands each one an id; every decision
//! here is made in terms of those ids, so none of it needs a socket. Time comes in as `now` in
//! monotonic seconds, never a wall clock.
//!
//! ## Why a reap exists at all
//!
//! UDP has no FIN. A peer that silently vanishes — a wifi switch, a client rebuild — never drives
//! the host's flow to failed, so without a reap one media and one cursor flow leak per rebuild, for
//! the daemon's whole life, until it runs out of descriptors.

use std::collections::{BTreeMap, BTreeSet};

use crate::recovery_routing::VideoChannel;
use crate::video_control::VideoControlMessage;

/// The transport's handle for one pinned flow.
pub type FlowId = u64;

/// Flow and reply-stamp bookkeeping for the shared mux transport.
///
/// It tracks the flows the listener pinned, the stamp saying which flow each lane's host→client
/// datagrams must ride, when each flow last carried anything inbound, and which stamps were made
/// for a lane that was never admitted.
#[derive(Debug, Clone, PartialEq)]
pub struct MuxFlowTable {
    media_flows: BTreeSet<FlowId>,
    cursor_flows: BTreeSet<FlowId>,
    media_reply: BTreeMap<u32, FlowId>,
    cursor_reply: BTreeMap<u32, FlowId>,
    flow_last_inbound: BTreeMap<FlowId, f64>,
    unadmitted_stamp_at: BTreeMap<u32, f64>,
    idle_timeout: f64,
}

impl MuxFlowTable {
    /// An empty table.
    ///
    /// `idle_timeout` is the same contract the per-lane idle reaper uses, so flow and lane
    /// lifetimes cannot silently drift apart.
    #[must_use]
    pub const fn new(idle_timeout: f64) -> Self {
        Self {
            media_flows: BTreeSet::new(),
            cursor_flows: BTreeSet::new(),
            media_reply: BTreeMap::new(),
            cursor_reply: BTreeMap::new(),
            flow_last_inbound: BTreeMap::new(),
            unadmitted_stamp_at: BTreeMap::new(),
            idle_timeout,
        }
    }

    /// Tracks a listener-accepted flow.
    ///
    /// `now` doubles as its first inbound stamp: the listener pins a flow only because a datagram
    /// arrived on it.
    pub fn accept(&mut self, flow: FlowId, is_media: bool, now: f64) {
        if is_media {
            self.media_flows.insert(flow);
        } else {
            self.cursor_flows.insert(flow);
        }
        self.flow_last_inbound.insert(flow, now);
    }

    /// Refreshes a tracked flow's last-inbound time — any decoded datagram proves the tuple alive.
    ///
    /// A no-op for an untracked flow, so a datagram racing a reset or a reap cannot resurrect a
    /// record that was already dropped.
    pub fn note_inbound(&mut self, flow: FlowId, now: f64) {
        if let Some(stamp) = self.flow_last_inbound.get_mut(&flow) {
            *stamp = now;
        }
    }

    /// Stamps the media reply flow for an ADMITTED lane.
    ///
    /// Re-stamped on every routed datagram, so a client whose source port changes mid-session — a
    /// rebind behind NAT — re-points the lane at its new flow. The displaced flow then ages out.
    pub fn stamp_media_reply(&mut self, channel_id: u32, flow: FlowId) {
        self.media_reply.insert(channel_id, flow);
    }

    /// Stamps the media reply flow for a not-yet-admitted bootstrap: a hello, or a list request.
    ///
    /// The stamp time is kept, so a bootstrap whose mint or list answer never completes on a lossy
    /// link cannot leak the entry forever. Only the FIRST unadmitted stamp starts that clock — a
    /// hello retransmit burst must not keep pushing a never-minting lane's expiry forward.
    pub fn stamp_media_bootstrap(&mut self, channel_id: u32, flow: FlowId, now: f64) {
        self.media_reply.insert(channel_id, flow);
        self.unadmitted_stamp_at.entry(channel_id).or_insert(now);
    }

    /// Stamps the cursor reply flow for a lane, from the inbound cursor prime.
    ///
    /// The prime legitimately races AHEAD of the media hello, so an unadmitted stamp is accepted —
    /// but it is tracked with a time, so an id that is never admitted, from a discovery poll whose
    /// media request was lost, is swept rather than left behind.
    pub fn stamp_cursor_reply(&mut self, channel_id: u32, flow: FlowId, now: f64, is_admitted: bool) {
        self.cursor_reply.insert(channel_id, flow);
        if is_admitted {
            self.unadmitted_stamp_at.remove(&channel_id);
        } else {
            self.unadmitted_stamp_at.entry(channel_id).or_insert(now);
        }
    }

    /// Drops a lane's reply stamps, on a clean bye or a retire.
    ///
    /// The flows themselves stay tracked: they may carry sibling lanes.
    pub fn retire_lane(&mut self, channel_id: u32) {
        self.media_reply.remove(&channel_id);
        self.cursor_reply.remove(&channel_id);
        self.unadmitted_stamp_at.remove(&channel_id);
    }

    /// Forgets a flow the transport reported failed or cancelled.
    ///
    /// It leaves the flow table, every reply stamp pointing at it is dropped, and its last-inbound
    /// record goes too, so a later reap never reports it again. Idempotent — a reaper-cancelled
    /// flow re-enters here harmlessly.
    pub fn flow_did_reset(&mut self, flow: FlowId, is_media: bool) {
        if is_media {
            self.media_flows.remove(&flow);
            self.media_reply.retain(|_, stamped| *stamped != flow);
        } else {
            self.cursor_flows.remove(&flow);
            self.cursor_reply.retain(|_, stamped| *stamped != flow);
        }
        self.flow_last_inbound.remove(&flow);
    }

    /// One reaper tick. The returned flows are the ones to close, outside whatever lock guards
    /// this.
    ///
    /// Two rules, in this order:
    ///
    /// 1. **The never-admitted stamp sweep.** A stamp made while its lane was unadmitted, whose
    ///    lane is STILL not admitted a full timeout later, is dropped from both maps — the
    ///    discovery and lost-mint leak. A lane that DID get admitted inside the window keeps its
    ///    stamps, which is the prime-races-ahead-of-hello case; only its expiry record is
    ///    discarded.
    /// 2. **The idle unreferenced flow reap.** A flow silent for a full timeout that is NOT the
    ///    current value of any reply stamp is removed and returned. A referenced flow is NEVER
    ///    reaped: a live lane's cursor flow receives nothing after its one prime, so idleness alone
    ///    must not kill it. It becomes reapable once its lane's stamps are gone, whether by a
    ///    retire or by a rebuild re-pointing them at a new flow.
    ///
    /// Rule 1 runs first, so a stale stamp cannot go on protecting the flow it orphaned.
    pub fn reap<F: Fn(u32) -> bool>(&mut self, now: f64, is_admitted: F) -> Vec<FlowId> {
        let expired: Vec<u32> = self
            .unadmitted_stamp_at
            .iter()
            .filter(|&(_, &stamped_at)| now - stamped_at >= self.idle_timeout)
            .map(|(&channel_id, _)| channel_id)
            .collect();
        for channel_id in expired {
            self.unadmitted_stamp_at.remove(&channel_id);
            if is_admitted(channel_id) {
                continue;
            }
            self.media_reply.remove(&channel_id);
            self.cursor_reply.remove(&channel_id);
        }

        let referenced: BTreeSet<FlowId> = self
            .media_reply
            .values()
            .chain(self.cursor_reply.values())
            .copied()
            .collect();
        let idle: Vec<FlowId> = self
            .flow_last_inbound
            .iter()
            .filter(|&(flow, &last_inbound)| {
                now - last_inbound >= self.idle_timeout && !referenced.contains(flow)
            })
            .map(|(&flow, _)| flow)
            .collect();
        for flow in &idle {
            self.flow_last_inbound.remove(flow);
            self.media_flows.remove(flow);
            self.cursor_flows.remove(flow);
        }
        idle
    }

    /// The flow this lane's host→client media datagrams must ride, if known.
    #[must_use]
    pub fn media_reply_flow(&self, channel_id: u32) -> Option<FlowId> {
        self.media_reply.get(&channel_id).copied()
    }

    /// The flow this lane's host→client cursor datagrams must ride, if known.
    #[must_use]
    pub fn cursor_reply_flow(&self, channel_id: u32) -> Option<FlowId> {
        self.cursor_reply.get(&channel_id).copied()
    }

    /// Daemon shutdown: drops everything and returns every tracked flow exactly once, to close.
    pub fn remove_all(&mut self) -> Vec<FlowId> {
        let flows: Vec<FlowId> = self
            .media_flows
            .iter()
            .chain(self.cursor_flows.iter())
            .copied()
            .collect();
        self.media_flows.clear();
        self.cursor_flows.clear();
        self.media_reply.clear();
        self.cursor_reply.clear();
        self.flow_last_inbound.clear();
        self.unadmitted_stamp_at.clear();
        flows
    }

    /// Whether this flow is still tracked on either side.
    ///
    /// A caller that holds the OBJECT an id names — the transport does; this table holds only ids —
    /// asks after a reset to learn whether it may release it, so nothing outlives the table by
    /// accident.
    #[must_use]
    pub fn tracks(&self, flow: FlowId) -> bool {
        self.media_flows.contains(&flow) || self.cursor_flows.contains(&flow)
    }

    /// How many accepted flows are tracked, media and cursor together.
    #[must_use]
    pub fn flow_count(&self) -> usize {
        self.media_flows.len() + self.cursor_flows.len()
    }
}

/// Whether a dropped datagram proves its sender still believes a live session exists.
///
/// ## The wedge this answers
///
/// A daemon RESTART forgets every admitted lane, but a client mid-session has no way to know: UDP
/// gives it no signal, its state machine stays streaming forever, and its keepalives and keystrokes
/// land on a lane that is gone. Dropping them silently freezes the pane with dead input until the
/// app is relaunched. Answering with a bye closes the loop — the client's existing bye handling
/// tears the dead session down and re-hellos within one keepalive interval.
///
/// ## What warrants one, and what must not
///
/// Input and recovery datagrams are only ever sent by a client that believes it is streaming, and
/// the in-session control messages are the same. A hello never reaches this decider, because it
/// bootstraps a mint, and the list requests are session-LESS discovery, so neither is answered. A
/// stray bye gets no reply: there is nothing to end, and replying could ping-pong with a confused
/// peer. Host→client payloads arriving inbound are corrupt or hostile — they are dropped without a
/// reply, never reflected at.
#[must_use]
pub fn warrants_bye(channel: VideoChannel, payload: &[u8]) -> bool {
    match channel {
        VideoChannel::Input | VideoChannel::Recovery => true,
        VideoChannel::Control => {
            matches!(
                VideoControlMessage::decode(payload),
                Ok(VideoControlMessage::Keepalive
                    | VideoControlMessage::ResizeRequest { .. }
                    | VideoControlMessage::FocusWindow
                    | VideoControlMessage::StreamSettings { .. }
                    | VideoControlMessage::AudioControl { .. }
                    | VideoControlMessage::PrivacyMode { .. })
            )
        },
        VideoChannel::Video | VideoChannel::Geometry | VideoChannel::Cursor | VideoChannel::Audio => false,
    }
}

/// Whether a datagram is the control-channel KEEPALIVE, which is the only proof the idle reaper
/// accepts that a lane speaks keepalive at all.
///
/// ## Why this is worth a decider rather than a byte test
///
/// The near side used to answer it by indexing the type byte and comparing it to `6`. That number
/// is spelled nowhere the wire owns, and it is one table over from [`VideoChannel::Audio`], whose
/// raw value is ALSO `6` — so a hand-written `== 6` beside a `channel == Control` test is a
/// transposition away from reading a channel tag as a message type and never failing loudly.
///
/// What it decides is load-bearing out of proportion to its size: the reaper's `saw_keepalive` is
/// STICKY and gates reap eligibility entirely, so a lane this predicate never says yes about can
/// never be torn down, and a lane it says yes about wrongly is torn down under a client that is
/// still watching.
///
/// ## This is behaviour-PRESERVING, deliberately
///
/// The decode is not stricter than the byte peek was. `decode`'s keepalive arm consumes the type
/// byte and nothing else, and it does not refuse a trailing remainder, so `[6][junk]` answers yes
/// through either reading — exactly as [`warrants_bye`] already answers yes for those same bytes.
/// Whether a zero-body control message should refuse a trailing remainder at all is the control
/// GRAMMAR's decision, and it belongs in `video_control.rs`, where changing it would move this
/// predicate and `warrants_bye` together instead of splitting them.
#[must_use]
pub fn payload_is_keepalive(channel: VideoChannel, payload: &[u8]) -> bool {
    matches!(channel, VideoChannel::Control)
        && matches!(
            VideoControlMessage::decode(payload),
            Ok(VideoControlMessage::Keepalive)
        )
}

/// Bounds how often an unbound-lane bye is actually SENT.
///
/// At most one per interval per lane, over at most `capacity` tracked lanes. A wedged client emits
/// a keepalive every few seconds plus input bursts on interaction, so one bye a second per lane is
/// ample to unwedge it, and the capacity bound keeps a hostile source from growing the map.
#[derive(Debug, Clone, PartialEq)]
pub struct UnboundByeRateLimiter {
    last_sent: BTreeMap<u32, f64>,
    min_interval: f64,
    capacity: usize,
}

impl UnboundByeRateLimiter {
    /// A limiter that has sent nothing.
    #[must_use]
    pub const fn new(min_interval: f64, capacity: usize) -> Self {
        Self {
            last_sent: BTreeMap::new(),
            min_interval,
            capacity: if capacity > 1 { capacity } else { 1 },
        }
    }

    /// Whether a bye may be sent for this lane now, recording the send when it says yes.
    ///
    /// When the map is full of entries that are all still fresh, a new lane is DENIED rather than
    /// admitted — quietly, and never unbounded.
    pub fn admit(&mut self, channel_id: u32, now: f64) -> bool {
        if let Some(last) = self.last_sent.get_mut(&channel_id) {
            if now - *last < self.min_interval {
                return false;
            }
            *last = now;
            return true;
        }
        if self.last_sent.len() >= self.capacity {
            self.last_sent.retain(|_, sent| now - *sent < self.min_interval);
            if self.last_sent.len() >= self.capacity {
                return false;
            }
        }
        self.last_sent.insert(channel_id, now);
        true
    }
}

/// The smallest re-arm delay after the first consecutive error.
pub const RECEIVE_BASE_BACKOFF: f64 = 0.005;
/// The capped re-arm delay, so a long error storm settles rather than spinning.
pub const RECEIVE_MAX_BACKOFF: f64 = 0.25;

/// Whether to re-arm the receive loop: only while the flow is still alive.
///
/// The loop must survive TRANSIENT per-datagram errors — an ICMP port-unreachable surfaces as a
/// receive error while the flow itself stays ready — and stop only when the flow is genuinely dead.
/// Liveness comes from the connection's own state, never from the per-receive error, which is why
/// the decision reduces to this one question.
#[must_use]
pub const fn should_rearm(connection_is_alive: bool) -> bool {
    connection_is_alive
}

/// The delay before re-arming after an error-bearing completion.
///
/// Re-arming a transient error is the fix; re-arming a SUSTAINED one — an ICMP port-unreachable
/// delivered on every receive while the flow stays ready — with zero delay is a busy loop at a full
/// core. So the delay doubles per consecutive error from the base, capped.
///
/// `consecutive_errors` counts back-to-back errors INCLUDING the one just observed, and the loop
/// resets it on the first error-free datagram: zero means re-arm immediately, so the hot path is
/// never delayed.
#[must_use]
pub fn receive_backoff(consecutive_errors: u32) -> f64 {
    if consecutive_errors == 0 {
        return 0.0;
    }
    // Two to the sixteenth times the base is far past the cap, so the shift can never overflow.
    let exponent = (consecutive_errors - 1).min(16);
    let scaled = RECEIVE_BASE_BACKOFF * f64::from(1_u32 << exponent);
    scaled.min(RECEIVE_MAX_BACKOFF)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the backoff rungs are the pinned constants themselves, not computed values"
    )]

    use super::{
        MuxFlowTable, RECEIVE_BASE_BACKOFF, RECEIVE_MAX_BACKOFF, UnboundByeRateLimiter, payload_is_keepalive,
        receive_backoff, should_rearm, warrants_bye,
    };
    use crate::recovery_routing::VideoChannel;
    use crate::video_control::VideoControlMessage;

    const IDLE: f64 = 10.0;
    const MEDIA: bool = true;
    const CURSOR: bool = false;

    fn admitted_none(_: u32) -> bool {
        false
    }

    #[test]
    fn a_lane_replies_on_the_flow_its_client_opened() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.accept(2, CURSOR, 0.0);
        table.stamp_media_reply(7, 1);
        table.stamp_cursor_reply(7, 2, 0.0, true);
        assert_eq!(table.media_reply_flow(7), Some(1));
        assert_eq!(table.cursor_reply_flow(7), Some(2));
        assert_eq!(table.media_reply_flow(8), None);
        assert_eq!(table.flow_count(), 2);
    }

    /// A client whose source port moves mid-session must not keep being answered on the dead flow.
    #[test]
    fn a_rebind_re_points_the_lane_and_the_displaced_flow_ages_out() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.stamp_media_reply(7, 1);
        table.accept(2, MEDIA, 5.0);
        table.stamp_media_reply(7, 2);
        assert_eq!(table.media_reply_flow(7), Some(2));
        assert_eq!(
            table.reap(15.0, |_| true),
            vec![1],
            "the old flow is unreferenced and silent",
        );
        assert_eq!(table.flow_count(), 1);
    }

    /// A live lane's cursor flow receives nothing after its one prime.
    #[test]
    fn a_referenced_flow_is_never_reaped_however_silent_it_is() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(2, CURSOR, 0.0);
        table.stamp_cursor_reply(7, 2, 0.0, true);
        assert!(table.reap(1000.0, |_| true).is_empty());
        table.retire_lane(7);
        assert_eq!(table.reap(1000.0, |_| true), vec![2]);
    }

    /// The discovery and lost-mint leak: a stamp for a lane that never became a session.
    #[test]
    fn a_never_admitted_stamp_is_swept_and_stops_protecting_its_flow() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.stamp_media_bootstrap(7, 1, 0.0);
        assert!(
            table.reap(5.0, admitted_none).is_empty(),
            "still inside the window"
        );
        assert_eq!(table.reap(10.0, admitted_none), vec![1]);
        assert_eq!(table.media_reply_flow(7), None);
    }

    /// The cursor prime legitimately arrives before the media hello.
    #[test]
    fn a_lane_admitted_inside_the_window_keeps_the_stamps_it_made_early() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(2, CURSOR, 0.0);
        table.stamp_cursor_reply(7, 2, 0.0, false);
        assert!(table.reap(10.0, |_| true).is_empty());
        assert_eq!(table.cursor_reply_flow(7), Some(2), "the stamps stay live");
        assert!(
            table.reap(1000.0, |_| true).is_empty(),
            "and its expiry record is gone, so it is never swept again",
        );
    }

    /// A hello retransmit burst must not keep pushing a doomed lane's expiry forward.
    #[test]
    fn only_the_first_unadmitted_stamp_starts_the_clock() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.stamp_media_bootstrap(7, 1, 0.0);
        for retry in 1..5 {
            table.stamp_media_bootstrap(7, 1, f64::from(retry));
        }
        assert_eq!(table.reap(10.0, admitted_none), vec![1]);
    }

    #[test]
    fn a_failed_flow_takes_every_stamp_that_pointed_at_it() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.stamp_media_reply(7, 1);
        table.stamp_media_reply(8, 1);
        table.flow_did_reset(1, MEDIA);
        assert_eq!(table.media_reply_flow(7), None);
        assert_eq!(table.media_reply_flow(8), None);
        assert_eq!(table.flow_count(), 0);
        table.flow_did_reset(1, MEDIA); // idempotent
        assert_eq!(table.flow_count(), 0);
    }

    /// A datagram racing a reset must not resurrect a record the table already dropped.
    #[test]
    fn an_untracked_flow_cannot_be_refreshed_back_into_the_table() {
        let mut table = MuxFlowTable::new(IDLE);
        table.note_inbound(99, 0.0);
        assert!(table.reap(1000.0, admitted_none).is_empty());
        assert_eq!(table.flow_count(), 0);
    }

    #[test]
    fn an_inbound_datagram_proves_the_flow_alive() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.note_inbound(1, 9.0);
        assert!(table.reap(15.0, admitted_none).is_empty());
        assert_eq!(table.reap(20.0, admitted_none), vec![1]);
    }

    #[test]
    fn shutdown_returns_every_flow_exactly_once() {
        let mut table = MuxFlowTable::new(IDLE);
        table.accept(1, MEDIA, 0.0);
        table.accept(2, CURSOR, 0.0);
        table.stamp_media_reply(7, 1);
        assert_eq!(table.remove_all(), vec![1, 2]);
        assert_eq!(table.flow_count(), 0);
        assert_eq!(table.media_reply_flow(7), None);
        assert!(table.remove_all().is_empty());
    }

    #[test]
    fn only_an_in_session_datagram_earns_a_bye() {
        assert!(warrants_bye(VideoChannel::Input, b"anything"));
        assert!(warrants_bye(VideoChannel::Recovery, b"anything"));
        assert!(warrants_bye(
            VideoChannel::Control,
            &VideoControlMessage::Keepalive.encode()
        ));
        assert!(warrants_bye(
            VideoChannel::Control,
            &VideoControlMessage::FocusWindow.encode()
        ));
    }

    #[test]
    fn discovery_and_host_to_client_traffic_is_never_answered() {
        assert!(
            !warrants_bye(VideoChannel::Control, &VideoControlMessage::ListWindows.encode()),
            "session-less discovery must bootstrap, never bye",
        );
        assert!(
            !warrants_bye(VideoChannel::Control, &VideoControlMessage::Bye.encode()),
            "nothing to end, and a reply could ping-pong",
        );
        assert!(
            !warrants_bye(VideoChannel::Video, b"anything"),
            "host-to-client bytes arriving inbound are corrupt or hostile",
        );
        assert!(!warrants_bye(VideoChannel::Cursor, b"anything"));
        assert!(!warrants_bye(VideoChannel::Control, b"\xff"));
    }

    /// The reaper's sticky proof: only a control keepalive latches it, and a keepalive-shaped
    /// payload on another channel must not — `Audio`'s raw value is `6` too, which is exactly the
    /// confusion a hand-written type-byte comparison invites.
    #[test]
    fn only_a_control_keepalive_proves_a_lane_speaks_keepalive() {
        let keepalive = VideoControlMessage::Keepalive.encode();
        assert!(payload_is_keepalive(VideoChannel::Control, &keepalive));
        assert!(
            !payload_is_keepalive(VideoChannel::Audio, &keepalive),
            "the same bytes on another channel are not a liveness proof",
        );
        assert!(!payload_is_keepalive(
            VideoChannel::Control,
            &VideoControlMessage::FocusWindow.encode()
        ));
        assert!(
            !payload_is_keepalive(VideoChannel::Control, b""),
            "an empty payload names no message at all",
        );
    }

    /// The two readings of the SAME type byte must stay equally strict. `decode`'s keepalive arm
    /// consumes the type byte and does not refuse a trailing remainder, so a garbage-suffixed
    /// keepalive is a keepalive to both — and if the control grammar ever tightens that, this
    /// fails rather than letting the reap proof and the bye reply drift apart.
    #[test]
    fn a_trailing_junk_keepalive_reads_the_same_way_to_both_predicates() {
        let suffixed = [VideoControlMessage::Keepalive.message_type(), 0xFF];
        assert_eq!(
            payload_is_keepalive(VideoChannel::Control, &suffixed),
            warrants_bye(VideoChannel::Control, &suffixed),
        );
        assert!(payload_is_keepalive(VideoChannel::Control, &suffixed));
    }

    #[test]
    fn a_wedged_lane_is_told_once_per_interval() {
        let mut limiter = UnboundByeRateLimiter::new(1.0, 256);
        assert!(limiter.admit(7, 0.0));
        assert!(!limiter.admit(7, 0.9));
        assert!(limiter.admit(7, 1.0));
        assert!(limiter.admit(8, 1.0), "a sibling lane has its own budget");
    }

    /// A hostile datagram source must not grow the map.
    #[test]
    fn the_limiter_denies_a_new_lane_while_every_slot_is_fresh() {
        let mut limiter = UnboundByeRateLimiter::new(1.0, 2);
        assert!(limiter.admit(1, 0.0));
        assert!(limiter.admit(2, 0.0));
        assert!(!limiter.admit(3, 0.5));
        assert!(limiter.admit(3, 1.5), "the stale slots are reclaimed");
    }

    #[test]
    fn the_receive_loop_survives_a_transient_error_and_stops_only_for_a_dead_flow() {
        assert!(should_rearm(true));
        assert!(!should_rearm(false));
    }

    /// A sustained error re-armed with no delay is a full core spent on nothing.
    #[test]
    fn the_backoff_doubles_per_consecutive_error_and_settles_at_the_cap() {
        assert_eq!(receive_backoff(0), 0.0, "the hot path is never delayed");
        assert_eq!(receive_backoff(1), RECEIVE_BASE_BACKOFF);
        assert_eq!(receive_backoff(2), RECEIVE_BASE_BACKOFF * 2.0);
        assert_eq!(receive_backoff(3), RECEIVE_BASE_BACKOFF * 4.0);
        assert_eq!(receive_backoff(100), RECEIVE_MAX_BACKOFF);
        assert_eq!(receive_backoff(u32::MAX), RECEIVE_MAX_BACKOFF);
    }
}
