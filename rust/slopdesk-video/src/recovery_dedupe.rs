//! Collapsing the client's deliberately redundant recovery requests back to ONE host action.
//!
//! The client sends each logical `RequestLtrRefresh` / `RequestIdr` as N byte-identical copies a
//! few milliseconds apart, so a single lost datagram cannot cost a recovery. This window turns that
//! burst back into one decision.
//!
//! ## Why the capturer's own latch is not enough
//!
//! Copies that land in the SAME capture frame collapse against the capturer's boolean latch, but
//! copies STRADDLING a frame boundary re-latch after the drain. On the LTR path — which has no
//! cooldown of its own — that encodes a second forced-refresh P-frame and resets the anchor
//! distance. A 6 ms copy spread straddles the 16.7 ms boundary at 60 fps often enough that dedup
//! here is REQUIRED for LTR, and belt-and-braces for IDR, whose admission policy absorbs duplicates
//! anyway.
//!
//! ## The key is the whole datagram
//!
//! Byte equality on the full payload — type byte and entire body, including the last-decoded frame
//! id the request carries — means zero coupling to the wire layout: the client encodes once per
//! logical request and re-sends the identical bytes, so a future body change is covered for free. A
//! ring rather than a single slot, because interleaved bursts for successive frames carry different
//! bytes and both must dedup. A duplicate does NOT refresh the original's timestamp: a legitimately
//! identical re-request ages back to admissible one window after the FIRST sighting, never starved
//! by its own copies.

use std::cmp::Ordering;

/// The dedup window over recently admitted recovery datagrams.
#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryRequestDeduper {
    /// Duplicates of an admitted payload are dropped for this long after its first sighting.
    window_seconds: f64,
    /// The most payloads remembered at once.
    capacity: usize,
    /// The admitted payloads still inside the window, oldest first.
    entries: Vec<(Vec<u8>, f64)>,
}

impl Default for RecoveryRequestDeduper {
    fn default() -> Self {
        Self::new(Self::DEFAULT_WINDOW_SECONDS, Self::DEFAULT_CAPACITY)
    }
}

impl RecoveryRequestDeduper {
    /// The default window: comfortably above twice the client's copy spread plus reorder skew, and
    /// below every legitimate re-request spacing.
    pub const DEFAULT_WINDOW_SECONDS: f64 = 0.025;

    /// The default ring size.
    pub const DEFAULT_CAPACITY: usize = 16;

    /// A deduper with the given window and ring size. A window of zero — or any value that fails
    /// `> 0`, which includes NaN — is the kill switch: everything is admitted. The capacity is
    /// floored at one.
    #[must_use]
    pub const fn new(window_seconds: f64, capacity: usize) -> Self {
        Self {
            window_seconds,
            capacity: if capacity > 1 { capacity } else { 1 },
            entries: Vec::new(),
        }
    }

    /// Whether the caller should PROCESS this datagram: true on a first sighting inside the window,
    /// false for a duplicate the caller should drop.
    ///
    /// The comparisons are deliberately written as the complements of the obvious ones, so that a
    /// degenerate clock fails toward doing MORE work rather than none. A NaN window fails `> 0` and
    /// admits everything — the kill switch. A NaN `now` makes `now - accepted_at > window` false,
    /// so every entry is KEPT and the duplicate is still caught; a bare `<=` would have expired the
    /// whole ring and admitted every copy.
    pub fn admit(&mut self, datagram: &[u8], now: f64) -> bool {
        if self.window_seconds.partial_cmp(&0.0) != Some(Ordering::Greater) {
            return true;
        }
        self.entries.retain(|(_, accepted_at)| {
            (now - accepted_at).partial_cmp(&self.window_seconds) != Some(Ordering::Greater)
        });
        if self.entries.iter().any(|(payload, _)| payload == datagram) {
            return false;
        }
        if self.entries.len() >= self.capacity {
            let excess = self.entries.len() - self.capacity + 1;
            self.entries.drain(..excess);
        }
        self.entries.push((datagram.to_vec(), now));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::RecoveryRequestDeduper;

    #[test]
    fn a_burst_of_identical_copies_becomes_one_action() {
        let mut deduper = RecoveryRequestDeduper::default();
        assert!(deduper.admit(b"request", 1.000));
        assert!(!deduper.admit(b"request", 1.003));
        assert!(
            !deduper.admit(b"request", 1.006),
            "even across a capture-frame boundary"
        );
    }

    #[test]
    fn a_duplicate_does_not_extend_its_own_window() {
        let mut deduper = RecoveryRequestDeduper::new(0.025, 16);
        assert!(deduper.admit(b"request", 1.000));
        assert!(!deduper.admit(b"request", 1.020), "still inside the window");
        // One window after the FIRST sighting, not after the last copy.
        assert!(
            deduper.admit(b"request", 1.026),
            "a genuine re-request is not starved"
        );
    }

    #[test]
    fn interleaved_bursts_for_different_frames_both_dedup() {
        let mut deduper = RecoveryRequestDeduper::default();
        assert!(deduper.admit(b"frame-10", 1.000));
        assert!(deduper.admit(b"frame-11", 1.001));
        assert!(!deduper.admit(b"frame-10", 1.002));
        assert!(!deduper.admit(b"frame-11", 1.003));
    }

    #[test]
    fn the_ring_is_bounded_and_evicts_the_oldest() {
        let mut deduper = RecoveryRequestDeduper::new(10.0, 2);
        assert!(deduper.admit(b"a", 1.0));
        assert!(deduper.admit(b"b", 1.1));
        assert!(deduper.admit(b"c", 1.2), "evicts `a`");
        assert!(!deduper.admit(b"c", 1.3));
        assert!(
            deduper.admit(b"a", 1.4),
            "`a` was evicted, so it is admissible again"
        );
    }

    #[test]
    fn a_zero_window_admits_everything() {
        let mut deduper = RecoveryRequestDeduper::new(0.0, 16);
        assert!(deduper.admit(b"request", 1.0));
        assert!(deduper.admit(b"request", 1.0), "the kill switch");
    }

    /// A degenerate clock must fail toward catching the duplicate, never toward admitting the
    /// whole burst.
    #[test]
    fn a_degenerate_clock_still_catches_a_duplicate() {
        let mut deduper = RecoveryRequestDeduper::new(f64::NAN, 16);
        assert!(deduper.admit(b"request", 1.0));
        assert!(deduper.admit(b"request", 1.0), "a NaN window is the kill switch");

        let mut sane_window = RecoveryRequestDeduper::default();
        assert!(sane_window.admit(b"request", 1.0));
        assert!(
            !sane_window.admit(b"request", f64::NAN),
            "the ring is kept, so the dup is seen"
        );
    }
}
