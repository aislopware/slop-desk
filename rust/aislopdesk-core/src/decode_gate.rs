//! Pre-emptive drop-until-anchor decode admission — a port of Swift `DecodeGate`.
//!
//! A delta that (transitively) references an unrecoverably-lost frame cannot decode — `VideoToolbox`
//! throws -12909 and tears the decompression session down, which wipes the decoder's reference
//! state and forces a full reconfigure. Once the reference chain is known-broken
//! ([`note_loss`](DecodeGate::note_loss)) deltas stop reaching the decoder; only ANCHOR
//! CANDIDATES are admitted:
//!  - a keyframe (references nothing), or
//!  - an acked-anchored frame (a `ForceLTRRefresh` product, forced against an LTR this client
//!    provably decoded before the loss), or
//!  - a delta OLDER than the oldest loss of the episode (its references predate the break).
//!
//! Two broken modes differ in their anchor set: [`Mode::BrokenChain`] (session alive → keyframe
//! OR acked-LTR) and [`Mode::NeedKeyframe`] (session torn down / never configured → keyframe
//! only). Pure value type — wrap-aware ([`distance_wrapped`](crate::seq::distance_wrapped)), no
//! clock, no transport.

use crate::seq::distance_wrapped;

/// The gate's admission mode.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Mode {
    /// Chain intact — everything submits.
    #[default]
    Open,
    /// ≥1 unrecoverable loss since the last anchor; the decoder session is still alive.
    BrokenChain,
    /// The decoder session is invalid (hard failure / never configured) — keyframe only.
    NeedKeyframe,
}

/// The admission decision for one reassembled frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// Feed this frame to the decoder.
    Submit,
    /// Drop this frame (would fail to decode and tear the session down).
    Drop,
}

/// Drop-until-anchor gate tracking the loss episode in wrap-aware sequence space.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DecodeGate {
    mode: Mode,
    min_lost_frame_id: Option<u32>,
    max_lost_frame_id: Option<u32>,
}

