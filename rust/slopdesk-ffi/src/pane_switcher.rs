//! The pane switcher's card, its ring walk and its rows, in C.
//!
//! The rules are `slopdesk_workspace::pane_switcher`; what is here is the marshalling.
//!
//! ## One crossing per ROW, not per field
//!
//! A row's title, its project, its note and the joined place line are four answers to the same
//! three inputs, and a card of ten rows redraws all of them on every ⌃⇥ press. They ride in one
//! delivery for the reason the catalogue doors do: a door per field was measured too expensive
//! inside a `SwiftUI` body, and four crossings could pair one row's title with another's place.

use core::ffi::c_uchar;

use slopdesk_workspace::pane_switcher;

use crate::workspace::{Span, text_of};
use crate::{borrow, deliver, push_text};

/// A walk around the frozen ring, by value.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CPaneSwitcherWalk {
    /// Whether the walk goes forward.
    pub forward: bool,
    /// How many single steps it takes.
    pub steps: usize,
}

/// Every word the card says, in one delivery.
///
/// ```text
/// 5 × [u32 length][UTF-8 bytes]   // `Word::ALL`'s own order
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_switcher_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in pane_switcher::Word::ALL {
        push_text(&mut blob, word.text());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The highest row a number key reaches.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_switcher_highest_shortcut() -> usize {
    pane_switcher::HIGHEST_SHORTCUT
}

/// The card's width in a window `container` points wide — the DESKTOP rung of the measure.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_switcher_width(container: f64) -> f64 {
    pane_switcher::width(container)
}

/// The card's width on a COMPACT screen. Neither desktop bound survives the move; the rule says
/// why.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_switcher_compact_width(container: f64) -> f64 {
    pane_switcher::compact_width(container)
}

/// The tallest the card may stand. An unmeasured container answers infinity — a first layout pass
/// must not clamp the card to zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_switcher_max_height(container: f64) -> f64 {
    pane_switcher::max_height(container)
}

/// How tall the rows stand: their true height, capped where they start to scroll.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_switcher_list_height(rows: usize, row_height: f64, container: f64) -> f64 {
    pane_switcher::list_height(rows, row_height, container)
}

/// The walk from one ring position to another: how many single steps, and which way.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_switcher_walk(
    from: usize,
    to: usize,
    count: usize,
) -> CPaneSwitcherWalk {
    let pane_switcher::Walk { forward, steps } = pane_switcher::walk(from, to, count);
    CPaneSwitcherWalk { forward, steps }
}

