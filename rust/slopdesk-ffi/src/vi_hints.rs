//! The vi / copy-mode reference card, in C.
//!
//! The rules are `slopdesk_workspace::vi_hints`; what is here is the marshalling.
//!
//! ## A COLUMN crosses, because a column is what the caller draws
//!
//! Twenty rows across three columns, each carrying a label and between one and four key chips, is
//! sixty-eight strings. A door per string would be sixty-eight crossings inside a view body that
//! re-runs whenever the card's width changes. One door per column answers with the whole column,
//! under `docs/55` §4's retry protocol.
//!
//! ## The chips inside a row are separated, not counted
//!
//! A row's keys ride as ONE run joined by `U+001F`, the unit separator, rather than as a count and
//! `n` runs. Nothing in these tables can contain a control character — they are single keys and
//! two-character chords — so the separator cannot collide with the data, and a fixed two runs per
//! row keeps the near side's walk a plain loop rather than a nested one.
//!
//! The LADDER is the other shape: three measured widths in, one rung out, because only the renderer
//! can measure its own type and only this side decides what the measurement means.

use core::ffi::c_uchar;

use slopdesk_workspace::vi_hints::{
    self, BAR_ACCESSIBILITY_LABEL, Column, EXIT_HELP, Layout, SEPARATOR, VisualMode,
};

use crate::{deliver, push_text};

/// The byte a row's key chips are joined with.
const CHIP_SEPARATOR: char = '\u{1f}';

