//! The caret colour codec, in C — `Sources/SlopDeskClientCore/Settings/CursorColorHex.swift`.
//!
//! The rules are [`slopdesk_terminal::cursor_color`]; what is here is the marshalling. Two doors,
//! one each way, because the two wells above them run in opposite directions: a stored
//! `cursor-color` string becomes the channels a colour well shows, and the channels a person picked
//! become the string [`slopdesk_terminal::config`] emits.
//!
//! ## Why the parse answers a packed `int32_t` rather than three channels and a flag
//!
//! `docs/55` §4b's rule is that an `Option` crosses as a value PLUS A FLAG, never as a sentinel,
//! and §4's paragraph on `slopdesk_fuzzy_rank` is the exception it names: a sentinel is admissible
//! when it is outside the answer's range BY CONSTRUCTION OF THE ALGORITHM rather than by a
//! convention somebody has to remember. That is the case here and it is worth stating exactly. The
//! answer is three bytes packed into the low 24 bits of a signed 32-bit word, so every colour this
//! door can name lies in `0x000000..=0xFFFFFF`; nothing the packing does can set a bit above the
//! 24th, let alone the sign bit. `-1` is not a magic number the near side has to know about — it is
//! a value the arithmetic cannot produce.
//!
//! The other defensible shape was a `uint32_t` answer beside a `bool *found`, and it was not taken
//! because it buys nothing: a second pointer, a second lifetime to argue about and a Swift `var` at
//! every call site, in order to separate two states that one signed word already separates. An
//! out-param earns its place where the payload genuinely uses its whole range — the doc's example
//! is `slopdesk_reassembler_next_dropped_frame`, where every `u32` is a legal frame id and no value
//! could have meant "none". Twenty-four bits of colour inside thirty-two bits of answer is the
//! opposite case.
//!
//! ## Why the format side is an ordinary `(out, cap)` delivery
//!
//! Six ASCII bytes would fit in a `uint64_t`, and packing them there would be a third convention
//! for a saving of nothing: the near side wants a `String`, so it would unpack the word into bytes
//! and decode them anyway. §4's shape is what it already reads every other text answer through, and
//! the retry it carries is unreachable at a fixed six.

use core::ffi::c_uchar;

use slopdesk_terminal::cursor_color::{self, CursorRgb};

use crate::{borrow, deliver};

/// The three channels in the low 24 bits, red highest — the same order the hex string spells.
///
/// Not `const`, and the reason is worth one line so nobody tries again: the widening is
/// `i32::From`, which is not a stable const trait, and the alternative — three `as i32` casts —
/// would trade a keyword nothing needs for three lint suppressions on a conversion that cannot lose
/// anything.
fn packed(color: CursorRgb) -> i32 {
    (i32::from(color.red) << 16) | (i32::from(color.green) << 8) | i32::from(color.blue)
}

