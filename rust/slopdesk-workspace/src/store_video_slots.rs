//! How many desktop streams a client is allowed to decode at once, and who is holding a slot.
//!
//! The client caps concurrent LIVE video (docs/22 §7): each video pane owns its own
//! `VTDecompressionSession`, display link and Metal renderer, and the cap bounds the decode +
//! composite cost that no amount of muxing on the UDP side makes cheaper. The store used to keep
//! that ledger as three stored properties and spell the admission arithmetic at the one place that
//! asked, with the accounting for a pane whose stack is still *releasing* written out at three
//! more.
//!
//! ## Why this is a LEDGER rather than a fold
//!
//! The other store rules are pure: hand them a column of facts and they answer. This one is state
//! AND the decisions over it — the cap, who is live, who is still letting go, and a promotion
//! counter that only moves on the transitions that actually FREE something. It lives as long as the
//! store does and four call sites mutate it. `docs/55` §4b calls that a handle, and the shim wraps
//! it as one.
//!
//! ## Nothing here knows a pane
//!
//! A pane is a UUID the caller owns. What crosses is a dense [`SlotToken`] the near side mints, so
//! the ledger's only claim about a token is that two equal tokens are the same pane. That is the
//! whole of what the arithmetic needs: the admission test excludes the ASKING token from the live
//! count, which is what lets an already-live pane see its own slot as free.
//!
//! ## The two halves of "is it live"
//!
//! The ledger is never the one that flips a pane's video on. The caller sets the pane live, reads
//! back whether it took, and reports the READING — [`VideoSlots::note_live`]. The same door serves
//! the iOS pause/resume fan-out, which flips the same flag behind the store's back. A ledger that
//! assumed the activation took would over-count a refusal it never saw.
//!
//! ## What the generation is for, and why it is guarded
//!
//! Admission is VIEW-driven: only an on-screen pane decodes, so when a slot frees nothing promotes
//! a pane that is sitting gated. [`VideoSlots::generation`] is the monotone nudge those panes
//! watch, and it moves on exactly the slot-FREEING transitions — a live pane standing down, a live
//! pane's close, and the moment that close's stack actually releases. A no-op stand-down freed
//! nothing, so it must not churn the surface; that guard is the reason the counter is here rather
//! than being "one bump per call".

/// One pane's place in the ledger, as the near side mints it.
///
/// Dense and stable for the life of the store: the caller keeps the UUID, this side keeps a number.
/// The ledger reads nothing into it but equality.
pub type SlotToken = u32;

/// What an admission request is answered with.
///
/// Three cases rather than a bool because the caller does something different in each, and deciding
/// WHICH of the three is the part that used to be a ladder of `guard`s in the store.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admission {
    /// No slot, or not a video pane at all. The caller shows the gated placeholder and does not
    /// touch the pane.
    Refuse,
    /// Already decoding. The caller reports success without re-activating anything — an idempotent
    /// re-request from a re-appearing view is the common case, not an error.
    AlreadyLive,
    /// A slot is free. The caller may set the pane live, and must report back what the pane
    /// actually did through [`VideoSlots::note_live`].
    Proceed,
}

/// The concurrent-live-video ledger: the cap, who holds a slot, and the promotion nudge.
#[derive(Clone, Debug)]
pub struct VideoSlots {
    /// The ceiling. Zero admits nothing, which is a real configuration (a terminal-only client).
    cap: usize,
    /// Every token that is decoding right now.
    live: Vec<SlotToken>,
    /// Every token whose pane is GONE but whose decode stack has not finished letting go. It still
    /// owns the hardware, so it still counts.
    releasing: Vec<SlotToken>,
    /// The monotone promotion nudge. Wrapping, because it is a change signal and not a quantity.
    generation: i64,
}

/// Adds `token` if it is not already present, keeping insertion order.
fn insert(set: &mut Vec<SlotToken>, token: SlotToken) {
    if !set.contains(&token) {
        set.push(token);
    }
}

/// Drops `token`, answering whether it was there. The answer is the whole point at two call sites:
/// a removal that removed nothing freed nothing.
fn remove(set: &mut Vec<SlotToken>, token: SlotToken) -> bool {
    let before = set.len();
    set.retain(|held| *held != token);
    set.len() != before
}

impl VideoSlots {
    /// An empty ledger with a ceiling of `cap` concurrent live panes.
    #[must_use]
    pub const fn new(cap: usize) -> Self {
        Self {
            cap,
            live: Vec::new(),
            releasing: Vec::new(),
            generation: 0,
        }
    }

    /// The ceiling this ledger was built with.
    #[must_use]
    pub const fn cap(&self) -> usize {
        self.cap
    }

