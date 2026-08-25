//! The order and the arithmetic of one pane's outbound frame queue — docs/59 step 2.
//!
//! hostd's PTY read loop appends a chunk per supervised read; ONE drain task pops, and what it pops
//! is not what was appended. Adjacent chunks COALESCE up to the credit-safe frame cap, so a flood
//! of kernel-sized reads costs one seq/encode/envelope/send round instead of N. An over-cap head
//! SPLITS so the 13-byte output header can never push a frame past the receiver's grant threshold —
//! the dead-zone stall `slopdesk-wire`'s `max_output_frame_payload_bytes` exists to prevent. And
//! `.exit` is a merge BARRIER: it never coalesces, so the reaper's exit code stays strictly after
//! the final output tail.
//!
//! **No byte is here.** The queue holds `(slot, len)`, and the caller holds the payload each slot
//! names. That is docs/55 §4b's test applied literally — the far side reads LENGTHS and never the
//! bytes, so the merge decision crosses for the cost of a call while the concatenation stays where
//! the `Data` already is. A door that took the chunk would pay a `Data` allocation per 32 KiB read,
//! which docs/55 §4c prices at 227.5 ns against a crossing's 1.0.
//!
//! **The slot is MINTED here**, not handed in. It is a queue coordinate rather than an identity —
//! nothing outside names it, it dies with the frame that ships it — and minting it on this side
//! buys the property the frame verdict is built on: chunk slots are CONSECUTIVE, so a merged run is
//! `first_slot .. first_slot + slots` and the verdict needs no counted buffer at all. `.exit` takes
//! no slot, which is what keeps the run consecutive across a barrier.
//!
//! What did NOT cross: the wake. Every mutation here answers what the queue now holds; the
//! `AsyncStream` continuation, the drain `Task` and the bounded-queue gate's pause sink stay in
//! hostd, for the reason [`crate::resize_fold`] leaves the `TIOCSWINSZ` there.

use std::collections::VecDeque;

/// The caller's name for one enqueued payload, minted by [`Outbox::append_chunk`].
///
/// Consecutive across the whole queue, because `.exit` does not take one.
pub type Slot = u64;

/// One entry, as the queue holds it: a length and the slot whose bytes the caller kept, or the
/// barrier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[expect(
    variant_size_differences,
    reason = "the lint prices the tax a large variant puts on every element of a container; this enum is 24 \
              bytes in a `VecDeque`, and the two ways to balance it are a `Box` — a heap allocation on the \
              per-read append path, the exact cost this module exists to avoid — or a dead field on the \
              barrier, which is a lie about what an exit carries"
)]
enum Item {
    /// `len` bytes the caller stored under `slot`.
    Chunk { slot: Slot, len: usize },
    /// The reaper's exit code. Never coalesces.
    Exit { code: i32 },
}

/// What one pop asks the caller to ship.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[expect(
    variant_size_differences,
    reason = "a by-value verdict returned once per outbound frame and never held in a collection, so the \
              per-element tax the lint prices is not charged anywhere here"
)]
pub enum Frame {
    /// Concatenate the payloads of `first_slot .. first_slot + slots`, in that order, and ship the
    /// result as ONE `.output`.
    ///
    /// `byte_count` is the frame's payload size — the number the bounded-queue gate dequeues, which
    /// sums to the producer's enqueued total exactly because a split frame counts only what it
    /// ships.
    ///
    /// `split` means the head chunk was over the cap: `slots` is 1, only the first `byte_count`
    /// bytes ship, and that slot STAYS queued holding the remainder. The caller keeps the slot's
    /// payload minus the shipped prefix, and clears its control — the sniffed control rides the
    /// prefix, since a per-channel control FIFO is the only order anything downstream relies on.
    Output {
        /// The first slot of the run.
        first_slot: Slot,
        /// How many consecutive slots the run covers. Always 1 when `split`.
        slots: usize,
        /// Payload bytes this frame ships.
        byte_count: usize,
        /// Whether the head slot was split rather than consumed.
        split: bool,
    },
    /// Ship the pane's exit code. The queue popped it whole.
    Exit {
        /// The reaped status.
        code: i32,
    },
}

