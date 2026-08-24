//! The in-pane find bar, in C.
//!
//! The rules are `slopdesk_workspace::find_bar`; what is here is the marshalling.
//!
//! Three of §6's shapes at once: the five fixed words cross as a GROUP, the match counter crosses
//! as a group of one because it is built from live text, the touch/pointer rung crosses BY VALUE as
//! three numbers with no interior, and the toggle's appearance crosses as a SCALAR.

use core::ffi::c_uchar;

use slopdesk_workspace::find_bar::{
    self, CLOSE_HELP, NEXT_MATCH_HELP, PLACEHOLDER, PREVIOUS_MATCH_HELP, Rung, SEARCH_ALL_TABS_HELP,
    TogglePillAppearance,
};

use crate::{borrow, deliver, push_text};

/// The find bar's three measurements at one input class.
///
/// By value, on [`CDwellGate`](crate::chrome::CDwellGate)'s argument: three numbers with no
/// interior, wanted together, and a caller that asked for them one at a time could pair a touch
/// plate with a pointer field.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CFindBarRung {
    /// The control plate's side, in points.
    pub plate: f64,
    /// The glyph inside it, in points.
    pub icon_size: f64,
    /// The query field's width, in points.
    pub field_width: f64,
}

impl From<Rung> for CFindBarRung {
    fn from(rung: Rung) -> Self {
        Self {
            plate: rung.plate,
            icon_size: rung.icon_size,
            field_width: rung.field_width,
        }
    }
}

/// Every fixed word the bar prints, in one delivery.
///
/// ```text
/// 5 × [u32 length][UTF-8 bytes]
/// ```
///
/// In order: the field's placeholder, the previous-match tooltip, the next-match tooltip, the
/// search-all-tabs tooltip, the close tooltip. A bar that is mounted wants all five.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_find_bar_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in [
        PLACEHOLDER,
        PREVIOUS_MATCH_HELP,
        NEXT_MATCH_HELP,
        SEARCH_ALL_TABS_HELP,
        CLOSE_HELP,
    ] {
        push_text(&mut blob, word);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The counter beside the field — `"3 of 12"`, or `0` when there is nothing to count.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// `position` and `total` are read only when `has_position` is set. The query decides whether an
/// absent position prints anything at all, which is why it crosses too: an empty query has no
/// counter, and a query with no matches has one that says so.
///
/// # Safety
/// `query` must be null or `query_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_find_bar_counter(
    has_position: bool,
    position: u32,
    total: u32,
    query: *const c_uchar,
    query_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let query = String::from_utf8_lossy(unsafe { borrow(query, query_len) });
    let Some(text) = find_bar::counter_text(has_position.then_some((position, total)), &query) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, &text);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The bar's three measurements at the caller's input class.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_find_bar_rung(touch: bool) -> CFindBarRung {
    find_bar::rung(touch).into()
}

/// How a mode toggle draws: `0` idle, `1` hovering, `2` on.
///
/// ON outranks HOVER — a pill that is both must not read as merely hovered, because the hover tone
/// is the weaker of the two and the state the user set is the one they need to see.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_find_toggle_appearance(is_on: bool, hovering: bool) -> u8 {
    TogglePillAppearance::resolve(is_on, hovering).code()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::find_bar::{self, TogglePillAppearance};

    use super::{
        slopdesk_ws_find_bar_counter, slopdesk_ws_find_bar_rung, slopdesk_ws_find_bar_words,
        slopdesk_ws_find_toggle_appearance,
    };
    use crate::testing::{delivered, runs};

    #[test]
    fn the_five_fixed_words_cross_in_their_documented_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_find_bar_words(out, cap) }
        });
        let words = runs(&blob, 5);
        let expected = [
            find_bar::PLACEHOLDER,
            find_bar::PREVIOUS_MATCH_HELP,
            find_bar::NEXT_MATCH_HELP,
            find_bar::SEARCH_ALL_TABS_HELP,
            find_bar::CLOSE_HELP,
        ];
        for (index, word) in expected.into_iter().enumerate() {
            assert_eq!(words.get(index).map(String::as_str), Some(word));
        }
    }

    /// Crosses one counter and returns what the near side would read — `None` for §4's `0`.
    fn counter(position: Option<(u32, u32)>, query: &str) -> Option<String> {
        let bytes = query.as_bytes().to_vec();
        let (has, at, total) = position.map_or((false, 0, 0), |(at, total)| (true, at, total));
        let blob = delivered(|out, cap| {
            // SAFETY: `bytes` and `out` are live locals for the call.
            unsafe { slopdesk_ws_find_bar_counter(has, at, total, bytes.as_ptr(), bytes.len(), out, cap) }
        });
        if blob.is_empty() {
            return None;
        }
        runs(&blob, 1).first().cloned()
    }

    #[test]
    fn the_counter_crosses_unchanged_including_its_silence() {
        for query in ["", "  ", "needle"] {
            for position in [None, Some((0, 0)), Some((3, 12))] {
                assert_eq!(
                    counter(position, query),
                    find_bar::counter_text(position, query),
                    "{query:?} at {position:?}",
                );
            }
        }
    }

    #[test]
    fn both_rungs_cross_by_value() {
        for touch in [false, true] {
            let crossed = slopdesk_ws_find_bar_rung(touch);
            let expected = find_bar::rung(touch);
            assert!((crossed.plate - expected.plate).abs() < f64::EPSILON);
            assert!((crossed.icon_size - expected.icon_size).abs() < f64::EPSILON);
            assert!((crossed.field_width - expected.field_width).abs() < f64::EPSILON);
        }
    }

    #[test]
    fn on_outranks_hover_across_the_boundary() {
        for is_on in [false, true] {
            for hovering in [false, true] {
                assert_eq!(
                    slopdesk_ws_find_toggle_appearance(is_on, hovering),
                    TogglePillAppearance::resolve(is_on, hovering).code(),
                );
            }
        }
        assert_eq!(slopdesk_ws_find_toggle_appearance(true, true), 2);
    }
}
