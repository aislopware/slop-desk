//! The cross-tab search overlay, in C.
//!
//! The rules are `slopdesk_workspace::global_search`; what is here is the marshalling.
//!
//! ## The excerpt door answers OFFSETS, and that is the point of it
//!
//! A hit inside an excerpt arrives as a range in the near side's own string, and the near side
//! counts UTF-16 code units while Rust counts UTF-8 bytes. Returning the three pieces of a split
//! excerpt as three strings would copy the excerpt across the boundary twice and hand the near side
//! a substring it did not slice itself. Returning BYTE OFFSETS is one crossing, no copy, and the
//! caller slices its own storage.
//!
//! An offset that falls INSIDE a surrogate pair — a range that would cut an emoji in half — is not
//! an offset at all, and the door refuses rather than rounding: the caller draws the flat excerpt,
//! which is what a highlight that cannot be placed should degrade to.

use core::ffi::c_uchar;

use slopdesk_workspace::global_search::{self, ModePill};

use crate::{borrow, deliver, push_text};

/// The overlay's fixed frame, by value.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CSearchPanelSize {
    /// Its width, in points.
    pub width: f64,
    /// Its height, in points.
    pub height: f64,
}

/// One mode pill, in one delivery.
///
/// ```text
/// [u8 underlined]
/// 2 × [u32 length][UTF-8 bytes]   // the pill's glyph text, then its tooltip
/// ```
///
/// The underline is a flag rather than a third word because it is the pill's own decoration —
/// whole-word is the one that wears it — and a caller that received it as text would have to parse
/// its way back to a boolean.
///
/// `0` is "there is no such pill".
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_find_mode_pill(index: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(pill) = ModePill::from_index(index) else {
        return 0;
    };
    let mut blob = vec![u8::from(pill.underlined())];
    push_text(&mut blob, pill.label());
    push_text(&mut blob, pill.help());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Which pills a surface offers, as a bitmask over the pill's own index.
///
/// The overlay drops whole-word; the in-pane bar keeps all three. The mask is over the SHARED
/// index space, so a caller can walk one list of pills and ask this once rather than keeping two
/// orders in step.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_find_mode_pills(global: bool) -> u8 {
    ModePill::offered(global)
}

/// The overlay's fixed frame.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_global_search_panel_size() -> CSearchPanelSize {
    CSearchPanelSize {
        width: global_search::PANEL_WIDTH,
        height: global_search::PANEL_HEIGHT,
    }
}

/// The overlay's fixed words and its two disclosure states, in one delivery.
///
/// ```text
/// 3 × [u32 length][UTF-8 bytes]   // the query prompt, then the collapsed and expanded chevrons
/// ```
///
/// Both disclosure states ride together rather than behind a `collapsed` flag, because a row that
/// can toggle wants both in hand — asking again mid-animation is a crossing per frame.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_global_search_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    push_text(&mut blob, global_search::QUERY_PROMPT);
    push_text(&mut blob, global_search::disclosure_state(true));
    push_text(&mut blob, global_search::disclosure_state(false));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The empty-state line for `query`, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// A blank query and a query with no hits say different things, which is the whole reason the text
/// crosses at all rather than the caller branching on emptiness itself.
///
/// # Safety
/// `query` must be null or `query_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_global_search_empty_line(
    query: *const c_uchar,
    query_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let query = String::from_utf8_lossy(unsafe { borrow(query, query_len) });
    let mut blob = Vec::new();
    push_text(&mut blob, global_search::empty_state_line(&query));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The result summary — `"12 results — 3 tabs"` — or `0` when there is nothing to summarise.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// `counted` says the search finished; a search still running has no total to print, and printing
/// a partial one is a number that goes DOWN as more arrives.
///
/// # Safety
/// `query` must be null or `query_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_global_search_summary(
    counted: bool,
    total_matches: u32,
    tab_count: u32,
    query: *const c_uchar,
    query_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let query = String::from_utf8_lossy(unsafe { borrow(query, query_len) });
    let Some(text) = global_search::summary(counted, total_matches, tab_count, &query) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, &text);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Where a UTF-16 hit range lands in an excerpt's own BYTES, or `false` when it lands nowhere.
