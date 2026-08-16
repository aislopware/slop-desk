//! The client's side of "one UDP flow per host": which panes share a flow, and when it closes.
//!
//! Every pane pointed at the same host and port pair rides ONE shared flow — one media and one
//! cursor socket — each as its own channel lane. The pool refcounts the lanes per endpoint and
//! tears the flow down ONLY when the last one closes, which is the subtle part: a pane closing or
//! reconnecting must never drop the flow its siblings are still streaming on.
//!
//! The lane id allocator is monotonic AND seeded, and the seed is the interesting half. A lane id
//! only has to be unique per shared flow within one process, which a counter gives for free while
//! never reusing a retired id — the property the host's router needs. But two DISTINCT clients
//! streaming the same host window each ran their own counter from one, so both minted lane id one,
//! and the host's reply-flow maps are keyed by the BARE lane id: the second client's lane HIJACKED
//! the first's video and cursor replies. Seeding each process from a random base separates the two
//! clients' id RANGES so their lanes cannot collide on the host. The seed is masked well below the
//! type's ceiling, so a long-lived client's increments cannot wrap into a sibling's range inside
//! any realistic session.
//!
//! The randomness itself is the caller's: this crate stays deterministic, so the base is injected.

use std::collections::{BTreeMap, BTreeSet};

/// The endpoint a shared flow is keyed by.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct FlowEndpoint {
    /// The host address as the caller wrote it.
    pub host: String,
    /// The media port.
    pub media_port: u16,
    /// The cursor port.
    pub cursor_port: u16,
}

impl FlowEndpoint {
    /// An endpoint from its three parts.
    #[must_use]
    pub fn new(host: impl Into<String>, media_port: u16, cursor_port: u16) -> Self {
        Self {
            host: host.into(),
            media_port,
            cursor_port,
        }
    }
}

/// What acquiring a lane asks the caller to do with the underlying sockets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcquireOutcome {
    /// The first lane on this endpoint: the caller must build the shared flow before registering.
    FlowCreated {
        /// The lane's id.
        channel_id: u32,
    },
    /// A sibling lane on a flow that is already up.
    LaneJoined {
        /// The lane's id.
        channel_id: u32,
    },
}

impl AcquireOutcome {
    /// The lane's id, whichever way it was acquired.
    #[must_use]
    pub const fn channel_id(self) -> u32 {
        match self {
            Self::FlowCreated { channel_id } | Self::LaneJoined { channel_id } => channel_id,
        }
    }
}

/// What releasing a lane asks the caller to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReleaseOutcome {
    /// No such endpoint or no such lane — nothing to unregister, and nothing to close.
    Unknown,
    /// The lane's sinks come off, and the flow stays up for its siblings.
    LaneRemoved,
    /// The last lane released: unregister it, then close the shared flow.
    FlowClosed,
}

/// The cap on how many times a one-shot request is retransmitted, which bounds a nonsense
/// interval-to-timeout ratio rather than trusting the arithmetic.
pub const MAX_REQUEST_SENDS: u32 = 1024;

/// The lowest lane id the allocator will ever mint. Zero is left alone so a bare zero on the wire
/// is always an unset field rather than someone's first lane.
pub const MIN_CHANNEL_ID: u32 = 1;
/// The ceiling the injected seed is masked to, which leaves the whole upper range as headroom for
/// a long-lived client's increments.
pub const SEED_MASK: u32 = 0x0FFF_FFFF;

/// The refcounted pool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoFlowPool {
    entries: BTreeMap<FlowEndpoint, BTreeSet<u32>>,
    next_channel_id: u32,
}

impl VideoFlowPool {
    /// A pool whose allocator starts at the given per-process random base, masked into the seed
    /// band and floored so it can never be zero.
    #[must_use]
    pub const fn new(seed: u32) -> Self {
        Self {
            entries: BTreeMap::new(),
            next_channel_id: (seed & SEED_MASK).saturating_add(MIN_CHANNEL_ID),
        }
    }

    /// How many distinct shared flows are pooled — one per active host, which is the whole point.
    #[must_use]
    pub fn shared_flow_count(&self) -> usize {
        self.entries.len()
    }