    /// Whether a slot is free FOR `token` right now — the pure read, with no mutation.
    ///
    /// Two things make this the same arithmetic an admission would do rather than a lookalike:
    ///
    /// - It EXCLUDES `token` from the live count. An already-decoding pane asking whether it may
    ///   decode is asking about the slot it is standing in, and counting itself would make the
    ///   answer flip the moment it succeeded.
    /// - It COUNTS the releasing set. A pane that closed this same tick is already gone from the
    ///   caller's registry, but its UDP flow, decoder and display link are not released until its
    ///   teardown completes; admitting a sibling before then would put two live stacks up at once.
    ///   A releasing token can never equal a live pane's token, so the set needs no self-exclusion.
    #[must_use]
    pub fn admits(&self, token: SlotToken) -> bool {
        let others = self.live.iter().filter(|held| **held != token).count();
        others + self.releasing.len() < self.cap
    }

    /// The verdict on a request to make `token` live.
    ///
    /// `is_video` and `already_live` are READINGS the caller took off the pane it holds, not
    /// questions this side could answer: whether a pane decodes video and whether it is decoding
    /// now are facts about a live object the ledger has never seen.
    #[must_use]
    pub fn admit(&self, token: SlotToken, is_video: bool, already_live: bool) -> Admission {
        if !is_video {
            return Admission::Refuse;
        }
        if already_live {
            return Admission::AlreadyLive;
        }
        if self.admits(token) {
            Admission::Proceed
        } else {
            Admission::Refuse
        }
    }

    /// Records what `token`'s pane ACTUALLY is after something flipped it — the confirm-read after
    /// an activation, and the resync after an iOS pause or resume flipped the flag directly.
    ///
    /// Idempotent in both directions, and deliberately silent: a pane going live consumes a slot
    /// rather than freeing one, and a pause is a fan-out over every pane at once, so neither is a
    /// promotion edge for the panes that are sitting gated.
    pub fn note_live(&mut self, token: SlotToken, live: bool) {
        if live {
            insert(&mut self.live, token);
        } else {
            remove(&mut self.live, token);
        }
    }

    /// `token`'s pane stops decoding while staying open (the view left the screen), answering the
    /// generation to publish.
    ///
    /// `was_live` is the caller's reading from BEFORE it stood the pane down, and it is what guards
    /// the nudge: an already-idle, unknown or non-video pane freed nothing, and bumping there would
    /// make every gated sibling re-attempt admission for a slot that never opened.
    pub fn stand_down(&mut self, token: SlotToken, was_live: bool) -> i64 {
        remove(&mut self.live, token);
        if was_live {
            self.bump();
        }
        self.generation
    }

    /// `token`'s pane CLOSED, answering the generation to publish.
    ///
    /// The pane leaves the live set either way — it is gone. `holds_stack` is the caller's reading,
    /// taken before teardown nils it, of whether it was a video pane that was actually decoding; a
    /// pane that was, keeps its slot booked under [`releasing`](Self::is_releasing) until the
    /// hardware is really let go.
    ///
    /// The nudge fires HERE, at the close, even though the slot is still counted. That is
    /// deliberate: a gated on-screen sibling re-attempts, is refused because the releasing set
    /// still counts, and parks — and the second nudge at [`release`](Self::release) is what
    /// promotes it the instant the slot truly opens. Nudging only at release would leave a pane
    /// that closed with no settle at all indistinguishable from one that never closed.
    pub fn orphan(&mut self, token: SlotToken, holds_stack: bool) -> i64 {
        remove(&mut self.live, token);
        if holds_stack {
            insert(&mut self.releasing, token);
            self.bump();
        }
        self.generation
    }

    /// Whether `token`'s decode stack is still letting go — the guard on the caller's settle sleep,
    /// so a pane that never held a stack is never slept for.
    #[must_use]
    pub fn is_releasing(&self, token: SlotToken) -> bool {
        self.releasing.contains(&token)
    }

    /// `token`'s decode stack is released, answering the generation to publish.
    ///
    /// Bumps only when the token was actually booked. A second release for the same token — a
    /// retried teardown, or a drain that ran after [`clear_releasing`](Self::clear_releasing) —
    /// freed nothing and must not churn the surface.
    pub fn release(&mut self, token: SlotToken) -> i64 {
        if remove(&mut self.releasing, token) {
            self.bump();
        }
        self.generation
    }

    /// Forgets every releasing token, for a caller that has drained every teardown it spawned.
    ///
    /// The backstop for a dropped release: once no teardown is in flight, nothing can still be
    /// letting go, so a token left booked here is a phantom holding a slot against the cap forever.
    /// Silent — this is a repair, and the state it repairs to is the one the drained caller already
    /// believes it is in.
    pub fn clear_releasing(&mut self) {
        self.releasing.clear();
    }

    /// The promotion nudge as it stands.
    #[must_use]
    pub const fn generation(&self) -> i64 {
        self.generation
    }

    /// How many panes are decoding right now.
    #[must_use]
    pub const fn live_count(&self) -> usize {
        self.live.len()
    }

    /// How many closed panes are still holding hardware.
    #[must_use]
    pub const fn releasing_count(&self) -> usize {
        self.releasing.len()
    }

