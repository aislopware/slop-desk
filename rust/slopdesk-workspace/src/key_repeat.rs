//! Holding a key down, on a platform that only tells you it went down once.
//!
//! `UIKit` fires `pressesBegan` and `pressesEnded` EXACTLY ONCE per physical key. There is no
//! auto-repeat the way macOS's `keyDown` has one, so holding an arrow or Delete on an iPad's
//! hardware keyboard does nothing past the first event unless the embedder re-emits the key itself.
//! This module is the decision half of that re-emission: which key is latched, whether an event
//! starts, continues or ends a repeat, and how long the next wait is.
//!
//! The other half — arming an actual timer — is NOT here and cannot be. A `DispatchSourceTimer` is
//! the platform's, the fire has to hop to the main actor, and the payload that gets re-emitted is a
//! typed value that has no C spelling. So the caller keeps the clock and the payload; this keeps
//! the state machine, and every question with an answer that could be WRONG is on this side.
//!
//! ## The cadence, and why it is two numbers rather than one
//!
//! Fire immediately, wait [`DEFAULT_INITIAL_DELAY_MS`], then repeat every
//! [`DEFAULT_REPEAT_INTERVAL_MS`]. The first wait is long because a tap is not a hold — without it
//! every single keypress would emit twice within a frame or two. The second is short because once
//! somebody is holding a key they are asking for a rate, and 20 Hz is what `SwiftTerm` and Blink
//! settled on. Both are overridable, and the reason is a test rather than a preference: an
//! integration test against a REAL timer needs a cadence it can cross twice in under a second.
//!
//! ## Identity is the caller's, and the caller's alone
//!
//! What makes two key events "the same key" is not decidable here — it is a property of whatever
//! the caller is repeating. So a key crosses as an opaque IDENTITY: a byte string the caller mints,
//! compared byte for byte and never interpreted. Two events with equal identity bytes are one key.
//!
//! That is not a weaker contract than the generic `Hashable` this replaces, it is the same one made
//! explicit — and it is the contract the runaway-repeat fix depends on. A held `⌃L` whose modifier
//! is released FIRST delivers the letter's `keyUp` as a plain `l`; if identity includes the
//! modifiers, that release does not match, the latch never clears, and the pane takes a control
//! byte twenty times a second until something else steals focus. Whether to spell identity
//! modifier-independently is the caller's call, and the empty identity is a legitimate one (a key
//! with no characters and no usage) rather than a sentinel.
//!
//! ## One generation counter does the work of two race checks
//!
//! The Swift this replaces had two: a "still holding this key?" test inside every timer callback,
//! and a "adopt this handle only if the key I armed it for is still held" test after every arm.
//! Both are asking the same thing — has the latch moved since this timer was armed — and both were
//! written against the KEY, which cannot tell a re-press apart from the press it replaced.
//!
//! Here every latch carries a generation that is never reused. A timer callback quotes the
//! generation it was armed under; if it is not the live one the callback is [`Tick::Stale`] and
//! fires nothing. That covers the re-press case the key comparison silently got wrong: pressing
//! `a`, releasing it and pressing it again inside 350 ms armed two timers whose key comparisons
//! BOTH passed, so the second press repeated at double rate.

/// The wait between the first fire and the first repeat, in milliseconds.
///
/// Long enough that a tap is not a hold. Every ordinary keystroke is one press well inside this, so
/// a shorter delay would make plain typing double letters.
pub const DEFAULT_INITIAL_DELAY_MS: u32 = 350;

/// The wait between repeats once the ramp is running: 20 Hz.
pub const DEFAULT_REPEAT_INTERVAL_MS: u32 = 50;

/// The two waits, together.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timing {
    /// Between the immediate fire and the first repeat.
    pub initial_delay_ms: u32,
    /// Between repeats after that.
    pub repeat_interval_ms: u32,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            initial_delay_ms: DEFAULT_INITIAL_DELAY_MS,
            repeat_interval_ms: DEFAULT_REPEAT_INTERVAL_MS,
        }
    }
}

/// Which timer just elapsed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// The one-shot armed by [`Down::Start`].
    Initial,
    /// The repeating timer armed by [`Tick::FireThenRepeat`].
    Repeating,
}

impl Stage {
    /// The byte a stage crosses as — declaration order.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Initial => 0,
            Self::Repeating => 1,
        }
    }

    /// A stage from its byte. An unnamed code reads as [`Stage::Repeating`], which is the safe
    /// default of the two: it fires and re-arms NOTHING, where a wrong `Initial` would arm a second
    /// repeating timer on top of the live one.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        if code == 0 { Self::Initial } else { Self::Repeating }
    }
}