    /// How many live lanes ride the shared flow for one endpoint.
    #[must_use]
    pub fn lane_count(&self, endpoint: &FlowEndpoint) -> usize {
        self.entries.get(endpoint).map_or(0, BTreeSet::len)
    }

    /// The id the next acquisition will mint.
    #[must_use]
    pub const fn peek_next_channel_id(&self) -> u32 {
        self.next_channel_id
    }

    /// Acquires a lane, creating the endpoint's flow on the first acquisition and reusing it after.
    pub fn acquire(&mut self, endpoint: FlowEndpoint) -> AcquireOutcome {
        let channel_id = self.next_channel_id;
        self.next_channel_id = self.next_channel_id.wrapping_add(1);
        let fresh = !self.entries.contains_key(&endpoint);
        self.entries.entry(endpoint).or_default().insert(channel_id);
        if fresh {
            AcquireOutcome::FlowCreated { channel_id }
        } else {
            AcquireOutcome::LaneJoined { channel_id }
        }
    }

    /// Releases a lane. The flow survives exactly as long as one pane still rides it.
    pub fn release(&mut self, endpoint: &FlowEndpoint, channel_id: u32) -> ReleaseOutcome {
        let Some(lanes) = self.entries.get_mut(endpoint) else {
            return ReleaseOutcome::Unknown;
        };
        if !lanes.remove(&channel_id) {
            return ReleaseOutcome::Unknown;
        }
        if lanes.is_empty() {
            self.entries.remove(endpoint);
            ReleaseOutcome::FlowClosed
        } else {
            ReleaseOutcome::LaneRemoved
        }
    }
}

/// The send schedule for a one-shot request over a fire-and-forget lane.
///
/// The video path has no request-and-response machinery, so a discovery or a fetch builds its own:
/// resend every interval until the reply lands or the deadline passes, then give up and answer
/// empty. Both the request AND the reply can be lost, so a single send is not enough; and a host
/// too old to understand the request simply never replies, which must resolve to an empty answer
/// rather than a hung picker.
///
/// Returns the offsets, in seconds from the start, at which the request should go out. It is a
/// plan rather than a loop so the deadline arithmetic is testable without a clock.
#[must_use]
pub fn request_send_offsets(timeout_seconds: f64, retry_interval_seconds: f64) -> Vec<f64> {
    if !timeout_seconds.is_finite()
        || !retry_interval_seconds.is_finite()
        || timeout_seconds <= 0.0
        || retry_interval_seconds <= 0.0
    {
        return Vec::new();
    }
    let mut offsets = Vec::new();
    let mut index: u32 = 0;
    loop {
        let at = f64::from(index) * retry_interval_seconds;
        if at >= timeout_seconds || index >= MAX_REQUEST_SENDS {
            break;
        }
        offsets.push(at);
        index += 1;
    }
    offsets
}

#[cfg(test)]
mod tests {
    use super::{
        AcquireOutcome, FlowEndpoint, MIN_CHANNEL_ID, ReleaseOutcome, SEED_MASK, VideoFlowPool,
        request_send_offsets,
    };

    fn endpoint(host: &str) -> FlowEndpoint {
        FlowEndpoint::new(host, 7100, 7101)
    }

    #[test]
    fn every_pane_on_one_host_rides_a_single_shared_flow() {
        let mut pool = VideoFlowPool::new(0);
        let first = pool.acquire(endpoint("mac-studio"));
        let second = pool.acquire(endpoint("mac-studio"));
        let third = pool.acquire(endpoint("mac-studio"));
        assert!(matches!(first, AcquireOutcome::FlowCreated { .. }));
        assert!(matches!(second, AcquireOutcome::LaneJoined { .. }));
        assert!(matches!(third, AcquireOutcome::LaneJoined { .. }));
        assert_eq!(pool.shared_flow_count(), 1);
        assert_eq!(pool.lane_count(&endpoint("mac-studio")), 3);
    }