    /// Moves the nudge. Wrapping: it is compared for CHANGE, never for size, and the caller's
    /// counter wraps on the same arithmetic.
    const fn bump(&mut self) {
        self.generation = self.generation.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::{Admission, VideoSlots};

    /// A ledger at a ceiling of two, with `count` panes already decoding.
    fn filled(cap: usize, count: u32) -> VideoSlots {
        let mut slots = VideoSlots::new(cap);
        for token in 0..count {
            slots.note_live(token, true);
        }
        slots
    }

    /// The plain case: the cap admits up to its ceiling and then stops.
    #[test]
    fn the_ceiling_holds() {
        let slots = filled(2, 2);
        assert!(!slots.admits(9));
        assert!(filled(2, 1).admits(9));
        assert!(!filled(0, 0).admits(9));
    }

    /// An already-decoding pane sees its OWN slot as free — it is asking about the one it stands
    /// in.
    #[test]
    fn the_asking_token_excludes_itself() {
        let slots = filled(2, 2);
        assert!(slots.admits(0), "token 0 is one of the two live panes");
        assert!(slots.admits(1));
        assert!(!slots.admits(2), "a third pane sees a saturated cap");
    }

    /// A closed pane still letting go of its stack keeps counting against the ceiling.
    #[test]
    fn a_releasing_stack_still_occupies_its_slot() {
        let mut slots = filled(2, 1);
        assert!(slots.admits(9));
        slots.orphan(5, true);
        assert!(
            !slots.admits(9),
            "one live plus one releasing saturates a cap of two"
        );
        slots.release(5);
        assert!(slots.admits(9));
    }

    /// The three verdicts, each from the reading that produces it.
    #[test]
    fn the_verdicts_read_off_the_callers_facts() {
        let slots = filled(2, 2);
        assert_eq!(
            slots.admit(9, false, false),
            Admission::Refuse,
            "not a video pane"
        );
        assert_eq!(slots.admit(9, true, true), Admission::AlreadyLive);
        assert_eq!(slots.admit(9, true, false), Admission::Refuse, "saturated");
        assert_eq!(filled(2, 1).admit(9, true, false), Admission::Proceed);
    }

    /// A refused activation the caller reported honestly does not book a slot.
    #[test]
    fn a_refused_activation_books_nothing() {
        let mut slots = VideoSlots::new(2);
        assert_eq!(slots.admit(1, true, false), Admission::Proceed);
        slots.note_live(1, false);
        assert_eq!(slots.live_count(), 0);
        assert_eq!(slots.generation(), 0, "an activation is not a promotion edge");
    }

    /// Standing a LIVE pane down nudges exactly once; standing an idle one down nudges never.
    #[test]
    fn the_nudge_is_guarded_to_a_slot_that_actually_freed() {
        let mut slots = filled(2, 2);
        assert_eq!(slots.stand_down(0, true), 1);
        assert_eq!(slots.stand_down(0, false), 1, "a repeat freed nothing");
        assert_eq!(slots.stand_down(7, false), 1, "an unknown pane freed nothing");
        assert_eq!(slots.live_count(), 1);
    }

    /// Closing a live video pane nudges at the close AND again at the real release.
    #[test]
    fn a_closed_video_pane_nudges_twice() {
        let mut slots = filled(2, 2);
        assert_eq!(slots.orphan(0, true), 1, "the close-time nudge");
        assert!(slots.is_releasing(0));
        assert_eq!(slots.release(0), 2, "the completion-site nudge");
        assert!(!slots.is_releasing(0));
        assert_eq!(slots.release(0), 2, "a second release freed nothing");
    }

    /// Closing a pane that was NOT decoding leaves the ledger and the nudge alone.
    #[test]
    fn a_closed_idle_pane_nudges_never() {
        let mut slots = filled(2, 1);
        assert_eq!(slots.orphan(3, false), 0);
        assert!(!slots.is_releasing(3));
        assert_eq!(slots.live_count(), 1);
    }

    /// A closing pane leaves the live set whether or not it was holding a stack.
    #[test]
    fn a_closed_pane_always_leaves_the_live_set() {
        let mut slots = filled(2, 2);
        slots.orphan(1, false);
        assert_eq!(slots.live_count(), 1);
        assert_eq!(slots.releasing_count(), 0);
    }

    /// The drain repair empties the releasing set without pretending a slot just freed.
    #[test]
    fn the_drain_repair_is_silent() {
        let mut slots = VideoSlots::new(2);
        slots.orphan(0, true);
        slots.orphan(1, true);
        let after_closes = slots.generation();
        slots.clear_releasing();
        assert_eq!(slots.releasing_count(), 0);
        assert_eq!(slots.generation(), after_closes);
        assert!(slots.admits(9));
    }

    /// The pause/resume resync is idempotent in both directions.
    #[test]
    fn the_resync_is_idempotent() {
        let mut slots = VideoSlots::new(2);
        slots.note_live(4, true);
        slots.note_live(4, true);
        assert_eq!(slots.live_count(), 1);
        slots.note_live(4, false);
        slots.note_live(4, false);
        assert_eq!(slots.live_count(), 0);
        assert_eq!(slots.generation(), 0);
    }
}
