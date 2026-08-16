//! Which session a muxed datagram belongs to, and what a lane that has none is owed.
//!
//! When several remote-window sessions share one host socket, each datagram is fronted by a channel
//! id. Everything here decides from that id alone, plus bookkeeping it holds: no sockets, no
//! sessions, no clock beyond the `now` a caller stamps.
//!
//! ## Reconnect-generation safety
//!
//! A reconnecting client is admitted under a NEW channel id and the prior one is retired. Datagrams
//! already on the wire for the OLD id must be DROPPED, never misrouted into the fresh session, or a
//! previous generation's frame or keystroke leaks into it. So a retired id is a known, benign drop,
//! distinct from an id that was never seen at all.

use std::collections::BTreeSet;

use crate::reassembler::distance_wrapped;
use crate::recovery_routing::VideoChannel;
use crate::video_control::VideoControlMessage;

/// What to do with one received muxed datagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuxDecision {
    /// Route it to the session bound to this lane.
    Route {
        /// The lane.
        channel_id: u32,
    },
    /// The lane was never admitted — an unknown or stray id.
    RejectUnadmitted,
    /// The lane was retired by a reconnect or teardown; this is a previous generation's bytes.
    DropRetired,
    /// The lane is mid-teardown, so EVERY datagram drops until the drain ends.
    DropDraining,
    /// Empty datagram. Never a fatal condition, just nothing to route.
    DropEmpty,
}

/// What the bootstrap arm should do with a datagram whose lane is not admitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapAction {
    /// Remember the lane's reply flow and deliver the datagram, so the registry can mint or answer.
    BootstrapDeliver,
    /// Drop it without touching any flow bookkeeping.
    DropNoStamp,
}

/// Bounds the retired set exactly as the reassembler bounds its retired frame ids.
///
/// The client's allocator is monotonic, so a retired id is otherwise never re-admitted and one
/// entry per pane and per reconnect leaks for the daemon's whole life. Because ids are monotonic,
/// an id far BELOW the high-water mark can have no in-flight datagram left, so dropping it is safe:
/// it falls back to an unadmitted rejection, which is a clean drop, and a fresh hello for that id
/// still re-admits.
const RETIRED_CAP: usize = 512;
/// How far below the high-water mark a retired id is kept.
const RETIRED_PRUNE_WINDOW: i32 = 256;

/// The per-datagram mux router for the host side.
///
/// Membership is order-INDEPENDENT — the retired prune filters by the wrap-aware high-water mark,
/// never by iteration order — so no ordering can leak into a decision or onto the wire.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct VideoMuxRouter {
    admitted: BTreeSet<u32>,
    retired: BTreeSet<u32>,
    draining: BTreeSet<u32>,
    highest_retired: Option<u32>,
}

impl VideoMuxRouter {
    /// A router with no lanes at all.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            admitted: BTreeSet::new(),
            retired: BTreeSet::new(),
            draining: BTreeSet::new(),
            highest_retired: None,
        }
    }

    /// Admits a lane. Idempotent, and it clears any retired or draining mark: a fresh generation
    /// may legitimately reuse an id.
    pub fn admit(&mut self, channel_id: u32) {
        self.admitted.insert(channel_id);
        self.retired.remove(&channel_id);
        self.draining.remove(&channel_id);
    }

    /// Retires a lane, so any further in-flight datagram for it is dropped as a stale generation.
    pub fn retire(&mut self, channel_id: u32) {
        self.admitted.remove(&channel_id);
        self.retired.insert(channel_id);
        // A fresh id with no prior mark, or one strictly ahead of the mark, advances it.
        if self
            .highest_retired
            .is_none_or(|high| distance_wrapped(channel_id, high) > 0)
        {
            self.highest_retired = Some(channel_id);
        }
        if self.retired.len() > RETIRED_CAP
            && let Some(high) = self.highest_retired
        {
            self.retired
                .retain(|id| distance_wrapped(high, *id) <= RETIRED_PRUNE_WINDOW);
        }
    }

    /// Begins tearing a lane down on the reaper path.
    ///
    /// It stops routing and HOLDS the lane, so a reconnect racing the teardown drops cleanly rather
    /// than reaching the dying session's still-registered sink or re-minting early.
    pub fn begin_drain(&mut self, channel_id: u32) {
        self.admitted.remove(&channel_id);
        self.draining.insert(channel_id);
    }

    /// Finishes a reaper teardown, moving the lane from draining to retired, where a fresh hello
    /// may re-admit it. Idempotent if the lane was not draining.
    pub fn end_drain(&mut self, channel_id: u32) {
        self.draining.remove(&channel_id);
        self.retire(channel_id);
    }

    /// Whether the lane is currently routable.
    #[must_use]
    pub fn is_admitted(&self, channel_id: u32) -> bool {
        self.admitted.contains(&channel_id)
    }

    /// Whether the lane is currently draining.
    #[must_use]
    pub fn is_draining(&self, channel_id: u32) -> bool {
        self.draining.contains(&channel_id)
    }

    /// Decides what to do with one received datagram.
    ///
    /// The admit and retire state is per lane, not per channel, so the channel it arrived on does
    /// not enter the decision — the caller carries it through. An empty datagram is dropped, and
    /// that check takes precedence over every lane state.
    #[must_use]
    pub fn route(&self, channel_id: u32, bytes_count: usize) -> MuxDecision {
        if bytes_count == 0 {
            return MuxDecision::DropEmpty;
        }
        if self.admitted.contains(&channel_id) {
            return MuxDecision::Route { channel_id };
        }
        if self.draining.contains(&channel_id) {
            return MuxDecision::DropDraining;
        }
        if self.retired.contains(&channel_id) {
            return MuxDecision::DropRetired;
        }
        MuxDecision::RejectUnadmitted
    }
}

