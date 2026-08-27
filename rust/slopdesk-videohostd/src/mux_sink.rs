//! The lane → session sink table, and the one ordering property it exists to give.
//!
//! `Sources/SlopDeskVideoHost/Mux/VideoMuxSessionRegistry.swift`'s `VideoMuxSinkTable`.
//!
//! The registry READS this on every dispatch; a lane's own transport WRITES it, synchronously,
//! inside `session.start()`. That synchrony is the whole point and not an implementation accident:
//! there is exactly ONE hello for a new lane, it is the datagram that MINTS the session, and it
//! must be deliverable the instant the mint returns. A sink registered by a later hop would miss
//! it, and the client would sit in `connecting` until its next retry.
//!
//! Nothing here is a rule — it is a map behind a lock, which is why it holds no decision at all.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_video::recovery_routing::VideoChannel;

/// One lane's delivery point: the session's own inbound handler.
///
/// `&[u8]` rather than an owned buffer, because the receive thread lends the datagram it just read
/// and every consumer copies only what it retains — the same borrow the Swift's tag-stripped slice
/// gave, with the lifetime checked instead of reasoned about.
pub type LaneSink = Arc<dyn Fn(VideoChannel, &[u8]) + Send + Sync>;

/// The lock-protected `channel_id` → sink table shared by the registry and the lane transports.
#[derive(Default)]
pub struct MuxSinkTable {
    sinks: Mutex<BTreeMap<u32, LaneSink>>,
}

impl core::fmt::Debug for MuxSinkTable {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("MuxSinkTable")
            .field("lanes", &self.count())
            .finish_non_exhaustive()
    }
}

impl MuxSinkTable {
    /// A table with no lanes.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Binds a lane's sink, replacing whatever it held.
    pub fn register(&self, channel_id: u32, sink: LaneSink) {
        drop(self.locked().insert(channel_id, sink));
    }

    /// Drops a lane's sink. Idempotent.
    pub fn unregister(&self, channel_id: u32) {
        drop(self.locked().remove(&channel_id));
    }

    /// A lane's sink, cloned out so the caller delivers OUTSIDE this lock — a sink that ran under
    /// it would hold every other lane's register and unregister for the length of a session hop.
    #[must_use]
    pub fn sink(&self, channel_id: u32) -> Option<LaneSink> {
        self.locked().get(&channel_id).map(Arc::clone)
    }

    /// Whether a lane is live — the registry's half of the dispatch question.
    #[must_use]
    pub fn contains(&self, channel_id: u32) -> bool {
        self.locked().contains_key(&channel_id)
    }

    /// How many lanes are live.
    #[must_use]
    pub fn count(&self) -> usize {
        self.locked().len()
    }

    /// The live lanes' ids — the virtual-display termination policy's live-lane snapshot input.
    #[must_use]
    pub fn channel_ids(&self) -> BTreeSet<u32> {
        self.locked().keys().copied().collect()
    }

    /// The table, with a poisoned lock taken anyway.
    ///
    /// A panic in a sink must not silently stop every other lane from ever registering again; the
    /// map itself has no invariant a partial write could break, so the recovered guard is sound.
    fn locked(&self) -> std::sync::MutexGuard<'_, BTreeMap<u32, LaneSink>> {
        self.sinks.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use slopdesk_video::recovery_routing::VideoChannel;

    use super::MuxSinkTable;

    #[test]
    fn a_registered_lane_is_live_and_delivers_what_it_is_handed() {
        let table = MuxSinkTable::new();
        let seen = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&seen);
        table.register(
            7,
            Arc::new(move |_channel, payload: &[u8]| {
                counter.fetch_add(payload.len(), Ordering::Relaxed);
            }),
        );
        assert!(table.contains(7));
        assert_eq!(table.count(), 1);
        table.sink(7).expect("just registered")(VideoChannel::Control, &[1, 2, 3]);
        assert_eq!(seen.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn an_unregistered_lane_is_gone_and_a_sibling_survives_it() {
        let table = MuxSinkTable::new();
        table.register(7, Arc::new(|_, _| {}));
        table.register(8, Arc::new(|_, _| {}));
        table.unregister(7);
        table.unregister(7); // idempotent
        assert!(!table.contains(7));
        assert!(table.contains(8));
        assert_eq!(table.channel_ids().into_iter().collect::<Vec<_>>(), vec![8]);
        assert!(table.sink(7).is_none());
        assert!(format!("{table:?}").contains("MuxSinkTable"));
    }
}
