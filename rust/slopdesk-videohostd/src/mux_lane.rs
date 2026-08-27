//! One lane of the shared flow, seen as a whole transport by the session riding it.
//!
//! `Sources/SlopDeskVideoHost/Mux/VideoMuxChannelTransport.swift`.
//!
//! The daemon mints one of these per client video channel. From the session's side it looks like a
//! transport it owns; the difference is entirely below:
//!
//! * `send` stamps THIS lane's id and hands the datagram to the shared sockets.
//! * `start` registers the lane's sink SYNCHRONOUSLY and admits the lane in the shared router. No
//!   socket is opened — the shared transport bound both, once, for every lane.
//! * `reset_client_flow` retires ONLY this lane: sibling sessions on the same flow keep streaming
//!   and this lane's still-in-flight datagrams drop rather than being misrouted into whatever
//!   re-admits next.
//!
//! Every one of those is the shared transport's or the router's; this file is the binding.

use std::sync::{Arc, Weak};

use slopdesk_video::recovery_routing::VideoChannel;

use crate::mux_sink::{LaneSink, MuxSinkTable};

/// The shared transport, as the three verbs a lane needs from it.
///
/// A trait rather than the concrete transport for the reason the Swift passed closures: the lane
/// must be constructible in a test that has no sockets, and the registry's mint-failure path needs
/// the same three verbs without either of them knowing how a datagram reaches a wire.
pub trait LaneControl: Send + Sync + core::fmt::Debug {
    /// Admits a lane as live, so the shared router routes its datagrams. Idempotent.
    fn admit(&self, channel_id: u32);
    /// Retires a lane. Siblings are untouched; this lane's in-flight bytes drop.
    fn retire(&self, channel_id: u32);
    /// Sends one datagram for a lane, framed and on the socket its channel rides.
    fn send(&self, datagram: &[u8], channel: VideoChannel, channel_id: u32);
}

/// What a lane tells when it retires ITSELF — a `bye`, or a session stopping.
///
/// The registry implements it, so its `minting` mark and session map are cleared by the same act
/// that unregisters the sink.
pub trait LaneRetired: Send + Sync + core::fmt::Debug {
    /// The lane retired. Idempotent by contract: a stop after a `bye` reaches here twice.
    fn lane_retired(&self, channel_id: u32);
}

/// A per-lane view over the ONE shared mux transport.
#[derive(Debug)]
pub struct MuxLaneTransport {
    channel_id: u32,
    shared: Arc<dyn LaneControl>,
    sinks: Arc<MuxSinkTable>,
    /// WEAK on purpose. The registry owns the session, the session owns this lane, so a strong
    /// edge back to the registry closes a cycle nothing could ever drop. A retire arriving after
    /// the registry is gone has nothing left to clear, which is exactly what the upgrade says.
    observer: Weak<dyn LaneRetired>,
}

impl MuxLaneTransport {
    /// A lane bound to `channel_id` over the shared transport.
    #[must_use]
    pub fn new(
        channel_id: u32,
        shared: Arc<dyn LaneControl>,
        sinks: Arc<MuxSinkTable>,
        observer: Weak<dyn LaneRetired>,
    ) -> Self {
        Self {
            channel_id,
            shared,
            sinks,
            observer,
        }
    }

    /// The lane this transport speaks for.
    #[must_use]
    pub const fn channel_id(&self) -> u32 {
        self.channel_id
    }

    /// Registers the lane's sink and admits the lane, in that order.
    ///
    /// The order is the contract: admitting first would let the very next datagram route to a lane
    /// whose sink is not there yet, and the datagram that matters most — the hello the mint is
    /// running for — is exactly the one in flight.
    pub fn start(&self, sink: LaneSink) {
        self.sinks.register(self.channel_id, sink);
        self.shared.admit(self.channel_id);
    }

    /// Sends one datagram on this lane.
    pub fn send(&self, datagram: &[u8], channel: VideoChannel) {
        self.shared.send(datagram, channel, self.channel_id);
    }

    /// The session is stopping.
    pub fn stop(&self) {
        self.retire_lane();
    }

