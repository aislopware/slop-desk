//! The in-pane find bar, in C.
//!
//! The rules are `slopdesk_workspace::find_bar`; what is here is the marshalling.
//!
//! Three of §6's shapes at once: the five fixed words cross as a GROUP, the match counter crosses
//! as a group of one because it is built from live text, the touch/pointer rung crosses BY VALUE as
//! three numbers with no interior, and the toggle's appearance crosses as a SCALAR.

use core::ffi::c_uchar;

use slopdesk_workspace::find_bar::{
    self, Action, Arming, CLOSE_HELP, NEXT_MATCH_HELP, PLACEHOLDER, PREVIOUS_MATCH_HELP, Rung,
    SEARCH_ALL_TABS_HELP, TogglePillAppearance,
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

/// The binding-action string the bar sends its surface, as ONE bare run of UTF-8.
///
/// `kind` names the action — `0` search, `1` navigate, `2` end, `3` scroll-to-row — and the other
/// three arguments carry only what that kind reads: `needle` for `0`, `forward` for `1`, `row` for
/// `3`. A kind no action answers to delivers NOTHING, so the near side sends nothing rather than
/// handing libghostty a string it would reject.
///
/// The whole string crosses, needle and all. A door answering `"search:"` for the caller to append
/// to would put one grammar in two languages, which is the drift this door exists to close; the
/// copy is nothing beside the scrollback scan the same keystroke already pays for.
///
/// # Safety
/// `needle` must be null or `needle_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_find_bar_wire(
    kind: u32,
    forward: bool,
    row: u32,
    needle: *const c_uchar,
    needle_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let needle = String::from_utf8_lossy(unsafe { borrow(needle, needle_len) });
    let action = match kind {
        0 => Action::Search { needle: &needle },
        1 => Action::Navigate { forward },
        2 => Action::End,
        3 => Action::ScrollToRow(row),
        _ => return 0,
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(action.wire().as_bytes(), out, cap) }
}

/// What arming the search does: `0` end it, `1` run the query on the surface.
///
/// ⚠️ **The mode flags no longer cross, and a companion door went with them.**
/// `slopdesk_ws_find_bar_row_driven` answered "the surface's matcher cannot express this mode", and
/// the bar then ran its own second scan; `slopdesk_term_surface_find` carries all four modes now,
/// so the only thing left to decide is whether there is anything to search at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_find_bar_arming(query_empty: bool) -> u8 {
    Arming::resolve(query_empty).code()
}

/// Which way vi's `n` / `N` steps: set `repeat_same_way` for `n`, clear it for `N`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_find_bar_nav_forward(
    repeat_same_way: bool,
    search_backward: bool,
) -> bool {
    find_bar::nav_forward(repeat_same_way, search_backward)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::find_bar::{self, Action, Arming, TogglePillAppearance};

    use super::{
        slopdesk_ws_find_bar_arming, slopdesk_ws_find_bar_counter, slopdesk_ws_find_bar_nav_forward,
        slopdesk_ws_find_bar_rung, slopdesk_ws_find_bar_wire, slopdesk_ws_find_bar_words,
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

    /// Crosses one action and returns the string the near side would hand libghostty.
    fn wire(kind: u32, forward: bool, row: u32, needle: &str) -> String {
        let bytes = needle.as_bytes().to_vec();
        let blob = delivered(|out, cap| {
            // SAFETY: `bytes` and `out` are live locals for the call.
            unsafe { slopdesk_ws_find_bar_wire(kind, forward, row, bytes.as_ptr(), bytes.len(), out, cap) }
        });
        // The producer is a Rust `String`, so the bytes cannot be invalid UTF-8.
        String::from_utf8_lossy(&blob).into_owned()
    }

    /// Every spelling survives the crossing — the door is the only place they exist, so this is the
    /// pin that a face reads the grammar it was given.
    #[test]
    fn all_five_binding_actions_cross_verbatim() {
        assert_eq!(
            wire(0, false, 0, "docs"),
            Action::Search { needle: "docs" }.wire()
        );
        assert_eq!(wire(1, true, 0, ""), Action::Navigate { forward: true }.wire());
        assert_eq!(wire(1, false, 0, ""), Action::Navigate { forward: false }.wire());
        assert_eq!(wire(2, false, 0, ""), Action::End.wire());
        assert_eq!(wire(3, false, 42, ""), Action::ScrollToRow(42).wire());
    }

    /// The needle crosses the arena whole — a query with a colon, a space or CJK in it is TEXT, and
    /// a byte lost here would arm libghostty with a different search than the counter counted.
    #[test]
    fn a_needle_is_not_reshaped_by_the_crossing() {
        for needle in ["a: b  c/d", "现在", "", "end_search"] {
            assert_eq!(
                wire(0, false, 0, needle),
                format!("search:{needle}"),
                "{needle:?}"
            );
        }
    }

    /// A kind no action answers to delivers nothing, so the face sends nothing — never an empty
    /// string libghostty would parse as an unknown binding.
    #[test]
    fn an_unknown_kind_delivers_no_string_at_all() {
        for kind in [4, 5, u32::MAX] {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_find_bar_wire(kind, false, 0, core::ptr::null(), 0, out, cap) }
            });
            assert!(blob.is_empty(), "kind {kind} answered");
        }
    }

    /// The empty field is the whole of the arming decision now — the mode flags used to be in it
    /// and are not, because every mode reaches the surface.
    #[test]
    fn the_arming_crosses_as_the_rule_states_it() {
        for query_empty in [false, true] {
            assert_eq!(
                slopdesk_ws_find_bar_arming(query_empty),
                Arming::resolve(query_empty).code(),
                "{query_empty}",
            );
        }
    }

    #[test]
    fn the_vi_direction_crosses_as_the_rule_states_it() {
        for repeat_same_way in [false, true] {
            for search_backward in [false, true] {
                assert_eq!(
                    slopdesk_ws_find_bar_nav_forward(repeat_same_way, search_backward),
                    find_bar::nav_forward(repeat_same_way, search_backward),
                );
            }
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