/// What a key going DOWN asks its caller to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Down {
    /// This key is already latched and its ramp is running. Do nothing — not a fire, not a re-arm.
    /// A second `pressesBegan` for a key that never came up is a duplicate, not a new press.
    Continue,
    /// This key takes the latch. Cancel any armed timer, emit the key ONCE now, then arm a one-shot
    /// `after_ms` from now and quote `generation` when it elapses.
    Start {
        /// The token this latch is known by until it moves.
        generation: u64,
        /// The one-shot's delay.
        after_ms: u32,
    },
}

/// What an elapsed timer asks its caller to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tick {
    /// The latch moved since this timer was armed — a release, another key, or a re-press. Emit
    /// nothing and let the timer go.
    Stale,
    /// Emit the key this timer was armed for. Whatever timer is running stays as it is.
    Fire,
    /// Emit the key, then replace the one-shot with a repeating timer every `every_ms`.
    FireThenRepeat {
        /// The repeating timer's interval.
        every_ms: u32,
    },
}

/// The latched key and the generation it is known by.
#[derive(Debug)]
struct Latch {
    identity: Vec<u8>,
    generation: u64,
}

/// Which key is held, and what each event about it means.
///
/// Holds no clock and no payload; see the module header for why both stay with the caller.
#[derive(Debug, Default)]
pub struct KeyRepeat {
    latch: Option<Latch>,
    /// The next generation to hand out. Wraps, which is unreachable: it would take 2^64 keypresses
    /// in one process, and wrapping is still better than a panic in a key path.
    next_generation: u64,
}

impl KeyRepeat {
    /// Nothing held.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// A key went down.
    ///
    /// `identity` is compared byte for byte against the latched one; see the module header.
    pub fn down(&mut self, identity: &[u8], timing: Timing) -> Down {
        if self
            .latch
            .as_ref()
            .is_some_and(|latch| latch.identity == identity)
        {
            return Down::Continue;
        }
        let generation = self.next_generation;
        self.next_generation = self.next_generation.wrapping_add(1);
        self.latch = Some(Latch {
            identity: identity.to_vec(),
            generation,
        });
        Down::Start {
            generation,
            after_ms: timing.initial_delay_ms,
        }
    }

    /// A key went up. `true` means the caller must cancel its armed timer.
    ///
    /// A release for a key that is NOT the latched one is ignored, so a stale event — the phone
    /// delivering a release for a key that was already superseded — cannot kill a live repeat.
    pub fn up(&mut self, identity: &[u8]) -> bool {
        if self
            .latch
            .as_ref()
            .is_some_and(|latch| latch.identity == identity)
        {
            self.latch = None;
            return true;
        }
        false
    }

    /// Drops any latch — focus loss, disconnect, teardown. `true` when there was one to drop, so
    /// the caller cancels its timer exactly when there is one.
    pub fn stop(&mut self) -> bool {
        self.latch.take().is_some()
    }

    /// A timer armed under `generation` just elapsed.
    #[must_use]
    pub fn elapsed(&self, stage: Stage, generation: u64, timing: Timing) -> Tick {
        if !self.is_current(generation) {
            return Tick::Stale;
        }
        match stage {
            Stage::Initial => {
                Tick::FireThenRepeat {
                    every_ms: timing.repeat_interval_ms,
                }
            },
            Stage::Repeating => Tick::Fire,
        }
    }

    /// Whether `generation` is still the live latch.
    ///
    /// The caller asks this once more after arming a timer: a release that landed while the arm was
    /// in flight means the fresh handle is already stale, and adopting it would leave a timer
    /// running with nobody to cancel it.
    #[must_use]
    pub fn is_current(&self, generation: u64) -> bool {
        self.latch
            .as_ref()
            .is_some_and(|latch| latch.generation == generation)
    }

    /// Whether any key is held and repeating.
    #[must_use]
    pub const fn is_held(&self) -> bool {
        self.latch.is_some()
    }

    /// The latched key's identity, for a caller that wants to say which key it is.
    ///
    /// Borrows rather than allocating: the answer is the bytes the caller handed in.
    #[must_use]
    pub fn held_identity(&self) -> Option<&[u8]> {
        self.latch.as_ref().map(|latch| latch.identity.as_slice())
    }
}

#[cfg(test)]
#[expect(
    clippy::panic,
    reason = "an unreachable branch in a test IS the report — a silent `return` would pass"
)]
mod tests {
    use super::{DEFAULT_INITIAL_DELAY_MS, DEFAULT_REPEAT_INTERVAL_MS, Down, KeyRepeat, Stage, Tick, Timing};

    /// Runs the whole ramp for one key, answering the generation the caller would be holding.
    #[track_caller]
    fn start(machine: &mut KeyRepeat, identity: &[u8]) -> u64 {
        match machine.down(identity, Timing::default()) {
            Down::Start { generation, after_ms } => {
                assert_eq!(after_ms, DEFAULT_INITIAL_DELAY_MS);
                generation
            },
            Down::Continue => panic!("expected a fresh latch for {identity:?}"),
        }
    }

