//! Where a copy-mode cursor lands on ONE terminal row, in C.
//!
//! Nine doors over [`slopdesk_terminal::vimotion`], and none of them takes §4's `(out, cap)` shape:
//! every answer is a single column, so there is nothing to size and nothing to retry. The row
//! crosses as `(ptr, len)` UTF-8 and the answer crosses as an `isize`.
//!
//! ## Why `isize` and not `usize`
//!
//! Half these motions can fail to land — `w` off the last word, `b` at the row's start — and that
//! failure is not an error but a WRAP: the caller moves to the neighbouring row and asks again. A
//! `usize` has no room for it, and §4's "0 means no answer" cannot be borrowed here because column
//! `0` is the most common landing there is. So [`NO_LANDING`] is `-1`, and every non-negative
//! answer is a real column. The motions that always land ([`slopdesk_vi_first_non_blank`],
//! [`slopdesk_vi_column_step`], [`slopdesk_vi_snap_to_cell`], [`slopdesk_vi_cell_width`]) never
//! return it.
//!
//! ## What is NOT here
//!
//! The motions. Which cells are addressable, what vim counts as a word, and how a wide glyph
//! occupies two columns but takes one step are `slopdesk-terminal`'s, in a crate that forbids
//! `unsafe` and shares its grapheme clustering with the link scanner — which is the whole point of
//! the row's columns being computed there rather than in the view.

use core::ffi::c_uchar;

use slopdesk_terminal::vimotion;

use crate::borrow;

/// The motion ran off the row's end or start — wrap to the neighbouring row and ask again.
pub const NO_LANDING: isize = -1;

/// Reads `(line, len)` as UTF-8, lossily.
///
/// A row that is not valid UTF-8 is repaired rather than refused: it came off a PTY, and refusing
/// would freeze the cursor on exactly the row a stray byte landed in.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[expect(
    unsafe_code,
    reason = "the one place these nine doors turn a caller's `(ptr, len)` into a row"
)]
unsafe fn row<'a>(line: *const c_uchar, len: usize) -> std::borrow::Cow<'a, str> {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    String::from_utf8_lossy(unsafe { borrow(line, len) })
}

/// A landing column as an `isize`, saturating rather than wrapping on a row wider than `isize::MAX`
/// — which no terminal has, and which would otherwise read as [`NO_LANDING`].
fn landed(col: usize) -> isize {
    isize::try_from(col).unwrap_or(isize::MAX)
}

/// An optional landing, with [`NO_LANDING`] for the wrap.
fn optional(col: Option<usize>) -> isize {
    col.map_or(NO_LANDING, landed)
}

/// `^` — the first non-blank cell's column, or `0` on a blank row. Always lands.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_first_non_blank(line: *const c_uchar, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    landed(vimotion::first_non_blank(&unsafe { row(line, len) }))
}

/// `$` — the LAST non-blank cell's column, or [`NO_LANDING`] on a blank row.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_last_non_blank(line: *const c_uchar, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    optional(vimotion::last_non_blank(&unsafe { row(line, len) }))
}

/// `w` — the start of the next word/punct run after `col`, or [`NO_LANDING`] off the row's end.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_next_word_start(line: *const c_uchar, len: usize, col: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    optional(vimotion::next_word_start(&unsafe { row(line, len) }, col))
}

/// `b` — the current run's start when the cursor sits inside one, else the previous run's;
/// [`NO_LANDING`] off the row's start.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_prev_word_start(line: *const c_uchar, len: usize, col: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    optional(vimotion::prev_word_start(&unsafe { row(line, len) }, col))
}

/// `e` — the current run's end when the cursor is before it, else the next run's; [`NO_LANDING`]
/// off the row's end.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_word_end(line: *const c_uchar, len: usize, col: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    optional(vimotion::word_end(&unsafe { row(line, len) }, col))
}

/// The start of the row's final run — where a backward wrap lands — or [`NO_LANDING`] on a blank
/// row.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_last_word_start(line: *const c_uchar, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    optional(vimotion::last_word_start(&unsafe { row(line, len) }))
}

