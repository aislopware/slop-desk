//! What the immersive-mode event tap does with one key event.
//!
//! While capture is engaged every key is swallowed locally and sent to the remote machine instead —
//! which is the point of immersive mode, and also the danger: a rule that swallows one key too many
//! turns the pane into a keyboard trap whose only exit is another computer.
//!
//! ## The two bail-outs, and why they are checked loosely
//!
//! Two chords must stay reachable no matter what the rest of this file says. ⌘⌥Esc opens Force
//! Quit, which is the recovery path when the app itself wedges, so it passes through untouched.
//! ⌃⌥⌘E disengages capture. Both are tested by CONTAINMENT rather than equality: a stuck caps-lock,
//! an fn bit, a shift the user is still holding, or any bit a newer keyboard sets must not be able
//! to make either hatch unreachable. ⌘Q deliberately does NOT get this treatment — quitting the
//! remote frontmost app is a first-class immersive verb, and the two chords above keep the local
//! exit open without it.
//!
//! Everything the policy does not understand passes through. Swallowing an unrecognised event is
//! the failure that traps the user; forwarding one is a keystroke that lands on the wrong machine.

use crate::input_event::{InputModifiers, modifier_keys};

/// What the tap callback does with one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Deliver it to the remote host and let macOS never see it.
    ForwardAndSwallow,
    /// Hand it back untouched — the local system or app handles it.
    PassThrough,
    /// The escape chord: tear capture down. Swallowed and never forwarded; it is a client-side
    /// control, not input meant for either machine.
    Disengage,
}

/// Which kind of tap event arrived.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EventKind {
    /// A key went down.
    KeyDown,
    /// A key came up.
    KeyUp,
    /// A modifier key changed state.
    FlagsChanged,
    /// Anything else the tap can deliver — a tap timeout, a re-enable, a type this policy has no
    /// rule for.
    #[default]
    Other,
}

/// `kVK_ANSI_E` — the escape chord's letter. Literal, so this stays a pure-value module.
pub const KEY_CODE_E: u16 = 14;

/// `kVK_Escape` — the Force Quit chord's key.
pub const KEY_CODE_ESCAPE: u16 = 53;

/// Whether a keycode is Escape — the one key that CANCELS an affordance rather than typing into it.
///
/// Asked by every surface that puts a local key monitor over a transient gesture, so the number
/// stays in the one module that already has to name it for the Force Quit chord.
#[must_use]
pub const fn is_escape(key_code: u16) -> bool {
    key_code == KEY_CODE_ESCAPE
}

/// The one decision per tap event.
///
/// A `FlagsChanged` is forwarded only when its keycode is a modifier this crate can name: an
/// unmapped one has no derivable direction, and forwarding a guess desynchronises the remote
/// modifier state — which is the stuck-⌘ bug the latch exists to clean up after. Let macOS keep it.
///
/// Everything else goes to the host, including the chords immersive mode exists for: ⌘Tab, ⌘Space,
/// ⌘backtick, the F-keys, and the media keys that arrive as plain F-key events. That still works
/// with `FlagsChanged` swallowed, because a keyDown's modifier bits come from hardware state rather
/// than from the flag deliveries this swallowed.
#[must_use]
pub fn decision(key_code: u16, modifiers: InputModifiers, kind: EventKind) -> Decision {
    match kind {
        EventKind::FlagsChanged => {
            if modifier_of(key_code).is_some() {
                Decision::ForwardAndSwallow
            } else {
                Decision::PassThrough
            }
        },
        EventKind::KeyDown | EventKind::KeyUp => {
            let chord = InputModifiers::CONTROL
                .union(InputModifiers::OPTION)
                .union(InputModifiers::COMMAND);
            if kind == EventKind::KeyDown && key_code == KEY_CODE_E && modifiers.contains(chord) {
                return Decision::Disengage;
            }
            let force_quit = InputModifiers::COMMAND.union(InputModifiers::OPTION);
            if key_code == KEY_CODE_ESCAPE && modifiers.contains(force_quit) {
                return Decision::PassThrough;
            }
            Decision::ForwardAndSwallow
        },
        EventKind::Other => Decision::PassThrough,
    }
}

/// Whether the event is a press or a release, for the forwarder.
///
/// A `FlagsChanged` carries no direction of its own, so it is derived the way every remote-desktop
/// tool derives it: the changed key just went DOWN if its own bit is now set in the event's state.
#[must_use]
pub fn is_down(key_code: u16, modifiers: InputModifiers, kind: EventKind) -> bool {
    match kind {
        EventKind::KeyDown => true,
        EventKind::FlagsChanged => modifier_of(key_code).is_some_and(|bit| modifiers.contains(bit)),
        EventKind::KeyUp | EventKind::Other => false,
    }
}

