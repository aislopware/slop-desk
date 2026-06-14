//! The client's decode frontier — a port of Swift `DecodeFrontier`.
//!
//! Tracks the wrap-aware highest `frame_id` that has SUCCESSFULLY decoded. Every recovery
//! request (`request_idr` / `request_ltr_refresh`) carries [`wire_value`](DecodeFrontier::wire_value)
//! so the host's delivery-keyed `RecoveryIDRPolicy` can tell whether a recently-sent keyframe
//! reached this client (request newer ⇒ delivered) or is a presumed casualty (request older +
//! past the in-flight grace ⇒ bypass the cooldown).
//!
//! Pure value type — no transport, no clock. Monotonic by [`distance_wrapped`](crate::seq::distance_wrapped)
//! (the same sequence-space discipline as the reassembler), so a late out-of-order decode can
//! never move the frontier backwards.

use crate::recovery::RecoveryMessage;
use crate::seq::distance_wrapped;

/// The wrap-aware monotonic maximum of successfully-decoded frame IDs.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DecodeFrontier {
    last_decoded_frame_id: Option<u32>,
}

impl DecodeFrontier {
    /// A fresh frontier with nothing decoded yet.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_decoded_frame_id: None,
        }
    }

    /// The highest frame ID that has decoded so far, or `None` before the first decode.
    #[must_use]
    pub const fn last_decoded_frame_id(self) -> Option<u32> {
        self.last_decoded_frame_id
    }

    /// Folds one successfully-decoded frame. Keep-newest, wrap-aware; older/equal IDs are no-ops.
    pub const fn note_decoded(&mut self, frame_id: u32) {
        if let Some(current) = self.last_decoded_frame_id {
            if distance_wrapped(frame_id, current) <= 0 {
                return;
            }
        }
        self.last_decoded_frame_id = Some(frame_id);
    }

    /// The on-wire field value: the frontier ID, or
    /// [`RecoveryMessage::NO_FRAME_DECODED_SENTINEL`] when nothing has decoded yet (frame IDs
    /// start at 0, so 0 can never be the sentinel).
    #[must_use]
    pub fn wire_value(self) -> u32 {
        self.last_decoded_frame_id
            .unwrap_or(RecoveryMessage::NO_FRAME_DECODED_SENTINEL)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_frontier_encodes_sentinel() {
        let frontier = DecodeFrontier::new();
        assert_eq!(frontier.last_decoded_frame_id(), None);
        assert_eq!(
            frontier.wire_value(),
            RecoveryMessage::NO_FRAME_DECODED_SENTINEL
        );
    }

    #[test]
    fn monotonic_keep_newest() {
        let mut frontier = DecodeFrontier::new();
        frontier.note_decoded(0); // frame ID 0 is REAL (ids start at 0)
        assert_eq!(frontier.wire_value(), 0);
        frontier.note_decoded(5);
        assert_eq!(frontier.wire_value(), 5);
        frontier.note_decoded(3); // late out-of-order decode — never regresses
        assert_eq!(frontier.wire_value(), 5);
        frontier.note_decoded(5); // duplicate — no-op
        assert_eq!(frontier.wire_value(), 5);
    }

    #[test]
    fn wrap_aware_advance() {
        let mut frontier = DecodeFrontier::new();
        frontier.note_decoded(u32::MAX - 1);
        frontier.note_decoded(2); // wrapped past u32::MAX — still "newer"
        assert_eq!(frontier.wire_value(), 2);
        frontier.note_decoded(u32::MAX); // pre-wrap id arriving late — older, ignored
        assert_eq!(frontier.wire_value(), 2);
    }
}