    /// The cadence, asked rather than spelled — this is the pair `KeyRepeaterTests`'
    /// `testInitialDelayThenRepeatCadence` asserted against wall-clock milliseconds.
    #[test]
    fn the_cadence_is_an_immediate_fire_then_350_then_50() {
        assert_eq!(DEFAULT_INITIAL_DELAY_MS, 350);
        assert_eq!(DEFAULT_REPEAT_INTERVAL_MS, 50);
        let standard = Timing::default();
        assert_eq!(standard.initial_delay_ms, 350);
        assert_eq!(standard.repeat_interval_ms, 50);

        let mut machine = KeyRepeat::new();
        let generation = start(&mut machine, b"a");
        // The immediate fire is the caller's, on the `Start` verdict itself — there is no timer for
        // it and nothing to ask about it.
        assert_eq!(
            machine.elapsed(Stage::Initial, generation, standard),
            Tick::FireThenRepeat { every_ms: 50 },
            "the initial one-shot fires and hands over to the repeating timer",
        );
        for _ in 0..5 {
            assert_eq!(
                machine.elapsed(Stage::Repeating, generation, standard),
                Tick::Fire
            );
        }
    }

    /// Ported from `testImmediateFireOnKeyDown` and `testSameKeyDownIsIdempotent`: the first press
    /// latches, and a duplicate press for the same key changes nothing.
    #[test]
    fn a_second_press_of_the_held_key_is_a_duplicate_not_a_new_press() {
        let mut machine = KeyRepeat::new();
        let generation = start(&mut machine, b"a");
        assert!(machine.is_held());
        assert_eq!(machine.held_identity(), Some(b"a".as_slice()));
        assert_eq!(
            machine.down(b"a", Timing::default()),
            Down::Continue,
            "no second fire, no second timer",
        );
        assert!(
            machine.is_current(generation),
            "and the live generation did not move"
        );
    }

    /// Ported from `testStopOnKeyUp` and `testKeyDownThenImmediateKeyUpFiresExactlyOnce` — the
    /// software-Backspace one-shot, which must leave NO armed timer behind or the pane takes a DEL
    /// flood.
    #[test]
    fn a_release_clears_the_latch_and_every_timer_armed_under_it_goes_stale() {
        let mut machine = KeyRepeat::new();
        let generation = start(&mut machine, b"\x7f");
        assert!(machine.up(b"\x7f"), "the release is the caller's cue to cancel");
        assert!(!machine.is_held());
        assert!(!machine.is_current(generation));
        assert_eq!(
            machine.elapsed(Stage::Initial, generation, Timing::default()),
            Tick::Stale,
            "a timer that outran its cancel fires nothing",
        );
        assert_eq!(
            machine.elapsed(Stage::Repeating, generation, Timing::default()),
            Tick::Stale,
        );
    }

    /// Ported from `testKeyUpForUnheldKeyIsIgnored`. A release for a key nobody is holding must not
    /// cancel the repeat that IS running.
    #[test]
    fn a_release_for_another_key_is_ignored() {
        let mut machine = KeyRepeat::new();
        let generation = start(&mut machine, b"a");
        assert!(!machine.up(b"b"), "nothing to cancel");
        assert!(machine.is_held());
        assert_eq!(
            machine.elapsed(Stage::Repeating, generation, Timing::default()),
            Tick::Fire
        );
        // And a release with nothing held at all.
        assert!(machine.up(b"a"));
        assert!(!machine.up(b"a"));
    }

    /// Ported from `testLastKeyWinsOnNewKeyDown`: holding `→` and then pressing `←` repeats `←`.
    #[test]
    fn the_last_key_pressed_takes_the_latch() {
        let mut machine = KeyRepeat::new();
        let first = start(&mut machine, "→".as_bytes());
        let second = start(&mut machine, "←".as_bytes());
        assert_ne!(first, second, "the new latch is a new generation");
        assert_eq!(machine.held_identity(), Some("←".as_bytes()));
        assert_eq!(
            machine.elapsed(Stage::Repeating, first, Timing::default()),
            Tick::Stale,
            "the superseded key's timer fires nothing",
        );
        assert_eq!(
            machine.elapsed(Stage::Repeating, second, Timing::default()),
            Tick::Fire
        );
    }

