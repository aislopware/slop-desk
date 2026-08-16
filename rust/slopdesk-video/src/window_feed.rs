//! The client-side assembler for the host-windows feed: chunks of one generation in, one complete
//! snapshot out, exactly once.
//!
//! Untrusted-input discipline throughout — a bounded map of partial generations, a bounded record
//! accumulation, and the pinned decode rule that every chunk of one generation must AGREE on
//! `chunk_count`. A disagreement means the generation is corrupt, and it is discarded rather than
//! patched; the next subscribe renewal heals it from the host's cached chunks.

use std::collections::BTreeMap;

use crate::video_control::HostWindowRecord;

/// One fully assembled snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompleteSnapshot {
    /// The generation these records describe.
    pub generation: u32,
    /// Every chunk's records, concatenated in chunk order.
    pub records: Vec<HostWindowRecord>,
}

/// A partly-received generation.
#[derive(Debug, Clone)]
struct Partial {
    /// The chunk count every chunk of this generation must agree on.
    chunk_count: u8,
    /// The records received so far, by chunk index.
    received: BTreeMap<u8, Vec<HostWindowRecord>>,
}

/// The assembler for `windowFeedSnapshot` chunks.
#[derive(Debug, Clone, Default)]
pub struct WindowFeedAssembler {
    /// The partly-received generations.
    partials: BTreeMap<u32, Partial>,
    /// Arrival order, so the oldest partial is the one evicted.
    insertion_order: Vec<u32>,
}

impl WindowFeedAssembler {
    /// How many partial generations are kept at once.
    ///
    /// In practice chunks interleave across at most adjacent generations — one answer per renewal —
    /// so the bound exists to keep a hostile sender from growing the map a generation at a time.
    pub const MAX_PARTIAL_GENERATIONS: usize = 4;

    /// The absolute record cap for one assembled generation.
    ///
    /// The host caps a snapshot at 64 records, so anything past this is padding and the generation
    /// is discarded — an untrusted accumulator gets a ceiling, not a best effort.
    pub const MAX_RECORDS_PER_GENERATION: usize = 512;

    /// An assembler with nothing in flight.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Folds one decoded chunk in, returning the snapshot when this chunk completes its generation.
    ///
    /// A duplicate chunk overwrites idempotently, which is what makes the host's dup-send free.
    pub fn fold(
        &mut self,
        generation: u32,
        chunk_index: u8,
        chunk_count: u8,
        records: Vec<HostWindowRecord>,
    ) -> Option<CompleteSnapshot> {
        let mut partial = if let Some(existing) = self.partials.get(&generation) {
            if existing.chunk_count != chunk_count {
                self.discard(generation);
                return None;
            }
            existing.clone()
        } else {
            if self.partials.len() >= Self::MAX_PARTIAL_GENERATIONS
                && let Some(&oldest) = self.insertion_order.first()
            {
                self.discard(oldest);
            }
            self.insertion_order.push(generation);
            Partial {
                chunk_count,
                received: BTreeMap::new(),
            }
        };

        partial.received.insert(chunk_index, records);
        if partial.received.len() != usize::from(chunk_count) {
            self.partials.insert(generation, partial);
            return None;
        }
        self.discard(generation);

        let mut assembled = Vec::new();
        for index in 0..chunk_count {
            // Every index is present: the count matches and the codec pinned index below count.
            if let Some(records) = partial.received.get(&index) {
                assembled.extend_from_slice(records);
            }
            if assembled.len() > Self::MAX_RECORDS_PER_GENERATION {
                return None;
            }
        }
        Some(CompleteSnapshot {
            generation,
            records: assembled,
        })
    }

    /// Drops one generation's partial state — corrupt, evicted, or just completed.
    fn discard(&mut self, generation: u32) {
        self.partials.remove(&generation);
        self.insertion_order.retain(|&held| held != generation);
    }

    /// Drops ALL partial state, at the end of a subscribe round, so a half-received generation
    /// never leaks into the next one. The renewal re-fetches it whole.
    pub fn reset(&mut self) {
        self.partials.clear();
        self.insertion_order.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::{CompleteSnapshot, WindowFeedAssembler};
    use crate::video_control::HostWindowRecord;

    /// A record identifiable by its window id alone.
    fn record(window_id: u32) -> HostWindowRecord {
        HostWindowRecord {
            window_id,
            ..HostWindowRecord::default()
        }
    }

    #[test]
    fn a_generation_completes_on_its_last_chunk_and_in_chunk_order() {
        let mut assembler = WindowFeedAssembler::new();
        assert_eq!(assembler.fold(3, 1, 2, vec![record(20), record(21)]), None);
        assert_eq!(
            assembler.fold(3, 0, 2, vec![record(10)]),
            Some(CompleteSnapshot {
                generation: 3,
                records: vec![record(10), record(20), record(21)],
            }),
            "chunk order, not arrival order",
        );
        // Delivered exactly once: the same last chunk again opens a fresh, incomplete generation.
        assert_eq!(assembler.fold(3, 0, 2, vec![record(10)]), None);
    }

    #[test]
    fn a_duplicate_chunk_overwrites_rather_than_counting_twice() {
        let mut assembler = WindowFeedAssembler::new();
        assert_eq!(assembler.fold(1, 0, 2, vec![record(1)]), None);
        assert_eq!(assembler.fold(1, 0, 2, vec![record(1)]), None, "still one of two");
        assert!(assembler.fold(1, 1, 2, vec![record(2)]).is_some());
    }

    #[test]
    fn a_disagreeing_chunk_count_discards_the_whole_generation() {
        let mut assembler = WindowFeedAssembler::new();
        assert_eq!(assembler.fold(1, 0, 2, vec![record(1)]), None);
        assert_eq!(
            assembler.fold(1, 1, 3, vec![record(2)]),
            None,
            "discarded, not patched"
        );
        assert_eq!(
            assembler.fold(1, 1, 2, vec![record(2)]),
            None,
            "the first chunk went too"
        );
    }

    #[test]
    fn the_oldest_partial_generation_is_evicted_once_the_map_is_full() {
        let mut assembler = WindowFeedAssembler::new();
        for generation in 0..u32::try_from(WindowFeedAssembler::MAX_PARTIAL_GENERATIONS).unwrap_or(4) {
            assert_eq!(assembler.fold(generation, 0, 2, vec![record(generation)]), None);
        }
        assert_eq!(
            assembler.fold(99, 0, 2, vec![record(99)]),
            None,
            "evicts generation 0"
        );
        assert_eq!(
            assembler.fold(0, 1, 2, vec![record(0)]),
            None,
            "generation 0 is gone"
        );
        assert!(assembler.fold(99, 1, 2, vec![record(98)]).is_some());
    }

    /// A padded generation is dropped whole rather than delivered short.
    #[test]
    fn an_over_capacity_generation_is_discarded() {
        let mut assembler = WindowFeedAssembler::new();
        let flood: Vec<HostWindowRecord> =
            (0..u32::try_from(WindowFeedAssembler::MAX_RECORDS_PER_GENERATION).unwrap_or(512))
                .map(record)
                .collect();
        assert_eq!(assembler.fold(1, 0, 2, flood), None);
        assert_eq!(
            assembler.fold(1, 1, 2, vec![record(9999)]),
            None,
            "one record too many"
        );
    }

    #[test]
    fn a_reset_drops_everything_in_flight() {
        let mut assembler = WindowFeedAssembler::new();
        assert_eq!(assembler.fold(1, 0, 2, vec![record(1)]), None);
        assembler.reset();
        assert_eq!(assembler.fold(1, 1, 2, vec![record(2)]), None);
    }
}