/// One column's rows, in one delivery.
///
/// ```text
/// [u16 row_count]
/// row_count × 2 × [u32 length][UTF-8 bytes]   // the chips joined by U+001F, then the label
/// ```
///
/// `0` is "there is no such column" — a column index no column has — and never an empty one: every
/// column in the table has rows.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_vi_hint_column(column: u8, out: *mut c_uchar, cap: usize) -> usize {
    let Some(column) = Column::from_index(column) else {
        return 0;
    };
    let rows = column.hints();
    let Ok(count) = u16::try_from(rows.len()) else {
        return 0;
    };
    let mut blob = Vec::from(count.to_be_bytes());
    for row in rows {
        push_text(&mut blob, &row.keys.join(&CHIP_SEPARATOR.to_string()));
        push_text(&mut blob, row.label);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Every fixed word the card prints, in one delivery.
///
/// ```text
/// 6 × [u32 length][UTF-8 bytes]
/// ```
///
/// In order: the range token, the exit help, the card's own accessibility label, then the three
/// column headings in drawn order. They travel together because a card that is mounted wants all
/// six, and the alternative is six doors for six constants.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_vi_hint_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    push_text(&mut blob, SEPARATOR);
    push_text(&mut blob, EXIT_HELP);
    push_text(&mut blob, BAR_ACCESSIBILITY_LABEL);
    for column in Column::ALL {
        push_text(&mut blob, column.heading());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Which arrangement a card of `available` points can afford: `0` three columns, `1` motion beside
/// a stack, `2` one column.
///
/// The three widths are the renderer's own measurement of what each column costs at its intrinsic
/// width, in drawn order.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_vi_hint_layout(
    available: f64,
    gap: f64,
    motion: f64,
    selection: f64,
    search: f64,
) -> u8 {
    vi_hints::layout(available, gap, motion, selection, search).code()
}

/// The columns each of a layout's slots draws, in order.
///
/// ```text
/// [u8 group_count]
/// group_count × ([u8 column_count] column_count × [u8 column_index])
/// ```
///
/// One group is one horizontal slot, and the columns inside it stack vertically. The answer is
/// bytes rather than runs because every value in it is a small index; a length-prefixed text run
/// per column would be framing for framing's sake.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_vi_hint_groups(layout: u8, out: *mut c_uchar, cap: usize) -> usize {
    let groups = Layout::from_code(layout).groups();
    let Ok(count) = u8::try_from(groups.len()) else {
        return 0;
    };
    let mut blob = vec![count];
    for group in groups {
        let Ok(width) = u8::try_from(group.len()) else {
            return 0;
        };
        blob.push(width);
        blob.extend(group.iter().map(|column| column.index()));
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The mode pill's own word and the combined accessibility label it rides in, in one delivery.
///
/// ```text
/// 2 × [u32 length][UTF-8 bytes]   // the pill label, then "Vi mode <label>[ <count>]"
/// ```
///
/// Both, because the pill draws one and announces the other in the same render, and the second is
/// built out of the first — a caller that asked for them separately could print a label the
/// announcement does not match.
///
/// `count` is read only when `has_count` is set; a repeat count of zero is a real count.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_vi_mode_words(
    mode: u8,
    count: u32,
    has_count: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mode = VisualMode::from_index(mode);
    let mut blob = Vec::new();
    push_text(&mut blob, mode.pill_label());
    push_text(
        &mut blob,
        &vi_hints::pill_accessibility_label(mode, has_count.then_some(count)),
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::vi_hints::{self, Column, Layout, VisualMode};

    use super::{
        CHIP_SEPARATOR, slopdesk_ws_vi_hint_column, slopdesk_ws_vi_hint_groups, slopdesk_ws_vi_hint_layout,
        slopdesk_ws_vi_hint_words, slopdesk_ws_vi_mode_words,
    };
    use crate::testing::{delivered, runs};

    /// EVERY row of EVERY column crosses with the chips and the label the table holds.
    #[test]
    fn every_row_of_every_column_matches_the_table() {
        let mut seen = 0;
        for column in Column::ALL {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_vi_hint_column(column.index(), out, cap) }
            });
            let count = blob
                .iter()
                .take(2)
                .fold(0_usize, |width, byte| width << 8 | usize::from(*byte));
            assert_eq!(count, column.hints().len(), "row count for {column:?}");
            let fields = runs(blob.get(2..).unwrap_or_default(), count * 2);
            for (index, row) in column.hints().iter().enumerate() {
                assert_eq!(
                    fields.get(index * 2).map(String::as_str),
                    Some(row.keys.join(&CHIP_SEPARATOR.to_string()).as_str()),
                );
                assert_eq!(fields.get(index * 2 + 1).map(String::as_str), Some(row.label));
                seen += 1;
            }
        }
        assert_eq!(
            seen, 20,
            "the corpus walked {seen} rows — this gate stopped reading"
        );
    }

    /// The chips split back apart on the separator, and no chip contains one.
    #[test]
    fn no_chip_contains_the_separator_it_is_joined_with() {
        for key in vi_hints::advertised_keys() {
            assert!(!key.contains(CHIP_SEPARATOR), "{key} would split itself");
        }
    }

    #[test]
    fn the_six_fixed_words_cross_in_their_documented_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_vi_hint_words(out, cap) }
        });
        let words = runs(&blob, 6);
        assert_eq!(words.first().map(String::as_str), Some(vi_hints::SEPARATOR));
        assert_eq!(words.get(1).map(String::as_str), Some(vi_hints::EXIT_HELP));
        assert_eq!(
            words.get(2).map(String::as_str),
            Some(vi_hints::BAR_ACCESSIBILITY_LABEL),
        );
        for (offset, column) in Column::ALL.into_iter().enumerate() {
            assert_eq!(words.get(3 + offset).map(String::as_str), Some(column.heading()));
        }
    }

    /// The rung the door answers is the rung the crate answers, at both boundaries.
    #[test]
    fn the_ladder_crosses_unchanged() {
        for available in [0.0, 100.0, 178.0, 179.0, 258.0, 259.0, 1000.0] {
            let crossed = slopdesk_ws_vi_hint_layout(available, 8.0, 100.0, 80.0, 70.0);
            assert_eq!(
                crossed,
                vi_hints::layout(available, 8.0, 100.0, 80.0, 70.0).code(),
                "at {available}",
            );
        }
    }

    #[test]
    fn every_rung_delivers_its_own_grouping() {
        for code in 0..3_u8 {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_vi_hint_groups(code, out, cap) }
            });
            let expected = Layout::from_code(code).groups();
            let mut cursor = 1;
            assert_eq!(blob.first().copied(), u8::try_from(expected.len()).ok());
            for group in expected {
                let width = blob.get(cursor).copied().unwrap_or_default();
                assert_eq!(usize::from(width), group.len());
                cursor += 1;
                let indices: Vec<u8> = group.iter().map(|column| column.index()).collect();
                assert_eq!(blob.get(cursor..cursor + group.len()), Some(indices.as_slice()));
                cursor += group.len();
            }
            assert_eq!(cursor, blob.len(), "the walk must land exactly on the end");
        }
    }

    #[test]
    fn the_pill_word_and_its_announcement_cross_together() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_vi_mode_words(1, 5, true, out, cap) }
        });
        let words = runs(&blob, 2);
        assert_eq!(words.first().map(String::as_str), Some("VISUAL"));
        assert_eq!(words.get(1).map(String::as_str), Some("Vi mode VISUAL 5"));
        let bare = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_vi_mode_words(0, 7, false, out, cap) }
        });
        assert_eq!(runs(&bare, 2).get(1).map(String::as_str), Some("Vi mode VI"));
        assert_eq!(VisualMode::from_index(0).pill_label(), "VI");
    }

    /// A column index no column has is no column at all — §4's `0` used for its literal meaning.
    #[test]
    fn nothing_is_read_past_the_end() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_ws_vi_hint_column(9, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
    }
}