///
/// `low` and `high` are UTF-16 code-unit offsets, which is what the near side counts. Both
/// out-parameters are written ONLY on `true`; a caller that reads them after `false` is reading
/// whatever it initialised them to, and the honest answer for a range that cannot be placed is to
/// draw the excerpt flat.
///
/// # Safety
/// `excerpt` must be null or `excerpt_len` live bytes, and both out-parameters must be null or
/// point to one writable `usize` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and all three pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_global_search_excerpt(
    excerpt: *const c_uchar,
    excerpt_len: usize,
    low: usize,
    high: usize,
    out_low: *mut usize,
    out_high: *mut usize,
) -> bool {
    if out_low.is_null() || out_high.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let excerpt = String::from_utf8_lossy(unsafe { borrow(excerpt, excerpt_len) });
    let Some((low, high)) = global_search::excerpt_cuts(&excerpt, low, high) else {
        return false;
    };
    // SAFETY: both were checked non-null above and are writable for one `usize` by the caller's
    // obligation. They may alias each other harmlessly — these are two independent plain writes.
    unsafe {
        out_low.write(low);
        out_high.write(high);
    }
    true
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::global_search::{self, ModePill};

    use super::{
        slopdesk_ws_find_mode_pill, slopdesk_ws_find_mode_pills, slopdesk_ws_global_search_empty_line,
        slopdesk_ws_global_search_excerpt, slopdesk_ws_global_search_panel_size,
        slopdesk_ws_global_search_summary, slopdesk_ws_global_search_words,
    };
    use crate::testing::{delivered, runs};

    #[test]
    fn every_pill_crosses_with_its_decoration_and_its_two_words() {
        for pill in ModePill::ALL {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_find_mode_pill(pill.index(), out, cap) }
            });
            let (flag, rest) = blob
                .split_first()
                .map_or((0xFF, [].as_slice()), |(flag, rest)| (*flag, rest));
            assert_eq!(flag == 1, pill.underlined(), "{pill:?}");
            let words = runs(rest, 2);
            assert_eq!(words.first().map(String::as_str), Some(pill.label()));
            assert_eq!(words.get(1).map(String::as_str), Some(pill.help()));
        }
    }

    #[test]
    fn each_surface_offers_the_pills_the_crate_says_it_does() {
        for global in [false, true] {
            assert_eq!(slopdesk_ws_find_mode_pills(global), ModePill::offered(global));
        }
        assert_eq!(
            slopdesk_ws_find_mode_pills(true),
            0b101,
            "the overlay drops whole-word"
        );
        assert_eq!(slopdesk_ws_find_mode_pills(false), 0b111);
    }

    #[test]
    fn the_overlay_frame_and_its_three_words_cross_unchanged() {
        let size = slopdesk_ws_global_search_panel_size();
        assert!((size.width - global_search::PANEL_WIDTH).abs() < f64::EPSILON);
        assert!((size.height - global_search::PANEL_HEIGHT).abs() < f64::EPSILON);
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_global_search_words(out, cap) }
        });
        let words = runs(&blob, 3);
        assert_eq!(
            words.first().map(String::as_str),
            Some(global_search::QUERY_PROMPT)
        );
        assert_eq!(
            words.get(1).map(String::as_str),
            Some(global_search::disclosure_state(true)),
        );
        assert_eq!(
            words.get(2).map(String::as_str),
            Some(global_search::disclosure_state(false)),
        );
    }

    #[test]
    fn the_empty_line_and_the_summary_cross_unchanged() {
        for query in ["", "   ", "needle"] {
            let bytes = query.as_bytes().to_vec();
            let line = delivered(|out, cap| {
                // SAFETY: `bytes` and `out` are live locals for the call.
                unsafe { slopdesk_ws_global_search_empty_line(bytes.as_ptr(), bytes.len(), out, cap) }
            });
            assert_eq!(
                runs(&line, 1).first().map(String::as_str),
                Some(global_search::empty_state_line(query)),
            );
            for counted in [false, true] {
                let blob = delivered(|out, cap| {
                    // SAFETY: `bytes` and `out` are live locals for the call.
                    unsafe {
                        slopdesk_ws_global_search_summary(
                            counted,
                            12,
                            3,
                            bytes.as_ptr(),
                            bytes.len(),
                            out,
                            cap,
                        )
                    }
                });
                let expected = global_search::summary(counted, 12, 3, query);
                if blob.is_empty() {
                    assert_eq!(expected, None, "{query:?} counted {counted}");
                } else {
                    assert_eq!(runs(&blob, 1).first().cloned(), expected);
                }
            }
        }
    }

    /// Crosses one range and returns the byte pair, or `None` for the refusal.
    fn cuts(excerpt: &str, low: usize, high: usize) -> Option<(usize, usize)> {
        let bytes = excerpt.as_bytes().to_vec();
        let (mut out_low, mut out_high) = (usize::MAX, usize::MAX);
        // SAFETY: `bytes` and both out-parameters are live locals for the call.
        let placed = unsafe {
            slopdesk_ws_global_search_excerpt(
                bytes.as_ptr(),
                bytes.len(),
                low,
                high,
                &raw mut out_low,
                &raw mut out_high,
            )
        };
        placed.then_some((out_low, out_high))
    }

    /// The hazard the door exists for: an ASCII range, a range past an emoji, and a range that
    /// would cut one in half.
    #[test]
    fn a_range_that_cannot_be_placed_is_refused_rather_than_rounded() {
        assert_eq!(cuts("hello world", 6, 11), Some((6, 11)));
        assert_eq!(cuts("a🙂bc", 0, 1), Some((0, 1)));
        // The emoji is TWO UTF-16 units, so 3 lands after it and 2 lands inside it.
        assert_eq!(cuts("a🙂bc", 3, 4), Some((5, 6)));
        assert_eq!(
            cuts("a🙂bc", 2, 4),
            None,
            "an offset inside a surrogate pair is no offset"
        );
        assert_eq!(cuts("hello", 5, 5), Some((5, 5)), "the end is a position too");
        assert_eq!(cuts("hello", 4, 2), None, "an inverted range is not a range");
        assert_eq!(cuts("hello", 0, 99), None);
    }

    /// A refusal writes NOTHING, which is what lets the caller keep its own initial values.
    #[test]
    fn a_refusal_leaves_the_out_parameters_alone() {
        let (mut low, mut high) = (7_usize, 9_usize);
        let bytes = b"hello".to_vec();
        // SAFETY: `bytes` and both out-parameters are live locals for the call.
        let placed = unsafe {
            slopdesk_ws_global_search_excerpt(bytes.as_ptr(), bytes.len(), 4, 2, &raw mut low, &raw mut high)
        };
        assert!(!placed);
        assert_eq!((low, high), (7, 9));
        // SAFETY: null out-parameters are exactly what the door's first guard documents.
        let null = unsafe {
            slopdesk_ws_global_search_excerpt(
                bytes.as_ptr(),
                bytes.len(),
                0,
                1,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
            )
        };
        assert!(!null);
    }

    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_ws_find_mode_pill(9, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
    }
}
