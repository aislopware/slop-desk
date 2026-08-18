//! What a window-scoped local key monitor does with an Escape.
//!
//! A transient surface — the Settings window, the pane-move drag — installs a process-wide
//! `keyDown` monitor and scopes it to its own window, because the focused-view route
//! (`onExitCommand`) resolves against whichever branch holds focus and a freshly-opened window has
//! none. The monitor then has to answer one question per event, and this module is that answer.
//!
//! ## Escape is claimed by more than one surface at a time
//!
//! Two local monitors racing for the same Escape resolve in `AppKit`'s undocumented install order,
//! so the arbitration cannot live in either of them. A chord recorder — where Escape already MEANS
//! "cancel this capture" — outranks a window dismiss, and it says so by publishing a flag the
//! dismissing monitor reads here. The outcome is then the same whichever monitor happens to run
//! first.
//!
//! ## Which modifiers disqualify, and which are not modifiers at all
//!
//! A dismiss is a PLAIN Escape: ⌘ ⌥ ⌃ ⇧ each make it somebody else's chord (⌥Esc is `macOS`'s own
//! Speak Selection). Caps lock and fn do not — a stuck caps lock is a state the user is in, not a
//! chord they typed, and refusing to close the window because of it is the same class of trap the
//! immersive tap's containment tests exist to prevent.

use crate::input_event::InputModifiers;
use crate::key_capture::is_escape;

/// The four modifiers that turn a bare Escape into a chord meant for something else.
pub const DISQUALIFYING_MODIFIERS: InputModifiers = InputModifiers::from_bits(
    InputModifiers::COMMAND.bits()
        | InputModifiers::OPTION.bits()
        | InputModifiers::CONTROL.bits()
        | InputModifiers::SHIFT.bits(),
);

/// Whether this key event should close the window its monitor is scoped to.
///
/// `chord_capture_armed` is a recorder's claim on Escape; while it is set the event passes through
/// untouched, so the recorder cancels its capture instead of the window closing under it.
#[must_use]
pub const fn dismisses_window(key_code: u16, modifiers: InputModifiers, chord_capture_armed: bool) -> bool {
    is_escape(key_code) && !chord_capture_armed && modifiers.intersection(DISQUALIFYING_MODIFIERS).is_empty()
}

#[cfg(test)]
mod tests {
    use super::{DISQUALIFYING_MODIFIERS, dismisses_window};
    use crate::input_event::InputModifiers;
    use crate::key_capture::KEY_CODE_ESCAPE;

    #[test]
    fn a_plain_escape_closes_the_window() {
        assert!(dismisses_window(
            KEY_CODE_ESCAPE,
            InputModifiers::default(),
            false
        ));
    }

    #[test]
    fn every_chord_modifier_disqualifies_on_its_own() {
        for modifier in [
            InputModifiers::COMMAND,
            InputModifiers::OPTION,
            InputModifiers::CONTROL,
            InputModifiers::SHIFT,
        ] {
            assert!(
                !dismisses_window(KEY_CODE_ESCAPE, modifier, false),
                "a modified Escape belongs to whoever bound that chord"
            );
            assert!(!DISQUALIFYING_MODIFIERS.intersection(modifier).is_empty());
        }
    }

    #[test]
    fn a_state_the_user_is_in_is_not_a_chord_they_typed() {
        for modifier in [InputModifiers::CAPS_LOCK, InputModifiers::FUNCTION] {
            assert!(
                dismisses_window(KEY_CODE_ESCAPE, modifier, false),
                "a stuck caps lock must not make the window unclosable"
            );
        }
    }

    #[test]
    fn the_recorder_outranks_the_dismiss() {
        assert!(!dismisses_window(
            KEY_CODE_ESCAPE,
            InputModifiers::default(),
            true
        ));
    }

    #[test]
    fn every_other_key_passes_through() {
        assert!(!dismisses_window(14, InputModifiers::default(), false));
        assert!(!dismisses_window(0, InputModifiers::default(), false));
    }
}
