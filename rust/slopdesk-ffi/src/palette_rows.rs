//! Which half lists a palette verb, in C.
//!
//! The rule is [`slopdesk_workspace::palette_rows`]; what is here is the marshalling, and it is the
//! smallest a table crossing gets — one predicate the near side asks per row while it builds its
//! catalog, plus the count-and-index pair that lets a test walk the far table and prove the two id
//! sets are the same one.
//!
//! ## Why a predicate and not a platform
//!
//! `shown(id, mac)` rather than `platform(id)` on purpose. The near side already knows which slice
//! it was compiled as; what it must never do is turn that back into a `#if` around a row. Handing
//! it a boolean about THIS row keeps the branch on the data, which is the whole point of the table.

use core::ffi::c_uchar;

use slopdesk_workspace::palette_rows;

use crate::{borrow, deliver};

/// Whether the half that identifies as `mac` lists the palette row `(id, len)`.
///
/// An id no row declares is SHOWN — see the rule module: a typo must not silently delete a row, and
/// `rust/slopdesk-invariants` is what makes an undeclared id impossible.
///
/// # Safety
/// `(id, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_palette_row_shown(id: *const c_uchar, len: usize, mac: bool) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(id, len) };
    palette_rows::shown(&String::from_utf8_lossy(bytes), mac)
}

/// How many verbs the table declares.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_palette_row_count() -> usize {
    palette_rows::ROWS.len()
}

/// One declared id, by position. `0` past the end.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_palette_row_id(index: usize, out: *mut c_uchar, cap: usize) -> usize {
    let Some(row) = palette_rows::ROWS.get(index) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(row.id.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{slopdesk_palette_row_count, slopdesk_palette_row_id, slopdesk_palette_row_shown};

    fn shown(id: &str, mac: bool) -> bool {
        // SAFETY: the pointer names a live local for the duration of the call.
        unsafe { slopdesk_palette_row_shown(id.as_ptr(), id.len(), mac) }
    }

    fn id_at(index: usize) -> String {
        let mut buffer = [0_u8; 128];
        // SAFETY: the buffer is a live local for the duration of the call.
        let written = unsafe { slopdesk_palette_row_id(index, buffer.as_mut_ptr(), buffer.len()) };
        // Nothing in this table is longer than the buffer, so a truncated read is the failure.
        String::from_utf8_lossy(buffer.get(..written).unwrap_or_default()).into_owned()
    }

    #[test]
    fn the_window_verbs_cross_as_the_macs_alone() {
        assert!(shown("action.detachPane", true));
        assert!(!shown("action.detachPane", false));
        assert!(!shown("action.pinWindow", false));
        assert!(shown("action.copyPath", false));
    }

    #[test]
    fn the_whole_table_is_walkable_and_stops_at_the_end() {
        let count = slopdesk_palette_row_count();
        assert!(count > 0);
        for index in 0..count {
            assert!(id_at(index).starts_with("action."), "row {index} crossed blank");
        }
        assert!(id_at(count).is_empty(), "past the end is nothing, not a panic");
    }

    #[test]
    fn a_null_id_is_the_empty_one_and_is_still_shown() {
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        assert!(unsafe { slopdesk_palette_row_shown(std::ptr::null(), 0, true) });
    }
}
