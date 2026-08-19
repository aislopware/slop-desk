//! Which half lists a KEYBINDING, in C.
//!
//! The rule is [`slopdesk_workspace::binding_rows`]; what is here is the marshalling, and it is the
//! same three doors [`crate::palette_rows`] opens for the palette's own id space — one predicate
//! the registry asks per row while it builds its table, plus the count-and-index pair a parity test
//! walks to prove the two id sets are the same one.
//!
//! Two id spaces, two tables, two door sets. Merging them would mean a door that takes a spelling
//! discriminator, which is the join-by-hand the rule module declines to maintain.

use core::ffi::c_uchar;

use slopdesk_workspace::binding_rows;

use crate::{borrow, deliver};

/// Whether the half that identifies as `mac` lists the binding row `(id, len)`.
///
/// An id no row declares is SHOWN — see the rule module: a typo must not silently unbind a chord.
///
/// # Safety
/// `(id, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_binding_row_shown(id: *const c_uchar, len: usize, mac: bool) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(id, len) };
    binding_rows::shown(&String::from_utf8_lossy(bytes), mac)
}

/// How many binding rows the table declares.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_binding_row_count() -> usize {
    binding_rows::ROWS.len()
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
pub unsafe extern "C" fn slopdesk_binding_row_id(index: usize, out: *mut c_uchar, cap: usize) -> usize {
    let Some(row) = binding_rows::ROWS.get(index) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(row.id.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{slopdesk_binding_row_count, slopdesk_binding_row_id, slopdesk_binding_row_shown};

    fn shown(id: &str, mac: bool) -> bool {
        // SAFETY: the pointer names a live local for the duration of the call.
        unsafe { slopdesk_binding_row_shown(id.as_ptr(), id.len(), mac) }
    }

    fn id_at(index: usize) -> String {
        let mut buffer = [0_u8; 128];
        // SAFETY: the buffer is a live local for the duration of the call.
        let written = unsafe { slopdesk_binding_row_id(index, buffer.as_mut_ptr(), buffer.len()) };
        // Nothing in this table is longer than the buffer, so a truncated read is the failure.
        String::from_utf8_lossy(buffer.get(..written).unwrap_or_default()).into_owned()
    }

    #[test]
    fn the_window_rows_cross_as_the_macs_alone() {
        assert!(shown("pane.detach", true));
        assert!(!shown("pane.detach", false));
        assert!(!shown("view.pinWindow", false));
        assert!(shown("pane.close", false));
    }

    #[test]
    fn the_whole_table_is_walkable_and_stops_at_the_end() {
        let count = slopdesk_binding_row_count();
        assert!(count > 0);
        for index in 0..count {
            assert!(
                id_at(index).contains('.'),
                "row {index} crossed blank or unqualified"
            );
        }
        assert!(id_at(count).is_empty(), "past the end is nothing, not a panic");
    }

    #[test]
    fn a_null_id_is_the_empty_one_and_is_still_shown() {
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        assert!(unsafe { slopdesk_binding_row_shown(std::ptr::null(), 0, true) });
    }
}