    #[test]
    fn a_different_endpoint_is_a_different_flow() {
        let mut pool = VideoFlowPool::new(0);
        pool.acquire(endpoint("mac-studio"));
        pool.acquire(endpoint("macbook-pro"));
        pool.acquire(FlowEndpoint::new("mac-studio", 7100, 7999));
        assert_eq!(pool.shared_flow_count(), 3, "the ports are part of the identity");
    }

    #[test]
    fn the_flow_survives_until_the_last_pane_lets_go() {
        let mut pool = VideoFlowPool::new(0);
        let first = pool.acquire(endpoint("mac-studio")).channel_id();
        let second = pool.acquire(endpoint("mac-studio")).channel_id();
        assert_eq!(
            pool.release(&endpoint("mac-studio"), first),
            ReleaseOutcome::LaneRemoved
        );
        assert_eq!(pool.shared_flow_count(), 1, "the sibling is still streaming");
        assert_eq!(
            pool.release(&endpoint("mac-studio"), second),
            ReleaseOutcome::FlowClosed
        );
        assert_eq!(pool.shared_flow_count(), 0);
    }

    #[test]
    fn releasing_something_that_was_never_acquired_closes_nothing() {
        let mut pool = VideoFlowPool::new(0);
        assert_eq!(pool.release(&endpoint("mac-studio"), 7), ReleaseOutcome::Unknown);
        let lane = pool.acquire(endpoint("mac-studio")).channel_id();
        assert_eq!(
            pool.release(&endpoint("mac-studio"), lane + 99),
            ReleaseOutcome::Unknown
        );
        assert_eq!(
            pool.release(&endpoint("macbook-pro"), lane),
            ReleaseOutcome::Unknown,
            "the right lane at the wrong endpoint is still nothing to close",
        );
        assert_eq!(pool.shared_flow_count(), 1);
    }

    #[test]
    fn a_retired_lane_id_is_never_minted_again() {
        let mut pool = VideoFlowPool::new(0);
        let first = pool.acquire(endpoint("mac-studio")).channel_id();
        pool.release(&endpoint("mac-studio"), first);
        let second = pool.acquire(endpoint("mac-studio")).channel_id();
        assert_eq!(
            second,
            first + 1,
            "the allocator never reuses, even on an empty pool"
        );
    }

    #[test]
    fn two_clients_seeded_apart_cannot_collide_on_the_host() {
        let mut one = VideoFlowPool::new(0x0000_0100);
        let mut other = VideoFlowPool::new(0x0100_0000);
        let mine: Vec<u32> = (0..8)
            .map(|_| one.acquire(endpoint("mac-studio")).channel_id())
            .collect();
        let theirs: Vec<u32> = (0..8)
            .map(|_| other.acquire(endpoint("mac-studio")).channel_id())
            .collect();
        assert!(
            mine.iter().all(|id| !theirs.contains(id)),
            "the whole point of the seed: separate ranges, so no reply flow is hijacked",
        );
    }

    #[test]
    fn the_seed_is_masked_into_its_band_and_never_lands_on_zero() {
        assert_eq!(VideoFlowPool::new(0).peek_next_channel_id(), MIN_CHANNEL_ID);
        assert_eq!(
            VideoFlowPool::new(u32::MAX).peek_next_channel_id(),
            SEED_MASK + MIN_CHANNEL_ID,
            "a wild base still lands inside the band, with the upper range left as headroom",
        );
    }

    #[test]
    fn the_request_goes_out_once_per_interval_until_the_deadline() {
        assert_eq!(request_send_offsets(3.0, 0.5), vec![0.0, 0.5, 1.0, 1.5, 2.0, 2.5]);
        assert_eq!(request_send_offsets(0.4, 0.5), vec![0.0], "one try still happens");
    }

    #[test]
    fn a_degenerate_schedule_sends_nothing_rather_than_looping_forever() {
        assert!(request_send_offsets(0.0, 0.5).is_empty());
        assert!(request_send_offsets(3.0, 0.0).is_empty());
        assert!(request_send_offsets(3.0, -1.0).is_empty());
        assert!(request_send_offsets(f64::NAN, 0.5).is_empty());
        assert!(request_send_offsets(3.0, f64::NAN).is_empty());
    }
}