    /// Ported from `testKeyUpMatchingByIdentityNotPayloadStopsRunawayRepeat`. The caller mints the
    /// identity, so a `⌃L` release that arrives as a plain `l` still matches when the caller spells
    /// identity modifier-independently — and does NOT when it spells it with the modifiers in.
    /// Both are legitimate; the point is that this module compares what it was given and nothing
    /// else.
    #[test]
    fn identity_is_whatever_the_caller_says_it_is() {
        // Modifier-independent: the physical key is the identity, the combo is the caller's
        // payload.
        let mut by_key = KeyRepeat::new();
        start(&mut by_key, b"l");
        assert!(
            by_key.up(b"l"),
            "the plain release matches the held control combo"
        );
        assert!(!by_key.is_held(), "no runaway flood");

        // Modifier-laden: the same release does not match, and the latch survives.
        let mut by_combo = KeyRepeat::new();
        let generation = start(&mut by_combo, b"ctrl-l");
        assert!(!by_combo.up(b"l"));
        assert!(by_combo.is_held());
        assert!(by_combo.is_current(generation));
    }

    /// `stop` is idempotent and says whether it did anything, so a caller cancels a timer exactly
    /// when there is one.
    #[test]
    fn stop_is_idempotent_and_reports_whether_it_dropped_a_latch() {
        let mut machine = KeyRepeat::new();
        assert!(!machine.stop(), "nothing held");
        let generation = start(&mut machine, b"x");
        assert!(machine.stop());
        assert!(!machine.stop());
        assert!(!machine.is_current(generation));
    }

    /// The re-press the old key comparison got wrong: press, release, press the SAME key again.
    /// Both timers were armed for an equal key, so a key-equality liveness check passed for both
    /// and the second press repeated at double rate. A generation cannot be equal by accident.
    #[test]
    fn a_re_press_of_the_same_key_makes_the_first_ramp_stale() {
        let mut machine = KeyRepeat::new();
        let first = start(&mut machine, b"a");
        assert!(machine.up(b"a"));
        let second = start(&mut machine, b"a");
        assert_ne!(first, second);
        assert_eq!(
            machine.elapsed(Stage::Initial, first, Timing::default()),
            Tick::Stale
        );
        assert_eq!(
            machine.elapsed(Stage::Initial, second, Timing::default()),
            Tick::FireThenRepeat {
                every_ms: DEFAULT_REPEAT_INTERVAL_MS
            },
        );
    }

    /// An overridden cadence rides every verdict — the integration test against a real
    /// `DispatchSourceTimer` needs one it can cross twice inside a second.
    #[test]
    fn an_overridden_cadence_is_the_one_that_comes_back() {
        let timing = Timing {
            initial_delay_ms: 30,
            repeat_interval_ms: 20,
        };
        let mut machine = KeyRepeat::new();
        let Down::Start { generation, after_ms } = machine.down(b"a", timing) else {
            panic!("expected a fresh latch");
        };
        assert_eq!(after_ms, 30);
        assert_eq!(
            machine.elapsed(Stage::Initial, generation, timing),
            Tick::FireThenRepeat { every_ms: 20 },
        );
    }

    /// The empty identity is a KEY, not a sentinel: a press with no characters and no HID usage is
    /// something the phone can deliver, and it must latch and release like any other.
    #[test]
    fn the_empty_identity_is_an_ordinary_key() {
        let mut machine = KeyRepeat::new();
        let generation = start(&mut machine, b"");
        assert!(machine.is_held());
        assert_eq!(machine.held_identity(), Some(b"".as_slice()));
        assert_eq!(machine.down(b"", Timing::default()), Down::Continue);
        assert_eq!(
            machine.elapsed(Stage::Repeating, generation, Timing::default()),
            Tick::Fire
        );
        assert!(machine.up(b""));
    }

    /// The stage byte round-trips, and an unnamed one reads as the stage that arms nothing.
    #[test]
    fn the_stage_byte_is_its_declaration_order_and_an_unknown_one_arms_nothing() {
        assert_eq!(Stage::Initial.code(), 0);
        assert_eq!(Stage::Repeating.code(), 1);
        for stage in [Stage::Initial, Stage::Repeating] {
            assert_eq!(Stage::from_code(stage.code()), stage);
        }
        assert_eq!(Stage::from_code(9), Stage::Repeating);
        let mut machine = KeyRepeat::new();
        let generation = start(&mut machine, b"a");
        assert_eq!(
            machine.elapsed(Stage::from_code(9), generation, Timing::default()),
            Tick::Fire,
            "an unnamed stage fires without re-arming",
        );
    }

    /// A generation is never handed out twice, however many keys pass through.
    #[test]
    fn generations_are_never_reused() {
        let mut machine = KeyRepeat::new();
        let mut seen = Vec::new();
        for index in 0..64_u8 {
            seen.push(start(&mut machine, &[index % 3]));
            machine.stop();
        }
        let mut sorted = seen.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), seen.len(), "every latch got its own token");
    }
}
