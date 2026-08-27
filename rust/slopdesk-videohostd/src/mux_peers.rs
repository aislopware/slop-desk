//! Which peer a flow id names — the one thing `NWListener` used to hold that a UDP socket does not.
//!
//! The Swift host bound an `NWListener` per port and let Network.framework mint an `NWConnection`
//! per source endpoint. That object was the "flow": [`slopdesk_video::mux_flow::MuxFlowTable`]
//! keeps ids and no objects, so the near side always had to hold an id → object registry beside it.
//!
//! A plain UDP socket has no such object. `recv_from` hands back the peer address and `send_to`
//! takes one, so the flow IS the peer address on a given socket, and this registry is the id ↔
//! address map that stands where the `NWConnection` registry stood. Everything downstream is
//! unchanged: the table, the router and the reaper all speak in ids.
//!
//! ## Two consequences worth stating rather than discovering
//!
//! * **A reaped flow costs nothing to close.** The `NWConnection` was a descriptor and an armed
//!   receive callback, so a leaked flow was a leaked fd and the reap existed to stop the daemon
//!   running out of them. Here a flow is two map entries. The reap still matters — an unbounded map
//!   fed by a hostile source is still unbounded — but there is no `cancel()` to perform outside the
//!   lock, so the transport's reaper does its whole tick under one.
//! * **A flow id is never reused.** The allocator is monotonic, so an address that is released and
//!   then talks again is interned as a NEW id — exactly what a fresh `NWConnection` object was.
//!   Reusing an id would let a stamp made for the dead flow answer for the live one.

use std::collections::BTreeMap;
use std::net::SocketAddr;

use slopdesk_video::mux_flow::FlowId;

/// The id ↔ peer-address registry for one transport's two sockets.
///
/// Keyed by socket as well as address, because a client's media and cursor datagrams legitimately
/// arrive from the same host on two different ports — and even from the same port, were a client
/// ever to share one socket, the two are distinct flows to every rule downstream.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PeerRegistry {
    by_peer: BTreeMap<(bool, SocketAddr), FlowId>,
    by_flow: BTreeMap<FlowId, SocketAddr>,
    /// The highest id ever minted. Monotonic; see the module note on why it never rewinds.
    highest: FlowId,
}

impl PeerRegistry {
    /// An empty registry that has minted nothing.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            by_peer: BTreeMap::new(),
            by_flow: BTreeMap::new(),
            highest: 0,
        }
    }

    /// The flow id for a peer on the media (`is_media`) or cursor socket, minting one if this is
    /// the first datagram from it.
    ///
    /// The second element is `true` only for a FRESH id, which is the transport's signal to
    /// `accept` the flow into the flow table rather than merely refresh it.
    pub fn intern(&mut self, peer: SocketAddr, is_media: bool) -> (FlowId, bool) {
        if let Some(&flow) = self.by_peer.get(&(is_media, peer)) {
            return (flow, false);
        }
        // Saturating rather than wrapping: at one flow per nanosecond a `u64` outlives the machine,
        // and a saturated allocator that hands out one shared id is still safe — it merges two
        // peers' bookkeeping, where a wrapped one would hand a live flow's id to a stranger.
        self.highest = self.highest.saturating_add(1);
        let flow = self.highest;
        self.by_peer.insert((is_media, peer), flow);
        self.by_flow.insert(flow, peer);
        (flow, true)
    }

    /// The address a flow id names, if it is still interned.
    #[must_use]
    pub fn peer(&self, flow: FlowId) -> Option<SocketAddr> {
        self.by_flow.get(&flow).copied()
    }

    /// Forgets a flow the table has finished with — a reap, or a shutdown. Idempotent.
    pub fn release(&mut self, flow: FlowId) {
        if self.by_flow.remove(&flow).is_some() {
            self.by_peer.retain(|_, interned| *interned != flow);
        }
    }

    /// Forgets every flow, for a shutdown that has already emptied the table.
    pub fn release_all(&mut self) {
        self.by_peer.clear();
        self.by_flow.clear();
    }

    /// How many flows are interned.
    #[must_use]
    pub fn len(&self) -> usize {
        self.by_flow.len()
    }

    /// Whether nothing is interned.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.by_flow.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;

    use super::PeerRegistry;

    const MEDIA: bool = true;
    const CURSOR: bool = false;

    fn peer(port: u16) -> SocketAddr {
        SocketAddr::from(([127, 0, 0, 1], port))
    }

    #[test]
    fn a_peer_keeps_one_id_for_as_long_as_it_is_interned() {
        let mut registry = PeerRegistry::new();
        let (first, fresh) = registry.intern(peer(9001), MEDIA);
        assert!(fresh, "the first datagram from a peer mints its flow");
        assert_eq!(registry.intern(peer(9001), MEDIA), (first, false));
        assert_eq!(registry.peer(first), Some(peer(9001)));
        assert_eq!(registry.len(), 1);
    }

    #[test]
    fn the_two_sockets_are_distinct_flows_for_the_same_address() {
        let mut registry = PeerRegistry::new();
        let (media, _) = registry.intern(peer(9001), MEDIA);
        let (cursor, fresh) = registry.intern(peer(9001), CURSOR);
        assert!(fresh);
        assert_ne!(media, cursor);
        assert_eq!(registry.len(), 2);
    }

    /// A stamp made for a dead flow must never be able to answer for a live one.
    #[test]
    fn a_released_peer_that_talks_again_is_a_new_flow() {
        let mut registry = PeerRegistry::new();
        let (first, _) = registry.intern(peer(9001), MEDIA);
        registry.release(first);
        assert_eq!(registry.peer(first), None);
        registry.release(first); // idempotent
        let (second, fresh) = registry.intern(peer(9001), MEDIA);
        assert!(fresh);
        assert_ne!(second, first);
    }

    #[test]
    fn a_shutdown_forgets_everything() {
        let mut registry = PeerRegistry::new();
        let _media = registry.intern(peer(9001), MEDIA);
        let _cursor = registry.intern(peer(9002), CURSOR);
        registry.release_all();
        assert!(registry.is_empty());
        // The allocator does NOT rewind with the map.
        let (next, _) = registry.intern(peer(9001), MEDIA);
        assert_eq!(next, 3);
    }

    #[test]
    fn an_unknown_id_names_no_peer() {
        let registry = PeerRegistry::new();
        assert_eq!(registry.peer(404), None);
        assert!(registry.is_empty());
        assert_eq!(PeerRegistry::default(), registry);
    }
}
