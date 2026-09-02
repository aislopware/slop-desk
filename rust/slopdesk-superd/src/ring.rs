//! The bytes a pane produced while nobody was listening.
//!
//! ## Why this exists at all
//! superd was designed as a custodian that never reads a pane's bytes, and that was right for the
//! problem it was solving: hostd holds the master, so the keystroke path gains no hop and
//! `tcgetpgrp` stays a syscall. But "never reads" has a consequence that only shows up during the
//! event superd exists for. Between hostd's exit and the next hostd's `adopt` **nobody is draining
//! the master**, so the kernel's PTY buffer fills — it is a few KB — and the child's next `write`
//! blocks. The agent does not die, which was the whole point; it simply stops, for as long as the
//! restart takes. A `claude` mid-task freezes at whatever line it had reached.
//!
//! So superd now owns the READ side and hostd subscribes to it. The parts of the original
//! reasoning that were load-bearing survive intact, because only the read side moved: hostd keeps
//! its duplicate of the master and still `write`s keystrokes and `tcgetpgrp`s it directly, with no
//! hop and no polled IPC. What it no longer does is `read`.
//!
//! ## What this structure is
//! A byte ring addressed by **absolute offsets since the pane was born**. Offsets never rewind and
//! never repeat, so a returning hostd asks for "everything after 91_244" and gets an unambiguous
//! answer — including the answer "I no longer have 91_244, the oldest I still hold is 132_800",
//! which is how a hostd that was away too long learns its transcript has a hole instead of
//! silently splicing two unrelated regions together.
//!
//! Offsets are per **pane life**, not persistent. They do not need to be: superd's own death takes
//! every pane with it (`docs/51` §4), so there is no case where a pane outlives the process that
//! numbered its bytes.
//!
//! ## Not the scrollback journal
//! The on-disk journal (`SlopDeskHost`'s `ScrollbackJournal`) is a different thing with a
//! different job — the transcript of a pane whose process is long gone, replayed above a *fresh*
//! shell after a reboot. It stays where it is. This ring is the resume buffer for a pane that is
//! still running, and it is memory-only for the same reason the offsets are.

use std::collections::VecDeque;

/// How much output one pane retains for a hostd that is away.
///
/// Sized for the event, not for history: a restart is seconds, and the thing that must fit is what
/// a busy agent emits in that window. 4 MiB is roughly a minute of a full-tilt build's output and
/// costs nothing when idle, because the ring only ever holds what was actually produced.
pub const DEFAULT_CAPACITY_BYTES: usize = 4 * 1024 * 1024;

/// Overrides [`DEFAULT_CAPACITY_BYTES`]. Read once at startup — see [`capacity_from_env`].
pub const CAPACITY_ENV_KEY: &str = "SLOPDESK_PANE_RING_BYTES";

/// What a subscriber gets back when it asks to resume from an offset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resume {
    /// The absolute offset the returned bytes actually start at. Equal to the requested offset on a
    /// clean resume; **greater** when the ring had already evicted past it.
    pub start: u64,
    /// The absolute offset just past the last returned byte — where the live stream picks up.
    pub head: u64,
    /// The retained bytes from `start` to `head`.
    pub bytes: Vec<u8>,
}

impl Resume {
    /// Whether bytes were lost between what the caller asked for and what it got.
    ///
    /// The caller is expected to act on this rather than ignore it: splicing a gap into a terminal
    /// transcript without marking it produces a screen that is not merely incomplete but *wrong* —
    /// a half-drawn frame followed by an unrelated one, with no escape sequence to reconcile them.
    #[must_use]
    pub const fn is_lossy(&self, requested: u64) -> bool {
        self.start > requested
    }
}

/// A pane's retained output.
#[derive(Debug)]
pub struct OutputRing {
    bytes: VecDeque<u8>,
    capacity: usize,
    /// Absolute offset of `bytes.front()`. Advances only by eviction.
    base: u64,
}

impl OutputRing {
    /// An empty ring holding at most `capacity` bytes.
    #[must_use]
    pub const fn new(capacity: usize) -> Self {
        Self {
            bytes: VecDeque::new(),
            capacity,
            base: 0,
        }
    }

    /// The absolute offset just past the newest byte — i.e. the total ever appended.
    #[must_use]
    pub fn head(&self) -> u64 {
        self.base.saturating_add(self.bytes.len() as u64)
    }

    /// The absolute offset of the oldest byte still retained.
    #[must_use]
    pub const fn base(&self) -> u64 {
        self.base
    }

    /// Appends a chunk, evicting from the front to stay within capacity.
    ///
    /// A chunk larger than the whole ring keeps its own tail rather than clearing to nothing: the
    /// newest bytes are the ones a returning client needs, and "the ring is empty because one big
    /// write arrived" would be a strictly worse answer than "here is the last 4 MiB of it".
    pub fn append(&mut self, chunk: &[u8]) {
        if self.capacity == 0 {
            self.base = self.base.saturating_add(chunk.len() as u64);
            return;
        }
        // Only the tail can survive, so never copy more than that in.
        let kept = chunk.len().min(self.capacity);
        let dropped_from_chunk = chunk.len().saturating_sub(kept);
        self.base = self.base.saturating_add(dropped_from_chunk as u64);
        self.bytes
            .extend(chunk.get(dropped_from_chunk..).unwrap_or_default());

        let overflow = self.bytes.len().saturating_sub(self.capacity);
        if overflow > 0 {
            drop(self.bytes.drain(..overflow));
            self.base = self.base.saturating_add(overflow as u64);
        }
    }

