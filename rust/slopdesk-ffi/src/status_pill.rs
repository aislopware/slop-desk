//! The pane's status chips, in C.
//!
//! The rules are `slopdesk_workspace::status_pill`; what is here is the marshalling.
//!
//! Two shapes, both `docs/55` §6's: the CLASSIFIERS cross as scalars — six gates in one byte, three
//! chips out in another — and the WORDS cross as a group, because a chip's label, its two
//! accessibility sentences and its dismiss tooltip are always wanted together and a door per string
//! would be four crossings to draw one chip.

use core::ffi::c_uchar;

use slopdesk_workspace::status_pill::{self, Conditions, Pill};

use crate::{deliver, push_text};

/// The chips that are up, as a bitmask over the chip's own index — bit `n` set means chip `n`
/// draws, low bit first, which IS the top-down stacking order.
///
/// `conditions` packs the six gates low bit first: read-only, copy mode, hint mode, secure input,
/// the secure-input setting, sync input.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_status_pills(conditions: u8) -> u8 {
    status_pill::visible(Conditions::from_bits(conditions))
}

/// The two chips that are not in [`slopdesk_ws_status_pills`]' list, as a bitmask: bit `0` is the
/// vi/copy-mode pill above the stack, bit `1` the key-hint bar along the bottom.
///
/// They travel together because they are the same question asked about the same mode — one door
/// rather than two, so a caller cannot ask one and forget the other.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_status_pill_gates(conditions: u8, hints_toggled: bool) -> u8 {
    let conditions = Conditions::from_bits(conditions);
    let mut gates = 0_u8;
    if status_pill::shows_vi_mode_pill(conditions) {
        gates |= 1;
    }
    if status_pill::shows_vi_key_hint_bar(conditions, hints_toggled) {
        gates |= 2;
    }
    gates
}

/// The plate chip `pill` stands on: `0` the chrome plate, `1` the fixed security tone, `2` the
/// fixed sync tone. `u8::MAX` for an index no chip has.
///
/// The refusal is outside the range of every real answer, which is §4's rule read at the scale of
/// one value.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_status_pill_fill(pill: u8) -> u8 {
    // Spelled as a `match` rather than a `map_or`, because `Option::map_or` is not const and a
    // door that answers one byte from a table has no business allocating a stack frame for it.
    match Pill::from_index(pill) {
        Some(pill) => pill.fill().code(),
        None => u8::MAX,
    }
}

/// Everything one chip SAYS, in one delivery.
///
/// ```text
/// [u8 is_dismissible]
/// 4 × [u32 length][UTF-8 bytes]   // label, accessibility label, accessibility hint, dismiss help
/// ```
///
/// A zero-length dismiss help is NO tooltip, which the flag beside it already says: the two agree
/// by construction, because the flag is derived from the string's presence on the far side.
///
/// `0` is "there is no such chip", never an empty one — a chip always has at least a label.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_status_pill_words(pill: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(pill) = Pill::from_index(pill) else {
        return 0;
    };
    let mut blob = vec![u8::from(pill.is_dismissible())];
    push_text(&mut blob, pill.label());
    push_text(&mut blob, pill.accessibility_label());
    push_text(&mut blob, pill.accessibility_hint());
    push_text(&mut blob, pill.dismiss_help().unwrap_or_default());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::status_pill::Pill;

    use super::{
        slopdesk_ws_status_pill_fill, slopdesk_ws_status_pill_gates, slopdesk_ws_status_pill_words,
        slopdesk_ws_status_pills,
    };
    use crate::testing::runs;

    /// The mask the crate answers with is the mask the door answers with, over the whole gate
    /// space — a parity assertion rather than a probe.
    #[test]
    fn every_gate_combination_crosses_unchanged() {
        for bits in 0..64_u8 {
            let conditions = slopdesk_workspace::status_pill::Conditions::from_bits(bits);
            let crossed = slopdesk_ws_status_pills(bits);
            assert_eq!(
                crossed,
                slopdesk_workspace::status_pill::visible(conditions),
                "{bits:#08b}"
            );
        }
    }

    #[test]
    fn the_two_mode_gates_ride_one_byte() {
        // copy mode only.
        let vi = slopdesk_ws_status_pill_gates(0b10, true);
        assert_eq!(vi, 0b11, "the chip and the bar are both up in vi mode");
        assert_eq!(slopdesk_ws_status_pill_gates(0b10, false), 0b01);
        assert_eq!(
            slopdesk_ws_status_pill_gates(0b110, true),
            0b10,
            "hint mode owns the corner"
        );
        assert_eq!(slopdesk_ws_status_pill_gates(0, true), 0);
    }

    #[test]
    fn every_chip_crosses_with_its_own_plate_and_its_own_words() {
        for pill in Pill::ALL {
            assert_eq!(slopdesk_ws_status_pill_fill(pill.index()), pill.fill().code());
            let blob = crate::testing::delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_status_pill_words(pill.index(), out, cap) }
            });
            let (flag, rest) = blob
                .split_first()
                .map_or((0, [].as_slice()), |(flag, rest)| (*flag, rest));
            assert!(!rest.is_empty(), "a chip delivered nothing at all");
            assert_eq!(flag == 1, pill.is_dismissible());
            let words = runs(rest, 4);
            assert_eq!(words.first().map(String::as_str), Some(pill.label()));
            assert_eq!(words.get(1).map(String::as_str), Some(pill.accessibility_label()));
            assert_eq!(words.get(2).map(String::as_str), Some(pill.accessibility_hint()));
            assert_eq!(words.get(3).map(String::as_str), pill.dismiss_help().or(Some("")));
        }
    }

    /// An index no chip has is no chip at all — §4's `0`, and the fill's out-of-range refusal.
    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_ws_status_pill_words(9, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
        assert_eq!(slopdesk_ws_status_pill_fill(9), u8::MAX);
    }
}