/// One row's four readings, in one delivery.
///
/// ```text
/// 4 × [u32 length][UTF-8 bytes]
/// //  the title AS DRAWN, the project, the note, and the two joined into a place line
/// ```
///
/// An EMPTY run is "there is none". A project or a note the rule declines to write is never blank —
/// a blank cwd yields no name at all — so the empty reading cannot collide with a real one.
///
/// Every input is a span into `blob`; an ABSENT span is the caller's `nil`.
///
/// # Safety
/// `(blob, blob_len)` must be readable for the call, and `(out, cap)` writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_switcher_row(
    title: Span,
    project_key: Span,
    cwd: Span,
    process_label: Span,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(blob, blob_len) };
    let (project_key, cwd) = (text_of(project_key, lent), text_of(cwd, lent));
    let project = pane_switcher::project_name(project_key, cwd);
    let note = pane_switcher::note(project_key, cwd);
    let drawn = pane_switcher::unrepeated(
        text_of(title, lent).unwrap_or(""),
        project.as_deref(),
        note.as_deref(),
        text_of(process_label, lent),
    );
    let place = pane_switcher::place_line(project.as_deref(), note.as_deref());
    let mut answer = Vec::new();
    push_text(&mut answer, drawn);
    push_text(&mut answer, project.as_deref().unwrap_or(""));
    push_text(&mut answer, note.as_deref().unwrap_or(""));
    push_text(&mut answer, place.as_deref().unwrap_or(""));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::pane_switcher;

    use super::{
        CPaneSwitcherWalk, slopdesk_ws_pane_switcher_compact_width,
        slopdesk_ws_pane_switcher_highest_shortcut, slopdesk_ws_pane_switcher_list_height,
        slopdesk_ws_pane_switcher_max_height, slopdesk_ws_pane_switcher_row, slopdesk_ws_pane_switcher_walk,
        slopdesk_ws_pane_switcher_width, slopdesk_ws_pane_switcher_words,
    };
    use crate::testing::{delivered, runs};
    use crate::workspace::Span;

    #[test]
    fn every_word_crosses_in_its_own_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_pane_switcher_words(out, cap) }
        });
        let words = runs(&blob, pane_switcher::Word::ALL.len());
        for (index, word) in pane_switcher::Word::ALL.into_iter().enumerate() {
            assert_eq!(
                words.get(index).map(String::as_str),
                Some(word.text()),
                "{word:?}"
            );
        }
        assert_eq!(
            slopdesk_ws_pane_switcher_highest_shortcut(),
            pane_switcher::HIGHEST_SHORTCUT
        );
    }

    #[test]
    fn every_measurement_crosses_unchanged() {
        for container in [0.0_f64, 390.0, 1_200.0, 3_000.0] {
            assert!(
                (slopdesk_ws_pane_switcher_width(container) - pane_switcher::width(container)).abs()
                    < f64::EPSILON
            );
            assert!(
                (slopdesk_ws_pane_switcher_compact_width(container)
                    - pane_switcher::compact_width(container))
                .abs()
                    < f64::EPSILON
            );
            let height = slopdesk_ws_pane_switcher_max_height(container);
            let expected = pane_switcher::max_height(container);
            assert_eq!(height.is_infinite(), expected.is_infinite(), "{container}");
            if expected.is_finite() {
                assert!((height - expected).abs() < f64::EPSILON);
            }
            assert!(
                (slopdesk_ws_pane_switcher_list_height(4, 34.0, container)
                    - pane_switcher::list_height(4, 34.0, container))
                .abs()
                    < f64::EPSILON
            );
        }
    }

    #[test]
    fn the_ring_walk_crosses_as_its_two_halves() {
        for (from, to, count) in [(0_usize, 3_usize, 5_usize), (4, 1, 5), (2, 2, 5), (0, 0, 0)] {
            let expected = pane_switcher::walk(from, to, count);
            assert_eq!(
                slopdesk_ws_pane_switcher_walk(from, to, count),
                CPaneSwitcherWalk {
                    forward: expected.forward,
                    steps: expected.steps,
                },
                "{from}\u{2192}{to} of {count}",
            );
        }
    }

    /// Crosses one row and reads its four answers.
    fn row(title: &str, project_key: Option<&str>, cwd: Option<&str>, process: Option<&str>) -> Vec<String> {
        let mut arena: Vec<u8> = Vec::new();
        let span = |text: Option<&str>, arena: &mut Vec<u8>| {
            text.map_or(
                Span {
                    offset: 0,
                    len: 0,
                    present: false,
                },
                |text| {
                    let offset = arena.len();
                    arena.extend_from_slice(text.as_bytes());
                    Span {
                        offset,
                        len: arena.len() - offset,
                        present: true,
                    }
                },
            )
        };
        let title_span = span(Some(title), &mut arena);
        let key_span = span(project_key, &mut arena);
        let cwd_span = span(cwd, &mut arena);
        let process_span = span(process, &mut arena);
        let blob = delivered(|out, cap| {
            // SAFETY: `arena` and `out` are live locals for the call.
            unsafe {
                slopdesk_ws_pane_switcher_row(
                    title_span,
                    key_span,
                    cwd_span,
                    process_span,
                    arena.as_ptr(),
                    arena.len(),
                    out,
                    cap,
                )
            }
        });
        runs(&blob, 4)
    }

    #[test]
    fn a_rows_four_readings_agree_with_the_rules_that_write_them() {
        let (key, cwd) = (Some("/Users/x/slopdesk"), Some("/Users/x/slopdesk/Sources/UI"));
        let project = pane_switcher::project_name(key, cwd);
        let note = pane_switcher::note(key, cwd);
        let answers = row("zsh", key, cwd, Some("zsh"));
        assert_eq!(answers.first().map(String::as_str), Some("zsh"));
        assert_eq!(answers.get(1).cloned(), project);
        assert_eq!(answers.get(2).cloned(), note);
        assert_eq!(
            answers.get(3).cloned(),
            pane_switcher::place_line(project.as_deref(), note.as_deref()),
        );
    }

    /// The stutter the rule exists for: a title that repeats its own place line.
    #[test]
    fn a_title_that_only_repeats_its_place_yields_to_the_process() {
        let answers = row(
            "UI",
            Some("/Users/x/slopdesk"),
            Some("/Users/x/slopdesk/Sources/UI"),
            Some("zsh"),
        );
        assert_eq!(answers.first().map(String::as_str), Some("zsh"));
    }

    /// A pane with no place at all leaves three empty runs, not a short delivery.
    #[test]
    fn a_placeless_pane_crosses_as_empties() {
        let answers = row("zsh", None, None, None);
        assert_eq!(answers.first().map(String::as_str), Some("zsh"));
        assert_eq!(answers.get(1).map(String::as_str), Some(""));
        assert_eq!(answers.get(2).map(String::as_str), Some(""));
        assert_eq!(answers.get(3).map(String::as_str), Some(""));
    }
}
