//! Moving a keyboard SELECTION over a list somebody is looking at.
//!
//! [`rail_list`](crate::rail_list) decides which rows exist and in what order. This decides where
//! the highlight goes when an arrow, a page key, a Home/End, a Tab or a `⌘1–9` chord arrives — over
//! any list, because the rule reads nothing but a count.
//!
//! Three overlays each had their own copy: the picker, the command navigator and the palette. All
//! three clamped with the same `max(0, min(count - 1, current + delta))`, and a fourth surface
//! would have written it again.
//!
//! ## Clamp, never wrap — except the pill ring
//!
//! A LIST clamps: arrowing past the last row leaves the highlight on the last row, which is what
//! every macOS list does and what the person expects when they hold the key down. A RING wraps,
//! because it has no ends to sit against — Tab through the picker's filter pills comes back around
//! to the first. Both are here so that "which one is this list?" is a choice of function rather
//! than a detail somebody re-derives.
//!
//! ## Saturating, not wrapping, arithmetic
//!
//! `current + delta` is computed with saturating adds. A page key over a list of two rows sends a
//! delta of a viewport's worth, Home/End send the whole count, and a caller is free to pass
//! `i64::MIN`; none of that may produce an index, and none of it may trap.

/// Moves a selection index by `delta` and clamps it to `[0, count - 1]`.
///
/// The SHARED contract for arrow (`±1`), page (`±page`) and Home/End (`±count`) navigation. An
/// empty list — any `count <= 0` — answers `0`, which is the index every one of those surfaces
/// stores while it has nothing to select.
#[must_use]
pub const fn clamped_selection(current: i64, delta: i64, count: i64) -> i64 {
    if count <= 0 {
        return 0;
    }
    let proposed = current.saturating_add(delta);
    if proposed < 0 {
        return 0;
    }
    let last = count - 1;
    if proposed > last { last } else { proposed }
}

/// The index a `⌘1–9` quick-pick chord names in a list of `row_count` visible rows.
///
/// `None` for `⌘0` — which is a filter chord, never a pick — for a chord above nine, and for a
/// chord past the rows actually on screen. The digit is 1-based because the keyboard is; the answer
/// is 0-based because the list is.
#[must_use]
pub const fn quick_pick_index(one_based: i64, row_count: usize) -> Option<usize> {
    if one_based < 1 || one_based > 9 {
        return None;
    }
    #[expect(
        clippy::cast_sign_loss,
        clippy::cast_possible_truncation,
        reason = "the range check above bounds the value to 1..=9"
    )]
    let index = (one_based - 1) as usize;
    if index < row_count { Some(index) } else { None }
}

/// The index `delta` steps around a ring of `count` entries, WRAPPING at both ends.
///
/// `None` for an empty ring, and for a starting index that is not in it — a caller whose current
/// value is not one of the entries has nothing to step from, and inventing a first entry for it
/// would move a selection nobody asked to move.
#[must_use]
pub const fn wrapped_index(index: usize, delta: i64, count: usize) -> Option<usize> {
    if count == 0 || index >= count {
        return None;
    }
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a ring nobody scrolls is far below i64::MAX entries; the guard above bounds it"
    )]
    let modulus = count as i64;
    #[expect(
        clippy::cast_possible_wrap,
        reason = "index < count, and count was just shown to fit"
    )]
    let from = index as i64;
    // `((i + d) % n + n) % n` — the second fold is what keeps a negative delta in range instead of
    // answering a negative index. The adds saturate, and a saturated value is still folded by the
    // same modulus, so the answer stays inside the ring whatever the caller passed.
    let wrapped = (from.saturating_add(delta) % modulus + modulus) % modulus;
    #[expect(
        clippy::cast_sign_loss,
        clippy::cast_possible_truncation,
        reason = "the double fold leaves a value in 0..modulus, and modulus came from a usize"
    )]
    let wrapped = wrapped as usize;
    Some(wrapped)
}

#[cfg(test)]
mod tests {
    use super::{clamped_selection, quick_pick_index, wrapped_index};

    #[test]
    fn an_arrow_moves_one_row_and_stops_at_both_ends() {
        assert_eq!(clamped_selection(0, 1, 3), 1);
        assert_eq!(clamped_selection(2, 1, 3), 2);
        assert_eq!(clamped_selection(0, -1, 3), 0);
    }

    #[test]
    fn a_page_or_a_home_end_key_is_the_same_clamp_with_a_bigger_delta() {
        assert_eq!(clamped_selection(1, 10, 3), 2);
        assert_eq!(clamped_selection(2, -10, 3), 0);
        // End, the way the picker spells it: from the top, by the whole list.
        assert_eq!(clamped_selection(0, 9 - 1, 9), 8);
    }

    #[test]
    fn an_empty_list_selects_the_index_every_surface_stores_for_nothing() {
        assert_eq!(clamped_selection(4, 1, 0), 0);
        assert_eq!(clamped_selection(4, 1, -3), 0);
    }

    #[test]
    fn a_delta_at_the_edge_of_the_integer_saturates_rather_than_wrapping() {
        assert_eq!(clamped_selection(1, i64::MAX, 5), 4);
        assert_eq!(clamped_selection(1, i64::MIN, 5), 0);
    }

    #[test]
    fn a_quick_pick_names_the_row_under_the_digit() {
        assert_eq!(quick_pick_index(1, 5), Some(0));
        assert_eq!(quick_pick_index(3, 5), Some(2));
    }

    #[test]
    fn the_filter_chord_and_everything_off_the_screen_pick_nothing() {
        assert_eq!(quick_pick_index(0, 5), None);
        assert_eq!(quick_pick_index(10, 20), None);
        assert_eq!(quick_pick_index(4, 3), None);
        assert_eq!(quick_pick_index(1, 0), None);
    }

    #[test]
    fn a_ring_comes_back_around_at_both_ends() {
        assert_eq!(wrapped_index(0, 1, 4), Some(1));
        assert_eq!(wrapped_index(3, 1, 4), Some(0));
        assert_eq!(wrapped_index(0, -1, 4), Some(3));
    }

    #[test]
    fn a_ring_with_nothing_to_step_from_does_not_move_the_selection() {
        assert_eq!(wrapped_index(0, 1, 0), None);
        assert_eq!(wrapped_index(7, 1, 4), None);
    }

    #[test]
    fn a_ring_folds_a_delta_of_any_size() {
        assert_eq!(wrapped_index(1, 9, 4), Some(2));
        assert_eq!(wrapped_index(1, -9, 4), Some(0));
        assert!(wrapped_index(1, i64::MIN, 4).is_some());
        assert!(wrapped_index(1, i64::MAX, 4).is_some());
    }
}