impl DecodeGate {
    /// A fresh, open gate.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            mode: Mode::Open,
            min_lost_frame_id: None,
            max_lost_frame_id: None,
        }
    }

    /// The current admission mode.
    #[must_use]
    pub const fn mode(&self) -> Mode {
        self.mode
    }

    /// OLDEST lost frame id of the episode (the chain is intact strictly before it).
    #[must_use]
    pub const fn min_lost_frame_id(&self) -> Option<u32> {
        self.min_lost_frame_id
    }

    /// NEWEST lost frame id of the episode (an anchor must decode strictly past it).
    #[must_use]
    pub const fn max_lost_frame_id(&self) -> Option<u32> {
        self.max_lost_frame_id
    }

    /// One unrecoverably-lost frame. Opens the episode; [`Mode::NeedKeyframe`] is strictly
    /// stronger and is never downgraded by a mere loss.
    pub fn note_loss(&mut self, frame_id: u32) {
        if self.mode == Mode::Open {
            self.mode = Mode::BrokenChain;
        }
        match self.max_lost_frame_id {
            Some(mx) if distance_wrapped(frame_id, mx) > 0 => {
                self.max_lost_frame_id = Some(frame_id);
            }
            None => self.max_lost_frame_id = Some(frame_id),
            _ => {}
        }
        match self.min_lost_frame_id {
            Some(mn) if distance_wrapped(frame_id, mn) < 0 => {
                self.min_lost_frame_id = Some(frame_id);
            }
            None => self.min_lost_frame_id = Some(frame_id),
            _ => {}
        }
    }

    /// A hard decode failure tore the session down — only an IDR helps now.
    pub const fn note_hard_decode_failure(&mut self) {
        self.mode = Mode::NeedKeyframe;
    }

    /// The decoder reported `awaiting_keyframe` (no session / parameter sets yet) — same anchor set.
    pub const fn note_awaiting_keyframe(&mut self) {
        self.mode = Mode::NeedKeyframe;
    }

    /// Admission decision for one reassembled frame. Pure — never mutates.
    #[must_use]
    pub const fn verdict(&self, frame_id: u32, keyframe: bool, acked_anchored: bool) -> Verdict {
        match self.mode {
            Mode::Open => Verdict::Submit,
            Mode::NeedKeyframe => {
                if keyframe {
                    Verdict::Submit
                } else {
                    Verdict::Drop
                }
            }
            Mode::BrokenChain => {
                if keyframe || acked_anchored {
                    return Verdict::Submit;
                }
                // Pre-break delta still in flight: references predate the OLDEST loss.
                if let Some(mn) = self.min_lost_frame_id {
                    if distance_wrapped(frame_id, mn) < 0 {
                        return Verdict::Submit;
                    }
                }
                Verdict::Drop
            }
        }
    }

    /// Folds one SUCCESSFUL decode. A keyframe re-opens the gate unless a loss NEWER than it is
    /// already on record. A non-keyframe success newer than every loss is the healed LTR anchor.
    pub fn note_decode_succeeded(&mut self, frame_id: u32, keyframe: bool) {
        if keyframe {
            if let Some(mx) = self.max_lost_frame_id {
                if distance_wrapped(frame_id, mx) <= 0 {
                    // The keyframe predates the newest loss: it re-anchored up to itself, but losses
                    // past it remain. Downgrade to BrokenChain (which then admits an acked-LTR
                    // refresh) ONLY if the session was still ALIVE. If it had been torn down
                    // (NeedKeyframe wiped the DPB), a stale keyframe rebuilds it empty — no
                    // pre-teardown acked LTR survives, so stay NeedKeyframe.
                    if self.mode != Mode::NeedKeyframe {
                        self.mode = Mode::BrokenChain;
                    }
                    return;
                }
            }
            self.reset();
            return;
        }
        if self.mode == Mode::BrokenChain {
            if let Some(mx) = self.max_lost_frame_id {
                if distance_wrapped(frame_id, mx) > 0 {
                    self.reset();
                }
            }
        }
    }

    const fn reset(&mut self) {
        self.mode = Mode::Open;
        self.min_lost_frame_id = None;
        self.max_lost_frame_id = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_submits_everything() {
        let g = DecodeGate::new();
        assert_eq!(g.mode(), Mode::Open);
        assert_eq!(g.verdict(10, false, false), Verdict::Submit);
        assert_eq!(g.verdict(11, true, false), Verdict::Submit);
        assert_eq!(g.verdict(12, false, true), Verdict::Submit);
    }

    #[test]
    fn loss_drops_newer_deltas_but_not_anchors() {
        let mut g = DecodeGate::new();
        g.note_loss(100);
        assert_eq!(g.mode(), Mode::BrokenChain);
        assert_eq!(g.verdict(101, false, false), Verdict::Drop);
        assert_eq!(g.verdict(150, false, false), Verdict::Drop);
        assert_eq!(g.verdict(100, false, false), Verdict::Drop);
        assert_eq!(g.verdict(102, true, false), Verdict::Submit);
        assert_eq!(g.verdict(103, false, true), Verdict::Submit);
        assert_eq!(g.verdict(99, false, false), Verdict::Submit);
    }

    #[test]
    fn two_losses_drop_delta_between_them() {
        let mut g = DecodeGate::new();
        g.note_loss(200);
        g.note_loss(210);
        assert_eq!(g.verdict(205, false, false), Verdict::Drop);
        assert_eq!(g.verdict(199, false, false), Verdict::Submit);
        assert_eq!(g.min_lost_frame_id(), Some(200));
        assert_eq!(g.max_lost_frame_id(), Some(210));
    }

    #[test]
    fn loss_order_irrelevant_for_min_max() {
        let mut g = DecodeGate::new();
        g.note_loss(210);
        g.note_loss(200);
        assert_eq!(g.min_lost_frame_id(), Some(200));
        assert_eq!(g.max_lost_frame_id(), Some(210));
    }

    #[test]
    fn acked_anchor_newer_than_every_loss_reopens() {
        let mut g = DecodeGate::new();
        g.note_loss(100);
        g.note_loss(104);
        g.note_decode_succeeded(106, false);
        assert_eq!(g.mode(), Mode::Open);
        assert_eq!(g.verdict(107, false, false), Verdict::Submit);
    }

    #[test]
    fn anchor_older_than_newest_loss_does_not_reopen() {
        let mut g = DecodeGate::new();
        g.note_loss(100);
        g.note_loss(110);
        g.note_decode_succeeded(105, false);
        assert_eq!(g.mode(), Mode::BrokenChain);
        assert_eq!(g.verdict(111, false, false), Verdict::Drop);
    }

    #[test]
    fn keyframe_newer_than_losses_reopens() {
        let mut g = DecodeGate::new();
        g.note_loss(100);
        g.note_decode_succeeded(101, true);
        assert_eq!(g.mode(), Mode::Open);
        assert_eq!(g.min_lost_frame_id(), None);
        assert_eq!(g.max_lost_frame_id(), None);
    }

    #[test]
    fn stale_keyframe_downgrades_to_broken_chain_only_when_session_was_alive() {
        // CASE 1 — session alive: downgrade to BrokenChain, acked-LTR refresh still admissible.
        let mut alive = DecodeGate::new();
        alive.note_loss(100);
        assert_eq!(alive.mode(), Mode::BrokenChain);
        alive.note_decode_succeeded(90, true);
        assert_eq!(alive.mode(), Mode::BrokenChain);
        assert_eq!(alive.verdict(101, false, false), Verdict::Drop);
        assert_eq!(alive.verdict(102, false, true), Verdict::Submit);

        // CASE 2 — session torn down: stay NeedKeyframe, acked-LTR refresh must NOT be admitted.
        let mut dead = DecodeGate::new();
        dead.note_loss(100);
        dead.note_hard_decode_failure();
        assert_eq!(dead.mode(), Mode::NeedKeyframe);
        dead.note_decode_succeeded(90, true);
        assert_eq!(dead.mode(), Mode::NeedKeyframe);
        assert_eq!(dead.verdict(101, false, false), Verdict::Drop);
        assert_eq!(dead.verdict(102, false, true), Verdict::Drop);
        dead.note_decode_succeeded(101, true);
        assert_eq!(dead.mode(), Mode::Open);
    }

    #[test]
    fn hard_failure_accepts_only_keyframes() {
        let mut g = DecodeGate::new();
        g.note_loss(50);
        g.note_hard_decode_failure();
        assert_eq!(g.mode(), Mode::NeedKeyframe);
        assert_eq!(g.verdict(60, false, true), Verdict::Drop);
        assert_eq!(g.verdict(49, false, false), Verdict::Drop);
        assert_eq!(g.verdict(61, true, false), Verdict::Submit);
        g.note_decode_succeeded(61, true);
        assert_eq!(g.mode(), Mode::Open);
    }

    #[test]
    fn awaiting_keyframe_gates_pre_idr_deltas() {
        let mut g = DecodeGate::new();
        g.note_awaiting_keyframe();
        assert_eq!(g.mode(), Mode::NeedKeyframe);
        assert_eq!(g.verdict(1, false, false), Verdict::Drop);
        assert_eq!(g.verdict(2, true, false), Verdict::Submit);
    }

    #[test]
    fn loss_while_need_keyframe_stays_need_keyframe() {
        let mut g = DecodeGate::new();
        g.note_hard_decode_failure();
        g.note_loss(300);
        assert_eq!(g.mode(), Mode::NeedKeyframe);
        assert_eq!(g.verdict(301, false, true), Verdict::Drop);
        g.note_decode_succeeded(301, true);
        assert_eq!(g.mode(), Mode::Open);
    }

    #[test]
    fn wrap_aware_loss_and_healing() {
        let mut g = DecodeGate::new();
        let near_wrap = u32::MAX - 1;
        g.note_loss(near_wrap);
        assert_eq!(g.verdict(2, false, false), Verdict::Drop);
        assert_eq!(g.verdict(near_wrap - 1, false, false), Verdict::Submit);
        g.note_decode_succeeded(3, false);
        assert_eq!(g.mode(), Mode::Open);
    }

    #[test]
    fn non_keyframe_success_while_open_is_no_op() {
        let mut g = DecodeGate::new();
        g.note_decode_succeeded(7, false);
        assert_eq!(g.mode(), Mode::Open);
        assert_eq!(g.max_lost_frame_id(), None);
    }
}