/// The `0…255` channels a 6-hex `cursor-color` string names, or `-1` for a string that names none.
///
/// The answer is `(red << 16) | (green << 8) | blue`, so the near side masks it apart the way it
/// would any packed colour. `-1` cannot collide with a colour: the packing only ever writes the low
/// 24 bits, which is what makes a sentinel admissible here at all (see the module note).
///
/// A refusal covers every reason there is no colour — the empty "follow the theme" spelling, the
/// wrong length, a non-hex character — because the caller does the same thing for all of them,
/// which is show the effective default. Bytes that are not UTF-8 are refused for the same reason
/// rather than treated as an error of their own: a `cursor-color` value that is not text is not a
/// colour.
///
/// # Safety
/// `(hex, hex_len)` must be readable for `hex_len` bytes, or `hex` must be null with `hex_len` 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(hex, hex_len)` is the caller's pair"
)]
pub unsafe extern "C" fn slopdesk_cursor_color_rgb(hex: *const c_uchar, hex_len: usize) -> i32 {
    // SAFETY: the caller's contract, discharged by Swift's `withUnsafeBufferPointer`, whose scope is
    // exactly this call.
    let bytes = unsafe { borrow(hex, hex_len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return -1;
    };
    cursor_color::rgb(text).map_or(-1, packed)
}

/// Three unit-RGB doubles as the UPPERCASE 6-hex `cursor-color` string, with no leading `#`.
///
/// Always six bytes, so a `cap` of six is the whole story and the §4 retry below it never runs. It
/// is still §4-shaped rather than a fixed-size write, because "nothing was written unless it fits"
/// is what makes a short buffer safe, and a door that opted out of the protocol on the grounds that
/// its answer is always the same size would be a door that stops being safe the day that stops
/// being true.
///
/// Every clamp, the NaN rule and the rounding are the wrapped crate's — the arithmetic that decides
/// which byte a channel becomes may not live in this file, and the reason it may not is that a
/// second rounding rule is precisely the drift a single codec exists to prevent.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes, or `out` must be null with `cap` 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_cursor_color_hex(
    red: f64,
    green: f64,
    blue: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = cursor_color::hex(red, green, blue);
    // SAFETY: the caller's contract.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{slopdesk_cursor_color_hex, slopdesk_cursor_color_rgb};

    fn parse(text: &str) -> i32 {
        // SAFETY: the pair is a live local for the duration of the call.
        unsafe { slopdesk_cursor_color_rgb(text.as_ptr(), text.len()) }
    }

    fn format(red: f64, green: f64, blue: f64) -> String {
        let mut buffer = [0_u8; 6];
        // SAFETY: the buffer is a live local.
        let needed =
            unsafe { slopdesk_cursor_color_hex(red, green, blue, buffer.as_mut_ptr(), buffer.len()) };
        buffer
            .get(..needed)
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
            .unwrap_or_default()
    }

    #[test]
    fn a_parsed_colour_arrives_packed_red_highest() {
        assert_eq!(parse("FF8800"), 0x00FF_8800);
        assert_eq!(parse("ff8800"), 0x00FF_8800, "either case, one answer");
        assert_eq!(
            parse("000000"),
            0,
            "black is zero, and zero is a real answer here"
        );
        assert_eq!(parse("FFFFFF"), 0x00FF_FFFF);
    }

    #[test]
    fn every_refusal_is_the_same_refusal_and_it_cannot_be_a_colour() {
        for text in ["", "   ", "12345", "1234567", "#FF8800", "GG0000", "+FF880"] {
            assert_eq!(parse(text), -1, "{text:?} names no colour");
        }
    }

    #[test]
    fn a_null_pair_is_the_empty_string_rather_than_a_crash() {
        // SAFETY: the null/zero pair is what `borrow` documents as empty.
        let answer = unsafe { slopdesk_cursor_color_rgb(core::ptr::null(), 0) };
        assert_eq!(answer, -1, "no colour, which is what an unset preference means");
    }

    #[test]
    fn the_packed_answer_never_reaches_the_sign_bit() {
        // The property the sentinel rests on, asserted over the whole range rather than argued for
        // in a comment: no legal colour can be mistaken for the refusal.
        for red in [0_u8, 1, 127, 128, 254, 255] {
            for green in [0_u8, 255] {
                for blue in [0_u8, 255] {
                    let text = format!("{red:02X}{green:02X}{blue:02X}");
                    let answer = parse(&text);
                    assert!(answer >= 0, "{text} packed negative");
                    assert!(answer <= 0x00FF_FFFF, "{text} packed above 24 bits");
                }
            }
        }
    }

    #[test]
    fn the_format_door_writes_six_uppercase_bytes() {
        assert_eq!(format(1.0, 136.0 / 255.0, 0.0), "FF8800");
        assert_eq!(format(1.5, -0.2, 0.0), "FF0000", "the clamp is the crate's");
        assert_eq!(format(f64::NAN, f64::INFINITY, 0.0), "00FF00");
    }

    #[test]
    fn a_short_output_buffer_reports_its_size_and_writes_nothing() {
        let mut tiny = [0xAA_u8; 3];
        // SAFETY: the buffer is a live local.
        let needed = unsafe { slopdesk_cursor_color_hex(1.0, 1.0, 1.0, tiny.as_mut_ptr(), tiny.len()) };
        assert_eq!(needed, 6);
        assert_eq!(tiny, [0xAA; 3], "an overflow leaves the caller's buffer alone");
    }

    #[test]
    fn a_null_output_buffer_is_the_sizing_call() {
        // SAFETY: `(null, 0)` is the documented way to ask for the length before allocating.
        let needed = unsafe { slopdesk_cursor_color_hex(0.0, 0.0, 0.0, core::ptr::null_mut(), 0) };
        assert_eq!(needed, 6);
    }
}