/// One pane's outbound frame queue.
///
/// Deliberately unlocked and not `Sync`: hostd holds every call under the one `NSLock` that already
/// guarded the array this replaces, so a second lock here would be a lock the caller's ordering
/// says nothing about. A `VecDeque` because the pop is from the front — the array-plus-cursor dance
/// the Swift original needed (and the bulk compaction that amortized it) exists only because
/// `Array.removeFirst()` is an O(count) memmove.
#[derive(Debug, Default)]
pub struct Outbox {
    /// Front is the next frame's head.
    queue: VecDeque<Item>,
    /// The next slot to mint. Monotone for the pane's whole life; wrapping it would take 2^64
    /// chunks, which at one 32 KiB read each is more bytes than the machine will ever produce.
    next_slot: Slot,
}

impl Outbox {
    /// An empty queue.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Enqueues `len` bytes and answers the slot the caller must store them under.
    pub fn append_chunk(&mut self, len: usize) -> Slot {
        let slot = self.next_slot;
        self.next_slot = self.next_slot.wrapping_add(1);
        self.queue.push_back(Item::Chunk { slot, len });
        slot
    }

    /// Enqueues the exit barrier.
    pub fn append_exit(&mut self, code: i32) {
        self.queue.push_back(Item::Exit { code });
    }