/// The modifier a keycode drives, or `None` for a keycode that is not a modifier key.
///
/// Left and right collapse onto one bit deliberately: the forwarder carries the keycode itself, so
/// the remote host still learns WHICH physical key moved — only the direction derivation needs the
/// bit, and both sides of the keyboard set the same one.
#[must_use]
pub const fn modifier_of(key_code: u16) -> Option<InputModifiers> {
    match key_code {
        54 | 55 => Some(InputModifiers::COMMAND),
        56 | 60 => Some(InputModifiers::SHIFT),
        58 | 61 => Some(InputModifiers::OPTION),
        59 | 62 => Some(InputModifiers::CONTROL),
        modifier_keys::CAPS_LOCK_KEY_CODE => Some(InputModifiers::CAPS_LOCK),
        63 => Some(InputModifiers::FUNCTION),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Decision, EventKind, KEY_CODE_E, KEY_CODE_ESCAPE, decision, is_down, is_escape, modifier_of,
    };
    use crate::input_event::{InputModifiers, modifier_keys};

    const ESCAPE_CHORD: InputModifiers = InputModifiers::from_bits(
        InputModifiers::CONTROL.bits() | InputModifiers::OPTION.bits() | InputModifiers::COMMAND.bits(),
    );

    #[test]
    fn the_escape_hatch_survives_every_extra_bit() {
        let stuck = InputModifiers::from_bits(
            ESCAPE_CHORD.bits() | InputModifiers::CAPS_LOCK.bits() | InputModifiers::SHIFT.bits(),
        );
        assert_eq!(
            decision(KEY_CODE_E, ESCAPE_CHORD, EventKind::KeyDown),
            Decision::Disengage
        );
        assert_eq!(
            decision(KEY_CODE_E, stuck, EventKind::KeyDown),
            Decision::Disengage
        );
    }

    #[test]
    fn the_escape_chord_is_a_key_down_only() {
        assert_eq!(
            decision(KEY_CODE_E, ESCAPE_CHORD, EventKind::KeyUp),
            Decision::ForwardAndSwallow,
            "the up is ordinary input; the chord already fired"
        );
    }

    #[test]
    fn force_quit_always_reaches_macos() {
        let chord = InputModifiers::COMMAND.union(InputModifiers::OPTION);
        let with_shift = chord.union(InputModifiers::SHIFT);
        assert_eq!(
            decision(KEY_CODE_ESCAPE, chord, EventKind::KeyDown),
            Decision::PassThrough
        );
        assert_eq!(
            decision(KEY_CODE_ESCAPE, with_shift, EventKind::KeyDown),
            Decision::PassThrough,
            "force-quit-frontmost is the same hatch"
        );
        assert_eq!(
            decision(KEY_CODE_ESCAPE, chord, EventKind::KeyUp),
            Decision::PassThrough
        );
    }

    #[test]
    fn the_cancel_key_is_the_one_the_force_quit_chord_names() {
        assert!(is_escape(KEY_CODE_ESCAPE));
        assert!(!is_escape(KEY_CODE_E));
    }

    #[test]
    fn a_bare_escape_and_command_q_go_to_the_remote_machine() {
        assert_eq!(
            decision(KEY_CODE_ESCAPE, InputModifiers::default(), EventKind::KeyDown),
            Decision::ForwardAndSwallow
        );
        // ⌘Q — quitting the remote frontmost app is a verb, not a local exit.
        assert_eq!(
            decision(12, InputModifiers::COMMAND, EventKind::KeyDown),
            Decision::ForwardAndSwallow
        );
    }

    #[test]
    fn only_a_nameable_modifier_edge_is_swallowed() {
        assert_eq!(
            decision(
                modifier_keys::CAPS_LOCK_KEY_CODE,
                InputModifiers::default(),
                EventKind::FlagsChanged
            ),
            Decision::ForwardAndSwallow
        );
        assert_eq!(
            decision(1, InputModifiers::default(), EventKind::FlagsChanged),
            Decision::PassThrough,
            "an unmapped edge has no derivable direction"
        );
    }

    #[test]
    fn an_event_the_policy_does_not_understand_is_never_swallowed() {
        assert_eq!(
            decision(KEY_CODE_E, ESCAPE_CHORD, EventKind::Other),
            Decision::PassThrough,
            "swallowing the unknown is what traps the user"
        );
    }

    #[test]
    fn a_modifier_edge_reads_its_direction_off_its_own_bit() {
        assert!(is_down(55, InputModifiers::COMMAND, EventKind::FlagsChanged));
        assert!(
            !is_down(55, InputModifiers::SHIFT, EventKind::FlagsChanged),
            "a different key's bit"
        );
        assert!(
            !is_down(1, InputModifiers::COMMAND, EventKind::FlagsChanged),
            "unmapped"
        );
        assert!(is_down(0, InputModifiers::default(), EventKind::KeyDown));
        assert!(!is_down(0, InputModifiers::default(), EventKind::KeyUp));
        assert!(!is_down(0, InputModifiers::default(), EventKind::Other));
    }

    #[test]
    fn both_sides_of_the_keyboard_drive_one_bit() {
        for (left, right, bit) in [
            (55_u16, 54_u16, InputModifiers::COMMAND),
            (56, 60, InputModifiers::SHIFT),
            (58, 61, InputModifiers::OPTION),
            (59, 62, InputModifiers::CONTROL),
        ] {
            assert_eq!(modifier_of(left), Some(bit));
            assert_eq!(modifier_of(right), Some(bit));
        }
        assert_eq!(modifier_of(63), Some(InputModifiers::FUNCTION));
        assert_eq!(modifier_of(14), None, "a letter is not a modifier");
    }

    /// Every keycode the latch tracks as a held modifier must be one this policy can name, or the
    /// tap would forward an edge the latch then has no way to clear.
    #[test]
    fn every_held_modifier_the_latch_tracks_is_nameable_here() {
        for key_code in modifier_keys::HELD_MODIFIER_KEY_CODES {
            assert!(
                modifier_of(key_code).is_some(),
                "keycode {key_code} has no modifier bit"
            );
        }
    }
}