/// What the bootstrap arm should do with a NOT-yet-admitted datagram.
///
/// The payload peek happens once, in the caller, and arrives here as two booleans, so this stays a
/// decision over what was observed.
///
/// A RETIRED lane re-admits ONLY when its control datagram is an actual hello: that is
/// cross-process id reuse after a client restart, and the dead old process has no in-flight
/// old-generation datagrams left, so an explicit hello is safe. A non-hello for a retired id still
/// drops, or stale video and input would reach a survivor. A recovery request rides its own
/// channel, never control, so it can never bootstrap.
///
/// An UNADMITTED lane bootstraps — and the caller stamps its reply flow — only when its first
/// control datagram is a hello or a window-list request. A stray or adversarial non-hello drops
/// WITHOUT the flow being remembered, which would otherwise leak a reply stamp for every id that
/// never helloed. A list request is delivered and stamped exactly like a hello so the daemon can
/// answer it, without minting anything.
///
/// A DRAINING lane drops even a hello: no false accept, and no premature re-mint that the teardown
/// would then kill.
#[must_use]
pub const fn bootstrap_action(
    decision: MuxDecision,
    channel: VideoChannel,
    payload_is_hello: bool,
    payload_is_list_request: bool,
) -> BootstrapAction {
    match decision {
        MuxDecision::RejectUnadmitted | MuxDecision::DropRetired => {
            if matches!(channel, VideoChannel::Control) && (payload_is_hello || payload_is_list_request) {
                BootstrapAction::BootstrapDeliver
            } else {
                BootstrapAction::DropNoStamp
            }
        },
        MuxDecision::DropDraining | MuxDecision::Route { .. } | MuxDecision::DropEmpty => {
            BootstrapAction::DropNoStamp
        },
    }
}

/// What the daemon should do with one demultiplexed datagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchDecision {
    /// A live lane exists — deliver to its session sink.
    Deliver {
        /// The lane.
        channel_id: u32,
    },
    /// A never-seen lane carrying a hello — mint a session for it, then deliver.
    Mint {
        /// The lane.
        channel_id: u32,
    },
    /// An unknown lane whose first datagram is not a hello. It cannot be bound, so it drops.
    DropUnbound {
        /// The lane.
        channel_id: u32,
    },
}

/// The dispatch decision for one demultiplexed datagram.
///
/// Two panes on the same host watch DIFFERENT windows, so they send different hellos and need
/// different sessions — the registry cannot pre-mint. It mints lazily on the FIRST hello for a
/// never-seen lane, picking the window that hello names.
///
/// `mint_in_flight` covers the hello retransmit burst UDP makes likely: a lane already minting
/// delivers rather than minting twice.
#[must_use]
pub fn dispatch_decision(
    channel_id: u32,
    channel: VideoChannel,
    payload: &[u8],
    lane_is_live: bool,
    mint_in_flight: bool,
) -> DispatchDecision {
    if lane_is_live || mint_in_flight {
        return DispatchDecision::Deliver { channel_id };
    }
    if matches!(channel, VideoChannel::Control)
        && matches!(
            VideoControlMessage::decode(payload),
            Ok(VideoControlMessage::Hello { .. } | VideoControlMessage::HelloDisplay { .. })
        )
    {
        return DispatchDecision::Mint { channel_id };
    }
    DispatchDecision::DropUnbound { channel_id }
}

#[cfg(test)]
mod tests {
    use super::{
        BootstrapAction, DispatchDecision, MuxDecision, VideoMuxRouter, bootstrap_action, dispatch_decision,
    };
    use crate::geometry::VideoSize;
    use crate::recovery_routing::VideoChannel;
    use crate::video_control::VideoControlMessage;

