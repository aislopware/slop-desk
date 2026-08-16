//! The swipe-nav status push — `Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift`.
//!
//! Type 3 on the cursor side-channel: whether the HOST's ⌘[/⌘] swipe translation would currently
//! accept a gesture, plus the recogniser knobs the client's peel-feedback mirror must match. The
//! client runs its own recogniser purely for VISUAL feedback (doc 05 §8), and feedback tuned to
//! different thresholds would promise fires that never come.
//!
//! It rides the cursor socket because that is the existing low-rate host→client UI-state channel.
//! Loss tolerance is fire-and-forget: the host re-sends on every frontmost-app change and on a slow
//! heartbeat, so a lost datagram self-heals within seconds, and the client defaults to NOT eligible
//! until the first status arrives. An old host therefore never shows the overlay, and the
//! affordance can never lie about an app where ⌘[ would EDIT TEXT.
//!
//! ```text
//! off 0: u8   type (= 3)
//! off 1: u8   eligible    (0/1)
//! off 2: u8   slow_tier   (0/1 — the host's SLOPDESK_SWIPE_NAV_SLOW operating point)
//! off 3: u16  fire_travel (points — the host's clamped SLOPDESK_SWIPE_NAV_TRAVEL)
//! off 5: u8   nav flags   (bit0 can_go_back, bit1 can_go_forward, bit2 history_known)
//! ```
//!
//! Six bytes, pinned by the `swipeNavStatus` golden vectors.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, VideoProtocolError};

/// Which way a swipe would navigate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwipeDirection {
    /// Fingers moved RIGHT — natural scrolling reveals the page to the LEFT — so history BACK,
    /// matching the local trackpad convention.
    Back,
    /// Fingers moved left → history forward.
    Forward,
}

/// The host's swipe-nav eligibility, as pushed to the client.
#[expect(
    clippy::struct_excessive_bools,
    reason = "the wire message IS five flags and one integer; collapsing them into a bitfield would hide \
              the layout the golden vector pins and buy nothing — the bits are already packed on the wire, \
              this is the decoded form"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SwipeNavStatusMessage {
    /// Whether a qualifying swipe would currently be translated into ⌘[/⌘] on the host.
    pub eligible: bool,
    /// Whether the host's slow tier is on (mirrors `SLOPDESK_SWIPE_NAV_SLOW`).
    pub slow_tier: bool,
    /// The host's lift-fire travel threshold in points, already clamped to `[20, 500]`.
    pub fire_travel: u16,
    /// The target app's ⌘[ would navigate right now. Meaningless unless `history_known`.
    pub can_go_back: bool,
    /// The target app's ⌘] would navigate right now. Meaningless unless `history_known`.
    pub can_go_forward: bool,
    /// The host actually READ the history state this push. `false` ⇒ the read failed or is disabled
    /// and the client must FAIL OPEN — treat both directions as navigable, never dark.
    pub history_known: bool,
}

impl SwipeNavStatusMessage {
    /// The on-wire message type byte, distinct from the cursor update (1) and shape (2).
    pub const MESSAGE_TYPE: u8 = 3;
    /// Encoded size in bytes — fixed.
    pub const ENCODED_SIZE: usize = 6;

    const CAN_GO_BACK_BIT: u8 = 1 << 0;
    const CAN_GO_FORWARD_BIT: u8 = 1 << 1;
    const HISTORY_KNOWN_BIT: u8 = 1 << 2;

