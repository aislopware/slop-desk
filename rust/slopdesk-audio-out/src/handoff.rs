//! The one thing the real-time thread shares with the producer.
//!
//! An `rtrb` SPSC ring plus two atomics, and nothing else. The stage, the pump and the resampler
//! all stay on the producer side; a render callback that reached any of them would be reading
//! state a preemptible pusher can be halfway through writing.
//!
//! ## Why a flush is a REQUEST rather than a drop
//! The producer can never take back a sample it has committed — that memory belongs to the
//! consumer, and moving the read index from the producer side would break the single-consumer law
//! the ring's wait-freedom stands on. So a local disable publishes a FRONTIER — the producer's
//! commit odometer at the moment of the ask — and the next render pass skips past it before it
//! copies. The pane falls silent on the next render quantum rather than one ring-drain later,
//! which is what "silent NOW" can honestly mean. A frontier rather than a flag because a re-prime
//! may start pushing in the same breath, and a flag would swallow those samples too.
//!
//! ## Why the shortfall is an ODOMETER and not a level
//! A consumer that drains the ring EXACTLY dry has zero-filled nothing and the listener heard no
//! silence — and at a ten-millisecond push cadence against a slightly longer render quantum, that
//! exact-dry drain is routine rather than a fault. A fill level of zero cannot tell the two apart.
//! A monotonic count of samples actually zero-filled can: the producer compares two observations,
//! and an advance between them means silence was genuinely played.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use core::sync::atomic::{AtomicU64, Ordering};

/// The producer's half of the hand-off.
#[derive(Debug)]
pub(crate) struct Handoff {
    ring: rtrb::Producer<f32>,
    signals: alloc_shared::Shared,
    capacity: usize,
    /// Total samples ever committed. The flush frontier is a value of this, which is what makes a
    /// flush discard exactly what was in flight when it was asked for and nothing pushed after.
    committed: u64,
}

/// The consumer's half, owned by the render callback.
#[derive(Debug)]
pub(crate) struct Render {
    ring: rtrb::Consumer<f32>,
    signals: alloc_shared::Shared,
    /// Total samples ever consumed OR skipped, on the same odometer as `Handoff::committed`.
    consumed: u64,
}

mod alloc_shared {
    use std::sync::Arc;

    use super::AtomicU64;

    /// The two atomics both sides read. Cloned, not borrowed: the consumer outlives any borrow the
    /// producer could lend it, because the device thread owns it.
    #[derive(Clone, Debug)]
    pub(crate) struct Shared(pub(crate) Arc<Signals>);

    /// The flush frontier, and the count of samples the render side has zero-filled.
    #[derive(Debug, Default)]
    pub(crate) struct Signals {
        /// Every sample below this point on the commit odometer is discarded un-played.
        pub(crate) flush_upto: AtomicU64,
        pub(crate) shortfall: AtomicU64,
    }

    impl Shared {
        pub(crate) fn new() -> Self {
            Self(Arc::new(Signals::default()))
        }
    }
}

/// Builds a hand-off of `capacity` interleaved samples and its render half.
pub(crate) fn pair(capacity: usize) -> (Handoff, Render) {
    let capacity = capacity.max(1);
    let (producer, consumer) = rtrb::RingBuffer::new(capacity);
    let signals = alloc_shared::Shared::new();
    (
        Handoff {
            ring: producer,
            signals: signals.clone(),
            capacity,
            committed: 0,
        },
        Render {
            ring: consumer,
            signals,
            consumed: 0,
        },
    )
}

impl Handoff {
    /// Samples committed and not yet consumed, as the producer sees it.
    ///
    /// Flush-requested-but-not-yet-skipped samples still count. That slack is acceptable for the
    /// depth bound this feeds: a flush also re-primes the stage, so no underrun is inferred across
    /// one.
    pub(crate) fn fill(&self) -> usize {
        self.capacity.saturating_sub(self.ring.slots())
    }

    /// Copies what fits and reports how much that was. Never blocks and never grows the ring —
    /// whatever does not fit stays STAGED, where the depth bound can still shed it.
    pub(crate) fn commit(&mut self, samples: &[f32]) -> usize {
        let (pushed, _) = self.ring.push_partial_slice(samples);
        self.committed += pushed.len() as u64;
        pushed.len()
    }

