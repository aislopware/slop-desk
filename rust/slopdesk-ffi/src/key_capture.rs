//! What the immersive tap does with one key event, in C.
//!
//! The rules are `slopdesk_video::key_capture`; what is here is the marshalling. Three answers,
//! none of them wider than a byte.
//!
//! ## `CGEventFlags` stops at this boundary
//!
//! The near side holds Apple's flags; the crate holds the wire's own six-bit mask, which is the one
//! every other input door already speaks. So the modifiers cross as that mask, and the modifier-key
//! table answers in it too — the caller turns the bit back into the `CGEventFlags` constant it
//! needs, and Apple's numbers stay in the one place that has a header for them.

use slopdesk_video::input_event::InputModifiers;
use slopdesk_video::key_capture::{self, Decision, EventKind};

/// `0` key down · `1` key up · `2` flags changed. Anything else is an event the policy has no rule
/// for, which passes through — swallowing the unknown is what traps the user.
const fn kind_of(raw: u8) -> EventKind {
    match raw {
        0 => EventKind::KeyDown,
        1 => EventKind::KeyUp,
        2 => EventKind::FlagsChanged,
        _ => EventKind::Other,
    }
}

/// What the tap does with one event: `0` forward and swallow · `1` pass through · `2` disengage.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_key_capture_decision(key_code: u16, modifiers: u8, kind: u8) -> u8 {
    match key_capture::decision(key_code, InputModifiers::from_bits(modifiers), kind_of(kind)) {
        Decision::ForwardAndSwallow => 0,
        Decision::PassThrough => 1,
        Decision::Disengage => 2,
    }
}

/// Whether the event is a press rather than a release.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_key_capture_is_down(key_code: u16, modifiers: u8, kind: u8) -> bool {
    key_capture::is_down(key_code, InputModifiers::from_bits(modifiers), kind_of(kind))
}

/// Whether a keycode is Escape — the cancel key, asked by every local monitor over a transient
/// gesture so none of them has to restate the number.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_key_capture_is_escape(key_code: u16) -> bool {
    key_capture::is_escape(key_code)
}

/// The modifier bit a keycode drives, or `-1` for a keycode that is not a modifier key. A real
/// answer is one of six bits in a byte, so the refusal is outside the range by construction.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_key_capture_modifier_bit(key_code: u16) -> i32 {
    match key_capture::modifier_of(key_code) {
        Some(bit) => bit.bits() as i32,
        None => -1,
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_video::input_event::InputModifiers;

    use super::{
        slopdesk_key_capture_decision, slopdesk_key_capture_is_down, slopdesk_key_capture_is_escape,
        slopdesk_key_capture_modifier_bit,
    };

    #[test]
    fn the_case_indexes_are_the_ones_the_header_names() {
        let chord = InputModifiers::CONTROL
            .union(InputModifiers::OPTION)
            .union(InputModifiers::COMMAND);
        assert_eq!(slopdesk_key_capture_decision(14, chord.bits(), 0), 2, "disengage");
        assert_eq!(
            slopdesk_key_capture_decision(
                53,
                InputModifiers::COMMAND.union(InputModifiers::OPTION).bits(),
                0
            ),
            1,
            "force quit passes through"
        );
        assert_eq!(slopdesk_key_capture_decision(0, 0, 0), 0, "forward and swallow");
    }

    #[test]
    fn an_unknown_event_kind_is_never_swallowed() {
        assert_eq!(slopdesk_key_capture_decision(0, 0, 200), 1, "pass through");
        assert!(!slopdesk_key_capture_is_down(0, 0, 200));
    }

    #[test]
    fn the_modifier_table_answers_in_the_wires_own_bits() {
        assert_eq!(
            slopdesk_key_capture_modifier_bit(55),
            i32::from(InputModifiers::COMMAND.bits())
        );
        assert_eq!(
            slopdesk_key_capture_modifier_bit(14),
            -1,
            "a letter is not a modifier"
        );
    }

    #[test]
    fn the_cancel_key_is_the_one_the_chord_already_names() {
        assert!(slopdesk_key_capture_is_escape(53));
        assert!(!slopdesk_key_capture_is_escape(14));
    }

    #[test]
    fn a_modifier_edge_reads_its_direction_off_its_own_bit() {
        assert!(slopdesk_key_capture_is_down(
            55,
            InputModifiers::COMMAND.bits(),
            2
        ));
        assert!(!slopdesk_key_capture_is_down(55, 0, 2));
    }
}
