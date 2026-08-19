//! Keyboard navigation over a rendered list, in C.
//!
//! The rules are `slopdesk_workspace::list_nav`'s; what is here is three pure doors. Nothing
//! crosses through a buffer at all: every rule reads a count and answers an INDEX into the list the
//! caller already holds, so the rows themselves never leave Swift.
//!
//! `-1` is the "no index" answer for the two that can decline, which no real index can be.

use slopdesk_workspace::list_nav;

/// A selection index moved by `delta` and clamped to `[0, count - 1]`; `0` for an empty list.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_list_clamped_selection(current: i64, delta: i64, count: i64) -> i64 {
    list_nav::clamped_selection(current, delta, count)
}

/// The 0-based row a `⌘1–9` chord names, or `-1` for `⌘0`, a chord above nine, and a chord past the
/// rows on screen.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_list_quick_pick(one_based: i64, row_count: usize) -> i64 {
    match list_nav::quick_pick_index(one_based, row_count) {
        #[expect(
            clippy::cast_possible_wrap,
            reason = "the answer is below the caller's row count, which came across as a usize"
        )]
        Some(index) => index as i64,
        None => -1,
    }
}

/// The entry `delta` steps around a ring of `count`, wrapping; `-1` for an empty ring or a starting
/// index that is not in it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_list_wrapped_index(index: usize, delta: i64, count: usize) -> i64 {
    match list_nav::wrapped_index(index, delta, count) {
        #[expect(
            clippy::cast_possible_wrap,
            reason = "the answer is below the caller's ring size, which came across as a usize"
        )]
        Some(wrapped) => wrapped as i64,
        None => -1,
    }
}

#[cfg(test)]
mod tests {
    use super::{slopdesk_list_clamped_selection, slopdesk_list_quick_pick, slopdesk_list_wrapped_index};

    #[test]
    fn the_clamp_crosses_with_both_ends_and_the_empty_list() {
        assert_eq!(slopdesk_list_clamped_selection(0, 1, 3), 1);
        assert_eq!(slopdesk_list_clamped_selection(2, 1, 3), 2);
        assert_eq!(slopdesk_list_clamped_selection(0, -1, 3), 0);
        assert_eq!(slopdesk_list_clamped_selection(4, 1, 0), 0);
    }

    #[test]
    fn a_pick_that_names_nothing_crosses_as_the_sentinel() {
        assert_eq!(slopdesk_list_quick_pick(1, 5), 0);
        assert_eq!(slopdesk_list_quick_pick(3, 5), 2);
        assert_eq!(slopdesk_list_quick_pick(0, 5), -1);
        assert_eq!(slopdesk_list_quick_pick(4, 3), -1);
    }

    #[test]
    fn the_ring_wraps_and_declines_what_it_cannot_step() {
        assert_eq!(slopdesk_list_wrapped_index(3, 1, 4), 0);
        assert_eq!(slopdesk_list_wrapped_index(0, -1, 4), 3);
        assert_eq!(slopdesk_list_wrapped_index(0, 1, 0), -1);
        assert_eq!(slopdesk_list_wrapped_index(9, 1, 4), -1);
    }
}