    /// Whether anything is waiting — the "carried frames" question a restarted drain asks itself
    /// before deciding whether the rebind owes it a kick.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    /// Pops the next frame, coalescing up to `cap` payload bytes.
    ///
    /// `cap` is passed in rather than read here because it is `slopdesk-wire`'s
    /// `max_output_frame_payload_bytes` — the PROTOCOL's number, and this crate does not read the
    /// protocol (see the manifest header). The door supplies it, so it is still spelled once.
    ///
    /// A `cap` of zero would make an over-cap split ship nothing and loop forever; the clamp below
    /// makes the smallest legal frame one byte, which cannot happen through the door (the flow
    /// constant's own floor is far above it) and cannot hang if it ever did.
    pub fn take(&mut self, cap: usize) -> Option<Frame> {
        let cap = cap.max(1);
        let head = *self.queue.front()?;
        let (slot, len) = match head {
            Item::Exit { code } => {
                self.queue.pop_front();
                return Some(Frame::Exit { code });
            },
            Item::Chunk { slot, len } => (slot, len),
        };
        if len > cap {
            // SPLIT: the head keeps the remainder in place, so byte order is untouched and the
            // caller's slot map is not re-keyed.
            if let Some(Item::Chunk { len: head_len, .. }) = self.queue.front_mut() {
                *head_len = len - cap;
            }
            return Some(Frame::Output {
                first_slot: slot,
                slots: 1,
                byte_count: cap,
                split: true,
            });
        }
        self.queue.pop_front();
        let mut byte_count = len;
        let mut slots = 1;
        // Greedily absorb following CHUNKS while they fit. `.exit` fails the pattern, which is what
        // makes it the barrier.
        while let Some(&Item::Chunk { len: more, .. }) = self.queue.front() {
            if byte_count + more > cap {
                break;
            }
            self.queue.pop_front();
            byte_count += more;
            slots += 1;
        }
        Some(Frame::Output {
            first_slot: slot,
            slots,
            byte_count,
            split: false,
        })
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a helper handed the exit barrier where an output frame was asserted has no meaningful \
                  default to return — a zero would read as a shipped empty frame and pass"
    )]

    use super::{Frame, Outbox};

    #[test]
    fn an_empty_queue_has_no_frame() {
        let mut outbox = Outbox::new();
        assert!(outbox.is_empty());
        assert_eq!(outbox.take(1024), None);
    }

    #[test]
    fn adjacent_chunks_coalesce_into_one_frame() {
        let mut outbox = Outbox::new();
        assert_eq!(outbox.append_chunk(3), 0);
        assert_eq!(outbox.append_chunk(2), 1);
        assert_eq!(outbox.append_chunk(4), 2);
        assert_eq!(
            outbox.take(1024),
            Some(Frame::Output {
                first_slot: 0,
                slots: 3,
                byte_count: 9,
                split: false,
            })
        );
        assert_eq!(outbox.take(1024), None, "everything was absorbed");
    }

    #[test]
    fn the_merge_stops_at_the_cap_rather_than_overshooting_it() {
        let mut outbox = Outbox::new();
        outbox.append_chunk(6);
        outbox.append_chunk(6);
        outbox.append_chunk(6);
        let Some(Frame::Output {
            slots, byte_count, ..
        }) = outbox.take(12)
        else {
            panic!("expected a frame");
        };
        assert_eq!((slots, byte_count), (2, 12));
        assert_eq!(
            outbox.take(12),
            Some(Frame::Output {
                first_slot: 2,
                slots: 1,
                byte_count: 6,
                split: false,
            })
        );
    }

    #[test]
    fn an_over_cap_head_splits_and_keeps_its_slot() {
        let mut outbox = Outbox::new();
        let slot = outbox.append_chunk(25);
        assert_eq!(
            outbox.take(10),
            Some(Frame::Output {
                first_slot: slot,
                slots: 1,
                byte_count: 10,
                split: true,
            })
        );
        assert_eq!(
            outbox.take(10),
            Some(Frame::Output {
                first_slot: slot,
                slots: 1,
                byte_count: 10,
                split: true,
            }),
            "the same slot ships its next prefix",
        );
        assert_eq!(
            outbox.take(10),
            Some(Frame::Output {
                first_slot: slot,
                slots: 1,
                byte_count: 5,
                split: false,
            }),
            "the tail fits, so the slot is finally consumed",
        );
        assert!(outbox.is_empty());
    }

    #[test]
    fn exit_is_a_barrier_that_never_coalesces() {
        let mut outbox = Outbox::new();
        outbox.append_chunk(6);
        outbox.append_chunk(6);
        outbox.append_exit(0);
        outbox.append_chunk(4);
        assert_eq!(
            outbox.take(1024),
            Some(Frame::Output {
                first_slot: 0,
                slots: 2,
                byte_count: 12,
                split: false,
            }),
            "the tail merges up to the barrier and stops",
        );
        assert_eq!(outbox.take(1024), Some(Frame::Exit { code: 0 }));
        assert_eq!(
            outbox.take(1024),
            Some(Frame::Output {
                first_slot: 2,
                slots: 1,
                byte_count: 4,
                split: false,
            }),
            "a chunk enqueued after the barrier keeps its own frame",
        );
    }

    #[test]
    fn exit_does_not_take_a_slot_so_the_run_stays_consecutive() {
        let mut outbox = Outbox::new();
        assert_eq!(outbox.append_chunk(1), 0);
        outbox.append_exit(3);
        assert_eq!(outbox.append_chunk(1), 1);
        assert_eq!(outbox.append_chunk(1), 2);
        assert_eq!(
            outbox.take(1024).map(frame_slots),
            Some((0, 0)),
            "the barrier stops the merge after the first chunk",
        );
        assert_eq!(outbox.take(1024), Some(Frame::Exit { code: 3 }));
        assert_eq!(
            outbox.take(1024).map(frame_slots),
            Some((1, 2)),
            "the two chunks after the barrier are one consecutive run",
        );
    }

    #[test]
    fn a_degenerate_cap_still_makes_progress() {
        let mut outbox = Outbox::new();
        outbox.append_chunk(2);
        assert_eq!(
            outbox.take(0).map(frame_bytes),
            Some(1),
            "the clamp keeps a zero cap from shipping an empty prefix forever",
        );
        assert_eq!(outbox.take(0).map(frame_bytes), Some(1));
        assert!(outbox.is_empty());
    }

    /// `(first_slot, last_slot)` of an output frame.
    fn frame_slots(frame: Frame) -> (u64, u64) {
        match frame {
            Frame::Output {
                first_slot, slots, ..
            } => {
                (
                    first_slot,
                    first_slot + u64::try_from(slots).unwrap_or(0).saturating_sub(1),
                )
            },
            Frame::Exit { .. } => panic!("expected an output frame"),
        }
    }

    /// The payload size of an output frame.
    fn frame_bytes(frame: Frame) -> usize {
        match frame {
            Frame::Output { byte_count, .. } => byte_count,
            Frame::Exit { .. } => panic!("expected an output frame"),
        }
    }
}