    fn hello_bytes() -> Vec<u8> {
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

    fn keepalive_bytes() -> Vec<u8> {
        VideoControlMessage::Keepalive.encode()
    }

    #[test]
    fn an_admitted_lane_routes_and_an_unknown_one_is_rejected() {
        let mut router = VideoMuxRouter::new();
        assert_eq!(router.route(7, 64), MuxDecision::RejectUnadmitted);
        router.admit(7);
        assert!(router.is_admitted(7));
        assert_eq!(router.route(7, 64), MuxDecision::Route { channel_id: 7 });
    }

    /// The whole reason the retired set is distinct from "never seen".
    #[test]
    fn a_previous_generations_datagram_drops_rather_than_reaching_the_new_session() {
        let mut router = VideoMuxRouter::new();
        router.admit(7);
        router.retire(7);
        assert_eq!(router.route(7, 64), MuxDecision::DropRetired);
        assert!(!router.is_admitted(7));
        router.admit(8); // the reconnect
        assert_eq!(router.route(8, 64), MuxDecision::Route { channel_id: 8 });
    }

    #[test]
    fn a_draining_lane_holds_every_datagram_until_the_teardown_finishes() {
        let mut router = VideoMuxRouter::new();
        router.admit(7);
        router.begin_drain(7);
        assert!(router.is_draining(7));
        assert_eq!(router.route(7, 64), MuxDecision::DropDraining);
        assert_eq!(
            bootstrap_action(MuxDecision::DropDraining, VideoChannel::Control, true, false),
            BootstrapAction::DropNoStamp,
            "even a hello: no false accept and no premature re-mint",
        );
        router.end_drain(7);
        assert_eq!(router.route(7, 64), MuxDecision::DropRetired);
    }

    #[test]
    fn an_empty_datagram_drops_ahead_of_every_lane_state() {
        let mut router = VideoMuxRouter::new();
        router.admit(7);
        assert_eq!(router.route(7, 0), MuxDecision::DropEmpty);
    }

    /// One entry per pane and per reconnect would otherwise leak for the daemon's whole life.
    #[test]
    fn the_retired_set_stays_bounded_and_keeps_the_ids_still_at_risk() {
        let mut router = VideoMuxRouter::new();
        for channel_id in 0..600 {
            router.retire(channel_id);
        }
        assert!(router.retired.len() <= 512);
        assert_eq!(
            router.route(599, 64),
            MuxDecision::DropRetired,
            "the newest ids, which can still have a datagram in flight, are kept",
        );
        assert_eq!(
            router.route(0, 64),
            MuxDecision::RejectUnadmitted,
            "the oldest fall back to a clean unknown-lane drop",
        );
    }

    #[test]
    fn a_pruned_id_still_re_admits_on_a_fresh_hello() {
        let mut router = VideoMuxRouter::new();
        for channel_id in 0..600 {
            router.retire(channel_id);
        }
        router.admit(0);
        assert_eq!(router.route(0, 64), MuxDecision::Route { channel_id: 0 });
    }

    #[test]
    fn only_a_hello_or_a_list_request_on_the_control_channel_bootstraps() {
        for decision in [MuxDecision::RejectUnadmitted, MuxDecision::DropRetired] {
            assert_eq!(
                bootstrap_action(decision, VideoChannel::Control, true, false),
                BootstrapAction::BootstrapDeliver,
            );
            assert_eq!(
                bootstrap_action(decision, VideoChannel::Control, false, true),
                BootstrapAction::BootstrapDeliver,
                "a list request is answered without minting anything",
            );
            assert_eq!(
                bootstrap_action(decision, VideoChannel::Control, false, false),
                BootstrapAction::DropNoStamp,
                "a stray control datagram must not leave a reply stamp behind",
            );
            assert_eq!(
                bootstrap_action(decision, VideoChannel::Recovery, true, false),
                BootstrapAction::DropNoStamp,
                "a recovery datagram rides its own channel and can never bootstrap",
            );
        }
    }

    #[test]
    fn a_live_lane_delivers_and_a_new_one_mints_on_its_first_hello() {
        assert_eq!(
            dispatch_decision(3, VideoChannel::Control, &hello_bytes(), true, false),
            DispatchDecision::Deliver { channel_id: 3 },
        );
        assert_eq!(
            dispatch_decision(3, VideoChannel::Control, &hello_bytes(), false, false),
            DispatchDecision::Mint { channel_id: 3 },
        );
    }

    /// UDP makes a hello retransmit burst likely; it must mint exactly one session.
    #[test]
    fn a_hello_retransmit_delivers_rather_than_minting_a_second_session() {
        assert_eq!(
            dispatch_decision(3, VideoChannel::Control, &hello_bytes(), false, true),
            DispatchDecision::Deliver { channel_id: 3 },
        );
    }

    #[test]
    fn an_unknown_lane_whose_first_datagram_is_not_a_hello_cannot_be_bound() {
        assert_eq!(
            dispatch_decision(3, VideoChannel::Control, &keepalive_bytes(), false, false),
            DispatchDecision::DropUnbound { channel_id: 3 },
        );
        assert_eq!(
            dispatch_decision(3, VideoChannel::Input, &hello_bytes(), false, false),
            DispatchDecision::DropUnbound { channel_id: 3 },
            "hello-shaped bytes on another channel bind nothing",
        );
        assert_eq!(
            dispatch_decision(3, VideoChannel::Control, b"\xff", false, false),
            DispatchDecision::DropUnbound { channel_id: 3 },
        );
    }
}
