//! How the reference sheet deals its runs of shortcuts into columns, in C.
//!
//! The rule is `slopdesk_workspace::cheat_sheet`; what is here is the marshalling. It is §4's plain
//! shape at the width of a `u32`: a lent buffer, and a return that is the number of ELEMENTS the
//! answer needs — one per section, so a caller that lent too little is told exactly how many.
//!
//! Nothing about a binding crosses. The caller hands over row COUNTS and gets back column INDICES
//! against its own section order, which is why the same door serves a two-column desktop card and a
//! phone's single column without either of them naming the other's layout.

use slopdesk_workspace::cheat_sheet;

/// Deals `count` sections, whose row counts are at `row_counts`, into `columns` columns.
///
/// Returns how many indices the answer NEEDS — always `count`. When that fits in `cap`, the first
/// `count` slots of `out` hold each section's column index in the caller's own order.
///
/// # Safety
/// `row_counts` must be null or point to `count` readable, aligned `u32`s, and `out` must be null
/// or point to `cap` writable, aligned `u32`s, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cheat_sheet_columns(
    row_counts: *const u32,
    count: usize,
    columns: u32,
    out: *mut u32,
    cap: usize,
) -> usize {
    if row_counts.is_null() || count == 0 {
        return 0;
    }
    // SAFETY: the caller's obligation — `count` readable, aligned `u32`s for this call.
    let counts = unsafe { core::slice::from_raw_parts(row_counts, count) };
    let assignment = cheat_sheet::column_assignment(counts, columns);
    if out.is_null() || cap < assignment.len() {
        return assignment.len();
    }
    // SAFETY: non-null, and by the caller's obligation writable for `cap` — which the check above
    // proved is at least as long as the answer.
    let room = unsafe { core::slice::from_raw_parts_mut(out, cap) };
    for (slot, column) in room.iter_mut().zip(&assignment) {
        *slot = *column;
    }
    assignment.len()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::slopdesk_cheat_sheet_columns;

    #[test]
    fn a_lent_buffer_takes_one_index_per_section() {
        let counts = [18_u32, 4, 3, 2];
        let mut out = [9_u32; 4];
        let needed =
            unsafe { slopdesk_cheat_sheet_columns(counts.as_ptr(), counts.len(), 2, out.as_mut_ptr(), 4) };
        assert_eq!(needed, 4);
        assert_eq!(out, [0, 1, 1, 1]);
    }

    #[test]
    fn a_short_buffer_is_told_the_size_and_left_alone() {
        let counts = [5_u32, 5, 5, 5];
        let mut out = [9_u32; 2];
        let needed =
            unsafe { slopdesk_cheat_sheet_columns(counts.as_ptr(), counts.len(), 2, out.as_mut_ptr(), 2) };
        assert_eq!(needed, 4, "the answer is the count it should have lent");
        assert_eq!(out, [9, 9], "nothing torn was written");
    }

    #[test]
    fn no_sections_is_no_answer() {
        let mut out = [9_u32; 2];
        let needed = unsafe { slopdesk_cheat_sheet_columns(core::ptr::null(), 0, 2, out.as_mut_ptr(), 2) };
        assert_eq!(needed, 0);
    }

    #[test]
    fn a_null_buffer_is_a_sizing_call() {
        let counts = [1_u32, 2, 3];
        let needed = unsafe {
            slopdesk_cheat_sheet_columns(counts.as_ptr(), counts.len(), 2, core::ptr::null_mut(), 0)
        };
        assert_eq!(needed, 3);
    }
}