    /// Everything retained from `offset` onwards, clamped to what still exists.
    ///
    /// An offset **past** the head is not an error and does not clamp backwards: a subscriber that
    /// asks for the future gets nothing and the head, which is exactly what "I am already
    /// up to date" should look like.
    #[must_use]
    pub fn read_from(&self, offset: u64) -> Resume {
        let start = offset.max(self.base).min(self.head());
        let skip = usize::try_from(start.saturating_sub(self.base)).unwrap_or(usize::MAX);
        // Two memcpys rather than a byte-at-a-time walk: this runs under the ring lock on every
        // subscribe, and a pump blocked behind a 4 MiB iterator is a pane that stops flowing while
        // a hostd adopts it.
        let (front, back) = self.bytes.as_slices();
        let mut bytes = Vec::with_capacity(self.bytes.len().saturating_sub(skip));
        bytes.extend_from_slice(front.get(skip..).unwrap_or_default());
        bytes.extend_from_slice(back.get(skip.saturating_sub(front.len())..).unwrap_or_default());
        Resume {
            start,
            head: self.head(),
            bytes,
        }
    }

    /// Drops everything retained without disturbing the offset numbering.
    ///
    /// Used when the pane's only subscriber is caught up and its owner wants the memory back. The
    /// base advances to the head, so a later `read_from` on a stale offset still reports the loss
    /// rather than pretending the bytes were never produced.
    pub fn forget(&mut self) {
        self.base = self.head();
        self.bytes.clear();
        self.bytes.shrink_to_fit();
    }
}

/// The capacity to build panes with, from the environment, falling back to the default.
///
/// A value of `0` is honoured and means "retain nothing": offsets still advance, so a returning
/// hostd is told, truthfully, that everything it missed is gone.
#[must_use]
pub fn capacity_from_env() -> usize {
    std::env::var(CAPACITY_ENV_KEY)
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .unwrap_or(DEFAULT_CAPACITY_BYTES)
}

#[cfg(test)]
mod tests {
    use super::{OutputRing, Resume};

    #[test]
    fn offsets_are_absolute_and_a_clean_resume_returns_exactly_the_gap() {
        let mut ring = OutputRing::new(1024);
        ring.append(b"hello ");
        ring.append(b"world");
        assert_eq!(ring.head(), 11);
        assert_eq!(ring.base(), 0);

        let resumed = ring.read_from(6);
        assert_eq!(resumed, Resume {
            start: 6,
            head: 11,
            bytes: b"world".to_vec(),
        });
        assert!(!resumed.is_lossy(6));
    }

    /// The case the whole type exists to make legible: hostd was away long enough to overflow.
    #[test]
    fn an_overflowed_resume_reports_where_it_actually_starts() {
        let mut ring = OutputRing::new(8);
        ring.append(b"0123456789ab");
        assert_eq!(ring.base(), 4, "the first four bytes were evicted");
        assert_eq!(ring.head(), 12);

        let resumed = ring.read_from(0);
        assert!(
            resumed.is_lossy(0),
            "asking for byte 0 must not silently return byte 4"
        );
        assert_eq!(resumed.start, 4);
        assert_eq!(resumed.bytes, b"456789ab");
    }

    /// A chunk bigger than the ring keeps its own tail. Clearing to empty would throw away the
    /// bytes most likely to matter.
    #[test]
    fn a_chunk_larger_than_the_ring_keeps_its_tail() {
        let mut ring = OutputRing::new(4);
        ring.append(b"abcdefghij");
        assert_eq!(ring.read_from(0).bytes, b"ghij");
        assert_eq!(ring.head(), 10);
        assert_eq!(ring.base(), 6);
    }

    /// Asking for the future is "I am up to date", not an error and not a rewind.
    #[test]
    fn an_offset_past_the_head_yields_nothing_and_does_not_rewind() {
        let mut ring = OutputRing::new(64);
        ring.append(b"abc");
        let resumed = ring.read_from(99);
        assert!(resumed.bytes.is_empty());
        assert_eq!(resumed.start, 3);
        assert_eq!(resumed.head, 3);
    }

    /// Capacity zero must still count, or a hostd that missed bytes would be told it missed none.
    #[test]
    fn a_zero_capacity_ring_still_advances_its_offsets() {
        let mut ring = OutputRing::new(0);
        ring.append(b"abcdef");
        assert_eq!(ring.head(), 6);
        assert!(ring.read_from(0).is_lossy(0));
    }

    /// The two halves of a wrapped ring come back in order, from any offset, whichever half it
    /// falls in.
    #[test]
    fn a_wrapped_ring_resumes_bit_exactly_from_either_half() {
        let mut ring = OutputRing::new(8);
        ring.append(b"01234567");
        ring.append(b"89ab");
        assert_eq!(ring.base(), 4);
        assert_eq!(ring.read_from(4).bytes, b"456789ab");
        assert_eq!(ring.read_from(6).bytes, b"6789ab");
        assert_eq!(ring.read_from(9).bytes, b"9ab");
        assert_eq!(ring.read_from(12).bytes, b"");
    }

    #[test]
    fn forget_releases_the_bytes_without_rewinding_the_numbering() {
        let mut ring = OutputRing::new(64);
        ring.append(b"abcdef");
        ring.forget();
        assert_eq!(ring.head(), 6);
        assert_eq!(ring.base(), 6);
        assert!(ring.read_from(2).is_lossy(2));
    }
}