    /// Asks the consumer to discard everything committed SO FAR. See the module note.
    ///
    /// Samples pushed after this call play normally: the frontier is the odometer reading at the
    /// moment of the ask, so a re-prime that starts immediately is not swallowed by its own flush.
    pub(crate) fn request_flush(&self) {
        self.signals.0.flush_upto.store(self.committed, Ordering::Release);
    }

    /// Samples the render side has zero-filled, cumulative. Compare two readings; do not read it
    /// as a level.
    pub(crate) fn shortfall(&self) -> u64 {
        self.signals.0.shortfall.load(Ordering::Relaxed)
    }
}

impl Render {
    /// One render pass: honour a pending flush, copy what is buffered, and conceal the rest with
    /// silence.
    ///
    /// Wait-free by construction — two atomic accesses, at most two memcpys, one relaxed add.
    /// There is no lock to contend for and nothing here allocates, so a busy pusher costs the
    /// render deadline nothing.
    pub(crate) fn fill(&mut self, out: &mut [f32]) {
        let frontier = self.signals.0.flush_upto.load(Ordering::Acquire);
        if self.consumed < frontier {
            // Skip, do not copy: a discarded sample is an index advance. Clamped by what is
            // actually committed, because the frontier is the PRODUCER's odometer and this side
            // may not have seen every push that reached it yet.
            let wanted = (frontier - self.consumed).min(self.ring.slots() as u64);
            #[expect(
                clippy::cast_possible_truncation,
                reason = "clamped to `slots()`, which is a usize"
            )]
            let skip = wanted as usize;
            if skip > 0
                && let Ok(chunk) = self.ring.read_chunk(skip)
            {
                chunk.commit_all();
                self.consumed += wanted;
            }
        }
        let (popped, remainder) = self.ring.pop_partial_slice(out);
        self.consumed += popped.len() as u64;
        if !remainder.is_empty() {
            remainder.fill(0.0);
            self.signals
                .0
                .shortfall
                .fetch_add(remainder.len() as u64, Ordering::Relaxed);
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the hand-off moves samples without touching them, so it is pinned by exact bits"
    )]

    use super::pair;

    #[test]
    fn a_short_ring_conceals_the_remainder_with_silence() {
        let (mut handoff, mut render) = pair(8);
        assert_eq!(handoff.commit(&[1.0, 2.0]), 2);
        let mut out = [-1.0_f32; 4];
        render.fill(&mut out);
        assert_eq!(out, [1.0, 2.0, 0.0, 0.0]);
        // Two samples of silence were genuinely played, and the odometer says so.
        assert_eq!(handoff.shortfall(), 2);
    }

    #[test]
    fn an_exactly_dry_drain_is_not_a_shortfall() {
        // The distinction the odometer exists for: draining the ring exactly dry zero-fills
        // nothing, so it must not read as starvation.
        let (mut handoff, mut render) = pair(8);
        assert_eq!(handoff.commit(&[1.0, 2.0, 3.0, 4.0]), 4);
        let mut out = [0.0_f32; 4];
        render.fill(&mut out);
        assert_eq!(handoff.shortfall(), 0);
    }

    #[test]
    fn a_full_ring_refuses_the_overflow_rather_than_growing() {
        let (mut handoff, _render) = pair(4);
        assert_eq!(handoff.commit(&[1.0; 10]), 4);
        assert_eq!(handoff.fill(), 4);
    }

    #[test]
    fn a_flush_discards_what_was_committed_and_keeps_what_follows() {
        let (mut handoff, mut render) = pair(16);
        handoff.commit(&[1.0, 2.0, 3.0, 4.0]);
        handoff.request_flush();
        handoff.commit(&[9.0, 9.0]);
        let mut out = [-1.0_f32; 4];
        render.fill(&mut out);
        // The pre-flush samples never play; the post-flush ones do. The flush frontier is the
        // request, not a fixed index — samples pushed after it are the caller's new intent.
        assert_eq!(out, [9.0, 9.0, 0.0, 0.0]);
    }

    #[test]
    fn a_flush_before_anything_was_pushed_swallows_nothing() {
        let (mut handoff, mut render) = pair(16);
        handoff.request_flush();
        handoff.commit(&[5.0, 6.0]);
        let mut out = [0.0_f32; 2];
        render.fill(&mut out);
        assert_eq!(out, [5.0, 6.0]);
    }
}