/// `h`/`l` — the column `delta` GLYPHS from `col`, clamped inside the row's text. Always lands.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_column_step(
    line: *const c_uchar,
    len: usize,
    col: usize,
    delta: isize,
) -> isize {
    // SAFETY: the caller's obligation, restated above.
    landed(vimotion::column_step(&unsafe { row(line, len) }, col, delta))
}

/// The addressable cell containing `col` — the wide-glyph and padding snap. Always lands.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_snap_to_cell(line: *const c_uchar, len: usize, col: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    landed(vimotion::snap_to_cell(&unsafe { row(line, len) }, col))
}

/// The block cursor's drawn width at `col`, in cells. Never `0`, always lands.
///
/// # Safety
/// `(line, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vi_cell_width(line: *const c_uchar, len: usize, col: usize) -> isize {
    // SAFETY: the caller's obligation, restated above.
    landed(vimotion::cell_width(&unsafe { row(line, len) }, col))
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        NO_LANDING, slopdesk_vi_cell_width, slopdesk_vi_column_step, slopdesk_vi_first_non_blank,
        slopdesk_vi_last_non_blank, slopdesk_vi_last_word_start, slopdesk_vi_next_word_start,
        slopdesk_vi_prev_word_start, slopdesk_vi_snap_to_cell, slopdesk_vi_word_end,
    };

    #[test]
    fn the_wrap_crosses_as_a_negative_and_column_zero_stays_a_column() {
        let line = "foo bar";
        // SAFETY: each pointer names a live local for the duration of its call.
        unsafe {
            assert_eq!(slopdesk_vi_next_word_start(line.as_ptr(), line.len(), 0), 4);
            assert_eq!(
                slopdesk_vi_next_word_start(line.as_ptr(), line.len(), 4),
                NO_LANDING
            );
            assert_eq!(
                slopdesk_vi_prev_word_start(line.as_ptr(), line.len(), 4),
                0,
                "column 0"
            );
            assert_eq!(
                slopdesk_vi_prev_word_start(line.as_ptr(), line.len(), 0),
                NO_LANDING
            );
            assert_eq!(slopdesk_vi_word_end(line.as_ptr(), line.len(), 0), 2);
            assert_eq!(slopdesk_vi_last_word_start(line.as_ptr(), line.len()), 4);
        }
    }

    #[test]
    fn the_always_landing_doors_answer_on_a_blank_row_rather_than_wrapping() {
        let blank = "   ";
        // SAFETY: each pointer names a live local for the duration of its call.
        unsafe {
            assert_eq!(slopdesk_vi_first_non_blank(blank.as_ptr(), blank.len()), 0);
            assert_eq!(slopdesk_vi_column_step(blank.as_ptr(), blank.len(), 2, 1), 0);
            assert_eq!(slopdesk_vi_snap_to_cell(blank.as_ptr(), blank.len(), 2), 0);
            assert_eq!(slopdesk_vi_cell_width(blank.as_ptr(), blank.len(), 2), 1);
            assert_eq!(
                slopdesk_vi_last_non_blank(blank.as_ptr(), blank.len()),
                NO_LANDING
            );
        }
    }

    #[test]
    fn a_wide_glyph_crosses_as_two_cells_and_one_step() {
        let line = "a中b";
        // SAFETY: each pointer names a live local for the duration of its call.
        unsafe {
            assert_eq!(slopdesk_vi_cell_width(line.as_ptr(), line.len(), 1), 2);
            assert_eq!(slopdesk_vi_column_step(line.as_ptr(), line.len(), 1, 1), 3);
            assert_eq!(
                slopdesk_vi_snap_to_cell(line.as_ptr(), line.len(), 2),
                1,
                "mid-glyph"
            );
        }
    }

    #[test]
    fn a_null_row_is_the_empty_one() {
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        unsafe {
            assert_eq!(slopdesk_vi_first_non_blank(std::ptr::null(), 0), 0);
            assert_eq!(slopdesk_vi_next_word_start(std::ptr::null(), 0, 0), NO_LANDING);
        }
    }
}
