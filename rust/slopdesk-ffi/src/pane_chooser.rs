//! What a pane kind is CALLED, in C.
//!
//! The table is `slopdesk_workspace::pane_chooser`; what is here is the marshalling.
//!
//! `docs/55` §6's group shape: one kind's four facts cross as ONE delivery rather than as four
//! doors, because a surface that drew the title from one call and the symbol from another could
//! draw a row for two different kinds if a kind byte ever changed between them.

use core::ffi::c_uchar;

use slopdesk_workspace::pane_chooser;

use crate::{deliver, push_text};

/// One kind's presentation row, in one delivery.
///
/// ```text
/// [u8 is_video]
/// 3 × [u32 length][UTF-8 bytes]   // title, SF Symbol name, mnemonic
/// ```
///
/// The mnemonic rides as TEXT rather than as a byte: it is one character today and every one of
/// them is ASCII, but a `u8` would make the first non-ASCII mnemonic a silent truncation rather
/// than a wider field.
///
/// `is_video` is the KIND's own answer, read through the table rather than stored beside it — the
/// duplication the Swift value type this replaces admitted to in the word "mirrors".
///
/// `kind` is a wire kind byte and is TOTAL: an unknown one draws the terminal row, so `0` is
/// unreachable — every row has a title.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_kind_option(kind: c_uchar, out: *mut c_uchar, cap: usize) -> usize {
    let option = pane_chooser::option_for_byte(kind);
    let mut blob = vec![u8::from(option.is_video)];
    let mut mnemonic = [0_u8; 4];
    push_text(&mut blob, option.title);
    push_text(&mut blob, option.symbol);
    push_text(&mut blob, option.mnemonic.encode_utf8(&mut mnemonic));
    // SAFETY: the caller's buffer obligation, forwarded unchanged.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    reason = "a delivery this side cannot cut back apart IS the report"
)]
#[expect(
    clippy::indexing_slicing,
    reason = "cutting the delivery at the lengths it carries IS the test"
)]
mod tests {
    use super::slopdesk_ws_pane_kind_option;

    /// The delivery, cut the way the Swift face cuts it.
    fn row(kind: u8) -> (bool, String, String, String) {
        let mut out = [0_u8; 128];
        // SAFETY: `out` is a live local buffer of exactly the length passed.
        let needed = unsafe { slopdesk_ws_pane_kind_option(kind, out.as_mut_ptr(), out.len()) };
        assert!(needed > 0 && needed <= out.len(), "the row must fit");
        let blob = &out[..needed];
        let is_video = blob[0] == 1;
        let mut cursor = 1;
        let mut fields: Vec<String> = Vec::new();
        for _ in 0..3 {
            let length = usize::try_from(u32::from_be_bytes(
                blob[cursor..cursor + 4].try_into().expect("four bytes of length"),
            ))
            .unwrap_or_default();
            cursor += 4;
            fields.push(String::from_utf8(blob[cursor..cursor + length].to_vec()).expect("UTF-8 field"));
            cursor += length;
        }
        assert_eq!(cursor, needed, "the delivery is consumed exactly");
        (is_video, fields[0].clone(), fields[1].clone(), fields[2].clone())
    }

    #[test]
    fn each_kind_crosses_whole_and_in_one_piece() {
        assert_eq!(
            row(0),
            (
                false,
                "Terminal".to_owned(),
                "apple.terminal".to_owned(),
                "t".to_owned()
            )
        );
        assert_eq!(
            row(1),
            (true, "Desktop".to_owned(), "display".to_owned(), "d".to_owned())
        );
    }

    #[test]
    fn an_unknown_kind_byte_still_draws_a_row() {
        assert_eq!(row(9), row(0));
        assert_eq!(row(255), row(0));
    }

    /// The size-then-read protocol: a buffer too small is told how much it needs and left alone.
    #[test]
    fn a_probe_that_did_not_fit_leaves_the_buffer_untouched() {
        let mut out = [0xAA_u8; 4];
        // SAFETY: `out` is a live local buffer of exactly the length passed.
        let needed = unsafe { slopdesk_ws_pane_kind_option(0, out.as_mut_ptr(), out.len()) };
        assert!(needed > out.len());
        assert_eq!(out, [0xAA; 4], "nothing was written");
    }
}
