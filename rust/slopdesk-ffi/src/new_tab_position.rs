//! Where a newly opened tab lands in the tab bar, in C.
//!
//! One door over [`slopdesk_tree::NewTabPosition`]: the `new-tab-position` policy's
//! placement arithmetic, plus the two clamps that keep its answer a VALID insertion index for a
//! list whose count and active index both arrive from a restored document.
//!
//! ## The rule was doubled, and the copy that had every caller was the one with no production one
//! `NewTabPosition.swift` carried the same three-case arithmetic and the same clamps, and it looked
//! live: a public method, a doc comment arguing for it, four test cases pinning the hostile inputs.
//! It had no production caller at all. Every real ⌘T and ⇧⌘T encodes the policy as a BYTE into a
//! workspace intent, and `slopdesk_tree::tree_ops` computes the index on the far side — so the
//! Swift arithmetic answered only its own tests, which is the worst possible arrangement for a pair
//! that has to agree. A drift there is not a red test; it is a green suite over a function nothing
//! runs, sitting next to the one that decides where the tab actually goes.
//!
//! ## Why the policy crosses as its CONFIG SPELLING and not as its byte
//! A byte would have been the obvious shape — the intent wire already spells one, and
//! `WorkspaceIntent.positionByte` is where. Reaching for it here would have meant a THIRD map from
//! the same three cases to the same three numbers, written in the one file that had just stopped
//! holding a copy of anything.
//!
//! The spelling costs nothing extra instead. `auto` / `end` / `after-current` IS the Swift enum's
//! `rawValue`, which is what the settings store persists, what the config file writes, and what
//! `slopdesk_settings::settings_catalog` already vends as this group's option TOKENS — so both
//! sides were spelling it anyway and `SettingsOptionCatalogTests` already fails if they disagree. A
//! token nobody recognises reads as the default rather than refusing, which is the same repair the
//! client's own settings bridge makes for a stale persisted value; the crate owns that fallback so
//! it is one answer rather than two.

use core::ffi::c_uchar;

use slopdesk_tree::NewTabPosition;

use crate::borrow;

/// The index a new tab is inserted at, under the policy `position` names.
///
/// A scalar answer with no refusal in it, because there is nothing here that could fail to have
/// one: every policy places every list, and a list too short or an active index past its end are
/// states the arithmetic is defined on rather than errors. So `0` is a real answer — it is where a
/// tab lands in an empty bar — and §4's "`0` means there is no answer" does not apply, which is why
/// this returns a signed count rather than a `size_t`.
///
/// Both counts are SIGNED for the caller's sake: a client counts tabs in `Int` and reads an active
/// index out of a document that may have lost tabs since it was written, so the impossible values
/// are reachable there. The crate clamps them — a negative count is no tabs, a negative active
/// index is the first one — and the answer is always in `0..=max(tab_count, 0)`.
///
/// # Safety
/// `(position, position_len)` must be null, or describe `position_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_new_tab_index(
    position: *const c_uchar,
    position_len: usize,
    active_index: i64,
    tab_count: i64,
) -> i64 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(position, position_len) };
    // Bytes that are not UTF-8 are not one of three ASCII spellings either, so they take the same
    // path a misspelling does. Which path that IS remains the crate's answer, not this module's.
    let spelling = core::str::from_utf8(bytes).unwrap_or_default();
    NewTabPosition::from_raw_or_default(spelling).insertion_index_signed(active_index, tab_count)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_tree::NewTabPosition;

    use super::slopdesk_ws_new_tab_index;

    fn index(position: &str, active: i64, count: i64) -> i64 {
        // SAFETY: the pointer names a live local for the duration of the call.
        unsafe { slopdesk_ws_new_tab_index(position.as_ptr(), position.len(), active, count) }
    }

    /// Walked rather than named: a fourth policy added to the vocabulary is invisible to a test
    /// that lists the three it was written against.
    #[test]
    fn every_spelling_crosses_as_the_placement_its_own_case_makes() {
        for position in NewTabPosition::ALL {
            for active in 0..4_i64 {
                for count in 0..4_i64 {
                    assert_eq!(
                        index(position.raw(), active, count),
                        position.insertion_index_signed(active, count),
                        "{} placed differently across the boundary",
                        position.raw(),
                    );
                }
            }
        }
    }

    #[test]
    fn the_two_appending_policies_answer_the_end_and_after_current_answers_the_next_slot() {
        assert_eq!(index("auto", 0, 3), 3);
        assert_eq!(index("end", 0, 3), 3);
        assert_eq!(index("after-current", 0, 3), 1);
        assert_eq!(index("after-current", 1, 3), 2);
        assert_eq!(index("after-current", 2, 3), 3, "after the last tab is the end");
    }

    #[test]
    fn a_hostile_count_or_active_index_still_answers_a_valid_insertion_index() {
        assert_eq!(
            index("after-current", -5, 3),
            1,
            "a negative active index is the first tab"
        );
        assert_eq!(index("after-current", 99, 3), 3);
        assert_eq!(index("after-current", 0, 0), 0);
        assert_eq!(index("end", 3, -1), 0, "a negative count is no tabs");
        assert_eq!(index("after-current", i64::MIN, i64::MIN), 0);
    }

    #[test]
    fn a_spelling_this_build_has_never_had_places_the_tab_where_the_default_does() {
        let appended = NewTabPosition::default().insertion_index_signed(1, 3);
        assert_eq!(
            index("afterCurrent", 1, 3),
            appended,
            "the camel-case spelling is not one"
        );
        assert_eq!(index("", 1, 3), appended);
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        assert_eq!(
            unsafe { slopdesk_ws_new_tab_index(std::ptr::null(), 0, 1, 3) },
            appended
        );
    }

    #[test]
    fn bytes_that_are_not_utf8_place_the_tab_where_an_unknown_spelling_does() {
        let bytes = [0xFF_u8, 0xFE];
        // SAFETY: the pointer names a live local for the duration of the call.
        let answer = unsafe { slopdesk_ws_new_tab_index(bytes.as_ptr(), bytes.len(), 1, 3) };
        assert_eq!(answer, NewTabPosition::default().insertion_index_signed(1, 3));
    }
}