    /// Builds a status message.
    #[must_use]
    #[expect(
        clippy::fn_params_excessive_bools,
        reason = "a plain constructor for a five-flag wire message; the field names at each call site are \
                  what keeps it readable, and a builder would be ceremony for one struct"
    )]
    pub const fn new(
        eligible: bool,
        slow_tier: bool,
        fire_travel: u16,
        can_go_back: bool,
        can_go_forward: bool,
        history_known: bool,
    ) -> Self {
        Self {
            eligible,
            slow_tier,
            fire_travel,
            can_go_back,
            can_go_forward,
            history_known,
        }
    }

    /// Whether the chip may show for a swipe in `direction`.
    ///
    /// Known-dead history suppresses the affordance; UNKNOWN history fails open. The HOST's fire
    /// path deliberately does not apply this — ⌘[/⌘] into an app that cannot navigate is a
    /// validated-menu no-op, so a stale-disabled read can only ever cost feedback, never a
    /// navigation (see `docs/DECISIONS.md`, the history gate).
    #[must_use]
    pub const fn allows_chip(&self, direction: SwipeDirection) -> bool {
        if !self.history_known {
            return true;
        }
        match direction {
            SwipeDirection::Back => self.can_go_back,
            SwipeDirection::Forward => self.can_go_forward,
        }
    }

    /// Encodes the fixed 6-byte big-endian message.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(Self::ENCODED_SIZE);
        out.put_u8(Self::MESSAGE_TYPE);
        out.put_u8(u8::from(self.eligible));
        out.put_u8(u8::from(self.slow_tier));
        out.put_u16(self.fire_travel);
        let mut flags = 0;
        if self.can_go_back {
            flags |= Self::CAN_GO_BACK_BIT;
        }
        if self.can_go_forward {
            flags |= Self::CAN_GO_FORWARD_BIT;
        }
        if self.history_known {
            flags |= Self::HISTORY_KNOWN_BIT;
        }
        out.put_u8(flags);
        out.into_vec()
    }

    /// Decodes a status message.
    ///
    /// # Errors
    /// [`VideoProtocolError::Truncated`] for a short datagram, [`VideoProtocolError::Malformed`]
    /// for the wrong type byte. Either way the caller DROPS it, never fatal.
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(data);
        let kind = reader.read_u8()?;
        if kind != Self::MESSAGE_TYPE {
            return Err(VideoProtocolError::malformed(format!(
                "not a swipe-nav status (type {kind})"
            )));
        }
        let eligible = reader.read_u8()? != 0;
        let slow_tier = reader.read_u8()? != 0;
        let fire_travel = reader.read_u16()?;
        let flags = reader.read_u8()?;
        Ok(Self::new(
            eligible,
            slow_tier,
            fire_travel,
            flags & Self::CAN_GO_BACK_BIT != 0,
            flags & Self::CAN_GO_FORWARD_BIT != 0,
            flags & Self::HISTORY_KNOWN_BIT != 0,
        ))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{SwipeDirection, SwipeNavStatusMessage};
    use crate::error::VideoProtocolError;

    #[test]
    fn every_flag_combination_round_trips_in_six_bytes() {
        for bits in 0_u8..8 {
            let status = SwipeNavStatusMessage::new(
                bits & 1 != 0,
                bits & 2 != 0,
                80,
                bits & 1 != 0,
                bits & 2 != 0,
                bits & 4 != 0,
            );
            let bytes = status.encode();
            assert_eq!(bytes.len(), SwipeNavStatusMessage::ENCODED_SIZE);
            assert_eq!(SwipeNavStatusMessage::decode(&bytes), Ok(status));
        }
    }

    #[test]
    fn unknown_history_fails_open_in_both_directions() {
        let unknown = SwipeNavStatusMessage::new(true, false, 80, false, false, false);
        assert!(unknown.allows_chip(SwipeDirection::Back));
        assert!(unknown.allows_chip(SwipeDirection::Forward));
    }

    #[test]
    fn known_history_suppresses_only_the_dead_direction() {
        let known = SwipeNavStatusMessage::new(true, false, 80, true, false, true);
        assert!(known.allows_chip(SwipeDirection::Back));
        assert!(!known.allows_chip(SwipeDirection::Forward));
    }

    #[test]
    fn the_wrong_type_byte_and_a_short_datagram_fail_distinctly() {
        assert!(matches!(
            SwipeNavStatusMessage::decode(&[1, 0, 0, 0, 0, 0]),
            Err(VideoProtocolError::Malformed(_))
        ));
        assert_eq!(
            SwipeNavStatusMessage::decode(&[3, 1]),
            Err(VideoProtocolError::Truncated)
        );
    }

    #[test]
    fn reserved_flag_bits_are_ignored_rather_than_rejected() {
        // Forward compatibility: a future sender setting bits 3-7 must not blank an old client.
        let bytes = [3, 1, 1, 0, 80, 0xFF];
        let decoded = SwipeNavStatusMessage::decode(&bytes).expect("high bits are reserved, not fatal");
        assert!(decoded.can_go_back && decoded.can_go_forward && decoded.history_known);
    }
}