    /// A `bye` on THIS lane. The listener is shared and untouched, so a reconnecting client
    /// re-opens under a fresh lane while its siblings never notice.
    pub fn reset_client_flow(&self) {
        self.retire_lane();
    }

    fn retire_lane(&self) {
        self.shared.retire(self.channel_id);
        self.sinks.unregister(self.channel_id);
        if let Some(observer) = self.observer.upgrade() {
            observer.lane_retired(self.channel_id);
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::{Arc, Mutex, Weak};

    use slopdesk_video::recovery_routing::VideoChannel;

    use super::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;

    /// The three verbs, recorded in the order they were asked for.
    #[derive(Debug, Default)]
    struct Recorder {
        acts: Mutex<Vec<String>>,
    }

    impl Recorder {
        fn acts(&self) -> Vec<String> {
            self.acts.lock().expect("uncontended").clone()
        }

        fn note(&self, act: &str) {
            self.acts.lock().expect("uncontended").push(act.to_owned());
        }
    }

    impl LaneControl for Recorder {
        fn admit(&self, channel_id: u32) {
            self.note(&format!("admit {channel_id}"));
        }

        fn retire(&self, channel_id: u32) {
            self.note(&format!("retire {channel_id}"));
        }

        fn send(&self, datagram: &[u8], channel: VideoChannel, channel_id: u32) {
            self.note(&format!(
                "send {channel_id} {} {}",
                channel.raw_value(),
                datagram.len()
            ));
        }
    }

    impl LaneRetired for Recorder {
        fn lane_retired(&self, channel_id: u32) {
            self.note(&format!("retired {channel_id}"));
        }
    }

    #[test]
    fn starting_a_lane_registers_its_sink_before_it_admits() {
        let shared = Arc::new(Recorder::default());
        let sinks = Arc::new(MuxSinkTable::new());
        let strong = Arc::clone(&shared);
        let weak = Arc::downgrade(&shared);
        let control: Arc<dyn LaneControl> = strong;
        let observer: Weak<dyn LaneRetired> = weak;
        let lane = MuxLaneTransport::new(7, control, Arc::clone(&sinks), observer);
        assert_eq!(lane.channel_id(), 7);
        lane.start(Arc::new(|_, _| {}));
        assert!(sinks.contains(7));
        assert_eq!(shared.acts(), vec!["admit 7".to_owned()]);
    }

    #[test]
    fn a_bye_retires_only_this_lane_and_tells_the_registry() {
        let shared = Arc::new(Recorder::default());
        let sinks = Arc::new(MuxSinkTable::new());
        sinks.register(8, Arc::new(|_, _| {}));
        let strong = Arc::clone(&shared);
        let weak = Arc::downgrade(&shared);
        let control: Arc<dyn LaneControl> = strong;
        let observer: Weak<dyn LaneRetired> = weak;
        let lane = MuxLaneTransport::new(7, control, Arc::clone(&sinks), observer);
        lane.start(Arc::new(|_, _| {}));
        lane.send(&[1, 2, 3], VideoChannel::Video);
        lane.reset_client_flow();
        assert!(!sinks.contains(7));
        assert!(sinks.contains(8), "a sibling lane keeps streaming");
        assert_eq!(shared.acts(), vec![
            "admit 7".to_owned(),
            "send 7 1 3".to_owned(),
            "retire 7".to_owned(),
            "retired 7".to_owned(),
        ],);
    }

    /// The cycle the weak edge exists for: a retire after the registry is gone must be a no-op,
    /// not a dangling call and not a leak that kept the registry alive to receive it.
    #[test]
    fn a_retire_after_the_registry_is_gone_is_quiet() {
        let shared = Arc::new(Recorder::default());
        let gone = Arc::new(Recorder::default());
        let weak = Arc::downgrade(&gone);
        let observer: Weak<dyn LaneRetired> = weak;
        drop(gone);
        let strong = Arc::clone(&shared);
        let control: Arc<dyn LaneControl> = strong;
        let lane = MuxLaneTransport::new(7, control, Arc::new(MuxSinkTable::new()), observer);
        lane.stop();
        assert_eq!(shared.acts(), vec!["retire 7".to_owned()]);
    }
}
