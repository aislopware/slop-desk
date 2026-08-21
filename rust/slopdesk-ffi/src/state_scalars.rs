//! The two scalar field conventions the near side had been composing for itself.
//!
//! Every other leaf of the document's field codec already crosses through [`crate::workspace`] —
//! the `u8`, the pairs, the `u32`, the `i64`, the strings. These two did not, and both were
//! *compositions* rather than omissions, which is what made them easy to leave behind: reading a
//! bool was "the `u8` door, then `!= 0`", and writing a signed exit code was "the `u32` door, then
//! a bit cast". A one-line composition on the near side is still a rule living in two languages,
//! and `slopdesk_workspace::state_codec` had already written both of them down — with no caller.
//!
//! What they are worth is narrow and real. `!= 0` against `== 1` is a disagreement about every
//! non-canonical byte a peer sends, and a signed cast on one side of a boundary with the decode on
//! the other is a round trip whose two halves nothing compares. Neither would fail a decode; both
//! would render.

use core::ffi::c_uchar;

use slopdesk_workspace::state_codec;

use crate::{borrow, deliver};

/// A one-byte field read as a BOOL: any non-zero byte is `true`, which is the discipline every
/// value that crossed a language or a network boundary is read with here.
///
/// `false` — the return, not `*out` — when the bytes are not exactly one, and then `out` is left
/// untouched. The answer and the refusal are separate channels for the reason the rest of this
/// family states: both of a bool's values are real answers, so no in-band byte could have meant
/// "these bytes are not a bool".
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes for the call; `out` null or writable for one
/// `bool`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_bool(bytes: *const c_uchar, len: usize, out: *mut bool) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let Some(value) = state_codec::decode_bool(unsafe { borrow(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `bool`.
        unsafe { *out = value };
    }
    true
}

/// A `pane/lastExitCode` value's bytes, under §4's convention: four of them, big-endian, carrying
/// the `u32` bit pattern so a signal-killed child's negative code survives.
///
/// The width is known before the call, so this carries no retry a caller ever travels — it is
/// `slopdesk_ws_encode_u32`'s shape, and it exists beside that door rather than through it because
/// the bit pattern is the CHOICE, and `slopdesk_ws_decode_i32` was already making the other half of
/// it on this side.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_i32(value: i32, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_i32(value), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{slopdesk_ws_decode_bool, slopdesk_ws_encode_i32};

    /// Reads a bool field through the door the way Swift does.
    fn decode(bytes: &[u8]) -> Option<bool> {
        let mut answer = false;
        // SAFETY: one live local slice and one live local `bool`, borrowed for the call.
        let decoded = unsafe { slopdesk_ws_decode_bool(bytes.as_ptr(), bytes.len(), &raw mut answer) };
        decoded.then_some(answer)
    }

    #[test]
    fn any_non_zero_byte_is_true_and_a_wrong_width_is_not_an_answer() {
        assert_eq!(decode(&[0]), Some(false));
        assert_eq!(decode(&[1]), Some(true));
        assert_eq!(
            decode(&[0xFF]),
            Some(true),
            "a peer that spells true as 0xFF is not sending false"
        );
        assert_eq!(decode(&[]), None);
        assert_eq!(decode(&[0, 0]), None, "two bytes are not a one-byte field");
    }

    #[test]
    fn a_refused_bool_leaves_the_caller_s_slot_untouched() {
        let mut answer = true;
        // SAFETY: one live literal and one live local, borrowed for the call.
        let decoded = unsafe { slopdesk_ws_decode_bool([0_u8, 0].as_ptr(), 2, &raw mut answer) };
        assert!(!decoded);
        assert!(answer, "a refusal must not write a value the caller would read");
    }

    #[test]
    fn a_null_out_is_a_probe_rather_than_a_crash() {
        // SAFETY: one live literal; the answer is deliberately not written anywhere.
        let decoded = unsafe { slopdesk_ws_decode_bool([1_u8].as_ptr(), 1, core::ptr::null_mut()) };
        assert!(decoded, "the verdict is the return, so it survives a null slot");
    }

    #[test]
    fn a_negative_exit_code_rides_as_its_bit_pattern() {
        let mut out = [0_u8; 4];
        // SAFETY: one live local buffer, borrowed for the call.
        let needed = unsafe { slopdesk_ws_encode_i32(-1, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 4);
        assert_eq!(out, [0xFF, 0xFF, 0xFF, 0xFF]);
        // SAFETY: as above.
        let needed = unsafe { slopdesk_ws_encode_i32(i32::MIN, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 4);
        assert_eq!(out, [0x80, 0, 0, 0], "big-endian, sign bit first");
    }

    #[test]
    fn a_short_buffer_is_told_its_width_and_written_to_not_at_all() {
        let mut out = [7_u8; 4];
        // SAFETY: one live local buffer, borrowed with a deliberately short `cap`.
        let needed = unsafe { slopdesk_ws_encode_i32(-9, out.as_mut_ptr(), 3) };
        assert_eq!(needed, 4);
        assert_eq!(
            out,
            [7, 7, 7, 7],
            "nothing was written, so a retry sees its own bytes"
        );
    }
}
